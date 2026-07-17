--!strict
-- ─────────────────────────────────────────────────────────────
-- RaidService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/RaidService
-- Purpose : Raid / heist state machine — the highest-exploit-surface system, so
--           it sits last on top of verified primitives. Start() gates a hit on
--           self / target-shield (Gaxia.Protection) / attacker cooldown (Gaxia.
--           Cooldown) / one-raid-at-a-time, then tracks the active raid. Resolve
--           moves loot ATOMICALLY: the steal is capped by the defender's Gaxia.
--           Vault value, debited via Economy.Spend, and credited via Economy.Add
--           — if the credit fails the defender is refunded (no currency dupe or
--           loss). The defender then gets a revenge shield, the attacker a
--           cooldown, and the attacker lands on the defender's revenge list.
--
-- Access  : Gaxia.Raid  (server)
--   local id, err = Gaxia.Raid.Start(attacker, defender)
--   local ok, summary = Gaxia.Raid.Resolve(id, true)   -- summary.loot
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal = SharedPkg.Signal

local GaxiaServer: any = nil
local function server(): any
	if not GaxiaServer then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server")
		GaxiaServer = require(serverInit :: any)
	end
	return GaxiaServer
end

local REVENGE_KEY    : string = "RaidRevenge"

export type RaidConfig = {
	Currency: string,
	Cooldown: number,           -- attacker re-raid cooldown (s)
	RevengeProtection: number,  -- defender shield after being raided (s)
	LootFraction: number,       -- fraction of defender vault value that's lootable
	MaxLoot: number,            -- hard cap per raid
}
export type RaidState = { id: string, attacker: any, defender: any, startedAt: number }
export type RaidSummary = { success: boolean, loot: number }

local RaidService = {}

RaidService.OnRaidStart = Signal.new() -- (attacker, defender, raidId)
RaidService.OnRaidEnd = Signal.new()   -- (attacker, defender, success, loot)

-- Runtime override bag (set via Configure()). Precedence for any setting:
--   Configure() override  >  Flag override (EConfig)  >  Config.Raid default  >  hardcoded fallback
local config: { [string]: any } = {}

local DEFAULTS: { [string]: any } = {
	Currency = "Coins", Cooldown = 300, RevengeProtection = 600,
	LootFraction = 0.1, MaxLoot = 1_000_000, RevengeMax = 20,
}

local function raidGet(key: string, fallback: any?): any
	if config[key] ~= nil then
		return config[key]
	end
	local s = server()
	return s.EConfig.Get(`Raid.{key}`, (s.Config.Raid or {})[key] or DEFAULTS[key] or fallback)
end

local activeRaids: { [string]: RaidState } = {}
local playerRaid: { [number]: string } = {} -- userId → raidId (both parties)
local seq = 0

-- ── PURE: how much can actually be stolen this raid ──
function RaidService.ComputeLoot(vaultValue: number, defenderBalance: number, fraction: number, maxLoot: number): number
	local cap = math.floor(math.max(0, vaultValue) * fraction)
	return math.min(cap, math.max(0, defenderBalance), maxLoot)
end

-- ── Config ──

function RaidService.Configure(partial: { [string]: any }): ()
	for k, v in pairs(partial) do
		(config :: any)[k] = v
	end
end

local function cooldownKey(player: any): string
	return `Raid:{player.UserId}`
end

-- ── Revenge list (persisted on the defender) ──

local function addRevenge(defender: any, attackerUserId: number): ()
	local Data = server().Data
	local list = Data.Get(defender, REVENGE_KEY)
	if typeof(list) ~= "table" then
		list = {}
	end
	table.insert(list, 1, attackerUserId)
	-- de-dup + trim
	local seen: { [number]: boolean } = {}
	local trimmed: { number } = {}
	for _, uid in ipairs(list) do
		if not seen[uid] and #trimmed < raidGet("RevengeMax") then
			seen[uid] = true
			table.insert(trimmed, uid)
		end
	end
	Data.Set(defender, REVENGE_KEY, trimmed)
end

function RaidService.GetRevengeTargets(player: any): { number }
	local list = server().Data.Get(player, REVENGE_KEY)
	if typeof(list) ~= "table" then
		return {}
	end
	local out: { number } = {}
	for _, uid in ipairs(list) do
		table.insert(out, uid)
	end
	return out
end

-- ── State queries ──

function RaidService.IsRaiding(player: any): boolean
	return playerRaid[player.UserId] ~= nil
end

function RaidService.GetActiveRaid(player: any): RaidState?
	local id = playerRaid[player.UserId]
	return id and activeRaids[id]
end

-- ── Gate ──

function RaidService.CanRaid(attacker: any, defender: any): (boolean, string)
	if attacker.UserId == defender.UserId then
		return false, "cannot raid self"
	end
	if server().Protection.IsProtected(defender) then
		return false, "target protected"
	end
	if server().Cooldown.IsActive(cooldownKey(attacker)) then
		return false, "on cooldown"
	end
	if playerRaid[attacker.UserId] or playerRaid[defender.UserId] then
		return false, "already in a raid"
	end
	return true, "ok"
end

-- ── Start ──

function RaidService.Start(attacker: any, defender: any): (string?, string?)
	local ok, err = RaidService.CanRaid(attacker, defender)
	if not ok then
		return nil, err
	end
	seq += 1
	local raidId = `raid_{seq}`
	activeRaids[raidId] = { id = raidId, attacker = attacker, defender = defender, startedAt = os.time() }
	playerRaid[attacker.UserId] = raidId
	playerRaid[defender.UserId] = raidId
	RaidService.OnRaidStart:Fire(attacker, defender, raidId)
	return raidId, nil
end

-- ── Resolve (atomic loot move + revenge shield + cooldown) ──

function RaidService.Resolve(raidId: string, success: boolean): (boolean, RaidSummary)
	local raid = activeRaids[raidId]
	if not raid then
		return false, { success = false, loot = 0 }
	end
	local attacker, defender = raid.attacker, raid.defender
	local Economy = server().Economy
	local Vault = server().Vault

	local currency = raidGet("Currency")
	local loot = 0
	if success then
		local cap = RaidService.ComputeLoot(
			Vault.GetValue(defender),
			Economy.Get(defender, currency),
			raidGet("LootFraction"),
			raidGet("MaxLoot")
		)
		if cap > 0 then
			-- Debit defender first; only keep it if the attacker credit lands.
			-- NOTE: deliberately NO pet Coins multiplier here — raid loot is a
			-- zero-sum TRANSFER (defender loses `cap`, attacker gains `cap`).
			-- Multiplying the credit would MINT currency; pets boost generated
			-- faucets (Idle / Quest), never transfers.
			if Economy.Spend(defender, currency, cap) then
				if Economy.Add(attacker, currency, cap) then
					loot = cap
				else
					Economy.Add(defender, currency, cap) -- refund — no dupe/loss
				end
			end
		end
		addRevenge(defender, attacker.UserId)
	end

	-- Defender gets a revenge shield; attacker goes on cooldown.
	server().Protection.Grant(defender, raidGet("RevengeProtection"))
	server().Cooldown.Start(cooldownKey(attacker), raidGet("Cooldown"))

	-- Tear down the active-raid bookkeeping.
	playerRaid[attacker.UserId] = nil
	playerRaid[defender.UserId] = nil
	activeRaids[raidId] = nil

	RaidService.OnRaidEnd:Fire(attacker, defender, success, loot)
	return true, { success = success, loot = loot }
end

return RaidService
