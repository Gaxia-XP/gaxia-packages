--!strict
-- ─────────────────────────────────────────────────────────────
-- Pool.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Shared/Pool
-- Purpose : Object pool. Reuse instances (effects, projectiles, particle
--           bursts, repeated parts) instead of create+destroy churn — one of
--           the top Roblox perf costs. Get() reuses a freed object or makes a
--           fresh one via the factory; Return() resets and parks it.
--
-- Access  : Gaxia.Pool  (shared)
--   local p = Gaxia.Pool.new(function() return Instance.new("Part") end,
--                            function(part) part.Parent = nil end)
--   local part = p.Get(); ... ; p.Return(part)   -- part: Part (inferred from the factory)
-- ─────────────────────────────────────────────────────────────

-- T = the pooled object's type (inferred from the factory). A bare `PoolObject`
-- annotation still means PoolObject<any>.
export type PoolObject<T = any> = {
	Get: () -> T,
	Return: (obj: T?) -> (), -- nil is ignored
	PreWarm: (n: number) -> (),
	Clear: () -> (), -- destroys parked Instances
	Size: () -> number, -- parked (available) objects
}

local Pool = {}

-- factory: builds a fresh object on a pool miss.
-- reset:   (optional) called on Return() to scrub state before parking.
-- Get() returns the factory's declared type: cast a template clone in the factory
-- (`function(): BasePart return template:Clone() :: BasePart end`). `reset` takes
-- `any` so a reset typed for the concrete class is accepted whatever the factory infers.
function Pool.new<T>(factory: () -> T, reset: ((obj: any) -> ())?): PoolObject<T>
	local available: { T } = {}
	local p = {}

	function p.Get(): T
		local obj = table.remove(available)
		if obj == nil then
			local fresh = factory()
			return fresh
		end
		return obj
	end

	function p.Return(obj: T?): ()
		if obj == nil then
			return
		end
		if reset then
			reset(obj)
		end
		table.insert(available, obj)
	end

	-- Pre-build `n` objects so the first burst doesn't pay the factory cost.
	function p.PreWarm(n: number): ()
		for _ = 1, n do
			table.insert(available, factory())
		end
	end

	-- Destroy any parked Instances and empty the pool.
	function p.Clear(): ()
		for _, obj in ipairs(available) do
			if typeof(obj) == "Instance" then
				((obj :: any) :: Instance):Destroy()
			end
		end
		table.clear(available)
	end

	function p.Size(): number
		return #available
	end

	return p :: PoolObject<T>
end

return Pool
