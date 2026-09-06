--!strict
--[[
	Module : BackpackGuard
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.BackpackGuard
	Purpose : Detects Tools that appear in a Player.Backpack or Character
	          without coming from the server's authorised pathway. Pairs with
	          ToolService — any Tool that lacks a tracked UID attribute is
	          destroyed and the player is flagged.

	WHY: A common exploit pattern is `Backpack:FindFirstChild` + cloning, or
	     direct Insert via tampered remote. ToolService.Create stamps a unique
	     UID + marks the tool as tracked; any Tool surfacing in a player's
	     inventory without that stamp didn't come from us.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Janitor = SharedPkg.Janitor

-- ── Config (server-side, see ServerStorage/Gaxia_Packages_Server/Config) ──
-- FindFirstChild (not WaitForChild): detectors are required THROUGH the server
-- loader's no-yield __index metamethod; WaitForChild would yield across that
-- boundary. Config's body is a pure table (no yields), so require is safe.
local Config = require(script.Parent.Parent:FindFirstChild("Config") :: ModuleScript) :: any

local UID_ATTR: string = "UID"

local BackpackGuard = {}
BackpackGuard.Name = "Backpack"

local orchestratorRef: any = nil
local playerJanitors: { [Player]: any } = {}

-- Direct-path lazy require — same pattern ToolDuplicationGuard uses to avoid
-- recursion with GaxiaServer.init.
local _toolServiceRef: any = nil
local function getToolService(): any
	if _toolServiceRef ~= nil then
		return _toolServiceRef
	end
	local libFolder = (script.Parent :: any).Parent:FindFirstChild("Lib")
	local toolMod = libFolder and libFolder:FindFirstChild("ToolService")
	if toolMod and toolMod:IsA("ModuleScript") then
		local ok, mod = pcall(require, toolMod)
		if ok then
			_toolServiceRef = mod
		end
	end
	return _toolServiceRef
end

-- A Tool is authorised iff it carries a UID attribute AND ToolService still
-- has it in its registry. The registry uses weak values, so destroyed tools
-- auto-evict — we don't have to worry about stale entries.
local function isAuthorised(tool: Tool): boolean
	local uid = tool:GetAttribute(UID_ATTR)
	if typeof(uid) ~= "string" or uid == "" then
		return false
	end
	local TS = getToolService()
	return TS ~= nil and TS.IsTracked(tool) == true
end

local function inspectAddition(player: Player, child: Instance)
	if not child:IsA("Tool") then
		return
	end
	-- Brief defer: gives the server-side creation pathway a frame to run
	-- ToolService.Track + parent the tool. Without this, a freshly-created
	-- tool would race the listener and look unauthorised.
	task.defer(function()
		if child.Parent == nil then
			return
		end -- already cleaned up
		if isAuthorised(child) then
			return
		end
		-- Unauthorised — destroy and flag. We treat this as HARD because the
		-- only way an unstamped Tool reaches a player's inventory is direct
		-- mutation, never legitimate gameplay.
		child:Destroy()
		if
			orchestratorRef
			and (
				not orchestratorRef.IsDetectorEnabled
				or orchestratorRef.IsDetectorEnabled(BackpackGuard.Name)
			)
		then
			orchestratorRef.Flag(player, "Backpack", Config.AntiCheat.Backpack.Severity, "server")
		end
	end)
end

local function attachContainer(player: Player, container: Instance)
	local janitor = playerJanitors[player]
	if not janitor then
		return
	end
	-- Scan existing children once, then listen for future additions.
	for _, child in ipairs(container:GetChildren()) do
		inspectAddition(player, child)
	end
	janitor:Add(container.ChildAdded:Connect(function(child)
		inspectAddition(player, child)
	end))
end

local function attachPlayer(player: Player)
	if playerJanitors[player] then
		return
	end
	local janitor = Janitor.new()
	playerJanitors[player] = janitor

	local function hookCharacter(character: Model)
		attachContainer(player, character)
	end

	-- Backpack appears as a child of the Player when the character first
	-- spawns; watch for it.
	local function hookBackpack()
		local bp = player:FindFirstChildOfClass("Backpack")
		if bp then
			attachContainer(player, bp)
		end
	end
	hookBackpack()
	janitor:Add(player.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then
			attachContainer(player, child)
		end
	end))

	if player.Character then
		hookCharacter(player.Character)
	end
	janitor:Add(player.CharacterAdded:Connect(hookCharacter))
end

local function detachPlayer(player: Player)
	local janitor = playerJanitors[player]
	if janitor then
		janitor:Cleanup()
		playerJanitors[player] = nil
	end
end

function BackpackGuard.Init(orchestrator: any): ()
	orchestratorRef = orchestrator
	for _, p in ipairs(Players:GetPlayers()) do
		attachPlayer(p)
	end
	Players.PlayerAdded:Connect(attachPlayer)
	Players.PlayerRemoving:Connect(detachPlayer)
end

return BackpackGuard
