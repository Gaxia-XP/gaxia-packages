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
-- Access  : Gaxia.Monetization  (server) — touch it at boot so ProcessReceipt is set:
--   Gaxia.Monetization.RegisterProduct(123456, function(player, receipt)
--     Gaxia.Economy.Add(player, "Gems", 100)
--   end)
--   Gaxia.Monetization.PromptProduct(player, 123456)
--   if Gaxia.Monetization.OwnsGamePass(player, 9999) then ... end
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local MarketplaceService = game:GetService("MarketplaceService")
local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local ServerStorage      = game:GetService("ServerStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages"):WaitForChild("init")) :: any
local Signal = SharedPkg.Signal

local RECEIPTS_KEY : string = "ProcessedReceipts"  -- Profile.Data key: { [purchaseId]=true }

local Monetization = {}

-- (player, productId, receiptInfo)
Monetization.OnPurchase = Signal.new()

local productGrants : { [number]: (player: Player, receipt: any) -> () } = {}
local gamePassCache : { [Player]: { [number]: boolean } } = setmetatable({}, { __mode = "k" }) :: any

-- Lazy DataManager (require the loader at call time, not under the load metamethod).
local GaxiaServer: any = nil
local function getData(): any
	if not GaxiaServer then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server"):WaitForChild("init")
		GaxiaServer = require(serverInit :: any)
	end
	return GaxiaServer.Data
end

-- ── Public API ──

-- Register the grant for a Developer Product. grantFn must be deterministic and
-- side-effect-once; idempotency is handled here (it won't be called twice for
-- the same PurchaseId).
function Monetization.RegisterProduct(productId: number, grantFn: (player: Player, receipt: any) -> ()): ()
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
	local pc = gamePassCache[player]
	if pc and pc[gamePassId] ~= nil then
		return pc[gamePassId]
	end
	local ok, owns = pcall(function(): boolean
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamePassId)
	end)
	local result = ok and owns == true
	pc = pc or {}
	pc[gamePassId] = result
	gamePassCache[player] = pc
	return result
end

-- ── ProcessReceipt (idempotent) ──
local Decision = Enum.ProductPurchaseDecision

function Monetization.HandleReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Decision.NotProcessedYet -- player left; Roblox retries when they return
	end
	local Data = getData()
	if not Data or not Data.IsLoaded(player) then
		return Decision.NotProcessedYet -- profile not ready; retry
	end

	local processed = Data.Get(player, RECEIPTS_KEY)
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

	local ok, err = pcall(grant, player, receiptInfo)
	if not ok then
		warn(`[Monetization] grant for product {receiptInfo.ProductId} failed: {err}`)
		return Decision.NotProcessedYet -- grant errored → retry (don't mark processed)
	end

	-- Persist the PurchaseId BEFORE returning Granted so a retry can't re-grant.
	processed[pid] = true
	Data.Set(player, RECEIPTS_KEY, processed)
	Data.Save(player) -- nudge a save so the receipt record isn't lost on a crash
	Monetization.OnPurchase:Fire(player, receiptInfo.ProductId, receiptInfo)
	return Decision.PurchaseGranted
end

-- Install the single allowed ProcessReceipt callback (set at module load → the
-- game must touch Gaxia.Monetization at boot, e.g. RegisterProduct, for it to bind).
MarketplaceService.ProcessReceipt = Monetization.HandleReceipt

return Monetization
