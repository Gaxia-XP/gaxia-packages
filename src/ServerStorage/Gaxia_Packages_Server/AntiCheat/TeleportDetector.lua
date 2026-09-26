--!strict
--[[
	Module : TeleportDetector
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.TeleportDetector
	Purpose : Flags HRP position deltas larger than TELEPORT_MAX_DELTA between
	          consecutive samples. Ignores ticks where the character re-spawned
	          or where state changed (e.g. Seated → Running can shift position).
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

local TeleportCfg = Config.AntiCheat.Teleport

local TELEPORT_MAX_DELTA : number = TeleportCfg.MaxDelta or 50
local TELEPORT_SEVERITY  : string = TeleportCfg.Severity or "hard"

-- (userId) → { pos: Vector3, character: Model } — clears on respawn so a
-- legitimate Teleport-on-spawn does not register as cheating.
local lastSnapshot: { [number]: { pos: Vector3, character: Model } } = {}

local TeleportDetector = {}
TeleportDetector.Name = "Teleport"

function TeleportDetector.Sample(player: Player, snapshot: Snapshot): Flag?
	local pos = snapshot.position
	local character = snapshot.character
	if not pos or not character then
		lastSnapshot[player.UserId] = nil
		return nil
	end

	local prev = lastSnapshot[player.UserId]
	-- Always update the last snapshot before returning so a flagged tick still
	-- anchors the next comparison (otherwise dual-teleport would be missed).
	lastSnapshot[player.UserId] = { pos = pos, character = character }

	if not prev then return nil end
	-- Character respawned: a different Model means we lost continuity; skip this tick.
	if prev.character ~= character then return nil end

	local delta = (pos - prev.pos).Magnitude
	if delta > TELEPORT_MAX_DELTA then
		-- Teleport is "hard" right away — there is no benign reason for a
		-- 50+ stud single-tick jump under normal physics.
		return { reason = "Teleport", severity = TELEPORT_SEVERITY }
	end
	return nil
end

return TeleportDetector
