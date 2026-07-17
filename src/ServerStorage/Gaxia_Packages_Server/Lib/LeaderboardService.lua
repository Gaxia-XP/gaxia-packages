--!strict
-- ─────────────────────────────────────────────────────────────
-- LeaderboardService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/LeaderboardService
-- Purpose : Thin OrderedDataStore wrapper for global top-N
--           leaderboards with name resolution and 60s caching
--           so we don't burn the per-server DataStore budget.
-- ─────────────────────────────────────────────────────────────

local CollectionService = game:GetService("CollectionService")

local DataStoreService = game:GetService("DataStoreService")
local UserService = game:GetService("UserService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal = SharedPkg.Signal

-- Lazy server access for Config (call-time; never at module load).
local GaxiaServer: any = nil
local function cacheTTL(): number
	if not GaxiaServer then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server")
		GaxiaServer = require(serverInit :: any)
	end
	return GaxiaServer.EConfig.Get("Leaderboard.CacheTTL", (GaxiaServer.Config.Leaderboard or {}).CacheTTL or 60)
end

local function defaultTopN(): number
	if not GaxiaServer then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server")
		GaxiaServer = require(serverInit :: any)
	end
	return GaxiaServer.EConfig.Get("Leaderboard.DefaultTopN", (GaxiaServer.Config.Leaderboard or {}).DefaultTopN or 100)
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

LeaderboardService.OnUpdate = Signal.new()

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

function LeaderboardService.Update(name: string, userId: number, value: number): boolean
	local store: OrderedDataStore = LeaderboardService.GetStore(name)
	local ok, err = pcall(function()
		store:SetAsync(tostring(userId), value)
	end)
	if not ok then
		warn(`[LeaderboardService] Update failed for {name}/{userId}: {err}`)
		return false
	end
	invalidateCacheForName(name)
	LeaderboardService.OnUpdate:Fire(name, userId, value)
	return true
end

function LeaderboardService.GetTop(name: string, count: number?): { LeaderboardEntry }
	local n: number = count or defaultTopN()
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

return LeaderboardService
