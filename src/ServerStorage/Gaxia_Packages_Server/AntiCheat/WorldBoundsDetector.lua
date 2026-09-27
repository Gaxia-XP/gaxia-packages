--!strict
--[[
	Module : WorldBoundsDetector
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.WorldBoundsDetector
	Purpose : Static AABB / kill-floor check. The velocity-delta detectors
	          (Teleport, Fly) miss SLOW drift under the map or a gradual walk to
	          far coordinates — a player can creep below the world or out to the
	          skybox without ever tripping a per-tick threshold. This is nearly
	          free: position is already in the shared per-tick snapshot.
	          Tunables live in Config.AntiCheat.WorldBounds.
]]

-- ── Dependencies ──
local Types  = require(script.Parent.Parent.Types)
local Config = require(script.Parent.Parent.Config)

-- ── Types ──
type Snapshot = Types.AntiCheatSnapshot
type Flag = Types.AntiCheatFlag

-- The section is optional: every tunable falls back to its default without it.
local Cfg = Config.AntiCheat.WorldBounds

local MIN_Y    : number = if Cfg then Cfg.MinY or -500 else -500          -- below this Y = under the map
local MAX_XZ   : number = if Cfg then Cfg.MaxXZ or 10000 else 10000       -- |X| or |Z| beyond this = off the map
local SEVERITY : string = if Cfg then Cfg.Severity or "hard" else "hard"

local WorldBoundsDetector = {}
WorldBoundsDetector.Name = "WorldBounds"

function WorldBoundsDetector.Sample(player: Player, snapshot: Snapshot): Flag?
	local pos = snapshot.position
	if not pos then
		return nil
	end
	if pos.Y < MIN_Y or math.abs(pos.X) > MAX_XZ or math.abs(pos.Z) > MAX_XZ then
		return { reason = "WorldBounds", severity = SEVERITY }
	end
	return nil
end

return WorldBoundsDetector
