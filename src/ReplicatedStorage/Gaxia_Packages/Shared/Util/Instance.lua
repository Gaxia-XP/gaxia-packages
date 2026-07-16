--!strict
--[[
	Instance.lua
	Location: ReplicatedStorage/Gaxia_Packages/Shared/Util/Instance
	Purpose: Helpers for finding, configuring, cloning, and tagging
	         Roblox Instances. Module name shadows global Instance —
	         that's intentional; require under a different local if needed.
--]]

local CollectionService = game:GetService("CollectionService")

local InstanceUtil = {}

-- ── Constants ──
local DEFAULT_WAIT_TIMEOUT: number = 10
local POLL_INTERVAL: number = 0.05 -- 50ms — quick enough for UI, easy on CPU.

-- ── Search ──

-- Recursively waits for a descendant of `parent` named `name`.
-- Polls every POLL_INTERVAL seconds until found or timeout elapses.
-- Returns nil on timeout (caller handles missing case).
function InstanceUtil.WaitForDescendant(parent: Instance, name: string, timeout: number?): Instance?
	local deadline: number = os.clock() + (timeout or DEFAULT_WAIT_TIMEOUT)
	-- Fast path: maybe it's already there.
	local found: Instance? = parent:FindFirstChild(name, true)
	if found then return found end
	-- Poll. ChildAdded would miss deeply-nested adds, so we re-search each tick.
	while os.clock() < deadline do
		task.wait(POLL_INTERVAL)
		found = parent:FindFirstChild(name, true)
		if found then return found end
	end
	return nil
end

-- Returns all descendants of `parent` (inclusive) carrying `tag`.
function InstanceUtil.GetTaggedDescendants(parent: Instance, tag: string): {Instance}
	local out: {Instance} = {}
	if CollectionService:HasTag(parent, tag) then
		out[#out + 1] = parent
	end
	for _, descendant in ipairs(parent:GetDescendants()) do
		if CollectionService:HasTag(descendant, tag) then
			out[#out + 1] = descendant
		end
	end
	return out
end

-- ── Mutation ──

-- Destroy that won't crash on already-destroyed/locked instances.
function InstanceUtil.SafeDestroy(instance: Instance?): ()
	if not instance then return end
	-- pcall: parent may be locked, or instance already :Destroy()'d.
	pcall(function()
		instance:Destroy()
	end)
end

-- Bulk-applies a property table to an instance. Returns it for chaining.
function InstanceUtil.SetProperties(instance: Instance, props: {[string]: any}): Instance
	for k, v in pairs(props) do
		(instance :: any)[k] = v
	end
	return instance
end

-- Clones `instance`, optionally re-parenting and applying property overrides.
-- Properties are applied BEFORE parenting so any constructor-side effects
-- (e.g., Tween targets, GUI layout) see the final values.
function InstanceUtil.Clone(instance: Instance, parent: Instance?, props: {[string]: any}?): Instance
	local cloned: Instance = instance:Clone()
	if props then
		InstanceUtil.SetProperties(cloned, props)
	end
	if parent then
		cloned.Parent = parent
	end
	return cloned
end

-- ── Hierarchy ──

-- Walks parents until one carries `tag`. Returns nil if none found.
function InstanceUtil.FindFirstAncestorWithTag(instance: Instance, tag: string): Instance?
	local current: Instance? = instance.Parent
	while current do
		if CollectionService:HasTag(current, tag) then
			return current
		end
		current = current.Parent
	end
	return nil
end

-- Pass-through to GetAttributes for API uniformity (lets call-sites avoid
-- importing nothing else from this module just for one Roblox call).
function InstanceUtil.GetAttributes(instance: Instance): {[string]: any}
	return instance:GetAttributes()
end

-- True if `instance` is a descendant of ANY instance in `ancestors`.
function InstanceUtil.IsDescendantOfAny(instance: Instance, ancestors: {Instance}): boolean
	for _, ancestor in ipairs(ancestors) do
		if instance:IsDescendantOf(ancestor) then
			return true
		end
	end
	return false
end

return InstanceUtil
