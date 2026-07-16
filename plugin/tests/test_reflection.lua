--!strict
-- Standalone test: run via MCP run_script_in_play_mode after a Rojo sync.
-- Requires the Reflection module from the dev mount.

local SS = game:GetService("ServerStorage")
local Reflection = require(SS:WaitForChild("__GaxiaPluginDev"):WaitForChild("Reflection")) :: any

local fails: { string } = {}
local function assertEq(label: string, got: any, want: any)
	if got ~= want then
		table.insert(fails, string.format("%s: got %s, want %s", label, tostring(got), tostring(want)))
	end
end
local function findProp(props: { any }, name: string): any
	for _, p in ipairs(props) do
		if p.name == name then return p end
	end
	return nil
end

-- T1: default Frame yields no non-default props.
local fresh = Instance.new("Frame")
local d1 = Reflection.diff(fresh)
assertEq("T1.empty", #d1, 0)

-- T2: a modified Frame yields exactly the changed props.
local f = Instance.new("Frame")
f.Size = UDim2.fromOffset(120, 80)
f.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
local d2 = Reflection.diff(f)
assertEq("T2.hasSize", findProp(d2, "Size") ~= nil, true)
assertEq("T2.hasBg",   findProp(d2, "BackgroundColor3") ~= nil, true)
assertEq("T2.noVisible", findProp(d2, "Visible") == nil, true)

-- T3: TextLabel includes Text and TextColor3 (class-specific props).
local lbl = Instance.new("TextLabel")
lbl.Text = "Hello"
lbl.TextColor3 = Color3.fromRGB(0, 255, 0)
local d3 = Reflection.diff(lbl)
assertEq("T3.hasText", findProp(d3, "Text") ~= nil, true)
assertEq("T3.hasTextColor3", findProp(d3, "TextColor3") ~= nil, true)

-- T4: attributes captured separately, sorted by name.
local a = Instance.new("Frame")
a:SetAttribute("Variant", "primary")
a:SetAttribute("Index", 3)
local attrs = Reflection.attributes(a)
assertEq("T4.attrCount", #attrs, 2)

-- T5: known/unknown class check.
assertEq("T5.knownFrame", Reflection.isKnown("Frame"), true)
assertEq("T5.unknownClass", Reflection.isKnown("FakeUnknownXYZ123"), false)

if #fails == 0 then
	return "PASS: all Reflection tests passed"
end
return "FAIL: " .. table.concat(fails, " | ")
