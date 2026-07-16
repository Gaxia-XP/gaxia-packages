--!strict
--[[
	Module : HeartbeatGuard
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.HeartbeatGuard
	Purpose : Detects players whose ClientAntiCheat has been disabled (module
	          deleted, RemoteEvent removed, script context tampered) by
	          requiring a periodic heartbeat from the client. Missed heartbeats
	          past HEARTBEAT_TIMEOUT raise a soft flag — repeated misses escalate
	          via the orchestrator's threshold ladder to a hard kick.

	WHY this exists:
	  An exploiter could delete ReplicatedStorage.Events.AntiCheat_Report or
	  ReplicatedStorage.Gaxia_Packages.Client.ClientAntiCheat to silence client
	  reports. The heartbeat channel is independent (System_Heartbeat) and
	  *expects* presence — silence is itself a signal.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Server Config lives at the package root (sibling of the AntiCheat folder).
-- FindFirstChild (never WaitForChild): detectors are required through the
-- server loader's no-yield __index metamethod; yielding there throws
-- "attempt to yield across metamethod/C-call boundary". Config is a pure
-- table, so require(FindFirstChild(...)) cannot yield.
local Config = require(script.Parent.Parent:FindFirstChild("Config") :: ModuleScript) :: any
local HeartbeatCfg = Config.AntiCheat.Heartbeat

-- Tunables. JOIN_GRACE must comfortably exceed the client's first-heartbeat
-- delay (default 5s in ClientAntiCheat) so a slow connection doesn't flag on
-- spawn. TIMEOUT is long enough to tolerate a single missed beat from network
-- jitter but short enough that escalation to hard kick happens within a minute.
local HEARTBEAT_TIMEOUT : number = (HeartbeatCfg.TimeoutSeconds :: any) or 15
local JOIN_GRACE        : number = (HeartbeatCfg.JoinGraceSeconds :: any) or 30
local HEARTBEAT_SEVERITY: string = (HeartbeatCfg.Severity :: any) or "soft"

local HeartbeatGuard = {}
HeartbeatGuard.Name = "Heartbeat"

local lastHeartbeat : { [Player]: number } = {}
local joinTime      : { [Player]: number } = {}
-- Per-player cooldown so one missed heartbeat doesn't burst-flag every sample
-- tick (sampler runs at 0.5s, much faster than the timeout window).
local lastFlagged   : { [Player]: number } = {}

function HeartbeatGuard.Init(_orchestrator: any): ()
	local events = ReplicatedStorage:WaitForChild("Events", 5)
	local remote = events and events:FindFirstChild("System_Heartbeat")
	if not remote or not remote:IsA("RemoteEvent") then
		warn("[HeartbeatGuard] System_Heartbeat RemoteEvent not found — guard disabled")
		return
	end

	-- Note: we intentionally do NOT validate payload — the *fact* of the fire
	-- is the signal. A compromised client could spoof these, but if they could
	-- spoof, they'd also pass other detectors; this guard only catches the
	-- "disabled" case.
	remote.OnServerEvent:Connect(function(player)
		lastHeartbeat[player] = os.clock()
	end)

	local function track(p: Player)
		joinTime[p] = os.clock()
	end
	for _, p in ipairs(Players:GetPlayers()) do track(p) end
	Players.PlayerAdded:Connect(track)
	Players.PlayerRemoving:Connect(function(p)
		lastHeartbeat[p] = nil
		joinTime[p]      = nil
		lastFlagged[p]   = nil
	end)
end

function HeartbeatGuard.Sample(player: Player, snapshot: any): any?
	local now = snapshot.clock
	local joined = joinTime[player]
	if not joined then return nil end                       -- not yet tracked
	if (now - joined) < JOIN_GRACE then return nil end      -- grace period

	-- If we never received a heartbeat, treat join time as the anchor so the
	-- timeout is measured from there.
	local last = lastHeartbeat[player] or joined
	if (now - last) < HEARTBEAT_TIMEOUT then return nil end

	-- Cooldown: only emit one flag per TIMEOUT window so threshold accumulation
	-- doesn't sprint through soft → hard within a single missed beat.
	local lastFlag = lastFlagged[player]
	if lastFlag and (now - lastFlag) < HEARTBEAT_TIMEOUT then return nil end
	lastFlagged[player] = now

	return { reason = "Heartbeat", severity = HEARTBEAT_SEVERITY }
end

return HeartbeatGuard
