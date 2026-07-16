--!strict
local SS = game:GetService("ServerStorage")
local TB = require(SS:WaitForChild("__GaxiaPluginDev"):WaitForChild("ThemeBridge")) :: any

local fails: { string } = {}
local function eq(label: string, got: any, want: any)
	if got ~= want then
		table.insert(fails, string.format("%s: got %s, want %s", label, tostring(got), tostring(want)))
	end
end

local bridge = TB.new()
eq("T1.empty.tokensUsed", #bridge:tokensUsed(), 0)

-- T2: match an exact token color.
-- Theme exposes Theme.Color(name) as accessor and Theme.Get().Color as the table.
local Theme = require(game:GetService("ReplicatedStorage"):WaitForChild("Gaxia_Packages"):WaitForChild("Shared"):WaitForChild("Theme")) :: any
local primary = Theme.Color("Primary")
eq("T2.matchPrimary", bridge:match(primary), "Primary")

eq("T3.noMatch", bridge:match(Color3.fromRGB(123, 45, 67)), nil)

local _ = bridge:match(primary)
local used = bridge:tokensUsed()
eq("T4.usedCount", #used, 1)
eq("T4.usedName",  used[1], "Primary")

if #fails == 0 then return "PASS: all ThemeBridge tests passed" end
return "FAIL: " .. table.concat(fails, " | ")
