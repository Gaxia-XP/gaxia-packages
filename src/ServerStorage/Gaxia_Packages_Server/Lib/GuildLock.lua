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
--           Studio fallback: when MemoryStore is unavailable in Studio (place
--           not published, or Studio API access off) the lock switches to a
--           single-server in-memory lock for the rest of the session (one warn).
--           Live servers never fall back: a MemoryStore error is "lock busy".
-- Access  : Gaxia.GuildLock  (server)
-- ─────────────────────────────────────────────────────────────
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local RunService = game:GetService("RunService")

local Lifecycle = require(script.Parent.ServiceLifecycle)

local MAP_NAME: string = "GaxiaGuildLocks"
local MAX_ATTEMPTS: number = 3
local BACKOFF_MS: { number } = { 50, 150, 300 }
local DEFAULT_TTL: number = 5

local GuildLock = {}

-- Studio-only single-server fallback (see header). guildId -> holder.
type LocalHold = { owner: string, expires: number }
local localLocks: { [string]: LocalHold } = {}
local useLocal = false

local function map(): MemoryStoreSortedMap
	return MemoryStoreService:GetSortedMap(MAP_NAME)
end

-- In Studio, switch to the in-memory lock after the first MemoryStore error.
-- Returns true when the caller should use the local lock from now on.
local function fallBackToLocal(err: any): boolean
	if useLocal then
		return true
	end
	if not RunService:IsStudio() then
		return false
	end
	useLocal = true
	warn(
		`[GuildLock] MemoryStore unavailable in Studio ({tostring(err)}); using a single-server lock for this session. Publish the place and enable Studio API access to test the cross-server lock.`
	)
	return true
end

local function localClaim(guildId: string, ownerId: string, ttlSec: number): boolean
	local now = os.clock()
	local hold = localLocks[guildId]
	if hold == nil or hold.expires <= now or hold.owner == ownerId then
		localLocks[guildId] = { owner = ownerId, expires = now + ttlSec }
		return true
	end
	return false
end

local function newOwnerId(): string
	return string.format("%s:%s", game.JobId, HttpService:GenerateGUID(false))
end

-- Try to claim the lock for `ownerId`. Returns true if claim succeeded.
local function tryClaim(guildId: string, ownerId: string, ttlSec: number): boolean
	if useLocal then
		return localClaim(guildId, ownerId, ttlSec)
	end
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
		if fallBackToLocal(err) then
			return localClaim(guildId, ownerId, ttlSec)
		end
		warn(`[GuildLock] UpdateAsync failed for guild '{guildId}': {tostring(err)}`)
		return false
	end
	return claimed
end

-- Claims the lock for `guildId` (retries 3 times with a short backoff). Returns
-- (ownerId, nil), or (nil, "lock busy") when another holder has it or MemoryStore
-- fails on a live server. In Studio without MemoryStore it uses a single-server lock.
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
	if useLocal then
		local hold = localLocks[guildId]
		if hold and hold.owner == ownerId then
			localLocks[guildId] = nil
		end
		return
	end
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
