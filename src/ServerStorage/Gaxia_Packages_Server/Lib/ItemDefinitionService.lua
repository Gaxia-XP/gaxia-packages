--!strict
-- ─────────────────────────────────────────────────────────────
-- ItemDefinitionService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/ItemDefinitionService
-- Purpose : Central registry describing what every item / decoration IS
--           (rarity, category, grid footprint, sell price, …). The single
--           source of truth so Collection/Refine/Vault/Loot/Placement don't
--           each invent and drift their own item tables. Pure config registry —
--           no runtime state, no external dependency.
--
-- Access  : Gaxia.ItemDef  (server)
--   Gaxia.ItemDef.RegisterMany({ Sprout = { rarity = "common", category = "Seed", sellPrice = 5 } })
--   local def = Gaxia.ItemDef.Get("Sprout")
--   local price = Gaxia.ItemDef.GetField("Sprout", "sellPrice", 0)
-- ─────────────────────────────────────────────────────────────
local Lifecycle = require(script.Parent.ServiceLifecycle)

export type ItemDef = {
	id: string,
	rarity: string?,      -- game-defined: "common" | "rare" | ...
	category: string?,    -- grouping: "Seed" | "Decoration" | "Tool" | ...
	footprint: Vector2?,  -- grid footprint (cols, rows) for placement
	sellPrice: number?,
	stackable: boolean?,
	maxStack: number?,
	[string]: any,        -- game-specific extras
}

local ItemDefinitionService = {}

local defs: { [string]: ItemDef } = {}

-- ── Public API ──

-- Register one definition. `id` is stamped onto a defensive copy so callers
-- can't later mutate the stored table by reference.
function ItemDefinitionService.Register(id: string, def: { [string]: any }): ()
	if type(id) ~= "string" or #id == 0 then
		warn("[ItemDefinitionService] Register: id must be a non-empty string")
		return
	end
	if type(def) ~= "table" then
		warn(`[ItemDefinitionService] Register: def for '{id}' must be a table`)
		return
	end
	local copy: ItemDef = {} :: any
	for k, v in pairs(def) do
		copy[k] = v
	end
	copy.id = id
	defs[id] = copy
end

-- Register a whole `{ [id] = def }` map at once (boot-time bulk load).
function ItemDefinitionService.RegisterMany(map: { [string]: { [string]: any } }): ()
	for id, def in pairs(map) do
		ItemDefinitionService.Register(id, def)
	end
end

function ItemDefinitionService.Get(id: string): ItemDef?
	return defs[id]
end

function ItemDefinitionService.Has(id: string): boolean
	return defs[id] ~= nil
end

-- A field read with a fallback default so consumers don't nil-check every access.
function ItemDefinitionService.GetField(id: string, field: string, default: any): any
	local d = defs[id]
	if d == nil then
		return default
	end
	local v = d[field]
	if v == nil then
		return default
	end
	return v
end

-- Shallow copy of the registry so callers can't mutate internal state.
function ItemDefinitionService.GetAll(): { [string]: ItemDef }
	local out: { [string]: ItemDef } = {}
	for id, d in pairs(defs) do
		out[id] = d
	end
	return out
end

function ItemDefinitionService.GetByCategory(category: string): { ItemDef }
	local out: { ItemDef } = {}
	for _, d in pairs(defs) do
		if d.category == category then
			table.insert(out, d)
		end
	end
	return out
end

function ItemDefinitionService.GetByRarity(rarity: string): { ItemDef }
	local out: { ItemDef } = {}
	for _, d in pairs(defs) do
		if d.rarity == rarity then
			table.insert(out, d)
		end
	end
	return out
end

function ItemDefinitionService.Count(): number
	local n = 0
	for _ in pairs(defs) do
		n += 1
	end
	return n
end

-- Pure registry: nothing to set up. Registered so Features / IsEnabled know it.
Lifecycle.Define(ItemDefinitionService, {
	Name = "ItemDef",
	Needs = {},
})

return ItemDefinitionService
