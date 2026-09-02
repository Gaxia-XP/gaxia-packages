--!strict
-- Compatibility facade over sleitnick/table-util. Existing Gaxia names and
-- mutating contracts stay intact while the common operations use the package.

local TableUtil = require(script.Parent.Parent.Parent.Packages.TableUtil)

local Table = {}

-- TableUtil.Copy intentionally does not support cycles, so preserve the safer
-- public Gaxia behavior for this one operation.
function Table.DeepCopy<T>(t: T): T
	local seen: { [any]: any } = {}
	local function copy(value: any): any
		if type(value) ~= "table" then
			return value
		end
		if seen[value] then
			return seen[value]
		end
		local result: { [any]: any } = {}
		seen[value] = result
		for key, child in value do
			result[copy(key)] = copy(child)
		end
		return result
	end
	return copy(t)
end

function Table.ShallowCopy<T>(t: T): T
	return TableUtil.Copy(t)
end

function Table.Merge(t1: { [any]: any }, t2: { [any]: any }): { [any]: any }
	return TableUtil.Assign(t1, t2)
end

-- TableUtil.Reconcile is immutable. Apply its result back onto the original
-- tables so existing DataManager and public callers keep their object identity.
function Table.Reconcile(target: { [any]: any }, template: { [any]: any }): { [any]: any }
	local reconciled = TableUtil.Reconcile(target, template)
	local function apply(current: { [any]: any }, result: { [any]: any }, defaults: { [any]: any })
		for key, default in defaults do
			local existing = current[key]
			local resolved = result[key]
			if existing == nil then
				current[key] = resolved
			elseif type(existing) == "table" and type(default) == "table" then
				apply(existing, resolved, default)
			end
		end
	end
	apply(target, reconciled, template)
	return target
end

-- TableUtil.Filter compacts arrays; Gaxia.Filter has always preserved keys.
function Table.Filter<K, V>(t: { [K]: V }, predicate: (V, K) -> boolean): { [K]: V }
	local result: { [K]: V } = {}
	for key, value in t do
		if predicate(value, key) then
			result[key] = value
		end
	end
	return result
end

function Table.Map<K, V, R>(t: { [K]: V }, fn: (V, K) -> R): { [K]: R }
	return TableUtil.Map(t, fn)
end

function Table.Reduce<K, V, A>(t: { [K]: V }, fn: (A, V, K) -> A, init: A): A
	local result = init
	for key, value in t do
		result = fn(result, value, key)
	end
	return result
end

function Table.Find<K, V>(t: { [K]: V }, predicate: (V, K) -> boolean): (V?, K?)
	return TableUtil.Find(t, predicate)
end

function Table.Contains<V>(t: { [any]: V }, target: V): boolean
	return TableUtil.Some(t, function(value: V)
		return value == target
	end)
end

function Table.Count<K, V>(t: { [K]: V }, predicate: ((V, K) -> boolean)?): number
	if predicate == nil then
		return #TableUtil.Keys(t)
	end
	return #TableUtil.Keys(TableUtil.Filter(t, predicate))
end

function Table.IsEmpty(t: { [any]: any }): boolean
	return TableUtil.IsEmpty(t)
end

function Table.Keys<K, V>(t: { [K]: V }): { K }
	return TableUtil.Keys(t)
end

function Table.Values<K, V>(t: { [K]: V }): { V }
	return TableUtil.Values(t)
end

function Table.Reverse<V>(array: { V }): { V }
	return TableUtil.Reverse(array)
end

-- TableUtil.Shuffle is immutable; copy its result back to preserve Gaxia's
-- documented in-place behavior and return the original array for chaining.
function Table.Shuffle<V>(array: { V }): { V }
	local shuffled = TableUtil.Shuffle(array)
	table.move(shuffled, 1, #shuffled, 1, array)
	return array
end

function Table.Random<V>(array: { V }): V?
	return TableUtil.Sample(array, 1)[1]
end

function Table.Flatten<V>(t: { any }, depth: number?): { V }
	return TableUtil.Flat(t, depth or math.huge)
end

return Table
