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
--   Gaxia.Monetization.OnGamePassPurchased:Connect(function(player, passId) ... end)
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

-- Profile.Data key: { [purchaseId] = order }. `order` counts up per player (1, 2, 3 …) so
-- the oldest records can be pruned; records saved by older versions hold `true` and
-- count as the oldest.
local RECEIPTS_KEY : string = "ProcessedReceipts"
-- How many granted PurchaseIds each player keeps. Roblox only re-sends a receipt that
-- was never acknowledged, so a short recent history is enough to stop a double grant
-- (a crash between the save and the PurchaseGranted reply), and the saved data no
-- longer grows with every purchase.
local MAX_RECEIPT_HISTORY : number = 100

local Monetization = {}

-- (player, productId, receiptInfo) after a product's grant succeeded and was recorded
Monetization.OnPurchase = Signal.new() :: Signal.Signal<Player, number, ReceiptInfo>
-- (player, gamePassId) when a player buys a game pass in this server
-- (MarketplaceService.PromptGamePassPurchaseFinished with wasPurchased = true).
-- OwnsGamePass returns true for that pass from then on.
Monetization.OnGamePassPurchased = Signal.new() :: Signal.Signal<Player, number>

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

local function setCachedOwnership(player: Player, gamePassId: number, owns: boolean): ()
	local pc = gamePassCache[player]
	if pc == nil then
		pc = {}
		gamePassCache[player] = pc
	end
	pc[gamePassId] = owns
end

-- Does the player own the game pass? Yields the first time for each (player, pass)
-- (UserOwnsGamePassAsync); the answer is then cached for the session. A failed Roblox
-- check returns false and is NOT cached, so the next call asks Roblox again. A pass
-- bought in this server (PromptGamePassPurchaseFinished) counts as owned at once.
-- Refunds or revokes during the session are only seen after the player rejoins.
function Monetization.OwnsGamePass(player: Player, gamePassId: number): boolean
	local cached = gamePassCache[player]
	if cached and cached[gamePassId] ~= nil then
		return cached[gamePassId]
	end
	local ok, owns = pcall(function(): boolean
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamePassId)
	end)
	if not ok then
		return false -- Roblox check failed: do not cache, retry on the next call
	end
	local result = owns == true
	-- A purchase that finished while this call yielded wins over the older answer.
	local now = gamePassCache[player]
	if now and now[gamePassId] == true then
		return true
	end
	setCachedOwnership(player, gamePassId, result)
	return result
end

local function onGamePassPurchaseFinished(player: Player, gamePassId: number, wasPurchased: boolean): ()
	if not wasPurchased then
		return
	end
	setCachedOwnership(player, gamePassId, true)
	Monetization.OnGamePassPurchased:Fire(player, gamePassId)
end

-- ── ProcessReceipt (idempotent) ──
local Decision = Enum.ProductPurchaseDecision

-- Record `pid` as granted, newest last, and drop the oldest records beyond
-- MAX_RECEIPT_HISTORY. Old `true` records (earlier versions) sort as the oldest.
type ReceiptRecord = { pid: string, order: number }
local function recordReceipt(processed: { [string]: any }, pid: string): ()
	local entries: { ReceiptRecord } = {}
	local newest = 0
	for key, value in processed do
		local order = if typeof(value) == "number" then value else 0
		newest = math.max(newest, order)
		table.insert(entries, { pid = key, order = order })
	end
	processed[pid] = newest + 1
	local excess = #entries + 1 - MAX_RECEIPT_HISTORY
	if excess <= 0 then
		return
	end
	table.sort(entries, function(a: ReceiptRecord, b: ReceiptRecord): boolean
		if a.order ~= b.order then
			return a.order < b.order
		end
		return a.pid < b.pid
	end)
	for i = 1, excess do
		processed[entries[i].pid] = nil
	end
end

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
	recordReceipt(processed, pid)
	DataManager.Set(player, RECEIPTS_KEY, processed)
	DataManager.Save(player) -- nudge a save so the receipt record isn't lost on a crash
	Monetization.OnPurchase:Fire(player, receiptInfo.ProductId, receiptInfo)
	return Decision.PurchaseGranted
end
Monetization.HandleReceipt = handleReceipt

-- Init installs the single allowed ProcessReceipt callback (last writer wins) and
-- listens to PromptGamePassPurchaseFinished (OnGamePassPurchased / OwnsGamePass). List
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
		MarketplaceService.PromptGamePassPurchaseFinished:Connect(onGamePassPurchaseFinished)
	end,
})

return Monetization
