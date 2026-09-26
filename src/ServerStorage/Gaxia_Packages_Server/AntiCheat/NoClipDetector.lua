--!strict
--[[
	Module : NoClipDetector
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.NoClipDetector
	Purpose : Flags the player when their HRP centre is genuinely embedded
	          inside CanCollide=true geometry — i.e. the engine's physics
	          could not push them back out. Combines an HRP-core overlap
	          probe with a movement gate so leaning against a wall (head /
	          shoulder touches but HRP centre is held back by physics) does
	          NOT register.
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

local NoClipCfg = Config.AntiCheat.NoClip

local NOCLIP_SEVERITY : string = NoClipCfg.Severity or "soft"

-- WHY a tight HRP-core probe at offset zero:
-- Previous versions used a chest probe (offset +2, size 1x2x1) which falsely
-- triggered when the player simply *leaned* against a wall — the chest/head
-- region overlapped the wall's bounding box even though Roblox physics was
-- actively keeping the HRP out. A tight 1×1×1 probe centred on the HRP only
-- catches the case where the centre of mass is INSIDE collidable geometry,
-- which is the actual signature of noclip / phasing exploits.
local PROBE_OFFSET    : Vector3 = Vector3.zero       -- HRP centre, not chest
local PROBE_SIZE      : Vector3 = Vector3.new(1, 1, 1)
local STREAK_REQUIRED : number  = 4                  -- ~2s continuous overlap before flagging
-- Minimum horizontal speed for a flag — standing still or leaning is
-- never a cheat signature, even if the probe spuriously overlaps a thin part.
local MIN_HORIZONTAL_SPEED : number = 4

local LEGITIMATE_INSIDE: { [Enum.HumanoidStateType]: boolean } = {
	[Enum.HumanoidStateType.Climbing] = true,
	[Enum.HumanoidStateType.Swimming] = true,
	[Enum.HumanoidStateType.Seated]   = true,
}

local streaks: { [number]: number } = {}

local NoClipDetector = {}
NoClipDetector.Name = "NoClip"

-- Reusable OverlapParams so we don't allocate per-tick.
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude
overlapParams.MaxParts = 4

function NoClipDetector.Sample(player: Player, snapshot: Snapshot): Flag?
	local hrp = snapshot.hrp
	if not hrp or not snapshot.character then
		streaks[player.UserId] = 0
		return nil
	end
	if snapshot.state and LEGITIMATE_INSIDE[snapshot.state] then
		streaks[player.UserId] = 0
		return nil
	end

	-- Movement gate: a player who isn't actually moving horizontally can't be
	-- noclipping THROUGH something — at worst they're touching geometry. Only
	-- consider overlaps while actively moving, so leaning doesn't trip the flag.
	local velocity = snapshot.velocity
	local horizontalSpeed = 0
	if velocity then
		horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	end
	if horizontalSpeed < MIN_HORIZONTAL_SPEED then
		streaks[player.UserId] = 0
		return nil
	end

	-- Exclude the character itself so we only see foreign parts overlapping it.
	overlapParams.FilterDescendantsInstances = { snapshot.character }

	local probeCFrame = hrp.CFrame + PROBE_OFFSET
	local parts = workspace:GetPartBoundsInBox(probeCFrame, PROBE_SIZE, overlapParams)
	local insideCollidable = false
	for _, part in ipairs(parts) do
		if part.CanCollide then
			insideCollidable = true
			break
		end
	end

	if insideCollidable then
		local streak = (streaks[player.UserId] or 0) + 1
		streaks[player.UserId] = streak
		if streak >= STREAK_REQUIRED then
			streaks[player.UserId] = 0
			return { reason = "NoClip", severity = NOCLIP_SEVERITY }
		end
	else
		streaks[player.UserId] = 0
	end
	return nil
end

return NoClipDetector
