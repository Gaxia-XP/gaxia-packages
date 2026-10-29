--!strict
-- ─────────────────────────────────────────────────────────────
-- PetService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/PetService
-- Purpose : Stat-boost pet system (MVP). Players hatch pets from weighted eggs
--           (Gaxia.Loot, with pity), own them per-profile, and equip up to N at
--           once; each equipped pet contributes an ADDITIVE Coins multiplier.
--           The faucet is intentionally NOT wired here — a game reads
--           GetCoinMultiplier(player) and multiplies its OWN coin grants. Pets
--           are STAT-ONLY this pass (no 3D follow model). Pet definitions live
--           in Gaxia.ItemDef (category "Pet"); every hatch auto-logs to
--           Gaxia.Codex via Loot.Roll. Owned + equipped persist under the "Pets"
--           profile key (outside DEFAULT_PROFILE, same pattern as Inventory).
--           Games add pets and eggs with RegisterPet / RegisterEgg (8 pets and
--           "BasicEgg" are built in). Every server-side change (GrantPet, BuyEgg,
--           Equip, Unequip, RemovePet, Register*) pushes PetSync (and BuyEgg
--           PetHatch) to the client, so the panel never shows stale pets.
--
-- Access  : Gaxia.Pet  (server)
--   local mult = Gaxia.Pet.GetCoinMultiplier(player)  -- 1 + Σ equipped coinBonus
--   local ok, petId = Gaxia.Pet.BuyEgg(player, "BasicEgg")
--   Gaxia.Pet.Equip(player, uid)
--   Gaxia.Pet.RegisterPet({ id = "pet_Unicorn", displayName = "Unicorn", rarity = "legendary", coinBonus = 2 })
--   Gaxia.Pet.RegisterEgg({ id = "GoldenEgg", cost = 500, pets = { { petId = "pet_Unicorn", weight = 1 } } })
--
-- Lifecycle: Init registers the catalog into ItemDef / Loot / Codex and the client
--            remotes (PetGetState, PetBuyEgg, PetEquip, PetUnequip, PetSync,
--            PetHatch) — listed in Features, so they exist before any player joins.
-- ─────────────────────────────────────────────────────────────
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Shared         = ReplicatedStorage.Gaxia_Packages.Shared
local Signal         = require(Shared.Signal)
local Net            = require(Shared.NetService)
local Guard          = require(Shared.Guard)
local Lifecycle      = require(script.Parent.ServiceLifecycle)
local Config         = require(script.Parent.Parent.Config)
local EConfig        = require(script.Parent.EffectiveConfig)
local DataManager    = require(script.Parent.DataManager)
local EconomyService = require(script.Parent.EconomyService)
-- Init registers the pet catalog into these three (they are Needs).
local ItemDefinitionService = require(script.Parent.ItemDefinitionService)
local LootService           = require(script.Parent.LootService)
local CodexService          = require(script.Parent.CodexService)

