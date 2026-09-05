--!strict
--[[
	Module : SpeedDetector
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.SpeedDetector
	Purpose : Flags horizontal speed that exceeds Humanoid.WalkSpeed scaled by
	          SPEED_TOLERANCE_MULTIPLIER. Requires 2 consecutive over-speed
	          ticks to avoid false positives from explosions / knockbacks.
]]


local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Constants = SharedPkg.Constants or {}

-- Server Config lives at the package root (sibling of the AntiCheat folder).
-- FindFirstChild (never WaitForChild): detectors are required through the
-- server loader's no-yield __index metamethod, and yielding there throws
-- "attempt to yield across metamethod/C-call boundary". Config's body is a
-- pure table, so require(FindFirstChild(...)) cannot yield.
local Config = require(script.Parent.Parent:FindFirstChild("Config") :: ModuleScript) :: any
local SpeedCfg = Config.AntiCheat.Speed

local SPEED_TOLERANCE : number = (SpeedCfg.ToleranceMultiplier :: any) or 1.5
local SPEED_SEVERITY  : string = (SpeedCfg.Severity :: any) or "soft"
local MIN_WALK_SPEED  : number = 8      -- floor when WalkSpeed is artificially low (sliding effects)
local STREAK_REQUIRED : number = 2      -- consecutive over-speed ticks before flagging

-- Per-player streak counter so a single noisy tick (explosion knockback) is forgiven.
local streaks: { [number]: number } = {}

local SpeedDetector = {}
SpeedDetector.Name = "Speed"

function SpeedDetector.Sample(player: Player, snapshot: any): any?
	local hrp = snapshot.hrp
	local humanoid = snapshot.humanoid
	if not hrp or not humanoid then
		streaks[player.UserId] = 0
		return nil
	end

	-- Project velocity onto the horizontal plane — vertical movement is the
	-- FlyDetector's domain.
	local velocity = snapshot.velocity :: Vector3?
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
			return { reason = "Speed", severity = SPEED_SEVERITY, source = "server" }
		end
	else
		streaks[player.UserId] = 0
	end
	return nil
end

return SpeedDetector
