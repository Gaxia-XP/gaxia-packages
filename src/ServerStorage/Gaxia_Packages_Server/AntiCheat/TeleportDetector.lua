--!strict
--[[
	Module : TeleportDetector
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.TeleportDetector
	Purpose : Flags HRP position deltas larger than TELEPORT_MAX_DELTA between
	          consecutive samples. Ignores ticks where the character re-spawned
	          or where state changed (e.g. Seated → Running can shift position).
]]


local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages"):WaitForChild("init")) :: any
local Constants = SharedPkg.Constants or {}

-- Server Config lives at the package root (sibling of the AntiCheat folder).
-- FindFirstChild (never WaitForChild): detectors are required through the
-- server loader's no-yield __index metamethod; yielding there throws
-- "attempt to yield across metamethod/C-call boundary". Config is a pure
-- table, so require(FindFirstChild(...)) cannot yield.
local Config = require(script.Parent.Parent:FindFirstChild("Config") :: ModuleScript) :: any
local TeleportCfg = Config.AntiCheat.Teleport

local TELEPORT_MAX_DELTA : number = (TeleportCfg.MaxDelta :: any) or 50
local TELEPORT_SEVERITY  : string = (TeleportCfg.Severity :: any) or "hard"

-- (userId) → { pos: Vector3, character: Model } — clears on respawn so a
-- legitimate Teleport-on-spawn does not register as cheating.
local lastSnapshot: { [number]: { pos: Vector3, character: Model } } = {}

local TeleportDetector = {}
TeleportDetector.Name = "Teleport"

function TeleportDetector.Sample(player: Player, snapshot: any): any?
	local pos = snapshot.position :: Vector3?
	local character = snapshot.character :: Model?
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
