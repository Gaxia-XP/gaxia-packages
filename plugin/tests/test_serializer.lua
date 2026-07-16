--!strict
local SS = game:GetService("ServerStorage")
local Dev = SS:WaitForChild("__GaxiaPluginDev")
local Serializer = require(Dev:WaitForChild("Serializer")) :: any

local fails: { string } = {}
local function eq(label: string, got: any, want: any)
	if got ~= want then
		table.insert(fails, string.format("%s: got %s, want %s", label, tostring(got), tostring(want)))
	end
end
local function contains(label: string, hay: string, needle: string)
	if not string.find(hay, needle, 1, true) then
		table.insert(fails, string.format("%s: %q not found in output", label, needle))
	end
end

-- Fixture 1: themed button.
local btn = Instance.new("TextButton")
btn.Name = "PlayButton"
btn.Size = UDim2.fromOffset(160, 44)
btn.Text = "Play"
-- UICorner.CornerRadius default in Roblox is UDim.new(0, 8); use 12 so it is non-default.
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = btn

local out = Serializer.toScript({btn}, { tokens = false, asModule = true })
contains("T1.module.header",   out, "return function(parent)")
contains("T1.module.footer",   out, "end")
contains("T1.button.new",      out, "Instance.new(\"TextButton\")")
contains("T1.button.size",     out, "UDim2.fromOffset(160, 44)")
contains("T1.button.text",     out, "Text = \"Play\"")
contains("T1.corner.new",      out, "Instance.new(\"UICorner\")")
contains("T1.corner.radius",   out, "UDim.new(0, 12)")
contains("T1.corner.parent",   out, ".Parent = ")
if string.find(out, "Visible", 1, true) then
	table.insert(fails, "T1.no_default_Visible: output should not include unchanged Visible")
end

-- Fixture 2: bare-block (no module wrapper).
local out2 = Serializer.toScript({btn}, { tokens = false, asModule = false })
if string.find(out2, "return function(parent)", 1, true) then
	table.insert(fails, "T2.bare.no_wrapper: bare output should not include the function wrapper")
end
contains("T2.bare.button", out2, "Instance.new(\"TextButton\")")

-- Fixture 3: skipped non-UI child gets a comment.
local frame = Instance.new("Frame")
local scr = Instance.new("LocalScript")
scr.Name = "Handler"
scr.Parent = frame
local out3 = Serializer.toScript({frame}, { tokens = false, asModule = true })
contains("T3.skipped", out3, "-- skipped: Handler (LocalScript)")

if #fails == 0 then return "PASS: all Serializer tests passed" end
return "FAIL: " .. table.concat(fails, " | ")
