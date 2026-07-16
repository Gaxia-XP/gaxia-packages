--!strict
-- ─────────────────────────────────────────────────────────────
-- Installer.lua
-- Location: plugin/src/Installer
-- Purpose : Clone the plugin's bundled Payload (framework template)
--           into the open place's services. Replaces existing
--           same-named instances. One undoable ChangeHistory record.
-- ─────────────────────────────────────────────────────────────

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Installer = {}

local function findPayload(): Instance?
	local entry = script.Parent
	return entry and entry:FindFirstChild("Payload")
end

-- Where each Payload root belongs in the place's DataModel.
local DEST: { [string]: Instance } = {
	Gaxia_Packages         = ReplicatedStorage,
	Gaxia_Packages_Server  = ServerStorage,
	Gaxia_ServerBootstrap  = ServerScriptService,
	Gaxia_ClientBootstrap  = StarterPlayer:FindFirstChild("StarterPlayerScripts") :: Instance,
}

export type Opts = { confirm: boolean?, payload: Instance? }

function Installer.install(opts: Opts?): (boolean, string)
	opts = opts or {}
	local payload = opts.payload or findPayload()
	if not payload then
		return false, "no Payload found (run from the built plugin, not the dev mount)"
	end

	local rec = ChangeHistoryService:TryBeginRecording("GaxiaCompanion_Install", "Install / Update Gaxia")
	local installed: { string } = {}

	for _, child in ipairs(payload:GetChildren()) do
		local dest = DEST[child.Name]
		if dest then
			local existing = dest:FindFirstChild(child.Name)
			if existing then existing:Destroy() end
			local clone = child:Clone()
			clone.Parent = dest
			table.insert(installed, child.Name)
		end
	end

	if rec then
		ChangeHistoryService:FinishRecording(rec,
			(#installed > 0) and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel)
	end

	if #installed == 0 then
		return false, "Payload had no recognised children"
	end
	return true, "Installed: " .. table.concat(installed, ", ")
end

return Installer
