--!strict
--[[
	Module : FlyDetector
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.FlyDetector
	Purpose : Flags sustained upward Y velocity while the Humanoid is NOT in
	          a state that legitimately produces lift (Jumping, Freefall,
	          Climbing, Swimming). Single-tick spikes are tolerated.
]]

-- ── Dependencies ──
local Types  = require(script.Parent.Parent.Types)
local Config = require(script.Parent.Parent.Config)

-- ── Types ──
-- Keep identical to AntiCheat/init.lua's exported Snapshot and Flag (a
-- detector cannot require the orchestrator: it requires the detectors).
type Snapshot = {
	clock: number,
	character: Model?,
	hrp: BasePart?,
	humanoid: Humanoid?,
	position: Vector3?,
	velocity: Vector3?,
	state: Enum.HumanoidStateType?,
	walkSpeed: number?,
}
type Flag = {
	reason: string,
	severity: Types.Severity | string,
}

local FlyCfg = Config.AntiCheat.Fly

local FLY_VELOCITY_THRESHOLD : number = FlyCfg.VelocityThreshold or 30
local FLY_SEVERITY           : string = FlyCfg.Severity or "soft"
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

function FlyDetector.Sample(player: Player, snapshot: Snapshot): Flag?
	local velocity = snapshot.velocity
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
