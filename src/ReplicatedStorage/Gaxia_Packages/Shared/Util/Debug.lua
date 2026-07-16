--!strict
-- ============================================================
-- Debug (ModuleScript)
-- Location : ReplicatedStorage/Gaxia_Packages/Shared/Util/Debug
-- Purpose  : Developer-facing diagnostics — pretty printer,
--            stack traces, execution timing, property watch,
--            and a formatted assert.
-- ============================================================

-- ── Constants ────────────────────────────────────────────────

local INDENT_UNIT : string = "  "    -- 2-space indent per depth level
local TAG         : string = "[Debug]"

-- ── Module ───────────────────────────────────────────────────

local Debug = {}

-- ── Pretty Printing ──────────────────────────────────────────

--- Returns a human-readable string of any Luau value.
--- Tables are rendered recursively with `indent` levels of indentation.
function Debug.Stringify(value: any, indent: number?): string
	local depth    : number = indent or 0
	local pad      : string = string.rep(INDENT_UNIT, depth)
	local innerPad : string = string.rep(INDENT_UNIT, depth + 1)

	if type(value) == "table" then
		-- Detect empty table early for compact output
		if next(value) == nil then
			return "{}"
		end

		local lines : { string } = { "{" }
		for k, v in value do
			local keyStr : string
			if type(k) == "string" then
				keyStr = k
			else
				keyStr = `[{tostring(k)}]`
			end
			table.insert(lines, `{innerPad}{keyStr} = {Debug.Stringify(v, depth + 1)},`)
		end
		table.insert(lines, `{pad}}`)
		return table.concat(lines, "\n")

	elseif type(value) == "string" then
		-- Wrap strings in quotes so they are distinguishable from numbers
		return `"{value}"`

	elseif type(value) == "nil" then
		return "nil"

	else
		-- Numbers, booleans, userdata — tostring is safe and informative
		return tostring(value)
	end
end

--- Prints the value via Stringify; pass indent to control initial depth.
function Debug.PrettyPrint(value: any, indent: number?): ()
	print(`{TAG} {Debug.Stringify(value, indent)}`)
end

-- ── Stack Trace ──────────────────────────────────────────────

--- Prints the current call stack.  Useful for tracing unexpected code paths.
function Debug.Trace(): ()
	-- debug.traceback returns the header line + each call level
	print(`{TAG} Stack trace:\n{debug.traceback("", 2)}`)
end

-- ── Timing ───────────────────────────────────────────────────

--- Calls fn, measures wall-clock duration, prints it, returns fn's result(s).
--- Label identifies the measurement in the output.
function Debug.Time<T...>(label: string, fn: () -> T...): T...
	local start   : number   = os.clock()
	local results : { any }  = { fn() }
	local elapsed : number   = os.clock() - start
	print(`{TAG} [{label}] took {string.format("%.6f", elapsed)}s`)
	return table.unpack(results)
end

-- ── Property Watcher ─────────────────────────────────────────

--- Prints a message whenever `propertyName` changes on instance.
--- Returns a disconnect function so callers can stop watching easily.
function Debug.Watch(instance: Instance, propertyName: string): () -> ()
	local connection : RBXScriptConnection = instance:GetPropertyChangedSignal(propertyName):Connect(function()
		local value : any = (instance :: any)[propertyName]
		print(`{TAG} {instance:GetFullName()}.{propertyName} changed → {Debug.Stringify(value)}`)
	end)
	-- Return a plain function so callers don't need to type RBXScriptConnection
	return function()
		connection:Disconnect()
	end
end

-- ── Assert ───────────────────────────────────────────────────

--- Like assert() but prints a formatted message with the TAG prefix.
--- `level` controls which stack level is reported in the error (default 2 = caller).
function Debug.Assert(condition: any, message: string?, level: number?): ()
	if not condition then
		local msg : string = message or "assertion failed"
		local lvl : number = level or 2
		error(`{TAG} {msg}`, lvl)
	end
end

-- ── Module Return ────────────────────────────────────────────

return Debug
