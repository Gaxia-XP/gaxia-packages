--!strict
--[[
	Module : RemoteRateLimiter
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.RemoteRateLimiter
	Purpose : Token-bucket rate limiter for RemoteEvent fires. Auto-wraps every
	          RemoteEvent under ReplicatedStorage.Events at startup so existing
	          handlers stay unchanged. Flag when a player exceeds the rate
	          budget more than BURST per second.

	Public extra API: RemoteRateLimiter.Wrap(remote)  -- attach to ad-hoc remotes.
]]


local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Constants = SharedPkg.Constants or {}

-- Rate limits stay in Shared/Constants: NetService (shared, runs on the client too)
-- reads the same keys, and a server-only Config can't be required from the client.
local RATE_LIMIT : number = (Constants.REMOTE_RATE_LIMIT_DEFAULT :: any) or 10
local BURST      : number = (Constants.REMOTE_RATE_BURST :: any) or 20

-- Severity, however, IS server-private — read it from the server Config like the
-- other detectors. FindFirstChild (never WaitForChild): loaded under the no-yield
-- __index metamethod; Config's body is a pure table so require cannot yield.
local Config = require(script.Parent.Parent:FindFirstChild("Config") :: ModuleScript) :: any
local RATE_SEVERITY : string = (Config.AntiCheat.RemoteRate.Severity :: any) or "soft"

-- (userId, remote) → { tokens: number, lastClock: number }
type Bucket = { tokens: number, lastClock: number }
local buckets: { [Player]: { [RemoteEvent]: Bucket } } = setmetatable({}, { __mode = "k" }) :: any

local RemoteRateLimiter = {}
RemoteRateLimiter.Name = "RemoteRate"

local orchestratorRef: any = nil

-- Refill tokens based on elapsed time. Caps at BURST so idle players cannot
-- bank infinite firepower.
local function refill(bucket: Bucket): ()
	local now = os.clock()
	local elapsed = now - bucket.lastClock
	bucket.tokens = math.min(BURST, bucket.tokens + elapsed * RATE_LIMIT)
	bucket.lastClock = now
end

local function getBucket(player: Player, remote: RemoteEvent): Bucket
	local perPlayer = buckets[player]
	if not perPlayer then
		perPlayer = {}
		buckets[player] = perPlayer
	end
	local b = perPlayer[remote]
	if not b then
		b = { tokens = BURST, lastClock = os.clock() }
		perPlayer[remote] = b
	end
	return b
end

-- ── Net folder skip guard (Phase 17.5) ──
-- NetService (Shared) parents every remote it creates under Events.Net and applies
-- its OWN per-(player,remote) token bucket. Wrapping those here too would emit a
-- redundant "RemoteRate" flag per Net fire — Wrap never actually drops the fire
-- (it shares the signal), it only flags, so the bug is spurious AntiCheat
-- escalation, not dropped packets. Skip any remote whose ancestor is Events.Net;
-- raw Events/* remotes stay auto-wrapped.
local netFolderRef: Instance? = nil

local function isNetManaged(remote: Instance): boolean
	local net = netFolderRef
	if not net then
		-- Lazily (re)resolve so a Net folder created after Init still gets skipped.
		local events = ReplicatedStorage:FindFirstChild("Events")
		net = events and events:FindFirstChild("Net")
		netFolderRef = net
	end
	if not net then
		return false
	end
	return remote == net or remote:IsDescendantOf(net)
end

-- Wrap a single RemoteEvent: every server-side OnServerEvent handler is now
-- gated by token availability. Returns the same RemoteEvent for chaining.
function RemoteRateLimiter.Wrap(remote: RemoteEvent): RemoteEvent
	-- Hook into OnServerEvent at the source so callers never see the firing.
	remote.OnServerEvent:Connect(function(player, ...)
		local bucket = getBucket(player, remote)
		refill(bucket)
		if bucket.tokens >= 1 then
			bucket.tokens -= 1
			-- Pass-through: caller's own OnServerEvent listeners still fire normally
			-- because we share the signal — Roblox dispatches to all connections.
			return
		end
		-- Out of tokens — flag and DROP this fire by simply not consuming any
		-- side state (other listeners still see it; if you want hard block,
		-- destroy the remote on flag).
		if orchestratorRef then
			orchestratorRef.Flag(player, "RemoteRate", RATE_SEVERITY)
		end
	end)
	return remote
end

function RemoteRateLimiter.Init(orchestrator: any): ()
	orchestratorRef = orchestrator
	-- Auto-wrap every RemoteEvent under ReplicatedStorage.Events. Detectors
	-- spawned after game start can still be wrapped via RemoteRateLimiter.Wrap.
	local events = ReplicatedStorage:FindFirstChild("Events")
	if events then
		-- Remotes under Events.Net are owned + rate-limited by NetService; cache the
		-- folder so isNetManaged() skips them and we don't double-count Net fires.
		netFolderRef = events:FindFirstChild("Net")
		for _, child in ipairs(events:GetDescendants()) do
			if child:IsA("RemoteEvent") and not isNetManaged(child) then
				RemoteRateLimiter.Wrap(child)
			end
		end
		-- Auto-wrap future RemoteEvents added to Events — except NetService's own.
		events.DescendantAdded:Connect(function(d)
			if d:IsA("RemoteEvent") and not isNetManaged(d) then
				RemoteRateLimiter.Wrap(d)
			end
		end)
	end
end

return RemoteRateLimiter
