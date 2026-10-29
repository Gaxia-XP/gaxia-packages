--!strict
-- ─────────────────────────────────────────────────────────────
-- Installer.lua
-- Location: plugin/src/Installer
-- Purpose : Clone the plugin's bundled Payload (framework template)
--           into the open place's services. Replaces existing
--           same-named instances. One undoable ChangeHistory record.
--
--           With opts.packages, installs only those packages plus what they
--           Require (Packages.lua) plus Core: the rest is removed from the clone
--           before it is parented, the loaders' type lists are trimmed to match,
--           and the pick is recorded on both package roots so the server boots
--           the picked services plus every installed package with Boot = true.
-- ─────────────────────────────────────────────────────────────

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local PackageSelect = require(script.Parent:WaitForChild("PackageSelect"))

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

-- Which side of Packages.lua each package root is.
local SIDE: { [string]: PackageSelect.Side } = {
	Gaxia_Packages        = "Replicated",
	Gaxia_Packages_Server = "Server",
}

export type Opts = {
	confirm: boolean?,
	payload: Instance?,
	-- Packages to install (their Requires are added). nil = everything, with no
	-- pick recorded (Config/Features then decides what boots).
	packages: { string }?,
}

-- The bundled package catalogue, for the picker.
function Installer.manifest(payload: Instance?): (PackageSelect.Manifest?, string?)
	local p = payload or findPayload()
	if not p then
		return nil, "no Payload found (run from the built plugin, not the dev mount)"
	end
	return PackageSelect.loadManifest(p)
end

-- The pick recorded by the last install in this place, or nil.
function Installer.currentPick(): { string }?
	local root = ServerStorage:FindFirstChild("Gaxia_Packages_Server")
	local value = root and root:GetAttribute(PackageSelect.ATTRIBUTE)
	if type(value) ~= "string" then
		return nil
	end
	return string.split(value, ",")
end

-- The packages this place has installed now, or nil when Gaxia is not installed.
function Installer.installedPackages(manifest: PackageSelect.Manifest): { string }?
	local serverRoot = ServerStorage:FindFirstChild("Gaxia_Packages_Server")
	local replicatedRoot = ReplicatedStorage:FindFirstChild("Gaxia_Packages")
	if serverRoot == nil and replicatedRoot == nil then
		return nil
	end
	return PackageSelect.installedIn(manifest, serverRoot, replicatedRoot)
end

function Installer.install(opts: Opts?): (boolean, string)
	local o: Opts = opts or {}
	local payload = o.payload or findPayload()
	if not payload then
		return false, "no Payload found (run from the built plugin, not the dev mount)"
	end

	-- Resolve the pick before touching the place, so a bad pick changes nothing.
	local kept: PackageSelect.Kept? = nil
	local pickValue = ""
	local installedCount = 0
	if o.packages then
		local manifest, why = PackageSelect.loadManifest(payload)
		if not manifest then
			return false, why or "no package catalogue"
		end
		local installed, unknown = PackageSelect.closure(manifest, o.packages)
		if #unknown > 0 then
			return false, "unknown package(s): " .. table.concat(unknown, ", ")
		end
		kept = PackageSelect.keptPaths(manifest, installed)
		local picked: { string } = {}
		local installedSet: { [string]: boolean } = {}
		for _, name in ipairs(installed) do
			installedSet[name] = true
		end
		for _, name in ipairs(o.packages) do
			if installedSet[name] then
				table.insert(picked, name)
			end
		end
		pickValue = table.concat(picked, ",")
		installedCount = #installed
	end

	local rec = ChangeHistoryService:TryBeginRecording("GaxiaCompanion_Install", "Install / Update Gaxia")
	local installed: { string } = {}
	local notes: { string } = {}

	for _, child in ipairs(payload:GetChildren()) do
		local dest = DEST[child.Name]
		if dest then
			local clone = child:Clone()
			local side = SIDE[child.Name]
			if kept and side then
				local keep = if side == "Server" then kept.Server else kept.Replicated
				PackageSelect.prune(clone, keep)
				-- The loader is the root ModuleScript; trim its type list to what is
				-- installed. Needs the plugin's script-editing permission.
				local okSource, err = pcall(function()
					local loader = clone :: ModuleScript
					loader.Source = PackageSelect.pruneTypeLines(loader.Source, keep)
				end)
				if not okSource then
					table.insert(notes, `could not trim {child.Name} types ({tostring(err)}): allow script edits for Gaxia Companion and reinstall`)
				end
				clone:SetAttribute(PackageSelect.ATTRIBUTE, pickValue)
			end
			local existing = dest:FindFirstChild(child.Name)
			if existing then existing:Destroy() end
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
	local msg = if kept
		then `Installed {installedCount} package(s) ({if pickValue == "" then "Core only" else pickValue} + dependencies)`
		else "Installed: " .. table.concat(installed, ", ")
	if #notes > 0 then
		msg ..= " — " .. table.concat(notes, "; ")
	end
	return true, msg
end

return Installer
