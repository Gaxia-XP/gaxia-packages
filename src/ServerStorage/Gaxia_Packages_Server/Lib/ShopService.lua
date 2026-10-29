--!strict
-- ─────────────────────────────────────────────────────────────
-- ShopService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/ShopService
-- Purpose : Server-authoritative shop catalog. RegisterItem with a soft-currency
--           cost (or a Robux DevProduct) + optional level / gamepass gates.
--           Purchase() validates every gate server-side, debits Economy (atomic,
--           with refund on a failed grant) or prompts the Robux product, then
--           grants. The #2 exploit surface after trading — never trust a client
--           "I bought it".
--
-- Access  : Gaxia.Shop  (server)
--   Gaxia.Shop.RegisterItem("SpeedBoost", { cost = 250, currency = "Coins",
--     levelReq = 3, grant = function(p) applyBoost(p) end })
--   Gaxia.Shop.RegisterItem("GemPack", { devProductId = 123456 }) -- Robux: no grant here
--   local ok, reason = Gaxia.Shop.Purchase(player, "SpeedBoost")
-- ─────────────────────────────────────────────────────────────
-- ── Dependencies ──
-- Monetization / Level / Economy / DataManager are only called from Purchase (call
-- time), so they are plain requires, not lifecycle Needs. Requiring Monetization does not bind
-- ProcessReceipt; its first call (OwnsGamePass / PromptProduct) starts it, as the
-- old first G.Monetization touch did.
local Lifecycle           = require(script.Parent.ServiceLifecycle)
local EconomyService      = require(script.Parent.EconomyService)
local LevelSystem         = require(script.Parent.LevelSystem)
local MonetizationService = require(script.Parent.MonetizationService)
local DataManager         = require(script.Parent.DataManager)

export type ShopItem = {
	id: string,
	cost: number?,          -- soft-currency price (default 0 = free)
	currency: string?,      -- soft currency key (default "Coins")
	levelReq: number?,      -- minimum Gaxia.Level
	gamePassReq: number?,   -- must own this gamepass to buy
	devProductId: number?,  -- if set: prompt a Robux product instead of debiting
	grant: (player: Player) -> (),
	[string]: any,
}
-- What RegisterItem takes: a ShopItem whose `id` is optional (the id argument is
-- used) and whose `grant` is optional for a Robux item (`devProductId` set: the
-- product's Monetization.RegisterProduct grant gives the reward). Items that cost
-- soft currency still need `grant`.
export type ShopItemDef = {
	id: string?,
	cost: number?,
	currency: string?,
	levelReq: number?,
	gamePassReq: number?,
	devProductId: number?,
	grant: ((player: Player) -> ())?,
	[string]: any,
}
-- Why Purchase did not complete ("prompted_robux": the Robux prompt was shown and
-- the product's grantFn runs when the receipt arrives; "not_loaded": the buyer's
-- saved data has not loaded yet, nothing was checked or spent — ask again later).
export type PurchaseFailure = "unknown_item" | "not_loaded" | "requires_gamepass" | "level_too_low"
	| "prompted_robux" | "insufficient_funds" | "grant_failed"

local Shop = {}

local catalog: { [string]: ShopItem } = {}

-- ── Public API ──

local function noGrant(_player: Player): () end

-- Add (or replace) an item. `def.id` may be left out: the item's id is always `id`.
-- `def.grant` is required unless `def.devProductId` is set (a Robux item is granted by
-- the product's Monetization.RegisterProduct function, never by Shop).
function Shop.RegisterItem(id: string, def: ShopItemDef): ()
	assert(typeof(id) == "string" and #id > 0, "Shop.RegisterItem needs an id")
	assert(typeof(def) == "table", "Shop.RegisterItem needs a definition table")
	assert(
		typeof(def.grant) == "function" or (def.grant == nil and def.devProductId ~= nil),
		"Shop item needs a grant function (only a devProductId item may leave it out)"
	)
	local copy = {} :: ShopItem
	for k, v in pairs(def) do
		copy[k] = v
	end
	copy.id = id
	if copy.grant == nil then
		copy.grant = noGrant
	end
	catalog[id] = copy
end

function Shop.Get(id: string): ShopItem?
	return catalog[id]
end

function Shop.GetCatalog(): { ShopItem }
	local out: { ShopItem } = {}
	for _, item in pairs(catalog) do
		table.insert(out, item)
	end
	return out
end

-- Server-authoritative purchase. Returns (ok, reason); reason is nil on success.
-- Returns false, "not_loaded" (and checks / spends nothing) while the buyer's data
-- is not loaded, so a just-joined player is not told "insufficient_funds". This holds for
-- every item: a Robux item does not prompt and a free item does not grant until then.
function Shop.Purchase(player: Player, id: string): (boolean, PurchaseFailure?)
	local item = catalog[id]
	if not item then
		return false, "unknown_item"
	end
	if not DataManager.IsLoaded(player) then
		return false, "not_loaded"
	end

	if item.gamePassReq and not MonetizationService.OwnsGamePass(player, item.gamePassReq) then
		return false, "requires_gamepass"
	end
	if item.levelReq and LevelSystem.GetLevel(player) < item.levelReq then
		return false, "level_too_low"
	end

	-- Robux item: prompt the product; the actual grant fires from the product's
	-- registered grantFn (Monetization.RegisterProduct), not here.
	if item.devProductId then
		MonetizationService.PromptProduct(player, item.devProductId)
		return false, "prompted_robux"
	end

	local cost = item.cost or 0
	local currency = item.currency or "Coins"
	if cost > 0 then
		if not EconomyService.Spend(player, currency, cost) then
			return false, "insufficient_funds"
		end
	end

	local ok, err = pcall(item.grant :: (Player) -> ...any, player)
	if not ok then
		warn(`[Shop] grant for '{id}' failed: {err}`)
		if cost > 0 then
			EconomyService.Add(player, currency, cost) -- refund a failed grant — never eat currency
		end
		return false, "grant_failed"
	end
	return true, nil
end

-- Pure API: nothing to set up. Registered so Features / IsEnabled know it.
Lifecycle.Define(Shop, {
	Name = "Shop",
	Needs = {},
})

return Shop
