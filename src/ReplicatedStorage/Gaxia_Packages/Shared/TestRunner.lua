--!strict
-- ─────────────────────────────────────────────────────────────
-- TestRunner.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Shared/TestRunner.lua
-- Purpose:  Minimal in-game test framework (Suite/It/Expect) so
--           gameplay code can be unit-tested without external deps.
-- ─────────────────────────────────────────────────────────────


-- ── Types ──
export type Case = {
	name   : string,
	passed : boolean,
	error  : string?,
}

export type Result = {
	suiteName : string,
	cases     : { Case },
	passed    : number,
	failed    : number,
	duration  : number,
}

export type Suite = {
	It         : (self: Suite, name: string, fn: () -> ()) -> (),
	BeforeEach : (self: Suite, fn: () -> ()) -> (),
	AfterEach  : (self: Suite, fn: () -> ()) -> (),
}

export type Expectation = {
	ToBe        : (self: Expectation, expected: any) -> Expectation,
	ToEqual     : (self: Expectation, expected: { [any]: any }) -> Expectation,
	ToBeTruthy  : (self: Expectation) -> Expectation,
	ToBeFalsy   : (self: Expectation) -> Expectation,
	ToBeNil     : (self: Expectation) -> Expectation,
	ToBeOfType  : (self: Expectation, t: string) -> Expectation,
	ToThrow     : (self: Expectation) -> Expectation,
}

-- ── Constants ──
local MS_PER_SECOND: number = 1000

local TestRunner = {}

-- ── Internal: deep table equality ──
-- WHY: ToEqual compares structure, not reference; otherwise table assertions
-- would always fail since two literals are never the same reference.
local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in pairs(a) do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k, _ in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function formatValue(v: any): string
	local t: string = typeof(v)
	if t == "string" then
		return `"{v}"`
	end
	return tostring(v)
end

-- ── Expect ──
function TestRunner.Expect(actual: any): Expectation
	local exp = {} :: any
	exp._actual = actual

	function exp:ToBe(expected: any): Expectation
		if (self :: any)._actual ~= expected then
			error(`Expected {formatValue(expected)}, got {formatValue((self :: any)._actual)}`, 2)
		end
		return self
	end

	function exp:ToEqual(expected: { [any]: any }): Expectation
		if not deepEqual((self :: any)._actual, expected) then
			error(`Expected tables to be deeply equal`, 2)
		end
		return self
	end

	function exp:ToBeTruthy(): Expectation
		local a = (self :: any)._actual
		if not a then
			error(`Expected truthy, got {formatValue(a)}`, 2)
		end
		return self
	end

	function exp:ToBeFalsy(): Expectation
		local a = (self :: any)._actual
		if a then
			error(`Expected falsy, got {formatValue(a)}`, 2)
		end
		return self
	end

	function exp:ToBeNil(): Expectation
		if (self :: any)._actual ~= nil then
			error(`Expected nil, got {formatValue((self :: any)._actual)}`, 2)
		end
		return self
	end

	function exp:ToBeOfType(t: string): Expectation
		local actualType: string = typeof((self :: any)._actual)
		if actualType ~= t then
			error(`Expected type "{t}", got "{actualType}"`, 2)
		end
		return self
	end

	function exp:ToThrow(): Expectation
		local fn = (self :: any)._actual
		if type(fn) ~= "function" then
			error(`ToThrow requires a function, got {typeof(fn)}`, 2)
		end
		local ok: boolean = pcall(fn)
		if ok then
			error(`Expected function to throw, but it did not`, 2)
		end
		return self
	end

	return exp :: Expectation
end

-- ── Suite runner ──
function TestRunner.Suite(name: string, build: (suite: Suite) -> ()): Result
	local cases: { Case } = {}
	local items: { { name: string, fn: () -> () } } = {}
	local beforeEach: (() -> ())? = nil
	local afterEach: (() -> ())? = nil

	local suite = {} :: any

	function suite:It(caseName: string, fn: () -> ()): ()
		table.insert(items, { name = caseName, fn = fn })
	end

	function suite:BeforeEach(fn: () -> ()): ()
		beforeEach = fn
	end

	function suite:AfterEach(fn: () -> ()): ()
		afterEach = fn
	end

	build(suite :: Suite)

	local suiteStart: number = os.clock()
	local passed: number = 0
	local failed: number = 0

	for _, item in ipairs(items) do
		local caseStart: number = os.clock()
		-- WHY pcall per It: a single assertion failure must not crash the suite.
		local ok: boolean, err: any = pcall(function()
			if beforeEach then
				beforeEach()
			end
			item.fn()
			if afterEach then
				afterEach()
			end
		end)
		local elapsedMs: number = (os.clock() - caseStart) * MS_PER_SECOND
		if ok then
			passed += 1
			table.insert(cases, { name = item.name, passed = true, error = nil })
			print(string.format("  ✓ %s (%.2fms)", item.name, elapsedMs))
		else
			failed += 1
			local errStr: string = tostring(err)
			table.insert(cases, { name = item.name, passed = false, error = errStr })
			print(`  ✗ {item.name} — {errStr}`)
		end
	end

	local duration: number = os.clock() - suiteStart
	print(string.format("=== Suite: %s — %d passed, %d failed (%.3fs) ===", name, passed, failed, duration))

	local result: Result = {
		suiteName = name,
		cases     = cases,
		passed    = passed,
		failed    = failed,
		duration  = duration,
	}
	return result
end

-- ── RunAll ──
function TestRunner.RunAll(suites: { (suite: Suite) -> () }): { Result }
	local results: { Result } = {}
	for i, builder in ipairs(suites) do
		local r: Result = TestRunner.Suite(`Suite#{i}`, builder)
		table.insert(results, r)
	end
	return results
end

return TestRunner
