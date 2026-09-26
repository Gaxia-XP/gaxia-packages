--!strict
--[[
	Module : HumanoidStateGuard
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.HumanoidStateGuard
	Purpose : Flags impossible Humanoid state transitions and state/environment
	          mismatches:
	            • Climbing without a TrussPart / Ladder within reach.
	            • Swimming without water terrain around the HRP.
	            • Re-entering Jumping while still airborne (double-jump exploit).
	          Built on Humanoid.StateChanged so cost is zero when idle.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

-- ── Dependencies ──
local Trove  = require(ReplicatedStorage.Gaxia_Packages.Shared.Trove)
local Types  = require(script.Parent.Parent.Types)
local Config = require(script.Parent.Parent.Config)

-- ── Types ──
-- The orchestrator API Init receives. Keep identical to AntiCheat/init.lua's
-- exported DetectorHost (a detector cannot require the orchestrator: it
-- requires the detectors).
type DetectorHost = {
	Flag: (player: Player, reason: string, severity: (Types.Severity | string)?) -> (),
	IsEnforcing: () -> boolean,
	IsDetectorEnabled: (name: string) -> boolean,
}

-- Server config. Climbing/Swimming default to "soft" so a false-positive doesn't
-- instant-kick; a game with custom climbing can set Enabled = false. The section
-- is optional (severity falls back to "soft" without it).
local HS_CONFIG = Config.AntiCheat.HumanoidState
local STATE_SEVERITY : string = if HS_CONFIG then HS_CONFIG.Severity or "soft" else "soft"

-- ── Tunables ──
-- Radius around the HRP we sweep for valid climb / swim surroundings.
local CLIMB_PROBE_RADIUS : number = 4
local SWIM_PROBE_RADIUS  : number = 3
-- Maximum number of Jumping → Freefall → Jumping cycles before flagging.
-- Roblox legitimately bounces a player through these on uneven ground, so we
-- allow a small streak before treating it as a double-jump exploit.
local DOUBLE_JUMP_STREAK : number = 2

local HumanoidStateGuard = {}
HumanoidStateGuard.Name = "HumanoidState"

local orchestratorRef : DetectorHost? = nil
local playerTroves : { [Player]: typeof(Trove.new()) } = {}
-- (humanoid) → { jumpsAirborne, lastJumpClock }
type JumpState = { jumpsAirborne: number, lastJumpClock: number }
local jumpState : { [Humanoid]: JumpState } = setmetatable({}, { __mode = "k" }) :: any

-- Re-used OverlapParams — we only ever exclude the character.
local climbOverlap = OverlapParams.new()
climbOverlap.FilterType = Enum.RaycastFilterType.Exclude
climbOverlap.MaxParts = 8

local function hasClimbSurfaceNearby(character: Model, hrp: BasePart): boolean
	climbOverlap.FilterDescendantsInstances = { character }
	local size = Vector3.new(CLIMB_PROBE_RADIUS, CLIMB_PROBE_RADIUS, CLIMB_PROBE_RADIUS)
	local parts = workspace:GetPartBoundsInBox(hrp.CFrame, size, climbOverlap)
	for _, p in ipairs(parts) do
		-- TrussPart is the canonical climbable. Games with custom ladders/walls
		-- tag them "Climbable" or "Ladder" via CollectionService — accept those too
		-- so a legitimate climb on a non-Truss surface isn't a false positive.
		if p:IsA("TrussPart")
			or CollectionService:HasTag(p, "Climbable")
			or CollectionService:HasTag(p, "Ladder") then
			return true
		end
	end
	return false
end

local function isInWater(hrp: BasePart): boolean
	-- ReadVoxels returns a 3-D array of material codes; a single 4-stud voxel
	-- centred on the HRP is enough to confirm "swimming-legit" terrain.
	local terrain = workspace.Terrain
	local region = Region3.new(
		hrp.Position - Vector3.new(SWIM_PROBE_RADIUS, SWIM_PROBE_RADIUS, SWIM_PROBE_RADIUS),
		hrp.Position + Vector3.new(SWIM_PROBE_RADIUS, SWIM_PROBE_RADIUS, SWIM_PROBE_RADIUS)
	):ExpandToGrid(4)
	local ok, materials = pcall(function()
		return terrain:ReadVoxels(region, 4)
	end)
	if not ok or not materials then return false end
	for x = 1, materials.Size.X do
		for y = 1, materials.Size.Y do
			for z = 1, materials.Size.Z do
				if materials[x][y][z] == Enum.Material.Water then
					return true
				end
			end
		end
	end
	return false
end

local function flag(player: Player, kind: string, severity: string)
	if not orchestratorRef then
		return
	end
	-- Self-gate: this detector flags via StateChanged events (no Sample), so the
	-- orchestrator's sampler-level per-detector gate can't reach it — check here so
	-- Config.AntiCheat.HumanoidState.Enabled=false / `/ac off HumanoidState` works.
	if orchestratorRef.IsDetectorEnabled and not orchestratorRef.IsDetectorEnabled("HumanoidState") then
		return
	end
	orchestratorRef.Flag(player, `HumanoidState:{kind}`, severity)
end

local function onStateChanged(player: Player, humanoid: Humanoid, _old: Enum.HumanoidStateType, new: Enum.HumanoidStateType)
	local character = humanoid.Parent :: Model?
	local hrp = character and (character :: any):FindFirstChild("HumanoidRootPart")
	if not character or not hrp then return end

	if new == Enum.HumanoidStateType.Climbing then
		if not hasClimbSurfaceNearby(character, hrp) then
			flag(player, "Climbing", STATE_SEVERITY)
		end
	elseif new == Enum.HumanoidStateType.Swimming then
		if not isInWater(hrp) then
			flag(player, "Swimming", STATE_SEVERITY)
		end
	elseif new == Enum.HumanoidStateType.Jumping then
		-- Track double-jump: each Jump while not having touched ground since
		-- the previous one increments the counter.
		local state = jumpState[humanoid]
		if not state then
			state = { jumpsAirborne = 0, lastJumpClock = 0 }
			jumpState[humanoid] = state
		end
		state.jumpsAirborne += 1
		state.lastJumpClock = os.clock()
		if state.jumpsAirborne > DOUBLE_JUMP_STREAK then
			flag(player, "DoubleJump", "soft")
			state.jumpsAirborne = 0 -- reset so we don't spam-flag every tick
		end
	elseif new == Enum.HumanoidStateType.Landed or new == Enum.HumanoidStateType.Running then
		-- Touching ground resets the airborne jump counter.
		local state = jumpState[humanoid]
		if state then state.jumpsAirborne = 0 end
	end
end

local function attachHumanoid(player: Player, humanoid: Humanoid)
	local trove = playerTroves[player]
	if not trove then return end
	trove:Add(humanoid.StateChanged:Connect(function(old, new)
		onStateChanged(player, humanoid, old, new)
	end))
end

local function attachPlayer(player: Player)
	if playerTroves[player] then return end
	local trove = Trove.new()
	playerTroves[player] = trove
	local function hookCharacter(character: Model)
		local hum = character:WaitForChild("Humanoid", 5) :: Humanoid?
		if hum then attachHumanoid(player, hum) end
	end
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

function HumanoidStateGuard.Init(orchestrator: DetectorHost): ()
	orchestratorRef = orchestrator
	for _, p in ipairs(Players:GetPlayers()) do attachPlayer(p) end
	Players.PlayerAdded:Connect(attachPlayer)
	Players.PlayerRemoving:Connect(detachPlayer)
end

return HumanoidStateGuard
