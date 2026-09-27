--!strict
-- ─────────────────────────────────────────────────────────────
-- Guard.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Shared/Guard
-- Purpose : Runtime schema validation (an osyris-`t`-style combinator lib) so
--           server RemoteEvent handlers can validate the SHAPE of client
--           payloads, not just individual scalars. Each check is
--           (value) -> (ok: boolean, err: string?). Compose with optional /
--           array / map / interface / union / literal.
--
-- Access  : Gaxia.Guard  (shared)
--   local checkBuy = Gaxia.Guard.strictInterface({ id = Gaxia.Guard.string, qty = Gaxia.Guard.integer })
--   local ok, err = checkBuy(payload); if not ok then return end
-- ─────────────────────────────────────────────────────────────
export type Check = (value: any) -> (boolean, string?)

local Guard = {}

-- ── Primitives ──
local function prim(typeName: string): Check
	return function(value: any): (boolean, string?)
		if typeof(value) == typeName then
			return true
		end
		return false, `expected {typeName}, got {typeof(value)}`
	end
end

Guard.number   = prim("number")
Guard.string   = prim("string")
Guard.boolean  = prim("boolean")
Guard.table    = prim("table")
Guard.Vector3  = prim("Vector3")
Guard.Vector2  = prim("Vector2")
Guard.CFrame   = prim("CFrame")
Guard.Color3   = prim("Color3")
Guard.instance = prim("Instance")

function Guard.any(_: any): (boolean, string?)
	return true
end

function Guard.integer(value: any): (boolean, string?)
	if typeof(value) ~= "number" then
		return false, `expected integer, got {typeof(value)}`
	end
	if value % 1 ~= 0 then
		return false, "expected integer, got a float"
	end
	return true
end

-- ── Combinators ──

-- nil OR matches `check`.
function Guard.optional(check: Check): Check
	return function(value: any): (boolean, string?)
		if value == nil then
			return true
		end
		return check(value)
	end
end

-- Exactly equal to `literal`.
function Guard.literal(literal: any): Check
	return function(value: any): (boolean, string?)
		if value == literal then
			return true
		end
		return false, `expected literal {tostring(literal)}, got {tostring(value)}`
	end
end

-- Matches at least one of the given checks.
function Guard.union(...: Check): Check
	local checks = { ... }
	return function(value: any): (boolean, string?)
		for _, c in ipairs(checks) do
			if c(value) then
				return true
			end
		end
		return false, "value matched no union member"
	end
end

-- Number within [min, max].
function Guard.numberRange(min: number, max: number): Check
	return function(value: any): (boolean, string?)
		if typeof(value) ~= "number" then
			return false, `expected number, got {typeof(value)}`
		end
		if value < min or value > max then
			return false, `number {value} out of range [{min}, {max}]`
		end
		return true
	end
end

-- Array (sequential) where every element matches `check`.
function Guard.array(check: Check): Check
	return function(value: any): (boolean, string?)
		if typeof(value) ~= "table" then
			return false, `expected array, got {typeof(value)}`
		end
		for i, v in ipairs(value) do
			local ok, err = check(v)
			if not ok then
				return false, `array[{i}]: {err}`
			end
		end
		return true
	end
end

-- Map where every key matches keyCheck and every value matches valueCheck.
function Guard.map(keyCheck: Check, valueCheck: Check): Check
	return function(value: any): (boolean, string?)
		if typeof(value) ~= "table" then
			return false, `expected map, got {typeof(value)}`
		end
		for k, v in pairs(value) do
			local ok, err = keyCheck(k)
			if not ok then
				return false, `map key: {err}`
			end
			ok, err = valueCheck(v)
			if not ok then
				return false, `map[{tostring(k)}]: {err}`
			end
		end
		return true
	end
end

-- Table where each named field matches its check (extra fields allowed).
function Guard.interface(shape: { [string]: Check }): Check
	return function(value: any): (boolean, string?)
		if typeof(value) ~= "table" then
			return false, `expected table, got {typeof(value)}`
		end
		for field, check in pairs(shape) do
			local ok, err = check(value[field])
			if not ok then
				return false, `field '{field}': {err}`
			end
		end
		return true
	end
end

-- Like interface, but rejects any field NOT declared in the shape (anti-exploit:
-- a payload may not smuggle extra keys past the validator).
function Guard.strictInterface(shape: { [string]: Check }): Check
	return function(value: any): (boolean, string?)
		if typeof(value) ~= "table" then
			return false, `expected table, got {typeof(value)}`
		end
		for field, check in pairs(shape) do
			local ok, err = check(value[field])
			if not ok then
				return false, `field '{field}': {err}`
			end
		end
		for field in pairs(value) do
			if shape[field :: string] == nil then
				return false, `unexpected field '{tostring(field)}'`
			end
		end
		return true
	end
end

return Guard
