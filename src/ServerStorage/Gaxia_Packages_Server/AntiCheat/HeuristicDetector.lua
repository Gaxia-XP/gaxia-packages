--!strict
--[[
	Module : HeuristicDetector
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.HeuristicDetector
	Purpose : Catches sub-threshold cheats the per-tick detectors miss. Keeps a
	          rolling window of each player's horizontal speed; a speedhack tuned
	          to stay JUST under SpeedDetector's 1.5x cap still shows up here as a
	          SUSTAINED high mean with LOW variance (a human's speed is noisy —
	          accel/decel/turn; a hack holds a near-constant high speed). Flags
	          that statistical signature. Tunables in Config.AntiCheat.Heuristic.
]]

local Players = game:GetService("Players")

-- ── Dependencies ──
local Types  = require(script.Parent.Parent.Types)
local Config = require(script.Parent.Parent.Config)

-- ── Types ──
type Snapshot = Types.AntiCheatSnapshot
type Flag = Types.AntiCheatFlag
type DetectorHost = Types.DetectorHost

-- The section is optional: every tunable falls back to its default without it.
local Cfg = Config.AntiCheat.Heuristic

local WINDOW       : number = if Cfg then Cfg.WindowSize or 20 else 20          -- samples per window (~10s at 0.5s)
local NEAR_LIMIT   : number = if Cfg then Cfg.NearLimitFactor or 1.3 else 1.3   -- mean > WalkSpeed * this = suspicious
local MAX_VARIANCE : number = if Cfg then Cfg.MaxVariance or 6 else 6           -- below this variance = "too consistent"
local MIN_SPEED    : number = if Cfg then Cfg.MinSpeed or 8 else 8              -- baseline floor (slow-zones)
local SEVERITY     : string = if Cfg then Cfg.Severity or "soft" else "soft"

local HeuristicDetector = {}
HeuristicDetector.Name = "Heuristic"

-- per-player rolling window of horizontal speeds
local windows: { [number]: { number } } = {}

function HeuristicDetector.Sample(player: Player, snapshot: Snapshot): Flag?
	local vel = snapshot.velocity
	local humanoid = snapshot.humanoid
	if not vel or not humanoid then
		return nil
	end
	local hspeed = Vector3.new(vel.X, 0, vel.Z).Magnitude

	local uid = player.UserId
	local w = windows[uid]
	if not w then
		w = {}
		windows[uid] = w
	end
	table.insert(w, hspeed)
	if #w > WINDOW then
		table.remove(w, 1)
	end
	if #w < WINDOW then
		return nil -- need a full window before judging
	end

	-- Mean.
	local sum = 0
	for _, s in ipairs(w) do
		sum += s
	end
	local mean = sum / #w

	local baseline = math.max(humanoid.WalkSpeed, MIN_SPEED)
	if mean < baseline * NEAR_LIMIT then
		return nil -- not suspiciously fast on average
	end

	-- Variance. Sustained high mean + low variance = a held, near-constant speed
	-- (a real player accelerates/turns/stops; a tuned speedhack does not).
	local varSum = 0
	for _, s in ipairs(w) do
		varSum += (s - mean) ^ 2
	end
	local variance = varSum / #w

	if variance < MAX_VARIANCE then
		windows[uid] = {} -- reset after flagging so we don't spam every tick
		return { reason = "Heuristic:SustainedSpeed", severity = SEVERITY }
	end
	return nil
end

-- Runs when the orchestrator registers this detector (was connected at require time).
function HeuristicDetector.Init(_orchestrator: DetectorHost): ()
	Players.PlayerRemoving:Connect(function(p: Player)
		windows[p.UserId] = nil
	end)
end

return HeuristicDetector
