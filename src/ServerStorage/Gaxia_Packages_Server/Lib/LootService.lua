--!strict
-- ─────────────────────────────────────────────────────────────
-- LootService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/LootService
-- Purpose : Weighted drop tables with PERSISTED pity. Loot boxes / harvest /
--           enemy drops re-roll their own math.random and either have no pity
--           (feels rigged) or pity that resets on rejoin (exploitable). Loot
--           defines weighted tables, rolls server-side, and tracks a per-table
--           miss counter in the profile so a Pity-guaranteed entry is forced
--           within N rolls — surviving rejoins. GetDropRates exposes the honest
--           odds, and every roll feeds Gaxia.Codex.Discover so collection logs
--           stay in sync. PickWeighted is a pure, seed-testable core.
--
-- Access  : Gaxia.Loot  (server)
--   Gaxia.Loot.DefineTable("Chest", { {Item="Common",Weight=80}, {Item="Epic",Weight=1,Pity=50} })
--   local drop = Gaxia.Loot.Roll(player, "Chest")   -- {Item, viaPity}
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages"):WaitForChild("init")) :: any
local Signal = SharedPkg.Signal

local GaxiaServer: any = nil
local function server(): any
	if not GaxiaServer then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server"):WaitForChild("init")
		GaxiaServer = require(serverInit :: any)
	end
	return GaxiaServer
end

local PITY_KEY : string = "LootPity"

export type LootEntry = { Item: string, Weight: number, Pity: number? }
export type Drop = { Item: string, viaPity: boolean }

local LootService = {}

LootService.OnDrop = Signal.new() -- (player, tableId, item, viaPity)

local tables: { [string]: { LootEntry } } = {}
local rng = Random.new()

-- ── PURE: pick an index from weights given a roll in [0,1) (seed-testable) ──
function LootService.PickWeighted(weights: { number }, roll01: number): number
	local total = 0
	for _, w in ipairs(weights) do
		total += math.max(0, w)
	end
	if total <= 0 then
		return 1
	end
	local target = roll01 * total
	local acc = 0
	for i, w in ipairs(weights) do
		acc += math.max(0, w)
		if target < acc then
			return i
		end
	end
	return #weights
end

-- ── Table registry ──

function LootService.DefineTable(tableId: string, entries: { LootEntry }): ()
	tables[tableId] = entries
end

function LootService.GetTable(tableId: string): { LootEntry }?
	return tables[tableId]
end

-- Honest base odds (item → probability 0..1) from the weights. Pity is a
-- separate guarantee on top, not folded into these numbers.
function LootService.GetDropRates(tableId: string): { [string]: number }
	local entries = tables[tableId]
	local rates: { [string]: number } = {}
	if not entries then
		return rates
	end
	local total = 0
	for _, e in ipairs(entries) do
		total += math.max(0, e.Weight)
	end
	for _, e in ipairs(entries) do
		rates[e.Item] = if total > 0 then math.max(0, e.Weight) / total else 0
	end
	return rates
end

-- ── Pity persistence ──

local function loadPity(player: Player): { [string]: any }
	local p = server().Data.Get(player, PITY_KEY)
	return (typeof(p) == "table") and p or {}
end

local function savePity(player: Player, p: { [string]: any }): ()
	server().Data.Set(player, PITY_KEY, p)
end

function LootService.GetPity(player: Player, tableId: string, item: string): number
	local tp = loadPity(player)[tableId]
	return (typeof(tp) == "table" and tp[item]) or 0
end

-- ── Roll ──

function LootService.Roll(player: Player, tableId: string): Drop?
	local entries = tables[tableId]
	if not entries or #entries == 0 then
		return nil
	end

	local pity = loadPity(player)
	local tp = pity[tableId]
	if typeof(tp) ~= "table" then
		tp = {}
		pity[tableId] = tp
	end

	-- Tick every pity entry's miss counter; flag the first that hit its guarantee.
	local forced: LootEntry? = nil
	for _, e in ipairs(entries) do
		if e.Pity then
			tp[e.Item] = (tp[e.Item] or 0) + 1
			if not forced and tp[e.Item] >= e.Pity then
				forced = e
			end
		end
	end

	local chosen: LootEntry
	local viaPity = false
	if forced then
		chosen = forced
		viaPity = true
	else
		local weights: { number } = {}
		for i, e in ipairs(entries) do
			weights[i] = e.Weight
		end
		chosen = entries[LootService.PickWeighted(weights, rng:NextNumber())]
	end

	-- Drawing a pity entry (forced or lucky) resets its counter.
	if chosen.Pity then
		tp[chosen.Item] = 0
	end
	savePity(player, pity)

	pcall(function()
		server().Codex.Discover(player, chosen.Item)
	end)
	LootService.OnDrop:Fire(player, tableId, chosen.Item, viaPity)
	return { Item = chosen.Item, viaPity = viaPity }
end

return LootService
