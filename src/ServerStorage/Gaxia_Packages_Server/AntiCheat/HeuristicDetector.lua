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
local CollectionService = game:GetService("CollectionService")

local Players = game:GetService("Players")

-- Server Config (sibling of AntiCheat). FindFirstChild — no-yield metamethod rule.
local Config = require(script.Parent.Parent:FindFirstChild("Config") :: ModuleScript) :: any
local Cfg = Config.AntiCheat.Heuristic or {}

local WINDOW       : number = (Cfg.WindowSize :: any) or 20       -- samples per window (~10s at 0.5s)
local NEAR_LIMIT   : number = (Cfg.NearLimitFactor :: any) or 1.3 -- mean > WalkSpeed * this = suspicious
local MAX_VARIANCE : number = (Cfg.MaxVariance :: any) or 6       -- below this variance = "too consistent"
local MIN_SPEED    : number = (Cfg.MinSpeed :: any) or 8          -- baseline floor (slow-zones)
local SEVERITY     : string = (Cfg.Severity :: any) or "soft"

local HeuristicDetector = {}
HeuristicDetector.Name = "Heuristic"

-- per-player rolling window of horizontal speeds
local windows: { [number]: { number } } = {}

function HeuristicDetector.Sample(player: Player, snapshot: any): any?
	local vel = snapshot.velocity :: Vector3?
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
		return { reason = "Heuristic:SustainedSpeed", severity = SEVERITY, source = "server" }
	end
	return nil
end

Players.PlayerRemoving:Connect(function(p: Player)
	windows[p.UserId] = nil
end)

return HeuristicDetector
