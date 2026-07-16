--!strict
local SS = game:GetService("ServerStorage")
local Dev = SS:WaitForChild("__GaxiaPluginDev")
local Runner = require(Dev:WaitForChild("Runner")) :: any

local fails: { string } = {}
local function eq(label: string, got: any, want: any)
	if got ~= want then
		table.insert(fails, string.format("%s: got %s, want %s", label, tostring(got), tostring(want)))
	end
end

-- A throwaway parent under ServerStorage so the test doesn't pollute the place.
local parent = Instance.new("Folder")
parent.Name = "RunnerTestParent"
parent.Parent = SS

-- T1: module returning build function — Runner calls it with parent.
local src1 = [[
return function(parent)
	local f = Instance.new("Frame")
	f.Name = "ViaBuild"
	f.Parent = parent
	return f
end
]]
local ok, root = Runner.run(src1, parent)
eq("T1.ok", ok, true)
eq("T1.rootName", root and root.Name or nil, "ViaBuild")
eq("T1.parented", parent:FindFirstChild("ViaBuild") ~= nil, true)

-- T2: module returning a bare Instance — Runner re-parents it.
local src2 = [[
local f = Instance.new("Frame")
f.Name = "ViaBareReturn"
return f
]]
local ok2, root2 = Runner.run(src2, parent)
eq("T2.ok", ok2, true)
eq("T2.parented", root2 and root2.Parent or nil, parent)

-- T3: syntax error — Runner reports failure, no instance left behind.
local before = #parent:GetChildren()
local ok3, err = Runner.run("this is not valid lua )))", parent)
eq("T3.notOk", ok3, false)
eq("T3.errIsString", typeof(err), "string")
eq("T3.noLeak", #parent:GetChildren(), before)

parent:Destroy()
if #fails == 0 then return "PASS: all Runner tests passed" end
return "FAIL: " .. table.concat(fails, " | ")
