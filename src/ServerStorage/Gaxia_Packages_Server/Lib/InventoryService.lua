--!strict
-- ─────────────────────────────────────────────────────────────
-- InventoryService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/InventoryService
-- Purpose : Deep inventory model — unique item INSTANCES, stacks, and equip
--           slots — on top of ItemService's flat {itemId:count}. RPG/gacha/
--           crafting need a specific sword with its own rolled stats, a potion
--           that stacks to 99, and a "Weapon" slot that holds exactly one. Each
--           non-stackable Add mints an instance with a UID + per-instance Props;
--           stackable items accumulate a single counted stack; Equip binds an
--           instance to a slot (replacing the prior occupant, which stays in the
--           bag). Persisted under "Inv"; removing an equipped instance auto-
--           unequips it.
--
-- Access  : Gaxia.Inventory  (server)
--   Gaxia.Inventory.DefineItem("Sword", { EquipSlot = "Weapon" })
--   local uid = Gaxia.Inventory.Add(player, "Sword", { Props = { atk = 12 } })
--   Gaxia.Inventory.Equip(player, uid)
-- ─────────────────────────────────────────────────────────────
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Shared      = ReplicatedStorage.Gaxia_Packages.Shared
local Signal      = require(Shared.Signal)
local Lifecycle   = require(script.Parent.ServiceLifecycle)
local DataManager = require(script.Parent.DataManager)

local INV_KEY : string = "Inv"

export type ItemDef = { Stackable: boolean?, MaxStack: number?, EquipSlot: string? }
export type Instance_ = { id: string, itemId: string, count: number, props: any }
export type AddOpts = { Count: number?, Props: any? }

local InventoryService = {}

-- (player, instance) after Add minted an instance or grew a stack (the stored instance)
InventoryService.OnAdd = Signal.new() :: Signal.Signal<Player, Instance_>
-- (player, instanceId, itemId) after Remove deleted a whole instance (not on a partial stack decrement)
InventoryService.OnRemove = Signal.new() :: Signal.Signal<Player, string, string>
-- (player, slot, instanceId) after an equip change; instanceId nil = the slot was emptied
InventoryService.OnEquip = Signal.new() :: Signal.Signal<Player, string, string?>

local defs: { [string]: ItemDef } = {}

function InventoryService.DefineItem(itemId: string, def: ItemDef): ()
	defs[itemId] = def
end

local function defOf(itemId: string): ItemDef
	return defs[itemId] or {}
end

-- ── Persistence (one blob: seq + items + equipped) ──

local function loadInv(player: Player): { [string]: any }
	local v = DataManager.Get(player, INV_KEY)
	if typeof(v) ~= "table" then
		v = {}
	end
	if typeof(v.items) ~= "table" then
		v.items = {}
	end
	if typeof(v.equipped) ~= "table" then
		v.equipped = {}
	end
	if typeof(v.__seq) ~= "number" then
		v.__seq = 0
	end
	return v
end

local function saveInv(player: Player, inv: { [string]: any }): ()
	DataManager.Set(player, INV_KEY, inv)
end

-- ── Add / Remove ──

function InventoryService.Add(player: Player, itemId: string, opts: AddOpts?): string
	local o: AddOpts = opts or {}
	local inv = loadInv(player)
	local def = defOf(itemId)

	local id: string
	if def.Stackable then
		id = `s_{itemId}`
		local inst = inv.items[id]
		if typeof(inst) ~= "table" then
			inst = { id = id, itemId = itemId, count = 0, props = o.Props }
			inv.items[id] = inst
		end
		inst.count += math.max(1, math.floor(o.Count or 1))
	else
		inv.__seq += 1
		id = `i_{inv.__seq}`
		inv.items[id] = { id = id, itemId = itemId, count = 1, props = o.Props }
	end

	saveInv(player, inv)
	InventoryService.OnAdd:Fire(player, inv.items[id])
	return id
end

function InventoryService.Remove(player: Player, instanceId: string, count: number?): boolean
	local inv = loadInv(player)
	local inst = inv.items[instanceId]
	if typeof(inst) ~= "table" then
		return false
	end
	local def = defOf(inst.itemId)
	if def.Stackable and count and count < inst.count then
		inst.count -= math.floor(count)
		saveInv(player, inv)
		return true
	end
	-- remove the whole instance + auto-unequip it
	inv.items[instanceId] = nil
	for slot, uid in pairs(inv.equipped) do
		if uid == instanceId then
			inv.equipped[slot] = nil
			InventoryService.OnEquip:Fire(player, slot, nil)
		end
	end
	saveInv(player, inv)
	InventoryService.OnRemove:Fire(player, instanceId, inst.itemId)
	return true
end

-- ── Queries ──

function InventoryService.Get(player: Player, instanceId: string): Instance_?
	local inst = loadInv(player).items[instanceId]
	return (typeof(inst) == "table") and inst or nil
end

function InventoryService.List(player: Player): { Instance_ }
	local out: { Instance_ } = {}
	for _, inst in pairs(loadInv(player).items) do
		if typeof(inst) == "table" then
			table.insert(out, inst)
		end
	end
	return out
end

function InventoryService.GetByItemId(player: Player, itemId: string): { Instance_ }
	local out: { Instance_ } = {}
	for _, inst in pairs(loadInv(player).items) do
		if typeof(inst) == "table" and inst.itemId == itemId then
			table.insert(out, inst)
		end
	end
	return out
end

-- ── Equip ──

function InventoryService.Equip(player: Player, instanceId: string, slot: string?): (boolean, string)
	local inv = loadInv(player)
	local inst = inv.items[instanceId]
	if typeof(inst) ~= "table" then
		return false, "no such instance"
	end
	local useSlot = slot or defOf(inst.itemId).EquipSlot
	if not useSlot then
		return false, "item has no equip slot"
	end
	inv.equipped[useSlot] = instanceId
	saveInv(player, inv)
	InventoryService.OnEquip:Fire(player, useSlot, instanceId)
	return true, useSlot
end

function InventoryService.Unequip(player: Player, slot: string): boolean
	local inv = loadInv(player)
	if inv.equipped[slot] == nil then
		return false
	end
	inv.equipped[slot] = nil
	saveInv(player, inv)
	InventoryService.OnEquip:Fire(player, slot, nil)
	return true
end

function InventoryService.GetEquipped(player: Player, slot: string): Instance_?
	local inv = loadInv(player)
	local uid = inv.equipped[slot]
	if not uid then
		return nil
	end
	local inst = inv.items[uid]
	return (typeof(inst) == "table") and inst or nil
end

function InventoryService.IsEquipped(player: Player, instanceId: string): boolean
	for _, uid in pairs(loadInv(player).equipped) do
		if uid == instanceId then
			return true
		end
	end
	return false
end

function InventoryService.GetEquipment(player: Player): { [string]: string }
	local out: { [string]: string } = {}
	for slot, uid in pairs(loadInv(player).equipped) do
		out[slot] = uid
	end
	return out
end

-- Pure API: nothing to set up. Registered so Features / IsEnabled know it.
Lifecycle.Define(InventoryService, {
	Name = "Inventory",
	Needs = {},
})

return InventoryService
