--!strict
-- ─────────────────────────────────────────────────────────────
-- InviteQueue.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/InviteQueue
-- Purpose : Durable cross-server invite delivery. One MemoryStoreSortedMap
--           per kind; each entry holds a list of pending invites for a target
--           userId. Push appends (capping to MAX_PER_USER, dropping oldest).
--           DrainFor reads + clears the entry; Remove drops matching items
--           (an accepted / declined request). Used by FriendService (kind=
--           "friend"), PartyService (kind="party"), GuildService (kind="guild").
-- Access  : Gaxia.InviteQueue  (server)
-- ─────────────────────────────────────────────────────────────
local MemoryStoreService = game:GetService("MemoryStoreService")

local Lifecycle = require(script.Parent.ServiceLifecycle)

-- Each kind stores its own item shape (see FriendService / GuildService /
-- PartyService for the per-kind invite types); the queue itself is untyped.
export type InviteKind = "friend" | "party" | "guild"

local MAP_PREFIX: string = "GaxiaInviteQueue_"
local MAX_PER_USER: number = 50
-- After DrainFor, the slot holds an empty list briefly until this TTL expires
-- (then the sorted-map entry is gone entirely and Push starts fresh).
local EMPTY_TTL: number = 60
-- Remove rewrites the remaining items with this TTL when the caller gives none.
local DEFAULT_REMOVE_TTL: number = 7 * 86400

local InviteQueue = {}

local function mapFor(kind: string): MemoryStoreSortedMap
	return MemoryStoreService:GetSortedMap(MAP_PREFIX .. kind)
end

function InviteQueue.Push(kind: InviteKind | string, toUserId: number, item: any, ttlSec: number): boolean
	local pushed = false
	local ok, err = pcall(function()
		mapFor(kind):UpdateAsync(tostring(toUserId), function(current: any)
			local list = (typeof(current) == "table") and current or {}
			table.insert(list, item)
			-- Cap: drop oldest until <= MAX_PER_USER.
			while #list > MAX_PER_USER do
				table.remove(list, 1)
			end
			pushed = true
			return list
		end, ttlSec)
	end)
	if not ok then
		warn(`[InviteQueue] Push({kind},{toUserId}) failed: {tostring(err)}`)
		return false
	end
	return pushed
end

function InviteQueue.DrainFor(kind: InviteKind | string, userId: number): { any }
	local drained: { any } = {}
	-- KNOWN MEMORYSTORE QUIRK: returning nil from the UpdateAsync transform
	-- CANCELS the update (does not delete). To actually clear the slot we
	-- write an empty list with a short TTL — Push treats it the same as
	-- "no entry" via the `(typeof == "table") and current or {}` guard.
	local ok, err = pcall(function()
		mapFor(kind):UpdateAsync(tostring(userId), function(current: any)
			if typeof(current) == "table" then
				drained = current
			end
			return {} -- clear by writing empty list (NOT nil — nil cancels)
		end, EMPTY_TTL)
	end)
	if not ok then
		warn(`[InviteQueue] DrainFor({kind},{userId}) failed: {tostring(err)}`)
		return {}
	end
	return drained
end

-- Removes the queued items for `toUserId` that `match` returns true for (for
-- example a friend request that was just accepted, so it does not come back at
-- the next join). The rest keep waiting, for `ttlSec` (default 7 days) from now.
-- Returns how many were removed: 0 when none matched or MemoryStore failed (warns).
-- `match` runs inside a MemoryStore transform: it must not yield.
function InviteQueue.Remove(kind: InviteKind | string, toUserId: number, match: (item: any) -> boolean, ttlSec: number?): number
	local removed = 0
	local ok, err = pcall(function()
		mapFor(kind):UpdateAsync(tostring(toUserId), function(current: any)
			removed = 0
			if typeof(current) ~= "table" then
				return nil -- nothing queued: cancel the update
			end
			local kept = {}
			for _, item in ipairs(current) do
				if match(item) then
					removed += 1
				else
					table.insert(kept, item)
				end
			end
			if removed == 0 then
				return nil -- unchanged: cancel the update
			end
			return kept
		end, if ttlSec and ttlSec > 0 then ttlSec else DEFAULT_REMOVE_TTL)
	end)
	if not ok then
		warn(`[InviteQueue] Remove({kind},{toUserId}) failed: {tostring(err)}`)
		return 0
	end
	return removed
end

-- Pure API: nothing to set up. Registered so Features / IsEnabled know it.
Lifecycle.Define(InviteQueue, {
	Name = "InviteQueue",
	Needs = {},
})

return InviteQueue
