--!strict
--[[
	Module : FlyDetector
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.FlyDetector
	Purpose : Flags sustained upward Y velocity while the Humanoid is NOT in
	          a state that legitimately produces lift (Jumping, Freefall,
	          Climbing, Swimming). Single-tick spikes are tolerated.
]]


local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Constants = SharedPkg.Constants or {}

-- Server Config lives at the package root (sibling of the AntiCheat folder).
-- FindFirstChild (never WaitForChild): detectors are required through the
-- server loader's no-yield __index metamethod; yielding there throws
-- "attempt to yield across metamethod/C-call boundary". Config is a pure
-- table, so require(FindFirstChild(...)) cannot yield.
local Config = require(script.Parent.Parent:FindFirstChild("Config") :: ModuleScript) :: any
local FlyCfg = Config.AntiCheat.Fly

local FLY_VELOCITY_THRESHOLD : number = (FlyCfg.VelocityThreshold :: any) or 30
local FLY_SEVERITY           : string = (FlyCfg.Severity :: any) or "soft"
local STREAK_REQUIRED        : number = 3   -- ~1.5s at 0.5s sampler

-- Humanoid states that legitimately produce upward Y velocity.
local LEGITIMATE_LIFT_STATES: { [Enum.HumanoidStateType]: boolean } = {
	[Enum.HumanoidStateType.Jumping]  = true,
	[Enum.HumanoidStateType.Freefall] = true,
	[Enum.HumanoidStateType.Climbing] = true,
	[Enum.HumanoidStateType.Swimming] = true,
	[Enum.HumanoidStateType.PlatformStanding] = true,
}

local streaks: { [number]: number } = {}

local FlyDetector = {}
FlyDetector.Name = "Fly"

function FlyDetector.Sample(player: Player, snapshot: any): any?
	local velocity = snapshot.velocity :: Vector3?
	if not velocity then
		streaks[player.UserId] = 0
		return nil
	end

	-- Allow lift when the engine has classified the character as airborne /
	-- climbing — those are the only legit producers of sustained upward Y.
	if snapshot.state and LEGITIMATE_LIFT_STATES[snapshot.state] then
		streaks[player.UserId] = 0
		return nil
	end

	if velocity.Y > FLY_VELOCITY_THRESHOLD then
		local streak = (streaks[player.UserId] or 0) + 1
		streaks[player.UserId] = streak
		if streak >= STREAK_REQUIRED then
			streaks[player.UserId] = 0
			return { reason = "Fly", severity = FLY_SEVERITY }
		end
	else
		streaks[player.UserId] = 0
	end
	return nil
end

return FlyDetector
