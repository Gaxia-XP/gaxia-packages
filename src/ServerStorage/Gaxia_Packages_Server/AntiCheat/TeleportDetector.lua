--!strict
--[[
	Module : TeleportDetector
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.TeleportDetector
	Purpose : Flags HRP position deltas larger than TELEPORT_MAX_DELTA between
	          consecutive samples. Ignores ticks where the character re-spawned.
	          Seated players (now or on the previous sample: a vehicle or a moving
	          seat carries them) are skipped. While falling (Freefall now or on the
	          previous sample) only the horizontal part of the move counts: a long
	          drop is legitimate, a sideways jump while "falling" is not.
]]

-- ── Dependencies ──
local Types  = require(script.Parent.Parent.Types)
local Config = require(script.Parent.Parent.Config)

-- ── Types ──
type Snapshot = Types.AntiCheatSnapshot
type Flag = Types.AntiCheatFlag

local TeleportCfg = Config.AntiCheat.Teleport

local TELEPORT_MAX_DELTA : number = TeleportCfg.MaxDelta or 50
local TELEPORT_SEVERITY  : string = TeleportCfg.Severity or "hard"

local SEATED   = Enum.HumanoidStateType.Seated
local FREEFALL = Enum.HumanoidStateType.Freefall

-- (userId) → last sample — clears on respawn so a legitimate Teleport-on-spawn
-- does not register as cheating.
type Last = { pos: Vector3, character: Model, seated: boolean, falling: boolean }
local lastSnapshot: { [number]: Last } = {}

local TeleportDetector = {}
TeleportDetector.Name = "Teleport"

local function isSeated(snapshot: Snapshot): boolean
	local humanoid = snapshot.humanoid
	return snapshot.state == SEATED or (humanoid ~= nil and humanoid.Sit)
end

function TeleportDetector.Sample(player: Player, snapshot: Snapshot): Flag?
	local pos = snapshot.position
	local character = snapshot.character
	if not pos or not character then
		lastSnapshot[player.UserId] = nil
		return nil
	end

	local seated = isSeated(snapshot)
	local falling = snapshot.state == FREEFALL
	local prev = lastSnapshot[player.UserId]
	-- Always update the last snapshot before returning so a flagged tick still
	-- anchors the next comparison (otherwise dual-teleport would be missed).
	lastSnapshot[player.UserId] = { pos = pos, character = character, seated = seated, falling = falling }

	if not prev then return nil end
	-- Character respawned: a different Model means we lost continuity; skip this tick.
	if prev.character ~= character then return nil end
	-- Seated (or just left a seat): the seat's assembly moves the character.
	if seated or prev.seated then return nil end

	local move = pos - prev.pos
	if falling or prev.falling then
		-- A fall (or its landing) moves the character down fast: count only the
		-- horizontal part of the move.
		move = Vector3.new(move.X, 0, move.Z)
	end
	if move.Magnitude > TELEPORT_MAX_DELTA then
		-- Teleport is "hard" right away — there is no benign reason for a
		-- 50+ stud single-tick jump under normal physics.
		return { reason = "Teleport", severity = TELEPORT_SEVERITY }
	end
	return nil
end

return TeleportDetector
