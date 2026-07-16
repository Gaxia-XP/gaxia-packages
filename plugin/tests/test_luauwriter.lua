--!strict
local SS = game:GetService("ServerStorage")
local W = require(SS:WaitForChild("__GaxiaPluginDev"):WaitForChild("LuauWriter")) :: any

local fails: { string } = {}
local function eq(label: string, got: any, want: any)
	if got ~= want then
		table.insert(fails, string.format("%s: got %q, want %q", label, tostring(got), tostring(want)))
	end
end

-- Scalars
eq("number.int",    W.value(42),       "42")
eq("number.float",  W.value(1.5),      "1.5")
eq("number.neg",    W.value(-3),       "-3")
eq("string.simple", W.value("hi"),     "\"hi\"")
eq("string.escape", W.value("a\"b"),   "\"a\\\"b\"")
eq("bool.true",     W.value(true),     "true")
eq("bool.false",    W.value(false),    "false")
eq("nil",           W.value(nil),      "nil")

-- Roblox types
eq("color3", W.value(Color3.fromRGB(255, 128, 0)), "Color3.fromRGB(255, 128, 0)")
eq("udim",          W.value(UDim.new(0.5, 10)),    "UDim.new(0.5, 10)")
eq("udim2.full",    W.value(UDim2.new(0.5, 10, 0.25, 5)), "UDim2.new(0.5, 10, 0.25, 5)")
eq("udim2.fromOffset",  W.value(UDim2.fromOffset(120, 80)), "UDim2.fromOffset(120, 80)")
eq("udim2.fromScale",   W.value(UDim2.fromScale(0.5, 0.5)),  "UDim2.fromScale(0.5, 0.5)")
eq("vector2",       W.value(Vector2.new(10, 20)),  "Vector2.new(10, 20)")
eq("rect",          W.value(Rect.new(1, 2, 3, 4)), "Rect.new(1, 2, 3, 4)")
eq("enum",          W.value(Enum.Font.SourceSans), "Enum.Font.SourceSans")

-- Writer (line builder)
local out = W.new()
out:line("local x = 1")
out:indent()
out:line("x = x + 1")
out:dedent()
out:line("return x")
local got = out:tostring()
local want = "local x = 1\n\tx = x + 1\nreturn x"
eq("writer.indent", got, want)

if #fails == 0 then return "PASS: all LuauWriter tests passed" end
return "FAIL: " .. table.concat(fails, " | ")
