--!strict
-- ─────────────────────────────────────────────────────────────
-- Component.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Shared/Component
-- Purpose : Bind behaviour to every instance carrying a CollectionService tag,
--           with automatic teardown when the tag/instance goes away. The
--           framework's house style is "tag gameplay objects, iterate via
--           GetTagged" — this is the helper that makes that a lifecycle, not a
--           manual loop. Added() may return a per-instance state passed back to
--           Removed() for cleanup (a lightweight component instance).
--
-- Access  : Gaxia.Component  (shared)
--   local coins = Gaxia.Component.Bind("Coin", {
--     Added   = function(part) return connectTouch(part) end,
--     Removed = function(part, conn) conn:Disconnect() end,
--   })
--   coins.Destroy()  -- detach from all + stop listening
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

export type Handlers = {
	Added: (instance: Instance) -> any?,
	Removed: ((instance: Instance, state: any) -> ())?,
}

export type Binding = {
	Destroy: () -> (),
	GetAll: () -> { [Instance]: any },
	Get: (instance: Instance) -> any,
}

local Component = {}

-- Sentinel stored when Added returns nil, so we can still track membership.
local NO_STATE = {}

function Component.Bind(tag: string, handlers: Handlers): Binding
	local states: { [Instance]: any } = {}
	local conns: { RBXScriptConnection } = {}
	local alive = true

	local function add(instance: Instance)
		if states[instance] ~= nil then
			return
		end
		local ok, state = pcall(handlers.Added, instance)
		if ok then
			states[instance] = if state == nil then NO_STATE else state
		else
			warn(`[Component] '{tag}' Added errored: {state}`)
		end
	end

	local function remove(instance: Instance)
		local state = states[instance]
		if state == nil then
			return
		end
		states[instance] = nil
		if handlers.Removed then
			local realState = if state == NO_STATE then nil else state
			local ok, err = pcall(handlers.Removed, instance, realState)
			if not ok then
				warn(`[Component] '{tag}' Removed errored: {err}`)
			end
		end
	end

	-- Bind current + future tagged instances.
	for _, inst in ipairs(CollectionService:GetTagged(tag)) do
		add(inst)
	end
	table.insert(conns, CollectionService:GetInstanceAddedSignal(tag):Connect(add))
	table.insert(conns, CollectionService:GetInstanceRemovedSignal(tag):Connect(remove))

	local binding = {}

	function binding.Destroy(): ()
		if not alive then
			return
		end
		alive = false
		for _, c in ipairs(conns) do
			c:Disconnect()
		end
		table.clear(conns)
		-- Tear down every live instance (removing the current key mid-pairs is legal).
		for inst in pairs(states) do
			remove(inst)
		end
	end

	function binding.GetAll(): { [Instance]: any }
		local out: { [Instance]: any } = {}
		for inst, st in pairs(states) do
			out[inst] = if st == NO_STATE then nil else st
		end
		return out
	end

	function binding.Get(instance: Instance): any
		local st = states[instance]
		return if st == NO_STATE then nil else st
	end

	return binding :: Binding
end

return Component
