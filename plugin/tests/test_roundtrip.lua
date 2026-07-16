--!strict
local SS = game:GetService("ServerStorage")
local Dev = SS:WaitForChild("__GaxiaPluginDev")
local Reflection = require(Dev:WaitForChild("Reflection")) :: any
local Serializer = require(Dev:WaitForChild("Serializer")) :: any
local Runner     = require(Dev:WaitForChild("Runner"))     :: any
local Fixtures   = require(Dev:WaitForChild("Fixtures"))   :: any

local fails: { string } = {}
local function note(s: string) table.insert(fails, s) end

-- Compare instance trees by ClassName + diff(prop) list + attributes.
local function nodeKey(inst: Instance): string
	local parts = { inst.ClassName }
	for _, p in ipairs(Reflection.diff(inst)) do
		table.insert(parts, p.name .. "=" .. tostring(p.value))
	end
	for _, a in ipairs(Reflection.attributes(inst)) do
		table.insert(parts, "@" .. a.name .. "=" .. tostring(a.value))
	end
	return table.concat(parts, "|")
end

local function compareTree(label: string, a: Instance, b: Instance)
	local ka, kb = nodeKey(a), nodeKey(b)
	if ka ~= kb then
		note(label .. ": key mismatch\n  A=" .. ka .. "\n  B=" .. kb)
		return
	end
	local kidsA, kidsB = a:GetChildren(), b:GetChildren()
	-- Skip non-UI children in A (Serializer also skips them).
	local function isUI(c: Instance): boolean
		return Reflection.isKnown(c.ClassName) or c.ClassName:sub(1, 2) == "UI"
	end
	local filtA: { Instance } = {}
	for _, c in ipairs(kidsA) do if isUI(c) then table.insert(filtA, c) end end
	if #filtA ~= #kidsB then
		note(label .. ": child count " .. #filtA .. " vs " .. #kidsB)
		return
	end
	for i, ca in ipairs(filtA) do
		compareTree(label .. "/" .. ca.Name, ca, kidsB[i])
	end
end

-- A scratch parent so we don't pollute the place.
local scratch = Instance.new("Folder"); scratch.Name = "__RT_Scratch"; scratch.Parent = SS

for _, fxName in ipairs({ "themedButton", "listFrame", "groupedFrame" }) do
	local src = Fixtures[fxName]() :: Instance
	local script = Serializer.toScript({src}, { tokens = false, asModule = true })
	local container = Instance.new("Folder"); container.Parent = scratch
	local ok, _ = Runner.run(script, container)
	if not ok then
		note(fxName .. ": Runner failed")
	else
		local rebuilt = container:GetChildren()[1]
		if not rebuilt then
			note(fxName .. ": no root produced")
		else
			compareTree(fxName, src, rebuilt)
		end
	end
end

scratch:Destroy()
if #fails == 0 then
	print("PASS: round-trip identity holds for all fixtures")
else
	print("FAIL:\n" .. table.concat(fails, "\n"))
end
