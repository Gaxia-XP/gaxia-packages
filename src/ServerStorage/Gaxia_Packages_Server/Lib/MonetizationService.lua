--!strict
-- ─────────────────────────────────────────────────────────────
-- MonetizationService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/MonetizationService
-- Purpose : Robux income — GamePasses + Developer Products with an IDEMPOTENT
--           ProcessReceipt. The framework had zero MarketplaceService usage, so
--           it literally couldn't take Robux. ProcessReceipt without idempotency
--           is the classic dupe/loss bug; here each granted PurchaseId is
--           persisted in the player's profile so Roblox's retry can never
--           double-grant.
--
-- Access  : Gaxia.Monetization  (server) — list "Monetization" in Features (or touch
--           it at boot) so ProcessReceipt is set before the first receipt arrives:
--   Gaxia.Monetization.RegisterProduct(123456, function(player, receipt)
--     Gaxia.Economy.Add(player, "Gems", 100)
--   end)
--   Gaxia.Monetization.PromptProduct(player, 123456)
--   if Gaxia.Monetization.OwnsGamePass(player, 9999) then ... end
-- ─────────────────────────────────────────────────────────────
local MarketplaceService = game:GetService("MarketplaceService")
local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
-- DataManager is only called from HandleReceipt (call time): a plain require, not a Need.
local Shared      = ReplicatedStorage.Gaxia_Packages.Shared
local Signal      = require(Shared.Signal)
local Lifecycle   = require(script.Parent.ServiceLifecycle)
local DataManager = require(script.Parent.DataManager)

-- ── Types ──
-- The receiptInfo table Roblox passes to MarketplaceService.ProcessReceipt. Roblox
-- always sends every field; the ones HandleReceipt does not read are optional so a
-- hand-made receipt (tests) still type-checks.
export type ReceiptInfo = {
	PlayerId: number,
	PurchaseId: string,
	ProductId: number,
	CurrencySpent: number?,
	CurrencyType: Enum.CurrencyType?,
	PlaceIdWherePurchased: number?,
	[string]: any,
}
-- Grants a Developer Product. Must be deterministic and side-effect-once; it is never
-- called twice for the same PurchaseId.
export type GrantFn = (player: Player, receipt: ReceiptInfo) -> ()

local RECEIPTS_KEY : string = "ProcessedReceipts"  -- Profile.Data key: { [purchaseId]=true }

local Monetization = {}

-- (player, productId, receiptInfo) after a product's grant succeeded and was recorded
Monetization.OnPurchase = Signal.new() :: Signal.Signal<Player, number, ReceiptInfo>

local productGrants : { [number]: GrantFn } = {}
local gamePassCache : { [Player]: { [number]: boolean } } = setmetatable({}, { __mode = "k" }) :: any

-- ── Public API ──

-- Register the grant for a Developer Product. grantFn must be deterministic and
-- side-effect-once; idempotency is handled here (it won't be called twice for
-- the same PurchaseId).
function Monetization.RegisterProduct(productId: number, grantFn: GrantFn): ()
	productGrants[productId] = grantFn
end

function Monetization.PromptProduct(player: Player, productId: number): ()
	MarketplaceService:PromptProductPurchase(player, productId)
end

function Monetization.PromptGamePass(player: Player, gamePassId: number): ()
	MarketplaceService:PromptGamePassPurchase(player, gamePassId)
end

-- Cached ownership check (UserOwnsGamePassAsync yields + can error; cache per player).
function Monetization.OwnsGamePass(player: Player, gamePassId: number): boolean
	local cached = gamePassCache[player]
	if cached and cached[gamePassId] ~= nil then
		return cached[gamePassId]
	end
	local ok, owns = pcall(function(): boolean
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamePassId)
	end)
	local result = ok and owns == true
	local pc: { [number]: boolean } = cached or {}
	pc[gamePassId] = result
	gamePassCache[player] = pc
	return result
end

-- ── ProcessReceipt (idempotent) ──
local Decision = Enum.ProductPurchaseDecision

-- A local function so Init binds this exact function (Monetization.HandleReceipt is
-- the same function once the service has started).
local function handleReceipt(receiptInfo: ReceiptInfo): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Decision.NotProcessedYet -- player left; Roblox retries when they return
	end
	if not DataManager.IsLoaded(player) then
		return Decision.NotProcessedYet -- profile not ready (or Data not running); retry
	end

	local processed = DataManager.Get(player, RECEIPTS_KEY)
	if typeof(processed) ~= "table" then
		processed = {}
	end
	local pid = tostring(receiptInfo.PurchaseId)
	if processed[pid] then
		return Decision.PurchaseGranted -- already granted → idempotent, never double-grant
	end

	local grant = productGrants[receiptInfo.ProductId]
	if not grant then
		-- Unknown product (maybe registered after a restart) — do NOT consume; retry later.
		return Decision.NotProcessedYet
	end

	local ok, err = pcall(grant :: (Player, ReceiptInfo) -> ...any, player, receiptInfo)
	if not ok then
		warn(`[Monetization] grant for product {receiptInfo.ProductId} failed: {err}`)
		return Decision.NotProcessedYet -- grant errored → retry (don't mark processed)
	end

	-- Persist the PurchaseId BEFORE returning Granted so a retry can't re-grant.
	processed[pid] = true
	DataManager.Set(player, RECEIPTS_KEY, processed)
	DataManager.Save(player) -- nudge a save so the receipt record isn't lost on a crash
	Monetization.OnPurchase:Fire(player, receiptInfo.ProductId, receiptInfo)
	return Decision.PurchaseGranted
end
Monetization.HandleReceipt = handleReceipt

-- Init installs the single allowed ProcessReceipt callback (last writer wins). List
-- "Monetization" in Features when the game sells Developer Products so it is bound at
-- boot; otherwise it binds the first time the game touches Gaxia.Monetization or calls
-- one of its functions (e.g. RegisterProduct) — NOT when the module is merely
-- required, as it used to be. A game that installs its own ProcessReceipt router
-- (delegating to HandleReceipt) must start Monetization first (Features,
-- GaxiaServer.Monetization, or GaxiaServer.Lifecycle.Ensure) and assign its router
-- after, or Init overwrites it.
Lifecycle.Define(Monetization, {
	Name = "Monetization",
	Needs = {},
	Init = function()
		MarketplaceService.ProcessReceipt = handleReceipt
	end,
})

return Monetization
