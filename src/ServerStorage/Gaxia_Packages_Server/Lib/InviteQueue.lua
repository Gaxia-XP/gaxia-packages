--!strict
-- ─────────────────────────────────────────────────────────────
-- InviteQueue.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/InviteQueue
-- Purpose : Durable cross-server invite delivery. One MemoryStoreSortedMap
--           per kind; each entry holds a list of pending invites for a target
--           userId. Push appends (capping to MAX_PER_USER, dropping oldest).
--           DrainFor reads + clears the entry. Used by FriendService (kind=
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

-- Pure API: nothing to set up. Registered so Features / IsEnabled know it.
Lifecycle.Define(InviteQueue, {
	Name = "InviteQueue",
	Needs = {},
})

return InviteQueue
