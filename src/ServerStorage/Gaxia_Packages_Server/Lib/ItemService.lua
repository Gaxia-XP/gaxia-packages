--!strict
--[[
	Module : ItemService
	Location: ServerStorage.Gaxia_Packages_Server.Lib.ItemService
	Purpose : Per-player inventory backed by DataManager's Profile.Inventory dict.
	          Give / Remove / Has / Count operations with anti-exploit clamping.
]]


-- ── Services ──
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

-- ── Shared ──
local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages"):WaitForChild("init")) :: any
local Signal    = SharedPkg.Signal

-- ── Lazy server packages (DataManager + Config + EConfig) ──
-- Defer require to first use so module-load order is not strict.
local GaxiaServer: any = nil
local function server(): any
	if not GaxiaServer then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server"):WaitForChild("init")
		GaxiaServer = require(serverInit :: any)
	end
	return GaxiaServer
end
local function getDataManager(): any
	return server().Data
end

-- ── Constants ──
local INVENTORY_KEY        : string = "Inventory"
local DEFAULT_MAX_ITEM_COUNT : number = 999_999    -- per-item clamp to defang exploit-driven Give calls
local DEFAULT_COUNT        : number = 1

-- Effective per-item clamp (Config default <- runtime override), read at call-time.
local function maxItemCount(): number
	local s = server()
	return s.EConfig.Get("Inventory.MaxItemCount", (s.Config.Inventory or {}).MaxItemCount or DEFAULT_MAX_ITEM_COUNT)
end

-- ── Module ──
local ItemService = {}

ItemService.OnItemChanged = Signal.new()

-- ── Helpers ──

-- Reads the current Inventory dict from DataManager, creating it if missing.
local function getInventory(player: Player): { [string]: number }?
	local Data = getDataManager()
	if not Data then return nil end
	local inv = Data.Get(player, INVENTORY_KEY)
	if typeof(inv) ~= "table" then
		-- Profile not loaded yet — caller decides whether to retry.
		return nil
	end
	return inv :: { [string]: number }
end

local function commit(player: Player, inventory: { [string]: number })
	local Data = getDataManager()
	if Data then Data.Set(player, INVENTORY_KEY, inventory) end
end

local function clampCount(count: number): number
	-- Anti-exploit: even if a server caller (or RemoteEvent) supplies a bogus
	-- number, the count never goes above the effective max or below 0.
	-- NaN must be caught explicitly: it passes BOTH one-sided comparisons below
	-- (every NaN comparison is false) and floor(NaN) is NaN — once committed it
	-- poisons the profile (DataStore rejects NaN, so every later save fails).
	if count ~= count then return 0 end
	local maxCount = maxItemCount()
	if count < 0 then return 0 end
	if count > maxCount then return maxCount end
	return math.floor(count)
end

-- ── Public API ──

-- Returns (ok, deliveredDelta). The delta can be less than the requested count
-- (per-item clamp absorbing into a near-full stack) — callers that echo the
-- amount back to a human must report the delta, not the request.
function ItemService.Give(player: Player, itemId: string, count: number?): (boolean, number?)
	assert(typeof(itemId) == "string" and #itemId > 0, "itemId must be non-empty string")
	local amount = clampCount(count or DEFAULT_COUNT)
	if amount <= 0 then return false end

	local inv = getInventory(player)
	if not inv then return false end

	local prev = inv[itemId] or 0
	local nextCount = clampCount(prev + amount)
	inv[itemId] = nextCount
	commit(player, inv)
	ItemService.OnItemChanged:Fire(player, itemId, nextCount, nextCount - prev)
	return true, nextCount - prev
end

function ItemService.Remove(player: Player, itemId: string, count: number?): boolean
	assert(typeof(itemId) == "string" and #itemId > 0, "itemId must be non-empty string")
	local amount = clampCount(count or DEFAULT_COUNT)
	if amount <= 0 then return false end

	local inv = getInventory(player)
	if not inv then return false end

	local prev = inv[itemId] or 0
	if prev < amount then
		-- Reject silent under-removal so callers can detect insufficient stock.
		return false
	end
	local nextCount = prev - amount
	if nextCount == 0 then
		inv[itemId] = nil
	else
		inv[itemId] = nextCount
	end
	commit(player, inv)
	ItemService.OnItemChanged:Fire(player, itemId, nextCount, nextCount - prev)
	return true
end

function ItemService.Has(player: Player, itemId: string, count: number?): boolean
	local needed = math.max(1, clampCount(count or DEFAULT_COUNT))
	return ItemService.Count(player, itemId) >= needed
end

function ItemService.Count(player: Player, itemId: string): number
	local inv = getInventory(player)
	if not inv then return 0 end
	return inv[itemId] or 0
end

function ItemService.GetInventory(player: Player): { [string]: number }?
	local inv = getInventory(player)
	if not inv then return nil end
	-- Shallow copy so callers cannot mutate profile data directly.
	local out: { [string]: number } = {}
	for k, v in pairs(inv) do out[k] = v end
	return out
end

function ItemService.Clear(player: Player, itemId: string): ()
	local inv = getInventory(player)
	if not inv then return end
	if inv[itemId] then
		local prev = inv[itemId]
		inv[itemId] = nil
		commit(player, inv)
		ItemService.OnItemChanged:Fire(player, itemId, 0, -prev)
	end
end

return ItemService
