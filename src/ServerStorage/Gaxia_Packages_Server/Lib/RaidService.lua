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
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
-- Protection / Cooldown / Vault / Economy / Data are only called from CanRaid and
-- Resolve (call time), so they are plain requires, not lifecycle Needs.
local Shared            = ReplicatedStorage.Gaxia_Packages.Shared
local Signal            = require(Shared.Signal)
local Lifecycle         = require(script.Parent.ServiceLifecycle)
local Config            = require(script.Parent.Parent.Config)
local EConfig           = require(script.Parent.EffectiveConfig)
local DataManager       = require(script.Parent.DataManager)
local EconomyService    = require(script.Parent.EconomyService)
local CooldownService   = require(script.Parent.CooldownService)
local ProtectionService = require(script.Parent.ProtectionService)
local VaultService      = require(script.Parent.VaultService)

local REVENGE_KEY    : string = "RaidRevenge"

export type RaidConfig = {
	Currency: string,
	Cooldown: number,           -- attacker re-raid cooldown (s)
	RevengeProtection: number,  -- defender shield after being raided (s)
	LootFraction: number,       -- fraction of defender vault value that's lootable
	MaxLoot: number,            -- hard cap per raid
}
export type RaidState = { id: string, attacker: Player, defender: Player, startedAt: number }
export type RaidSummary = { success: boolean, loot: number }
-- Why CanRaid / Start refused a raid.
export type RaidRefusal = "cannot raid self" | "target protected" | "on cooldown" | "already in a raid"
-- Partial override bag for Configure (any subset of Config.Raid's keys).
export type RaidOverrides = {
	Currency: string?,
	Cooldown: number?,
	RevengeProtection: number?,
	LootFraction: number?,
	MaxLoot: number?,
	RevengeMax: number?,
	[string]: any,
}

local RaidService = {}

-- (attacker, defender, raidId) after Start opens a raid
RaidService.OnRaidStart = Signal.new() :: Signal.Signal<Player, Player, string>
-- (attacker, defender, success, loot) after Resolve closes it; loot = currency moved
RaidService.OnRaidEnd = Signal.new() :: Signal.Signal<Player, Player, boolean, number>

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
	local raidConfig = Config.Raid :: { [string]: any }
	return EConfig.Get(`Raid.{key}`, raidConfig[key] or DEFAULTS[key] or fallback)
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

function RaidService.Configure(partial: RaidOverrides): ()
	for k, v in pairs(partial) do
		config[k] = v
	end
end

local function cooldownKey(player: Player): string
	return `Raid:{player.UserId}`
end

-- ── Revenge list (persisted on the defender) ──

local function addRevenge(defender: Player, attackerUserId: number): ()
	local list = DataManager.Get(defender, REVENGE_KEY)
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
	DataManager.Set(defender, REVENGE_KEY, trimmed)
end

function RaidService.GetRevengeTargets(player: Player): { number }
	local list = DataManager.Get(player, REVENGE_KEY)
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

function RaidService.IsRaiding(player: Player): boolean
	return playerRaid[player.UserId] ~= nil
end

function RaidService.GetActiveRaid(player: Player): RaidState?
	local id = playerRaid[player.UserId]
	return id and activeRaids[id]
end

-- ── Gate ──

function RaidService.CanRaid(attacker: Player, defender: Player): (boolean, RaidRefusal | "ok")
	if attacker.UserId == defender.UserId then
		return false, "cannot raid self"
	end
	if ProtectionService.IsProtected(defender) then
		return false, "target protected"
	end
	if CooldownService.IsActive(cooldownKey(attacker)) then
		return false, "on cooldown"
	end
	if playerRaid[attacker.UserId] or playerRaid[defender.UserId] then
		return false, "already in a raid"
	end
	return true, "ok"
end

-- ── Start ──
-- Gameplay API (opens a raid), not a lifecycle hook — see Lifecycle.Define below.

function RaidService.Start(attacker: Player, defender: Player): (string?, RaidRefusal?)
	local ok, err = RaidService.CanRaid(attacker, defender)
	if not ok then
		return nil, err :: RaidRefusal
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

	local currency = raidGet("Currency")
	local loot = 0
	if success then
		local cap = RaidService.ComputeLoot(
			VaultService.GetValue(defender),
			EconomyService.Get(defender, currency),
			raidGet("LootFraction"),
			raidGet("MaxLoot")
		)
		if cap > 0 then
			-- Debit defender first; only keep it if the attacker credit lands.
			-- NOTE: deliberately NO pet Coins multiplier here — raid loot is a
			-- zero-sum TRANSFER (defender loses `cap`, attacker gains `cap`).
			-- Multiplying the credit would MINT currency; pets boost generated
			-- faucets (Idle / Quest), never transfers.
			if EconomyService.Spend(defender, currency, cap) then
				if EconomyService.Add(attacker, currency, cap) then
					loot = cap
				else
					EconomyService.Add(defender, currency, cap) -- refund — no dupe/loss
				end
			end
		end
		addRevenge(defender, attacker.UserId)
	end

	-- Defender gets a revenge shield; attacker goes on cooldown.
	ProtectionService.Grant(defender, raidGet("RevengeProtection"))
	CooldownService.Start(cooldownKey(attacker), raidGet("Cooldown"))

	-- Tear down the active-raid bookkeeping.
	playerRaid[attacker.UserId] = nil
	playerRaid[defender.UserId] = nil
	activeRaids[raidId] = nil

	RaidService.OnRaidEnd:Fire(attacker, defender, success, loot)
	return true, { success = success, loot = loot }
end

-- Pure API (raid state lives in memory, created on use): nothing to set up.
-- RaidService.Start above is the gameplay API; this spec has no lifecycle hooks.
Lifecycle.Define(RaidService, {
	Name = "Raid",
	Needs = {},
})

return RaidService
