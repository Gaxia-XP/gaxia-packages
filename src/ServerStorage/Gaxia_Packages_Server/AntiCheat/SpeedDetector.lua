--!strict
--[[
	Module : SpeedDetector
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.SpeedDetector
	Purpose : Flags horizontal speed that exceeds Humanoid.WalkSpeed scaled by
	          SPEED_TOLERANCE_MULTIPLIER. Requires 2 consecutive over-speed
	          ticks to avoid false positives from explosions / knockbacks.
	          Seated players (vehicles, moving seats) are skipped; "seated" means
	          Humanoid.SeatPart is set (server-made seat weld, not spoofable).
	          While falling (Freefall: flings, jump pads, knockback) the limit is
	          multiplied by Config.AntiCheat.Speed.FreefallMultiplier (default 2)
	          instead of skipping the check: the client sets Freefall, so a full
	          exemption would let a speed hacker who stays airborne go any speed.
	          Trade-off: a launch faster than 2x the limit for 2+ samples is a
	          (soft) flag; raise FreefallMultiplier for games with big launchers.
]]

-- ── Dependencies ──
local Types  = require(script.Parent.Parent.Types)
local Config = require(script.Parent.Parent.Config)

-- ── Types ──
type Snapshot = Types.AntiCheatSnapshot
type Flag = Types.AntiCheatFlag

local SpeedCfg = Config.AntiCheat.Speed

local SPEED_TOLERANCE : number = SpeedCfg.ToleranceMultiplier or 1.5
local SPEED_SEVERITY  : string = SpeedCfg.Severity or "soft"
local MIN_WALK_SPEED  : number = 8      -- floor when WalkSpeed is artificially low (sliding effects)
local STREAK_REQUIRED : number = 2      -- consecutive over-speed ticks before flagging
local FREEFALL_MULT   : number = SpeedCfg.FreefallMultiplier or 2

local FREEFALL = Enum.HumanoidStateType.Freefall

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

	-- A seat (vehicle) carries the character: WalkSpeed is not the limit. Only a
	-- server-confirmed seat (SeatPart) counts; the Seated state / Sit are client-set.
	if humanoid.SeatPart ~= nil then
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
	if snapshot.state == FREEFALL then
		-- Knockback / jump pads add sideways speed in the air: allow more, but
		-- keep checking (the client sets Freefall itself).
		limit *= FREEFALL_MULT
	end

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
