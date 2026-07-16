--!strict
-- ─────────────────────────────────────────────────────────────
-- LuauWriter.lua
-- Location: plugin/src/LuauWriter
-- Purpose : Render Lua values (incl. Roblox value types) as Luau
--           literals, and provide a line-based code writer with
--           an indent stack. Pure module: no Studio API, no state
--           outside the returned writer instance.
-- ─────────────────────────────────────────────────────────────

local LuauWriter = {}

-- ── Value → Luau literal ────────────────────────────────────

local function fmtNumber(n: number): string
	-- Integers as ints, floats with %g (drops trailing zeros).
	if n == math.floor(n) and math.abs(n) < 1e15 then
		return tostring(math.floor(n))
	end
	return string.format("%g", n)
end

local function fmtString(s: string): string
	-- Escape backslash + double-quote, render control chars as \\xHH.
	local escaped = s:gsub("\\", "\\\\"):gsub("\"", "\\\"")
		:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
	return "\"" .. escaped .. "\""
end

local function fmtColor3(c: Color3): string
	return string.format("Color3.fromRGB(%d, %d, %d)",
		math.floor(c.R * 255 + 0.5),
		math.floor(c.G * 255 + 0.5),
		math.floor(c.B * 255 + 0.5))
end

local function fmtUDim(u: UDim): string
	return string.format("UDim.new(%s, %s)", fmtNumber(u.Scale), fmtNumber(u.Offset))
end

local function fmtUDim2(u: UDim2): string
	local xS, xO, yS, yO = u.X.Scale, u.X.Offset, u.Y.Scale, u.Y.Offset
	if xS == 0 and yS == 0 then
		return string.format("UDim2.fromOffset(%s, %s)", fmtNumber(xO), fmtNumber(yO))
	end
	if xO == 0 and yO == 0 then
		return string.format("UDim2.fromScale(%s, %s)", fmtNumber(xS), fmtNumber(yS))
	end
	return string.format("UDim2.new(%s, %s, %s, %s)",
		fmtNumber(xS), fmtNumber(xO), fmtNumber(yS), fmtNumber(yO))
end

local function fmtVector2(v: Vector2): string
	return string.format("Vector2.new(%s, %s)", fmtNumber(v.X), fmtNumber(v.Y))
end

local function fmtRect(r: Rect): string
	return string.format("Rect.new(%s, %s, %s, %s)",
		fmtNumber(r.Min.X), fmtNumber(r.Min.Y), fmtNumber(r.Max.X), fmtNumber(r.Max.Y))
end

local function fmtEnumItem(e: EnumItem): string
	return tostring(e) -- already "Enum.Category.Item"
end

local function fmtFont(f: Font): string
	-- Font has Family / Weight / Style. Use Font.new with all three.
	return string.format("Font.new(%s, Enum.FontWeight.%s, Enum.FontStyle.%s)",
		fmtString(f.Family), f.Weight.Name, f.Style.Name)
end

function LuauWriter.value(v: any): string
	local t = typeof(v)
	if v == nil then return "nil" end
	if t == "number"  then return fmtNumber(v) end
	if t == "string"  then return fmtString(v) end
	if t == "boolean" then return v and "true" or "false" end
	if t == "Color3"  then return fmtColor3(v) end
	if t == "UDim"    then return fmtUDim(v) end
	if t == "UDim2"   then return fmtUDim2(v) end
	if t == "Vector2" then return fmtVector2(v) end
	if t == "Rect"    then return fmtRect(v) end
	if t == "EnumItem" then return fmtEnumItem(v) end
	if t == "Font"    then return fmtFont(v) end
	-- Fallback: emit as a tostring inside a comment-marked string so the
	-- output is at least syntactically valid Lua. Caller decides whether
	-- to skip these.
	return string.format("nil --[[unsupported: %s]]", t)
end

-- Render a string as a Luau long-string literal, picking a bracket level whose
-- closing delimiter ( ]==] ) does not occur in the content. A newline is inserted
-- right after the opening bracket because Lua swallows an immediate leading
-- newline — this keeps the content byte-exact (used for emitting Script.Source).
function LuauWriter.longString(s: string): string
	local level = 0
	while string.find(s, "]" .. string.rep("=", level) .. "]", 1, true) do
		level += 1
	end
	local eq = string.rep("=", level)
	return "[" .. eq .. "[\n" .. s .. "]" .. eq .. "]"
end

-- ── Writer (line accumulator with indent stack) ─────────────

export type Writer = {
	line: (self: Writer, s: string) -> (),
	indent: (self: Writer) -> (),
	dedent: (self: Writer) -> (),
	tostring: (self: Writer) -> string,
}

function LuauWriter.new(): Writer
	local self = { _lines = {}, _depth = 0 }
	function self:line(s)
		table.insert(self._lines, string.rep("\t", self._depth) .. s)
	end
	function self:indent() self._depth += 1 end
	function self:dedent()
		if self._depth > 0 then self._depth -= 1 end
	end
	function self:tostring(): string
		return table.concat(self._lines, "\n")
	end
	return self :: any
end

return LuauWriter
