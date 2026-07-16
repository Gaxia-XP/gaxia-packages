--!strict
--[[
	Module : ToolDuplicationGuard
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.ToolDuplicationGuard
	Purpose : Pairs with ToolService — listens for Tool.OnDuplicate and converts
	          the destroy event into an AntiCheat flag against the player who
	          owns the duplicate. Also scans existing Backpack/Character on join
	          to catch tools that pre-date the listener.
]]


local Players           = game:GetService("Players")
local ServerStorage     = game:GetService("ServerStorage")

-- ── Config (server-side, see ServerStorage/Gaxia_Packages_Server/Config) ──
-- FindFirstChild (not WaitForChild): detectors are required THROUGH the server
-- loader's no-yield __index metamethod; WaitForChild would yield across that
-- boundary. Config's body is a pure table (no yields), so require is safe.
local Config = require(script.Parent.Parent:FindFirstChild("Config") :: ModuleScript) :: any

local ToolDuplicationGuard = {}
ToolDuplicationGuard.Name = "ToolDupe"

local orchestratorRef: any = nil

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
local function scanPlayer(player: Player, ToolService: any)
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

function ToolDuplicationGuard.Init(orchestrator: any): ()
	orchestratorRef = orchestrator
	-- WHY direct path require (NOT via GaxiaServer):
	-- AntiCheat is loaded *inside* GaxiaServer.init's body, so requiring
	-- GaxiaServer here would form a recursion cycle that Roblox rejects with
	-- "Requested module was required recursively". Loading ToolService by its
	-- absolute Lib path breaks the cycle — ToolService has no dependency on
	-- the AntiCheat orchestrator, so a direct require is safe.
	local libFolder = (script.Parent :: any).Parent:FindFirstChild("Lib")
	local toolMod = libFolder and libFolder:FindFirstChild("ToolService")
	if not toolMod or not toolMod:IsA("ModuleScript") then
		warn("[ToolDuplicationGuard] ToolService module not found — guard disabled")
		return
	end
	local ok, Tool = pcall(require, toolMod)
	if not ok or not Tool or not (Tool :: any).OnDuplicate then
		warn(`[ToolDuplicationGuard] ToolService.OnDuplicate signal not found — guard disabled ({tostring(Tool)})`)
		return
	end

	Tool.OnDuplicate:Connect(function(dupe: Tool)
		local owner = findOwner(dupe)
		if owner then
			orchestratorRef.Flag(owner, "ToolDupe", Config.AntiCheat.ToolDupe.Severity)
		end
	end)

	-- Scan existing + future players for already-present tools so initial state
	-- (e.g. dev rejoining a place with manually-placed tools) is covered.
	for _, p in ipairs(Players:GetPlayers()) do scanPlayer(p, Tool) end
	Players.PlayerAdded:Connect(function(p)
		-- Wait briefly so the default Roblox character setup has time to populate the Backpack.
		task.wait(1)
		scanPlayer(p, Tool)
	end)
end

return ToolDuplicationGuard
