--!strict
local SS = game:GetService("ServerStorage")
local Dev = SS:WaitForChild("__GaxiaPluginDev")
local Installer = require(Dev:WaitForChild("Installer")) :: any

local fails: { string } = {}
local function eq(label: string, got: any, want: any)
	if got ~= want then
		table.insert(fails, string.format("%s: got %s, want %s", label, tostring(got), tostring(want)))
	end
end

-- T1: dev mount has no Payload reachable, install must return ok=false with mention of "Payload".
local ok, msg = Installer.install({ confirm = false })
eq("T1.dev.noPayload", ok, false)
if typeof(msg) == "string" and not string.find(msg, "Payload") then
	table.insert(fails, "T1.dev.msg.mentionsPayload: msg=" .. tostring(msg))
end

-- T2: explicit payload injection (testing the clone path without needing the built .rbxm).
local fake = Instance.new("Folder")
fake.Name = "FakePayload"
local fakeShared = Instance.new("Folder")
fakeShared.Name = "Gaxia_Packages"
fakeShared.Parent = fake
fake.Parent = SS

local before = game:GetService("ReplicatedStorage"):FindFirstChild("Gaxia_Packages")
local ok2, msg2 = Installer.install({ confirm = false, payload = fake })
eq("T2.ok", ok2, true)
local after = game:GetService("ReplicatedStorage"):FindFirstChild("Gaxia_Packages")
eq("T2.replaced", after ~= nil and after ~= before, true)

-- Restore the real Gaxia: undo the change.
game:GetService("ChangeHistoryService"):Undo()
fake:Destroy()

if #fails == 0 then return "PASS: all Installer tests passed" end
return "FAIL: " .. table.concat(fails, " | ")
