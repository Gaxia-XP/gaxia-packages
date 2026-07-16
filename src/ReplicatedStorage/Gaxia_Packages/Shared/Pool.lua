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
--   local part = p.Get(); ... ; p.Return(part)
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

export type PoolObject = {
	Get: () -> any,
	Return: (obj: any) -> (),
	PreWarm: (n: number) -> (),
	Clear: () -> (),
	Size: () -> number,
}

local Pool = {}

-- factory: builds a fresh object on a pool miss.
-- reset:   (optional) called on Return() to scrub state before parking.
function Pool.new(factory: () -> any, reset: ((obj: any) -> ())?): PoolObject
	local available: { any } = {}
	local p = {}

	function p.Get(): any
		local obj = table.remove(available)
		if obj == nil then
			obj = factory()
		end
		return obj
	end

	function p.Return(obj: any): ()
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
				(obj :: Instance):Destroy()
			end
		end
		table.clear(available)
	end

	function p.Size(): number
		return #available
	end

	return p :: PoolObject
end

return Pool
