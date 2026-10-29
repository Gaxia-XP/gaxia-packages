--!strict
-- ─────────────────────────────────────────────────────────────
-- LeaderboardService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/LeaderboardService
-- Purpose : Thin OrderedDataStore wrapper for global top-N
--           leaderboards with name resolution and 60s caching
--           so we don't burn the per-server DataStore budget.
--
-- Lifecycle: pure API (nothing to set up).
-- ─────────────────────────────────────────────────────────────

local DataStoreService = game:GetService("DataStoreService")
local UserService = game:GetService("UserService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Signal    = require(ReplicatedStorage.Gaxia_Packages.Shared.Signal)
local Lifecycle = require(script.Parent.ServiceLifecycle)
local Config    = require(script.Parent.Parent.Config)
local EConfig   = require(script.Parent.EffectiveConfig)

-- Config default <- runtime Flag override, read per call.
local function cacheTTL(): number
	return EConfig.Get("Leaderboard.CacheTTL", Config.Leaderboard.CacheTTL or 60)
end

-- OrderedDataStore pages hold 1..100 entries (GetSortedAsync errors outside that).
local MAX_TOP_N: number = 100

-- Clamp a requested entry count to a whole number in 1..MAX_TOP_N.
local function clampCount(n: number): number
	if n ~= n then
		return MAX_TOP_N -- NaN
	end
	return math.clamp(math.floor(n), 1, MAX_TOP_N)
end

local function defaultTopN(): number
	return clampCount(EConfig.Get("Leaderboard.DefaultTopN", Config.Leaderboard.DefaultTopN or MAX_TOP_N))
end

-- ── Types ──
export type LeaderboardEntry = {
	userId: number,
	name: string?,
	value: number,
	rank: number,
}

type CachedTop = {
	entries: { LeaderboardEntry },
	expiresAt: number,
}

-- ── Module ──
local LeaderboardService = {}

-- WHY: keep one OrderedDataStore handle per board name to share quota.
local stores: { [string]: OrderedDataStore } = {}
local topCache: { [string]: CachedTop } = {}

-- (name, userId, value) after a successful Update write (value is the stored whole number)
LeaderboardService.OnUpdate = Signal.new() :: Signal.Signal<string, number, number>

-- ── Helpers ──

local function getCacheKey(name: string, count: number): string
	return `{name}::{count}`
end

local function invalidateCacheForName(name: string): ()
	-- WHY: a single Update can change any rank, so blow away every cached count for this board.
	for key in pairs(topCache) do
		if string.sub(key, 1, #name + 2) == `{name}::` then
			topCache[key] = nil
		end
	end
end

-- ── Public API ──

function LeaderboardService.GetStore(name: string): OrderedDataStore
	local existing: OrderedDataStore? = stores[name]
	if existing then
		return existing
	end
	local store: OrderedDataStore = DataStoreService:GetOrderedDataStore(name)
	stores[name] = store
	return store
end

-- Write a player's score. OrderedDataStore keeps whole numbers only, so `value` is
-- rounded down (12.7 -> 12). Returns false (with a warning) for a value that is not a
-- finite number, or when the write fails.
function LeaderboardService.Update(name: string, userId: number, value: number): boolean
	if typeof(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		warn(`[LeaderboardService] Update ignored for {name}/{userId}: value must be a finite number, got {value}`)
		return false
	end
	local intValue: number = math.floor(value)
	local store: OrderedDataStore = LeaderboardService.GetStore(name)
	local ok, err = pcall(function()
		store:SetAsync(tostring(userId), intValue)
	end)
	if not ok then
		warn(`[LeaderboardService] Update failed for {name}/{userId}: {err}`)
		return false
	end
	invalidateCacheForName(name)
	LeaderboardService.OnUpdate:Fire(name, userId, intValue)
	return true
end

-- The top `count` entries (default Leaderboard.DefaultTopN), best first. `count` is
-- clamped to 1..100 (an OrderedDataStore page holds at most 100). Cached CacheTTL seconds.
function LeaderboardService.GetTop(name: string, count: number?): { LeaderboardEntry }
	local n: number = if typeof(count) == "number" then clampCount(count) else defaultTopN()
	local cacheKey: string = getCacheKey(name, n)
	local cached: CachedTop? = topCache[cacheKey]
	if cached and cached.expiresAt > os.clock() then
		return cached.entries
	end

	local store: OrderedDataStore = LeaderboardService.GetStore(name)
	local results: { LeaderboardEntry } = {}

	local ok, pages = pcall(function()
		return store:GetSortedAsync(false, n)
	end)
	if not ok or not pages then
		warn(`[LeaderboardService] GetSortedAsync failed for {name}: {pages}`)
		return results
	end

	local ok2, page = pcall(function()
		return pages:GetCurrentPage()
	end)
	if not ok2 or not page then
		warn(`[LeaderboardService] GetCurrentPage failed for {name}: {page}`)
		return results
	end

	local userIds: { number } = {}
	for rank, entry in ipairs(page) do
		local uid: number = tonumber(entry.key) or 0
		table.insert(results, {
			userId = uid,
			name = nil,
			value = entry.value,
			rank = rank,
		})
		if uid > 0 then
			table.insert(userIds, uid)
		end
	end

	-- WHY: name resolution is best-effort; never fail the board because a username lookup tripped.
	if #userIds > 0 then
		local okNames, infos = pcall(function()
			return UserService:GetUserInfosByUserIdsAsync(userIds)
		end)
		if okNames and infos then
			local byId: { [number]: string } = {}
			for _, info in ipairs(infos) do
				byId[info.Id] = info.Username
			end
			for _, row in ipairs(results) do
				row.name = byId[row.userId]
			end
		else
			warn(`[LeaderboardService] Username resolution failed for {name}: {infos}`)
		end
	end

	topCache[cacheKey] = {
		entries = results,
		expiresAt = os.clock() + cacheTTL(),
	}
	return results
end

function LeaderboardService.GetRank(name: string, userId: number): number?
	-- WHY: scan the cached/fetched top list; OrderedDataStore has no direct rank lookup.
	local top: { LeaderboardEntry } = LeaderboardService.GetTop(name, defaultTopN())
	for _, entry in ipairs(top) do
		if entry.userId == userId then
			return entry.rank
		end
	end
	return nil
end

-- Pure API: nothing to set up. Registered so Features / IsEnabled know it.
Lifecycle.Define(LeaderboardService, {
	Name = "Leaderboard",
	Needs = {},
})

return LeaderboardService
