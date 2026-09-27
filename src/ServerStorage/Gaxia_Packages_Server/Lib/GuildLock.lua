--!strict
-- ─────────────────────────────────────────────────────────────
-- GuildLock.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/GuildLock
-- Purpose : Cross-server mutex for guild record mutations. Wraps
--           MemoryStoreSortedMap:UpdateAsync with a compare-and-set
--           owner-token. WithLock(guildId, fn, ttl) acquires, runs fn,
--           and releases (release is in a pcall so a throwing fn still
--           releases). Read paths (no mutation) do NOT use this lock —
--           reads hit DataStore directly.
-- Access  : Gaxia.GuildLock  (server)
-- ─────────────────────────────────────────────────────────────
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")

local Lifecycle = require(script.Parent.ServiceLifecycle)

local MAP_NAME: string = "GaxiaGuildLocks"
local MAX_ATTEMPTS: number = 3
local BACKOFF_MS: { number } = { 50, 150, 300 }
local DEFAULT_TTL: number = 5

local GuildLock = {}

local function map(): MemoryStoreSortedMap
	return MemoryStoreService:GetSortedMap(MAP_NAME)
end

local function newOwnerId(): string
	return string.format("%s:%s", game.JobId, HttpService:GenerateGUID(false))
end

-- Try to claim the lock for `ownerId`. Returns true if claim succeeded.
local function tryClaim(guildId: string, ownerId: string, ttlSec: number): boolean
	local claimed = false
	local ok, err = pcall(function()
		map():UpdateAsync(guildId, function(current: any): string?
			-- nil  → free, claim it
			-- ""   → released sentinel (see Release), treat as free
			-- ours → renew
			-- else → held by someone else, refuse
			if current == nil or current == "" or current == ownerId then
				claimed = true
				return ownerId
			end
			claimed = false
			return nil -- no-op write
		end, ttlSec)
	end)
	if not ok then
		warn(`[GuildLock] UpdateAsync failed for guild '{guildId}': {tostring(err)}`)
		return false
	end
	return claimed
end

function GuildLock.Acquire(guildId: string, ttlSec: number?): (string?, string?)
	local ttl = ttlSec or DEFAULT_TTL
	local ownerId = newOwnerId()
	for attempt = 1, MAX_ATTEMPTS do
		if tryClaim(guildId, ownerId, ttl) then
			return ownerId, nil
		end
		if attempt < MAX_ATTEMPTS then
			task.wait(BACKOFF_MS[attempt] / 1000)
		end
	end
	return nil, "lock busy"
end

function GuildLock.Renew(guildId: string, ownerId: string, ttlSec: number): boolean
	-- Re-claim with our own ownerId; tryClaim's "ours → renew" branch handles it.
	return tryClaim(guildId, ownerId, ttlSec)
end

function GuildLock.Release(guildId: string, ownerId: string): ()
	-- Use UpdateAsync to atomically CAS-verify ownership AND clear in one shot:
	-- writing the empty-string sentinel ("") with TTL=1 expires fast and is treated
	-- as "free" by tryClaim's nil-or-ours check. Returning nil from the transform
	-- would only ABORT the update (it does NOT delete in MemoryStoreSortedMap), so
	-- we cannot rely on that path. If current ~= ownerId (TTL expired, someone
	-- else took over), we leave the slot alone.
	local ok, err = pcall(function()
		map():UpdateAsync(guildId, function(current: any): string?
			if current == ownerId then
				return "" -- sentinel: not ours, not held; will expire in 1s anyway
			end
			return nil -- not ours; cancel the update
		end, 1)
	end)
	if not ok then
		warn(`[GuildLock] Release UpdateAsync failed for guild '{guildId}': {tostring(err)}`)
	end
end

function GuildLock.WithLock(guildId: string, fn: () -> any, ttlSec: number?): (boolean, any)
	local ownerId, reason = GuildLock.Acquire(guildId, ttlSec)
	if not ownerId then
		return false, reason or "lock busy"
	end
	local ok, result = pcall(fn)
	GuildLock.Release(guildId, ownerId)
	if not ok then
		return false, result
	end
	return true, result
end

-- Pure API: nothing to set up. Registered so Features / IsEnabled know it.
Lifecycle.Define(GuildLock, {
	Name = "GuildLock",
	Needs = {},
})

return GuildLock
