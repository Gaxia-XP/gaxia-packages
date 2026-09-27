--!strict
--[[
	Module : ToolDuplicationGuard
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.ToolDuplicationGuard
	Purpose : Pairs with ToolService — listens for Tool.OnDuplicate and converts
	          the destroy event into an AntiCheat flag against the player who
	          owns the duplicate. Also scans existing Backpack/Character on join
	          to catch tools that pre-date the listener.
]]

local Players = game:GetService("Players")

-- ── Dependencies ──
-- ToolService is required directly (NOT via GaxiaServer): it never requires
-- AntiCheat, so there is no cycle, and it is a pure API with nothing to start.
local Types       = require(script.Parent.Parent.Types)
local Config      = require(script.Parent.Parent.Config)
local ToolService = require(script.Parent.Parent.Lib.ToolService)

-- ── Types ──
type DetectorHost = Types.DetectorHost

local ToolDuplicationGuard = {}
ToolDuplicationGuard.Name = "ToolDupe"

local orchestratorRef: DetectorHost? = nil

-- Resolve the Player who currently owns the given Tool instance (parented to
-- their Backpack or equipped on their Character). Returns nil for orphan tools.
local function findOwner(tool: Tool): Player?
	local backpack = tool:FindFirstAncestorOfClass("Backpack")
	if backpack then
		local p = backpack.Parent
		if p and p:IsA("Player") then return p :: Player end
	end
	local char = tool:FindFirstAncestorOfClass("Model")
	if char then
		for _, player in ipairs(Players:GetPlayers()) do
			if player.Character == char then return player end
		end
	end
	return nil
end

-- Walk the player's Backpack + Character for tools and call ToolService.Track
-- so any pre-existing duplicate UID is detected on join.
local function scanPlayer(player: Player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, child in ipairs(backpack:GetChildren()) do
			if child:IsA("Tool") then ToolService.Track(child) end
		end
	end
	if player.Character then
		for _, child in ipairs(player.Character:GetChildren()) do
			if child:IsA("Tool") then ToolService.Track(child) end
		end
	end
end

function ToolDuplicationGuard.Init(orchestrator: DetectorHost): ()
	orchestratorRef = orchestrator

	ToolService.OnDuplicate:Connect(function(dupe: Tool)
		local owner = findOwner(dupe)
		if owner and orchestratorRef then
			orchestratorRef.Flag(owner, "ToolDupe", Config.AntiCheat.ToolDupe.Severity)
		end
	end)

	-- Scan existing + future players for already-present tools so initial state
	-- (e.g. dev rejoining a place with manually-placed tools) is covered.
	for _, p in ipairs(Players:GetPlayers()) do scanPlayer(p) end
	Players.PlayerAdded:Connect(function(p)
		-- Wait briefly so the default Roblox character setup has time to populate the Backpack.
		task.wait(1)
		scanPlayer(p)
	end)
end

return ToolDuplicationGuard
