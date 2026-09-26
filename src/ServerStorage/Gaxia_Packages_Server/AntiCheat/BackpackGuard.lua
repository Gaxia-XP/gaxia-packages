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

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPack       = game:GetService("StarterPack")

-- ── Dependencies ──
-- ToolService is required directly (it never requires AntiCheat, so no cycle).
local Trove       = require(ReplicatedStorage.Gaxia_Packages.Shared.Trove)
local Types       = require(script.Parent.Parent.Types)
local Config      = require(script.Parent.Parent.Config)
local ToolService = require(script.Parent.Parent.Lib.ToolService)

-- ── Types ──
type DetectorHost = Types.DetectorHost

local UID_ATTR : string = "UID"

local BackpackGuard = {}
BackpackGuard.Name = "Backpack"

local orchestratorRef : DetectorHost? = nil
local playerTroves : { [Player]: typeof(Trove.new()) } = {}

-- A Tool is authorised iff it carries a UID attribute AND ToolService still
-- has it in its registry. The registry uses weak values, so destroyed tools
-- auto-evict — we don't have to worry about stale entries.
-- Roblox itself copies StarterPack (and the player's StarterGear) into the
-- Backpack on every spawn; those tools never pass through ToolService, so without
-- this every player carrying a starter tool was flagged HARD — with three starter
-- tools the same-frame strikes reached a permanent ban. Server-side inventory
-- mutation is what this guard is for; a matching starter tool name is legitimate.
local function isStarterTool(player: Player, tool: Tool): boolean
	local packTool = StarterPack:FindFirstChild(tool.Name)
	if packTool and packTool:IsA("Tool") then return true end
	local gear = player:FindFirstChild("StarterGear")
	local gearTool = gear and gear:FindFirstChild(tool.Name)
	return gearTool ~= nil and gearTool:IsA("Tool")
end

local function isAuthorised(tool: Tool): boolean
	local uid = tool:GetAttribute(UID_ATTR)
	if typeof(uid) ~= "string" or uid == "" then return false end
	return ToolService.IsTracked(tool) == true
end

local function inspectAddition(player: Player, child: Instance)
	if not child:IsA("Tool") then return end
	-- Brief defer: gives the server-side creation pathway a frame to run
	-- ToolService.Track + parent the tool. Without this, a freshly-created
	-- tool would race the listener and look unauthorised.
	task.defer(function()
		if child.Parent == nil then return end       -- already cleaned up
		if isAuthorised(child) or isStarterTool(player, child) then return end
		-- Unauthorised — destroy and flag. We treat this as HARD because the
		-- only way an unstamped Tool reaches a player's inventory is direct
		-- mutation, never legitimate gameplay. In observe mode (Enforce = false)
		-- the tool is kept: only the flag is recorded.
		if orchestratorRef and orchestratorRef.IsEnforcing() then
			child:Destroy()
		end
		if orchestratorRef then
			orchestratorRef.Flag(player, "Backpack", Config.AntiCheat.Backpack.Severity)
		end
	end)
end

local function attachContainer(player: Player, container: Instance)
	local trove = playerTroves[player]
	if not trove then return end
	-- Scan existing children once, then listen for future additions.
	for _, child in ipairs(container:GetChildren()) do
		inspectAddition(player, child)
	end
	trove:Add(container.ChildAdded:Connect(function(child)
		inspectAddition(player, child)
	end))
end

local function attachPlayer(player: Player)
	if playerTroves[player] then return end
	local trove = Trove.new()
	playerTroves[player] = trove

	local function hookCharacter(character: Model)
		attachContainer(player, character)
	end

	-- Backpack appears as a child of the Player when the character first
	-- spawns; watch for it.
	local function hookBackpack()
		local bp = player:FindFirstChildOfClass("Backpack")
		if bp then attachContainer(player, bp) end
	end
	hookBackpack()
	trove:Add(player.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then attachContainer(player, child) end
	end))

	if player.Character then hookCharacter(player.Character) end
	trove:Add(player.CharacterAdded:Connect(hookCharacter))
end

local function detachPlayer(player: Player)
	local trove = playerTroves[player]
	if trove then
		trove:Clean()
		playerTroves[player] = nil
	end
end

function BackpackGuard.Init(orchestrator: DetectorHost): ()
	orchestratorRef = orchestrator
	for _, p in ipairs(Players:GetPlayers()) do attachPlayer(p) end
	Players.PlayerAdded:Connect(attachPlayer)
	Players.PlayerRemoving:Connect(detachPlayer)
end

return BackpackGuard
