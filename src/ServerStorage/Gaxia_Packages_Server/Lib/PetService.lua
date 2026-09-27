--!strict
-- ─────────────────────────────────────────────────────────────
-- PetService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/PetService
-- Purpose : Stat-boost pet system (MVP). Players hatch pets from a weighted egg
--           (Gaxia.Loot, with pity), own them per-profile, and equip up to N at
--           once; each equipped pet contributes an ADDITIVE Coins multiplier.
--           The faucet is intentionally NOT wired here — a game reads
--           GetCoinMultiplier(player) and multiplies its OWN coin grants. Pets
--           are STAT-ONLY this pass (no 3D follow model). Pet definitions live
--           in Gaxia.ItemDef (category "Pet"); every hatch auto-logs to
--           Gaxia.Codex via Loot.Roll. Owned + equipped persist under the "Pets"
--           profile key (outside DEFAULT_PROFILE, same pattern as Inventory).
--
-- Access  : Gaxia.Pet  (server)
--   local mult = Gaxia.Pet.GetCoinMultiplier(player)  -- 1 + Σ equipped coinBonus
--   local ok, petId = Gaxia.Pet.BuyEgg(player, "BasicEgg")
--   Gaxia.Pet.Equip(player, uid)
--
-- Lifecycle: Init registers the catalog into ItemDef / Loot / Codex and the client
--            remotes (PetGetState, PetBuyEgg, PetEquip, PetUnequip, PetSync,
--            PetHatch) — listed in Features, so they exist before any player joins.
-- ─────────────────────────────────────────────────────────────
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

local PET_DEFS: { [string]: PetDef } = {
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
local PET_ORDER: { string } = {
	"pet_Cat", "pet_Dog", "pet_Bunny", "pet_Fox", "pet_Panda", "pet_Penguin", "pet_Tiger", "pet_Dragon",
}

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
}

export type EquipResult = "equipped" | "bad uid" | "not owned" | "already equipped" | "all slots full"
export type UnequipResult = "unequipped" | "bad uid" | "not equipped"

local PetService = {}

-- (player, petId, uid) after GrantPet added a pet to the profile
PetService.OnPetGranted   = Signal.new() :: Signal.Signal<Player, string, string>
-- (player, equipped) after Equip / Unequip; equipped = a copy of the equipped uid list
PetService.OnEquipChanged = Signal.new() :: Signal.Signal<Player, { string }>

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
	return uid
end

-- ── Buy egg (spend Coins → weighted Loot.Roll → grant; refund on failure) ──

function PetService.BuyEgg(player: Player, eggId: string?): (boolean, string)
	local eggTable = eggId or EGG_TABLE_ID -- nil defaults to the only egg (explicit, not a bypass)
	if eggTable ~= EGG_TABLE_ID then
		return false, "unknown egg"
	end
	local cost = eggCost()
	if not EconomyService.Spend(player, EGG_CURRENCY, cost) then
		return false, "not enough Coins"
	end
	-- Refund helper: warn loudly if the refund itself fails (e.g. balance already
	-- at the Economy cap) so the lost coins are never silent.
	local function refund(reason: string): (boolean, string)
		if not EconomyService.Add(player, EGG_CURRENCY, cost) then
			warn(`[PetService] refund of {cost} {EGG_CURRENCY} failed for {player.Name} ({reason})`)
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
	return {
		owned      = owned,
		equipped   = equipped,
		multiplier = multiplierOf(pets),
		slots      = maxSlots(),
		eggCost    = eggCost(),
		defs       = defsPublic(),
		order      = PET_ORDER,
	}
end

local function pushSnapshot(player: Player): ()
	Net.FireClient(player, "PetSync", PetService.Snapshot(player))
end

-- ── Init: register catalog into ItemDef / Loot / Codex ──

local function registerContent(): ()
	local itemDefs: { [string]: { [string]: any } } = {}
	for id, d in pairs(PET_DEFS) do
		itemDefs[id] = {
			category = PET_CATEGORY,
			rarity = d.rarity,
			displayName = d.displayName,
			coinBonus = d.coinBonus,
		}
	end
	ItemDefinitionService.RegisterMany(itemDefs)

	local entries: { LootService.LootEntry } = {}
	for _, id in ipairs(PET_ORDER) do
		local d = PET_DEFS[id]
		table.insert(entries, { Item = id, Weight = d.weight, Pity = d.pity })
	end
	LootService.DefineTable(EGG_TABLE_ID, entries)

	-- Codex accuracy (completion %): pre-register so the catalog size is correct.
	-- pcall — Codex is optional; Loot.Roll auto-discovers on its own besides this.
	pcall(function()
		local codexDefs: { [string]: CodexService.EntryDef } = {}
		for id, d in pairs(PET_DEFS) do
			codexDefs[id] = { Rarity = d.rarity, Set = CODEX_SET }
		end
		CodexService.RegisterMany(codexDefs)
	end)
end

-- ── Init: register client-facing remotes (anti-exploit via Net + Guard) ──

local function registerRemotes(): ()
	-- Initial state pull (RemoteFunction).
	Net.OnInvoke("PetGetState", function(player: Player): PetSnapshot
		return PetService.Snapshot(player)
	end, { rate = 10 })

	-- Buy egg. Server is authoritative: it spends, rolls, grants, then re-syncs.
	Net.OnServer("PetBuyEgg", function(player: Player, payload: any)
		local ok, result = PetService.BuyEgg(player, payload.egg)
		Net.FireClient(player, "PetHatch", {
			ok = ok,
			petId = if ok then result else nil,
			reason = if ok then nil else result,
		})
		pushSnapshot(player)
	end, { rate = 4, validators = { Guard.strictInterface({ egg = Guard.string }) } })

	-- Equip / unequip by owned uid. Equip/Unequip re-validate ownership + slots.
	Net.OnServer("PetEquip", function(player: Player, payload: any)
		PetService.Equip(player, payload.uid)
		pushSnapshot(player)
	end, { rate = 10, validators = { Guard.strictInterface({ uid = Guard.string }) } })

	Net.OnServer("PetUnequip", function(player: Player, payload: any)
		PetService.Unequip(player, payload.uid)
		pushSnapshot(player)
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