-- ── Constants ──
local PETS_KEY         : string = "Pets"       -- profile key (outside DEFAULT_PROFILE, like Inventory's "Inv")
local PET_CATEGORY     : string = "Pet"        -- ItemDef category for the roster
local CODEX_SET        : string = "Pets"       -- Codex set name for the collection index
local EGG_TABLE_ID     : string = "BasicEgg"   -- Loot table id
local EGG_CURRENCY     : string = "Coins"      -- currency an egg costs
local DEFAULT_EGG_COST : number = 100          -- ultimate fallback if Config absent
local DEFAULT_SLOTS    : number = 3            -- ultimate fallback if Config absent
local MAX_UID_LEN      : number = 64           -- reject client uid payloads longer than any legit "u_<n>"
local MAX_ID_LEN       : number = 64           -- longest pet / egg id RegisterPet / RegisterEgg accept

-- Effective tunables: runtime Flag override <- Config.Pets default <- fallback.
-- Read per call so an admin `/flag set Pets.X` applies live.
local function configuredSlots(): any
	return EConfig.Get("Pets.MaxEquipSlots", Config.Pets.MaxEquipSlots or DEFAULT_SLOTS)
end
local function configuredEggCost(): any
	return EConfig.Get("Pets.EggCost", Config.Pets.EggCost or DEFAULT_EGG_COST)
end

-- ── Pet catalog (MVP roster) ──
-- `coinBonus` is ADDITIVE: equipping a +0.05 pet makes GetCoinMultiplier 1.05;
-- equipping three +0.05 pets makes it 1.15. `weight`/`pity` feed the egg's Loot
-- table. `icon` is PROVISIONAL ("" → the client renders a placeholder image plus
-- the always-visible name label, so a slot is never blank). Swap in real
-- rbxassetid pet art here once assets are sourced.
export type PetRarity = "common" | "uncommon" | "rare" | "epic" | "legendary"

export type PetDef = {
	displayName: string,
	rarity: PetRarity,
	coinBonus: number,
	weight: number,
	pity: number?,
	icon: string,
}

local PET_DEFS: { [string]: PetDef } = { -- built-in roster; RegisterPet adds to it
	pet_Cat     = { displayName = "Cat",     rarity = "common",    coinBonus = 0.05, weight = 40,  icon = "" },
	pet_Dog     = { displayName = "Dog",     rarity = "common",    coinBonus = 0.05, weight = 30,  icon = "" },
	pet_Bunny   = { displayName = "Bunny",   rarity = "uncommon",  coinBonus = 0.10, weight = 12,  icon = "" },
	pet_Fox     = { displayName = "Fox",     rarity = "uncommon",  coinBonus = 0.12, weight = 10,  icon = "" },
	pet_Panda   = { displayName = "Panda",   rarity = "rare",      coinBonus = 0.20, weight = 4,   icon = "" },
	pet_Penguin = { displayName = "Penguin", rarity = "rare",      coinBonus = 0.25, weight = 3,   icon = "" },
	pet_Tiger   = { displayName = "Tiger",   rarity = "epic",      coinBonus = 0.40, weight = 1.5, icon = "" },
	pet_Dragon  = { displayName = "Dragon",  rarity = "legendary", coinBonus = 1.00, weight = 0.5, pity = 50, icon = "" },
}

-- Stable display/iteration order (rarity ascending). Loot weighting is
-- order-independent, but the egg table + client grid read this for determinism.
-- RegisterPet inserts new ids after the last pet of the same or a lower rarity.
local PET_ORDER: { string } = {
	"pet_Cat", "pet_Dog", "pet_Bunny", "pet_Fox", "pet_Panda", "pet_Penguin", "pet_Tiger", "pet_Dragon",
}

local RARITY_RANK: { [string]: number } = { common = 1, uncommon = 2, rare = 3, epic = 4, legendary = 5 }

-- What RegisterPet takes. Only `id` is required: displayName defaults to the id,
-- rarity to "common", coinBonus to 0 and icon to "" (placeholder image).
export type PetRegistration = {
	id: string,
	displayName: string?,
	rarity: PetRarity?,
	coinBonus: number?,
	icon: string?,
}

-- One pet in an egg: `weight` is its relative chance (> 0); `pity` = sure within N eggs.
export type EggPet = { petId: string, weight: number, pity: number? }

-- What RegisterEgg takes. `cost` defaults to Config.Pets.EggCost (flag Pets.EggCost),
-- `currency` to "Coins". Every petId must be registered first (RegisterPet or built in).
-- `panel` = false: only server code (BuyEgg) can buy it; the panel's PetBuyEgg
-- remote refuses it (an egg that is sold only at a place in the world).
export type EggRegistration = {
	id: string,
	pets: { EggPet },
	cost: number?,
	currency: string?,
	panel: boolean?,
}

-- Price of one egg, as sent to the client (Snapshot.eggs).
export type EggInfo = { cost: number, currency: string }

type EggDef = { entries: { LootService.LootEntry }, cost: number?, currency: string, panel: boolean }

-- The built-in BasicEgg: the built-in roster with its weights (cost from Config).
local function basicEggEntries(): { LootService.LootEntry }
	local entries: { LootService.LootEntry } = {}
	for _, id in ipairs(PET_ORDER) do
		local d = PET_DEFS[id]
		if d.weight > 0 then -- registered pets have weight 0: they are only in their own eggs
			table.insert(entries, { Item = id, Weight = d.weight, Pity = d.pity })
		end
	end
	return entries
end

-- Registered eggs (RegisterEgg adds to it). Init fills in BasicEgg unless a game
-- already registered its own "BasicEgg".
local EGGS: { [string]: EggDef } = {}

export type PetInstance = { petId: string, uid: string }

-- Client-visible slice of a PetDef (Snapshot.defs).
export type PetPublicDef = { displayName: string, rarity: PetRarity, coinBonus: number, icon: string }

-- What Snapshot returns and PetGetState / PetSync send to the client.
export type PetSnapshot = {
	owned: { PetInstance },
	equipped: { string },      -- equipped uids, in equip order
	multiplier: number,        -- GetCoinMultiplier for this state
	slots: number,             -- max pets equipped at once
	eggCost: number,           -- Coins per BasicEgg
	defs: { [string]: PetPublicDef },
	order: { string },         -- stable display order of pet ids
	eggs: { [string]: EggInfo }, -- every egg the panel can buy, and its price
}

-- What BuyEgg sends to the client as PetHatch (snapshot = the state after the hatch).
export type PetHatchPayload = {
	ok: boolean,
	petId: string?,
	displayName: string?,
	reason: string?,
	egg: string,
	snapshot: PetSnapshot,
}

export type EquipResult = "equipped" | "bad uid" | "not owned" | "already equipped" | "all slots full"
export type UnequipResult = "unequipped" | "bad uid" | "not equipped"
export type RemoveResult = string -- the removed uid, or "bad id" / "not owned" / "data not loaded"

local PetService = {}

-- (player, petId, uid) after GrantPet added a pet to the profile
PetService.OnPetGranted   = Signal.new() :: Signal.Signal<Player, string, string>
-- (player, equipped) after Equip / Unequip / RemovePet of an equipped pet; equipped = a copy of the equipped uid list
PetService.OnEquipChanged = Signal.new() :: Signal.Signal<Player, { string }>
-- (player, petId, uid) after RemovePet took a pet out of the profile
PetService.OnPetRemoved   = Signal.new() :: Signal.Signal<Player, string, string>

-- ── Persistence (one blob: owned map + equipped list + uid sequence) ──

local function loadPets(player: Player): { [string]: any }
	local v = DataManager.Get(player, PETS_KEY)
	if typeof(v) ~= "table" then
		v = {}
	end
	if typeof(v.owned) ~= "table" then
		v.owned = {}
	end
	if typeof(v.equipped) ~= "table" then
		v.equipped = {}
	end
	if typeof(v.__seq) ~= "number" then
		v.__seq = 0
	end
	return v
end

local function savePets(player: Player, pets: { [string]: any }): ()
	DataManager.Set(player, PETS_KEY, pets)
end

-- ── Helpers ──

local function maxSlots(): number
	local n = tonumber(configuredSlots()) or DEFAULT_SLOTS
	return math.max(1, math.floor(n))
end

local function eggCost(): number
	local c = tonumber(configuredEggCost()) or DEFAULT_EGG_COST
	-- Floor at 1: Economy.Spend rejects amounts <= 0, so a 0 cost would make the
	-- egg silently unpurchasable (looks identical to "not enough Coins").
	return math.max(1, math.floor(c))
end

local function defOf(petId: string): PetDef?
	return PET_DEFS[petId]
end

-- Price of an egg: its registered cost, else the configured Pets.EggCost.
local function costOf(egg: EggDef): number
	if egg.cost then
		return math.max(1, math.floor(egg.cost))
	end
	return eggCost()
end

-- ── Client pushes (PetSync), coalesced: many changes in one frame send one snapshot ──
local pendingPush: { [Player]: boolean } = {}
local pushScheduled = false

local function flushPushes(): ()
	pushScheduled = false
	local players = pendingPush
	pendingPush = {}
	for player in pairs(players) do
		-- Only players still in the game with loaded data (Snapshot reads the profile).
		if player.Parent ~= nil and DataManager.IsLoaded(player) then
			local ok, err = pcall(function()
				Net.FireClient(player, "PetSync", PetService.Snapshot(player))
			end)
			if not ok then
				warn(`[PetService] PetSync to {player.Name} failed: {err}`)
			end
		end
	end
end

-- Queue a PetSync for `player` at the end of this frame.
local function schedulePush(player: Player): ()
	pendingPush[player] = true
	if not pushScheduled then
		pushScheduled = true
		task.defer(flushPushes)
	end
end

-- Defs changed (RegisterPet / RegisterEgg after players joined): resync everyone.
local function schedulePushAll(): ()
	for _, player in ipairs(Players:GetPlayers()) do
		schedulePush(player)
	end
end

local function isEquipped(pets: { [string]: any }, uid: string): boolean
	for _, u in ipairs(pets.equipped) do
		if u == uid then
			return true
		end
	end
	return false
end

-- Pure: total multiplier for an already-loaded pets blob (1 + Σ equipped bonus).
-- Equipped uids that no longer map to an owned pet are skipped, so a corrupt
-- equipped list can never inflate the result.
local function multiplierOf(pets: { [string]: any }): number
	local mult = 1.0
	for _, uid in ipairs(pets.equipped) do
		local inst = pets.owned[uid]
		if typeof(inst) == "table" then
			local def = defOf(inst.petId)
			if def then
				mult += def.coinBonus
			end
		end
	end
	return mult
end

-- ── Public: Coins multiplier (THE core API the scope specifies) ──
-- Returns 1 + Σ coinBonus of every currently-equipped pet. A game multiplies its
-- own coin grants by this (the faucet is the game's; this service never grants).
-- Returns a neutral 1.0 until the profile has loaded (no pets equipped yet
-- anyway), so a faucet calling this in the join window never errors.
function PetService.GetCoinMultiplier(player: Player): number
	if not DataManager.IsLoaded(player) then
		return 1.0
	end
	return multiplierOf(loadPets(player))
end

-- ── Queries ──

function PetService.GetOwned(player: Player): { PetInstance }
	local out: { PetInstance } = {}
	for _, inst in pairs(loadPets(player).owned) do
		if typeof(inst) == "table" then
			table.insert(out, { petId = inst.petId, uid = inst.uid })
		end
	end
	return out
end

function PetService.GetEquipped(player: Player): { string }
	local out: { string } = {}
	for _, uid in ipairs(loadPets(player).equipped) do
		table.insert(out, uid)
	end
	return out
end

-- ── Grant (server-internal; the only way a pet enters a profile) ──

function PetService.GrantPet(player: Player, petId: string): string?
	if not defOf(petId) then
		warn(`[PetService] GrantPet: unknown petId '{petId}' for {player.Name}`)
		return nil
	end
	local pets = loadPets(player)
	pets.__seq += 1
	local uid = `u_{pets.__seq}`
	pets.owned[uid] = { petId = petId, uid = uid }
	savePets(player, pets)
	PetService.OnPetGranted:Fire(player, petId, uid)
	schedulePush(player)
	return uid
end

-- ── Remove (server-internal; e.g. trade, sell, fuse) ──
-- `id` is a uid ("u_3": that pet) or a pet id ("pet_Cat": one pet of that kind,
-- an unequipped one first). An equipped pet is unequipped first. Returns
-- (true, removedUid) or (false, "bad id" | "not owned" | "data not loaded").
function PetService.RemovePet(player: Player, id: string): (boolean, RemoveResult)
	if typeof(id) ~= "string" or #id == 0 or #id > MAX_UID_LEN then
		return false, "bad id"
	end
	if not DataManager.IsLoaded(player) then
		return false, "data not loaded"
	end
	local pets = loadPets(player)
	local uid: string? = nil
	if typeof(pets.owned[id]) == "table" then
		uid = id
	else
		-- By pet id: prefer an unequipped one, lowest uid number first (deterministic).
		local best: string?, bestEquipped, bestSeq = nil, true, math.huge
		for u, inst in pairs(pets.owned) do
			if typeof(inst) == "table" and inst.petId == id then
				local eq = isEquipped(pets, u)
				local seq = tonumber(string.match(u, "^u_(%d+)$")) or math.huge
				if best == nil or (bestEquipped and not eq) or (eq == bestEquipped and seq < bestSeq) then
					best, bestEquipped, bestSeq = u, eq, seq
				end
			end
		end
		uid = best
	end
	if uid == nil then
		return false, "not owned"
	end
	local petId: string = pets.owned[uid].petId
	pets.owned[uid] = nil
	local wasEquipped = false
	for i, u in ipairs(pets.equipped) do
		if u == uid then
			table.remove(pets.equipped, i)
			wasEquipped = true
			break
		end
	end
	savePets(player, pets)
	PetService.OnPetRemoved:Fire(player, petId, uid)
	if wasEquipped then
		PetService.OnEquipChanged:Fire(player, table.clone(pets.equipped))
	end
	schedulePush(player)
	return true, uid
end

-- ── Buy egg (spend currency → weighted Loot.Roll → grant; refund on failure) ──

local function buyEgg(player: Player, eggTable: string): (boolean, string)
	local egg = EGGS[eggTable]
	if not egg then
		return false, "unknown egg"
	end
	local cost = costOf(egg)
	local currency = egg.currency
	if not EconomyService.Spend(player, currency, cost) then
		return false, `not enough {currency}`
	end
	-- Refund helper: warn loudly if the refund itself fails (e.g. balance already
	-- at the Economy cap) so the lost coins are never silent.
	local function refund(reason: string): (boolean, string)
		if not EconomyService.Add(player, currency, cost) then
			warn(`[PetService] refund of {cost} {currency} failed for {player.Name} ({reason})`)
		end
		return false, reason
	end
	local drop = LootService.Roll(player, eggTable)
	if typeof(drop) ~= "table" or typeof(drop.Item) ~= "string" then
		return refund("egg unavailable")
	end
	local uid = PetService.GrantPet(player, drop.Item)
	if not uid then
		return refund("bad drop")
	end
	return true, drop.Item
end

-- Spends the egg's price, rolls a pet and grants it (refunds on failure). `eggId`
-- nil = "BasicEgg". Returns (true, petId) or (false, reason): "unknown egg",
-- "not enough <Currency>", "egg unavailable", "bad drop". Also sends PetHatch
-- (toast) and PetSync (panel) to the player, success or not.
function PetService.BuyEgg(player: Player, eggId: string?): (boolean, string)
	local eggTable = eggId or EGG_TABLE_ID -- nil defaults to BasicEgg (explicit, not a bypass)
	local ok, result = buyEgg(player, eggTable)
	if player.Parent ~= nil and DataManager.IsLoaded(player) then
		local def = if ok then defOf(result) else nil
		local payload: PetHatchPayload = {
			ok = ok,
			petId = if ok then result else nil,
			displayName = if def then def.displayName else nil,
			reason = if ok then nil else result,
			egg = eggTable,
			snapshot = PetService.Snapshot(player),
		}
		pcall(function()
			Net.FireClient(player, "PetHatch", payload)
		end)
	end
	schedulePush(player)
	return ok, result
end

-- ── Equip / Unequip (server-authoritative; bounded by maxSlots) ──

function PetService.Equip(player: Player, uid: string): (boolean, EquipResult)
	if #uid > MAX_UID_LEN then -- reject oversized attacker strings before the hash lookup
		return false, "bad uid"
	end
	local pets = loadPets(player)
	if typeof(pets.owned[uid]) ~= "table" then
		return false, "not owned"
	end
	if isEquipped(pets, uid) then
		return false, "already equipped"
	end
	if #pets.equipped >= maxSlots() then
		return false, "all slots full"
	end
	table.insert(pets.equipped, uid)
	savePets(player, pets)
	PetService.OnEquipChanged:Fire(player, table.clone(pets.equipped))
	schedulePush(player)
	return true, "equipped"
end

function PetService.Unequip(player: Player, uid: string): (boolean, UnequipResult)
	if #uid > MAX_UID_LEN then
		return false, "bad uid"
	end
	local pets = loadPets(player)
	local removed = false
	for i, u in ipairs(pets.equipped) do
		if u == uid then
			table.remove(pets.equipped, i)
			removed = true
			break
		end
	end
	if not removed then
		return false, "not equipped"
	end
	savePets(player, pets)
	PetService.OnEquipChanged:Fire(player, table.clone(pets.equipped))
	schedulePush(player)
	return true, "unequipped"
end

-- ── Client snapshot (owned + equipped + multiplier + read-only defs) ──

local function defsPublic(): { [string]: PetPublicDef }
	local out: { [string]: PetPublicDef } = {}
	for id, d in pairs(PET_DEFS) do
		out[id] = { displayName = d.displayName, rarity = d.rarity, coinBonus = d.coinBonus, icon = d.icon }
	end
	return out
end

function PetService.Snapshot(player: Player): PetSnapshot
	local pets = loadPets(player) -- single load; build owned/equipped/multiplier from it
	local owned: { PetInstance } = {}
	for _, inst in pairs(pets.owned) do
		if typeof(inst) == "table" then
			table.insert(owned, { petId = inst.petId, uid = inst.uid })
		end
	end
	local equipped: { string } = {}
	for _, uid in ipairs(pets.equipped) do
		table.insert(equipped, uid)
	end
	local eggs: { [string]: EggInfo } = {}
	for id, egg in pairs(EGGS) do
		if egg.panel then
			eggs[id] = { cost = costOf(egg), currency = egg.currency }
		end
	end
	return {
		owned      = owned,
		equipped   = equipped,
		multiplier = multiplierOf(pets),
		slots      = maxSlots(),
		eggCost    = if EGGS[EGG_TABLE_ID] then costOf(EGGS[EGG_TABLE_ID]) else eggCost(),
		defs       = defsPublic(),
		order      = table.clone(PET_ORDER),
		eggs       = eggs,
	}
end

-- ── Catalog registration (ItemDef / Loot / Codex registries are module-level, so
-- this works before or after Init; Init registers the whole catalog again) ──

local function registerPetContent(id: string, d: PetDef): ()
	ItemDefinitionService.Register(id, {
		category = PET_CATEGORY,
		rarity = d.rarity,
		displayName = d.displayName,
		coinBonus = d.coinBonus,
	})
	-- Codex accuracy (completion %): pre-register so the catalog size is correct.
	-- pcall — Codex is optional; Loot.Roll auto-discovers on its own besides this.
	local entry: CodexService.EntryDef = { Rarity = d.rarity :: string, Set = CODEX_SET }
	pcall(CodexService.Register, id, entry)
end

local function registerContent(): ()
	if EGGS[EGG_TABLE_ID] == nil then
		EGGS[EGG_TABLE_ID] = { entries = basicEggEntries(), cost = nil, currency = EGG_CURRENCY, panel = true }
	end
	for id, d in pairs(PET_DEFS) do
		registerPetContent(id, d)
	end
	for id, egg in pairs(EGGS) do
		LootService.DefineTable(id, egg.entries)
	end
end

local function validId(id: any): boolean
	return typeof(id) == "string" and #id > 0 and #id <= MAX_ID_LEN
end

local function reject(fn: string, reason: string): (boolean, string?)
	warn(`[PetService] {fn}: {reason}`)
	return false, reason
end

-- Add a pet (or replace one with the same id) from a server Script. Call it before
-- RegisterEgg lists the pet. Returns true, or false and the reason (also warned).
-- Ids that look like a uid ("u_<number>") are refused.
function PetService.RegisterPet(def: PetRegistration): (boolean, string?)
	if typeof(def) ~= "table" or not validId(def.id) then
		return reject("RegisterPet", "id must be a string of 1 to 64 characters")
	end
	local id = def.id
	if string.match(id, "^u_%d+$") then
		return reject("RegisterPet", `id '{id}' looks like a pet uid; pick another`)
	end
	local rarity: PetRarity = def.rarity or "common"
	if RARITY_RANK[rarity] == nil then
		return reject("RegisterPet", `'{id}': rarity must be common, uncommon, rare, epic or legendary`)
	end
	local bonus = def.coinBonus or 0
	if typeof(bonus) ~= "number" or bonus ~= bonus or bonus < 0 or bonus == math.huge then
		return reject("RegisterPet", `'{id}': coinBonus must be a number >= 0`)
	end
	if def.displayName ~= nil and typeof(def.displayName) ~= "string" then
		return reject("RegisterPet", `'{id}': displayName must be a string`)
	end
	if def.icon ~= nil and typeof(def.icon) ~= "string" then
		return reject("RegisterPet", `'{id}': icon must be a string`)
	end
	local old = PET_DEFS[id]
	local d: PetDef = {
		displayName = def.displayName or id,
		rarity = rarity,
		coinBonus = bonus,
		-- weight / pity only feed the built-in BasicEgg; eggs list their own weights.
		weight = if old then old.weight else 0,
		pity = if old then old.pity else nil,
		icon = def.icon or "",
	}
	PET_DEFS[id] = d
	if not old then
		-- Insert after the last pet whose rarity is the same or lower.
		local at = 1
		for i, other in ipairs(PET_ORDER) do
			if RARITY_RANK[PET_DEFS[other].rarity] <= RARITY_RANK[rarity] then
				at = i + 1
			end
		end
		table.insert(PET_ORDER, at, id)
	end
	registerPetContent(id, d)
	schedulePushAll()
	return true, nil
end

-- Add an egg (or replace one with the same id, "BasicEgg" too) from a server Script.
-- Every petId must already be registered. Returns true, or false and the reason (also warned).
function PetService.RegisterEgg(def: EggRegistration): (boolean, string?)
	if typeof(def) ~= "table" or not validId(def.id) then
		return reject("RegisterEgg", "id must be a string of 1 to 64 characters")
	end
	local id = def.id
	if typeof(def.pets) ~= "table" or #def.pets == 0 then
		return reject("RegisterEgg", `'{id}': pets must list at least one pet (petId and weight)`)
	end
	local entries: { LootService.LootEntry } = {}
	for i, e in ipairs(def.pets) do
		if typeof(e) ~= "table" or typeof(e.petId) ~= "string" or not PET_DEFS[e.petId] then
			return reject("RegisterEgg", `'{id}': pets[{i}] has an unknown petId (RegisterPet it first)`)
		end
		if typeof(e.weight) ~= "number" or not (e.weight > 0) or e.weight == math.huge then
			return reject("RegisterEgg", `'{id}': pets[{i}].weight must be a number > 0`)
		end
		if e.pity ~= nil and (typeof(e.pity) ~= "number" or not (e.pity >= 1)) then
			return reject("RegisterEgg", `'{id}': pets[{i}].pity must be a number >= 1`)
		end
		table.insert(entries, { Item = e.petId, Weight = e.weight, Pity = if e.pity then math.floor(e.pity) else nil })
	end
	if def.cost ~= nil and (typeof(def.cost) ~= "number" or not (def.cost >= 1) or def.cost == math.huge) then
		return reject("RegisterEgg", `'{id}': cost must be a number >= 1`)
	end
	if def.currency ~= nil and (typeof(def.currency) ~= "string" or #def.currency == 0) then
		return reject("RegisterEgg", `'{id}': currency must be a currency name like "Coins"`)
	end
	if def.panel ~= nil and typeof(def.panel) ~= "boolean" then
		return reject("RegisterEgg", `'{id}': panel must be true or false`)
	end
	EGGS[id] = { entries = entries, cost = def.cost, currency = def.currency or EGG_CURRENCY, panel = def.panel ~= false }
	LootService.DefineTable(id, entries)
	schedulePushAll()
	return true, nil
end

-- ── Init: register client-facing remotes (anti-exploit via Net + Guard) ──

local function registerRemotes(): ()
	-- Initial state pull (RemoteFunction).
	Net.OnInvoke("PetGetState", function(player: Player): PetSnapshot
		return PetService.Snapshot(player)
	end, { rate = 10 })

	-- Buy egg. Server is authoritative: it spends, rolls, grants, then re-syncs.
	-- BuyEgg itself sends PetHatch + PetSync.
	Net.OnServer("PetBuyEgg", function(player: Player, payload: any)
		local egg = EGGS[payload.egg]
		if egg and not egg.panel then
			return -- sold only by server code (RegisterEgg panel = false)
		end
		PetService.BuyEgg(player, payload.egg)
	end, { rate = 4, validators = { Guard.strictInterface({ egg = Guard.string }) } })

	-- Equip / unequip by owned uid. Equip/Unequip re-validate ownership + slots.
	-- A refused click still resyncs, so the panel drops its stale view.
	Net.OnServer("PetEquip", function(player: Player, payload: any)
		PetService.Equip(player, payload.uid)
		schedulePush(player)
	end, { rate = 10, validators = { Guard.strictInterface({ uid = Guard.string }) } })

	Net.OnServer("PetUnequip", function(player: Player, payload: any)
		PetService.Unequip(player, payload.uid)
		schedulePush(player)
	end, { rate = 10, validators = { Guard.strictInterface({ uid = Guard.string }) } })

	-- Pre-create the server→client remotes so a client's OnClient subscription
	-- (which WaitForChilds the remote) resolves at join even before the first real
	-- push. FireAllClients with zero players is a harmless no-op that still mints
	-- the RemoteEvent under Events/Net.
	Net.FireAllClients("PetSync")
	Net.FireAllClients("PetHatch")
end

Lifecycle.Define(PetService, {
	Name = "Pet",
	-- Init registers the pet catalog into all three.
	Needs = { ItemDefinitionService, LootService, CodexService },
	Init = function()
		-- Catalog first, then remotes (as before: a catalog error stops the remotes
		-- from registering). Pet is listed in Features, so both are ready before any
		-- player joins; nothing here yields.
		registerContent()
		registerRemotes()
	end,
})

return PetService
