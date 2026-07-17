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
--   local ok, reason = Gaxia.Shop.Purchase(player, "SpeedBoost")
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local ServerStorage = game:GetService("ServerStorage")

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

local Shop = {}

local catalog: { [string]: ShopItem } = {}

-- Lazy server loader (Economy / Level / Monetization).
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

-- ── Public API ──

function Shop.RegisterItem(id: string, def: ShopItem): ()
	assert(typeof(id) == "string" and #id > 0, "Shop.RegisterItem needs an id")
	assert(typeof(def.grant) == "function", "Shop item needs a grant function")
	local copy = {} :: ShopItem
	for k, v in pairs(def) do
		copy[k] = v
	end
	copy.id = id
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

-- Server-authoritative purchase. Returns (ok, reason). reason ∈ unknown_item /
-- requires_gamepass / level_too_low / prompted_robux / insufficient_funds /
-- grant_failed.
function Shop.Purchase(player: Player, id: string): (boolean, string?)
	local item = catalog[id]
	if not item then
		return false, "unknown_item"
	end
	local G = server()

	if item.gamePassReq and not G.Monetization.OwnsGamePass(player, item.gamePassReq) then
		return false, "requires_gamepass"
	end
	if item.levelReq and G.Level.GetLevel(player) < item.levelReq then
		return false, "level_too_low"
	end

	-- Robux item: prompt the product; the actual grant fires from the product's
	-- registered grantFn (Monetization.RegisterProduct), not here.
	if item.devProductId then
		G.Monetization.PromptProduct(player, item.devProductId)
		return false, "prompted_robux"
	end

	local cost = item.cost or 0
	local currency = item.currency or "Coins"
	if cost > 0 then
		if not G.Economy.Spend(player, currency, cost) then
			return false, "insufficient_funds"
		end
	end

	local ok, err = pcall(item.grant, player)
	if not ok then
		warn(`[Shop] grant for '{id}' failed: {err}`)
		if cost > 0 then
			G.Economy.Add(player, currency, cost) -- refund a failed grant — never eat currency
		end
		return false, "grant_failed"
	end
	return true
end

return Shop
