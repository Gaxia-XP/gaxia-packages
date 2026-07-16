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
local CollectionService = game:GetService("CollectionService")

-- Server Config (sibling of the AntiCheat folder). FindFirstChild — no-yield
-- metamethod rule (detectors load through the loader's __index).
local Config = require(script.Parent.Parent:FindFirstChild("Config") :: ModuleScript) :: any
local Cfg = Config.AntiCheat.WorldBounds or {}

local MIN_Y    : number = (Cfg.MinY :: any) or -500     -- below this Y = under the map
local MAX_XZ   : number = (Cfg.MaxXZ :: any) or 10000   -- |X| or |Z| beyond this = off the map
local SEVERITY : string = (Cfg.Severity :: any) or "hard"

local WorldBoundsDetector = {}
WorldBoundsDetector.Name = "WorldBounds"

function WorldBoundsDetector.Sample(player: Player, snapshot: any): any?
	local pos = snapshot.position :: Vector3?
	if not pos then
		return nil
	end
	if pos.Y < MIN_Y or math.abs(pos.X) > MAX_XZ or math.abs(pos.Z) > MAX_XZ then
		return { reason = "WorldBounds", severity = SEVERITY }
	end
	return nil
end

return WorldBoundsDetector
