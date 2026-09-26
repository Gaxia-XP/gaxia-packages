--!strict
--[[
	Module : SpeedDetector
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.SpeedDetector
	Purpose : Flags horizontal speed that exceeds Humanoid.WalkSpeed scaled by
	          SPEED_TOLERANCE_MULTIPLIER. Requires 2 consecutive over-speed
	          ticks to avoid false positives from explosions / knockbacks.
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

local SpeedCfg = Config.AntiCheat.Speed

local SPEED_TOLERANCE : number = SpeedCfg.ToleranceMultiplier or 1.5
local SPEED_SEVERITY  : string = SpeedCfg.Severity or "soft"
local MIN_WALK_SPEED  : number = 8      -- floor when WalkSpeed is artificially low (sliding effects)
local STREAK_REQUIRED : number = 2      -- consecutive over-speed ticks before flagging

-- Per-player streak counter so a single noisy tick (explosion knockback) is forgiven.
local streaks: { [number]: number } = {}

local SpeedDetector = {}
SpeedDetector.Name = "Speed"

function SpeedDetector.Sample(player: Player, snapshot: Snapshot): Flag?
	local hrp = snapshot.hrp
	local humanoid = snapshot.humanoid
	if not hrp or not humanoid then
		streaks[player.UserId] = 0
		return nil
	end

	-- Project velocity onto the horizontal plane — vertical movement is the
	-- FlyDetector's domain.
	local velocity = snapshot.velocity
	if not velocity then return nil end
	local horizontal = Vector3.new(velocity.X, 0, velocity.Z).Magnitude

	-- Use the higher of (current WalkSpeed, MIN_WALK_SPEED) so games that
	-- temporarily lower WalkSpeed (slow-zones) don't widen the cheat window.
	local baseline = math.max(humanoid.WalkSpeed, MIN_WALK_SPEED)
	local limit    = baseline * SPEED_TOLERANCE

	if horizontal > limit then
		local streak = (streaks[player.UserId] or 0) + 1
		streaks[player.UserId] = streak
		if streak >= STREAK_REQUIRED then
			-- Reset after flagging so a continuously-cheating player produces
			-- one flag every (STREAK_REQUIRED * SAMPLER_INTERVAL) seconds —
			-- enough cadence to escalate to "hard" without spamming OnFlag.
			streaks[player.UserId] = 0
			return { reason = "Speed", severity = SPEED_SEVERITY }
		end
	else
		streaks[player.UserId] = 0
	end
	return nil
end

return SpeedDetector
