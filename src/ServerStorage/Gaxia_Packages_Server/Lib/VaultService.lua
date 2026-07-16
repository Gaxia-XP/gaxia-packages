--!strict
-- ─────────────────────────────────────────────────────────────
-- VaultService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/VaultService
-- Purpose : Capacity-bounded, server-authoritative secure storage — the "bank"
--           tycoons/heist games need that's separate from the carry inventory.
--           Deposit moves items from Gaxia.Item into a capacity-checked vault;
--           Withdraw moves them back; both atomic (refund on failure). GetValue
--           sums stored items by a value table — the number a heist loots against
--           and a leaderboard ranks on. Capacity is per-player and upgradeable.
--           Persisted under "Vault" / "VaultCapacity".
--
-- Access  : Gaxia.Vault  (server)
--   Gaxia.Vault.SetItemValue("Diamond", 100)
--   Gaxia.Vault.Deposit(player, "Diamond", 3)
--   local net = Gaxia.Vault.GetValue(player)   -- heist loot-cap / leaderboard
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages"):WaitForChild("init")) :: any
local Signal = SharedPkg.Signal

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

local VAULT_KEY    : string = "Vault"
local CAPACITY_KEY : string = "VaultCapacity"
local DEFAULT_CAPACITY : number = 100        -- ultimate fallback if Config absent
local MAX_CAPACITY     : number = 10_000_000

-- Effective tunable: runtime Flag override <- Config.Vault default <- fallback.
local function vaultGet(key: string, fallback: any): any
	local s = server()
	return s.EConfig.Get(`Vault.{key}`, (s.Config.Vault or {})[key] or fallback)
end

local VaultService = {}

VaultService.OnChanged = Signal.new() -- (player, itemId, newCount)

-- Global per-item value registry (for GetValue). Default 1.
local itemValues: { [string]: number } = {}

-- ── Value registry ──

function VaultService.SetItemValue(itemId: string, value: number): ()
	itemValues[itemId] = math.max(0, value)
end

function VaultService.GetItemValue(itemId: string): number
	return itemValues[itemId] or vaultGet("DefaultItemValue", 1)
end

-- ── Persistence helpers ──

local function loadVault(player: Player): { [string]: number }
	local v = server().Data.Get(player, VAULT_KEY)
	return (typeof(v) == "table") and v or {}
end

local function saveVault(player: Player, v: { [string]: number }): ()
	server().Data.Set(player, VAULT_KEY, v)
end

-- ── Capacity ──

function VaultService.GetCapacity(player: Player): number
	local c = server().Data.Get(player, CAPACITY_KEY)
	return (typeof(c) == "number") and c or vaultGet("DefaultCapacity", DEFAULT_CAPACITY)
end

function VaultService.SetCapacity(player: Player, n: number): ()
	local clamped = math.clamp(math.floor(n), 0, vaultGet("MaxCapacity", MAX_CAPACITY))
	server().Data.Set(player, CAPACITY_KEY, clamped)
end

function VaultService.AddCapacity(player: Player, delta: number): number
	local next = math.clamp(VaultService.GetCapacity(player) + math.floor(delta), 0, vaultGet("MaxCapacity", MAX_CAPACITY))
	server().Data.Set(player, CAPACITY_KEY, next)
	return next
end

-- ── Contents / usage ──

function VaultService.GetContents(player: Player): { [string]: number }
	local v = loadVault(player)
	local out: { [string]: number } = {}
	for k, n in pairs(v) do
		out[k] = n
	end
	return out
end

function VaultService.GetCount(player: Player, itemId: string): number
	return loadVault(player)[itemId] or 0
end

function VaultService.GetUsed(player: Player): number
	local total = 0
	for _, n in pairs(loadVault(player)) do
		total += n
	end
	return total
end

function VaultService.GetFree(player: Player): number
	return math.max(0, VaultService.GetCapacity(player) - VaultService.GetUsed(player))
end

-- Total stored value (sum of count × per-item value) — heist loot-cap / leaderboard.
function VaultService.GetValue(player: Player): number
	local total = 0
	for itemId, n in pairs(loadVault(player)) do
		total += n * VaultService.GetItemValue(itemId)
	end
	return total
end

-- ── Deposit / Withdraw (atomic against Gaxia.Item) ──

function VaultService.Deposit(player: Player, itemId: string, count: number?): (boolean, string)
	local amount = math.floor(count or 1)
	-- amount ~= amount catches NaN, which passes `<= 0` (NaN comparisons are
	-- all false) and would otherwise poison the persisted vault table.
	if amount ~= amount or amount <= 0 then
		return false, "bad amount"
	end
	if VaultService.GetUsed(player) + amount > VaultService.GetCapacity(player) then
		return false, "vault full"
	end
	local Item = server().Item
	if not Item.Remove(player, itemId, amount) then
		return false, "not enough in inventory"
	end
	local v = loadVault(player)
	v[itemId] = (v[itemId] or 0) + amount
	saveVault(player, v)
	VaultService.OnChanged:Fire(player, itemId, v[itemId])
	return true, "ok"
end

function VaultService.Withdraw(player: Player, itemId: string, count: number?): (boolean, string)
	local amount = math.floor(count or 1)
	-- NaN guard: `have < NaN` is false, so NaN would pass the stock check and
	-- write `have - NaN` (NaN) into the vault before the refund logic runs.
	if amount ~= amount or amount <= 0 then
		return false, "bad amount"
	end
	local v = loadVault(player)
	local have = v[itemId] or 0
	if have < amount then
		return false, "not enough in vault"
	end
	-- Remove from vault first; refund if the inventory credit fails.
	local nextCount = have - amount
	if nextCount == 0 then
		v[itemId] = nil
	else
		v[itemId] = nextCount
	end
	saveVault(player, v)

	local Item = server().Item
	if not Item.Give(player, itemId, amount) then
		v[itemId] = have -- refund vault
		saveVault(player, v)
		return false, "inventory credit failed"
	end
	VaultService.OnChanged:Fire(player, itemId, nextCount)
	return true, "ok"
end

return VaultService
