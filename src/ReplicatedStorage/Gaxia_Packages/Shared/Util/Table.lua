--!strict
--[[
	Table.lua
	Location: ReplicatedStorage/Gaxia_Packages/Shared/Util/Table
	Purpose: General-purpose table utilities for arrays and dictionaries.
	         Pure functions (no mutation) unless explicitly noted (Shuffle).
--]]

local Table = {}

-- ── Constants ──
local DEFAULT_FLATTEN_DEPTH: number = math.huge

-- ── Copy ──

-- Recursively clones nested tables. Cycle-safe via a seen-set.
function Table.DeepCopy<T>(t: T): T
	local seen: {[any]: any} = {}
	local function copy(v: any): any
		if type(v) ~= "table" then
			return v
		end
		if seen[v] then
			return seen[v]
		end
		local out: {[any]: any} = {}
		seen[v] = out
		for k, val in pairs(v :: any) do
			out[copy(k)] = copy(val)
		end
		return out
	end
	return copy(t)
end

-- One-level copy. Faster than DeepCopy for flat structures.
function Table.ShallowCopy<T>(t: T): T
	local out: {[any]: any} = {}
	for k, v in pairs(t :: any) do
		out[k] = v
	end
	return (out :: any) :: T
end

-- ── Merge / Reconcile ──

-- Returns a NEW table; t2 keys win over t1.
function Table.Merge(t1: {[any]: any}, t2: {[any]: any}): {[any]: any}
	local out: {[any]: any} = {}
	for k, v in pairs(t1) do out[k] = v end
	for k, v in pairs(t2) do out[k] = v end
	return out
end

-- Fills missing keys in `target` from `template`, recursively.
-- Used to upgrade saved data when a new field is added to defaults.
function Table.Reconcile(target: {[any]: any}, template: {[any]: any}): {[any]: any}
	for k, v in pairs(template) do
		if target[k] == nil then
			-- Deep-copy so caller can't mutate the template via the target.
			target[k] = if type(v) == "table" then Table.DeepCopy(v) else v
		elseif type(target[k]) == "table" and type(v) == "table" then
			Table.Reconcile(target[k], v)
		end
	end
	return target
end

-- ── Functional ──

-- Keeps entries where predicate(value, key) is truthy. Preserves keys.
function Table.Filter<K, V>(t: {[K]: V}, predicate: (V, K) -> boolean): {[K]: V}
	local out: {[K]: V} = {}
	for k, v in pairs(t) do
		if predicate(v, k) then
			out[k] = v
		end
	end
	return out
end

-- Maps each value through fn. Preserves keys.
function Table.Map<K, V, R>(t: {[K]: V}, fn: (V, K) -> R): {[K]: R}
	local out: {[K]: R} = {}
	for k, v in pairs(t) do
		out[k] = fn(v, k)
	end
	return out
end

-- Folds the table into a single accumulator value.
function Table.Reduce<K, V, A>(t: {[K]: V}, fn: (A, V, K) -> A, init: A): A
	local acc: A = init
	for k, v in pairs(t) do
		acc = fn(acc, v, k)
	end
	return acc
end

-- Returns the first (value, key) pair where predicate is truthy, or nil.
function Table.Find<K, V>(t: {[K]: V}, predicate: (V, K) -> boolean): (V?, K?)
	for k, v in pairs(t) do
		if predicate(v, k) then
			return v, k
		end
	end
	return nil, nil
end

-- True if any value strictly equals `target`.
function Table.Contains<V>(t: {[any]: V}, target: V): boolean
	for _, v in pairs(t) do
		if v == target then
			return true
		end
	end
	return false
end

-- Counts entries; if predicate given, only those matching.
function Table.Count<K, V>(t: {[K]: V}, predicate: ((V, K) -> boolean)?): number
	local n: number = 0
	if predicate then
		for k, v in pairs(t) do
			if predicate(v, k) then
				n += 1
			end
		end
	else
		for _ in pairs(t) do
			n += 1
		end
	end
	return n
end

-- True if the table has zero entries (works for non-array tables too).
function Table.IsEmpty(t: {[any]: any}): boolean
	return next(t) == nil
end

-- Returns an array of the table's keys. Order is undefined for dictionaries.
function Table.Keys<K, V>(t: {[K]: V}): {K}
	local out: {K} = {}
	for k in pairs(t) do
		out[#out + 1] = k
	end
	return out
end

-- Returns an array of the table's values. Order is undefined for dictionaries.
function Table.Values<K, V>(t: {[K]: V}): {V}
	local out: {V} = {}
	for _, v in pairs(t) do
		out[#out + 1] = v
	end
	return out
end

-- ── Array helpers ──

-- Returns a NEW array with elements in reverse order.
function Table.Reverse<V>(array: {V}): {V}
	local n: number = #array
	local out: {V} = table.create(n)
	for i = 1, n do
		out[i] = array[n - i + 1]
	end
	return out
end

-- Fisher-Yates shuffle, IN-PLACE. Returns the same array for chaining.
function Table.Shuffle<V>(array: {V}): {V}
	for i = #array, 2, -1 do
		local j: number = math.random(1, i)
		array[i], array[j] = array[j], array[i]
	end
	return array
end

-- Returns a uniformly random element, or nil if the array is empty.
function Table.Random<V>(array: {V}): V?
	local n: number = #array
	if n == 0 then
		return nil
	end
	return array[math.random(1, n)]
end

-- Flattens nested arrays up to `depth` levels (default = infinite).
function Table.Flatten<V>(t: {any}, depth: number?): {V}
	local maxDepth: number = depth or DEFAULT_FLATTEN_DEPTH
	local out: {V} = {}
	local function recurse(arr: {any}, d: number)
		for _, v in ipairs(arr) do
			if type(v) == "table" and d < maxDepth then
				recurse(v, d + 1)
			else
				out[#out + 1] = v
			end
		end
	end
	recurse(t, 0)
	return out
end

return Table
