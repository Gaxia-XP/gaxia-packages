--!strict
-- ─────────────────────────────────────────────────────────────
-- CodexService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/CodexService
-- Purpose : Collection / Pokédex registry — the spine of collect-em-all genres
--           (bestiary, fish-dex, sticker album, mount log). A global catalog
--           defines entries (rarity, set membership); per player it tracks
--           discovered count + first-seen time, completion %, and fires once
--           when a defined set is fully collected (set reward). Persisted under
--           the "Codex" profile key. Named "Codex" to avoid colliding with
--           Roblox's CollectionService.
--
-- Access  : Gaxia.Codex  (server)
--   Gaxia.Codex.Register("Goldfish", { Rarity = "Common", Set = "Pond" })
--   local r = Gaxia.Codex.Discover(player, "Goldfish")   -- {isNew, count}
--   Gaxia.Codex.GetCompletion(player)                    -- 0..1
-- ─────────────────────────────────────────────────────────────
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Shared      = ReplicatedStorage.Gaxia_Packages.Shared
local Signal      = require(Shared.Signal)
local Lifecycle   = require(script.Parent.ServiceLifecycle)
local DataManager = require(script.Parent.DataManager)

local PROFILE_KEY : string = "Codex"
local SETS_FIELD  : string = "__sets" -- reserved sub-key tracking already-completed sets

export type EntryDef = { Rarity: string?, Set: string? }
export type EntryState = { count: number, firstSeen: number }
export type DiscoverResult = { isNew: boolean, count: number }

local CodexService = {}

-- (player, entryId, isNew) on every Discover
CodexService.OnDiscover = Signal.new() :: Signal.Signal<Player, string, boolean>
-- (player, setName, reward) once per set, the first time all its entries are collected
CodexService.OnSetComplete = Signal.new() :: Signal.Signal<Player, string, any>

-- ── Global catalog (registered at startup; not per-player) ──
-- Module-level so registrations made by other services (e.g. PetService's Init)
-- persist whatever order services start in.
local catalog: { [string]: EntryDef } = {}
local sets: { [string]: { entries: { string }, reward: any } } = {}

-- ── Catalog registration ──

function CodexService.Register(entryId: string, def: EntryDef?): ()
	catalog[entryId] = def or {}
end

function CodexService.RegisterMany(defs: { [string]: EntryDef }): ()
	for id, d in pairs(defs) do
		catalog[id] = d
	end
end

function CodexService.DefineSet(setName: string, entryIds: { string }, reward: any?): ()
	sets[setName] = { entries = entryIds, reward = reward }
end

function CodexService.IsRegistered(entryId: string): boolean
	return catalog[entryId] ~= nil
end

function CodexService.GetCatalogSize(): number
	local n = 0
	for _ in pairs(catalog) do
		n += 1
	end
	return n
end

-- ── Per-player persistence ──

local function load(player: Player): { [string]: any }
	local c = DataManager.Get(player, PROFILE_KEY)
	return (typeof(c) == "table") and c or {}
end

local function save(player: Player, c: { [string]: any }): boolean
	return DataManager.Set(player, PROFILE_KEY, c) == true
end

local function entryOf(c: { [string]: any }, entryId: string): EntryState?
	local e = c[entryId]
	if typeof(e) == "table" and entryId ~= SETS_FIELD then
		return e :: EntryState
	end
	return nil
end

local function isSetCompleteWith(c: { [string]: any }, setName: string): boolean
	local s = sets[setName]
	if not s then
		return false
	end
	for _, id in ipairs(s.entries) do
		if entryOf(c, id) == nil then
			return false
		end
	end
	return true
end

-- Fire OnSetComplete once per set, the first time all its entries are owned.
local function checkSets(player: Player, c: { [string]: any }): boolean
	local completedTable = c[SETS_FIELD]
	if typeof(completedTable) ~= "table" then
		completedTable = {}
		c[SETS_FIELD] = completedTable
	end
	local changed = false
	for name, s in pairs(sets) do
		if not completedTable[name] and isSetCompleteWith(c, name) then
			completedTable[name] = true
			changed = true
			CodexService.OnSetComplete:Fire(player, name, s.reward)
		end
	end
	return changed
end

-- ── Public per-player API ──

-- Record that `player` collected `entryId` (+amount). Returns {isNew, count}.
function CodexService.Discover(player: Player, entryId: string, amount: number?): DiscoverResult
	if catalog[entryId] == nil then
		catalog[entryId] = {} -- auto-register so unknown drops still log
	end
	local amt = math.max(1, math.floor(amount or 1))
	local c = load(player)
	local e = entryOf(c, entryId)
	local isNew = e == nil
	if isNew then
		e = { count = 0, firstSeen = os.time() }
		c[entryId] = e
	end
	;(e :: EntryState).count += amt
	if isNew then
		checkSets(player, c)
	end
	save(player, c)
	CodexService.OnDiscover:Fire(player, entryId, isNew)
	return { isNew = isNew, count = (e :: EntryState).count }
end

function CodexService.Has(player: Player, entryId: string): boolean
	return entryOf(load(player), entryId) ~= nil
end

function CodexService.GetCount(player: Player, entryId: string): number
	local e = entryOf(load(player), entryId)
	return e and e.count or 0
end

function CodexService.GetEntry(player: Player, entryId: string): EntryState?
	return entryOf(load(player), entryId)
end

function CodexService.GetDiscoveredCount(player: Player): number
	local c = load(player)
	local n = 0
	for id in pairs(c) do
		if id ~= SETS_FIELD and catalog[id] ~= nil then
			n += 1
		end
	end
	return n
end

-- Fraction of the catalog discovered (0..1).
function CodexService.GetCompletion(player: Player): number
	local total = CodexService.GetCatalogSize()
	if total == 0 then
		return 0
	end
	return CodexService.GetDiscoveredCount(player) / total
end

function CodexService.IsSetComplete(player: Player, setName: string): boolean
	return isSetCompleteWith(load(player), setName)
end

-- Pure registry: nothing to set up. Registered so Features / IsEnabled know it.
Lifecycle.Define(CodexService, {
	Name = "Codex",
	Needs = {},
})

return CodexService
