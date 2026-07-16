--!strict
-- ─────────────────────────────────────────────────────────────
-- Runner.lua
-- Location: plugin/src/Runner
-- Purpose : Compile and execute a Luau UI Script back into real
--           instances under a target parent. Wrapped in a single
--           ChangeHistoryService record (one undo) and pcall (errors
--           surface to the caller as ok=false, message).
--
-- Approach: build a temporary ModuleScript, set its .Source, require
-- it (fresh — no require cache poisoning since the module is new each
-- run), then destroy the temp after. Setting .Source requires the
-- plugin's "edit scripts" permission, prompted on first install.
-- ─────────────────────────────────────────────────────────────

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ServerStorage = game:GetService("ServerStorage")

local Runner = {}

-- A hidden, plugin-local scratch parent for the temp ModuleScript.
local function scratchParent(): Instance
	local s = ServerStorage:FindFirstChild("__GaxiaPlugin_Scratch")
	if not s then
		s = Instance.new("Folder")
		s.Name = "__GaxiaPlugin_Scratch"
		s.Parent = ServerStorage
	end
	return s
end

local function compileAndCall(source: string, target: Instance): (boolean, any)
	local tmp = Instance.new("ModuleScript")
	tmp.Name = "__GaxiaRun_" .. tostring(math.random(1e6, 9e6))
	-- Setting .Source requires plugin's "edit scripts" permission.
	local okSet, errSet = pcall(function() tmp.Source = source end)
	if not okSet then
		tmp:Destroy()
		return false, "cannot set ModuleScript.Source (plugin permission?): " .. tostring(errSet)
	end
	tmp.Parent = scratchParent()

	local okReq, value = pcall(require, tmp)
	tmp:Destroy()
	if not okReq then
		return false, tostring(value)
	end

	if typeof(value) == "function" then
		local okCall, ret = pcall(value, target)
		if not okCall then return false, tostring(ret) end
		return true, ret
	end
	if typeof(value) == "Instance" then
		(value :: Instance).Parent = target
		return true, value
	end
	return false, "module returned " .. typeof(value) .. " (expected function or Instance)"
end

function Runner.run(source: string, target: Instance): (boolean, any)
	local recordId = "GaxiaCompanion_Run"
	-- TryBeginRecording requires Plugin capability; pcall-guard so tests in
	-- Studio context outside an active plugin still work correctly.
	local recOk, rec = pcall(function()
		return ChangeHistoryService:TryBeginRecording(recordId, "Gaxia: Script -> Instance")
	end)
	local ok, result = compileAndCall(source, target)
	if recOk and rec then
		ChangeHistoryService:FinishRecording(rec,
			ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel)
	end
	return ok, result
end

return Runner
