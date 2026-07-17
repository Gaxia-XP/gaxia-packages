--!strict
-- ─────────────────────────────────────────────────────────────
-- Module : PerformanceMonitor
-- Location: ReplicatedStorage/Gaxia_Packages/Shared/PerformanceMonitor
-- Purpose : Cross-context (client + server) performance helpers:
--           rolling-average FPS, memory usage, network ping,
--           and a per-frame Signal. Single Heartbeat subscription
--           shared across all callers.
-- ─────────────────────────────────────────────────────────────

local RunService        = game:GetService("RunService")
local Stats             = game:GetService("Stats")
local Players           = game:GetService("Players")
local ScriptContext     = game:GetService("ScriptContext")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal    = SharedPkg.Signal

local PerformanceMonitor = {}
PerformanceMonitor.OnFrame = Signal.new() -- fires (dt) each Heartbeat

-- ── Rolling FPS buffer ──
-- WHY rolling avg over 60 frames: instantaneous 1/dt is noisy and useless
-- to devs; ~1-second mean (at 60fps) is what people actually read.
local BUFFER = 60
local dts : { number } = {}
local idx = 0
local count = 0

RunService.Heartbeat:Connect(function(dt: number)
	idx = (idx % BUFFER) + 1
	dts[idx] = dt
	if count < BUFFER then count += 1 end
	PerformanceMonitor.OnFrame:Fire(dt)
end)

function PerformanceMonitor.GetFPS(): number
	if count == 0 then return 0 end
	local sum = 0
	for i = 1, count do sum += dts[i] end
	if sum <= 0 then return 0 end
	return math.floor((count / sum) + 0.5)
end

function PerformanceMonitor.GetMemoryMB(): number
	local ok, mb = pcall(function()
		return Stats:GetTotalMemoryUsageMb()
	end)
	if ok and typeof(mb) == "number" then return math.floor(mb + 0.5) end
	return 0
end

function PerformanceMonitor.GetPing(player: Player?): number
	-- Server: needs a player. Client: defaults to LocalPlayer.
	local target : Player? = player
	if not target and RunService:IsClient() then
		target = Players.LocalPlayer
	end
	if not target then return 0 end
	local ok, ping = pcall(function()
		return (target :: Player):GetNetworkPing() * 1000
	end)
	if ok and typeof(ping) == "number" then return math.floor(ping + 0.5) end
	return 0
end

-- WHY ScriptContext children: there's no first-class "active script count" API;
-- ScriptContext children approximate it. Documented as informative only.
local function getScriptCount(): number
	local ok, kids = pcall(function()
		return ScriptContext:GetChildren()
	end)
	if ok and typeof(kids) == "table" then return #kids end
	return 0
end

type Snapshot = {
	fps         : number,
	memoryMB    : number,
	scriptCount : number,
	ping        : number?,
}

function PerformanceMonitor.Snapshot(): Snapshot
	local snap : Snapshot = {
		fps         = PerformanceMonitor.GetFPS(),
		memoryMB    = PerformanceMonitor.GetMemoryMB(),
		scriptCount = getScriptCount(),
		ping        = nil,
	}
	if RunService:IsClient() then
		snap.ping = PerformanceMonitor.GetPing(nil)
	end
	return snap
end

return PerformanceMonitor
