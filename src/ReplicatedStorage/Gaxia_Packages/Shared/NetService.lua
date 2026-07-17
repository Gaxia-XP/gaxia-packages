--!strict
--[[
	Module : NetService
	Location: ReplicatedStorage/Gaxia_Packages/Shared/NetService
	Purpose : Centralised RemoteEvent/RemoteFunction wrapper. Auto-creates
	          remotes under ReplicatedStorage.Events.Net, enforces per-player
	          rate-limit on the server, and validates arg shape. Eliminates
	          boilerplate of finding/creating remotes by name.

	Server:
		Net.OnServer("AwardCoin", function(player, amount) ... end, { rate=5 })
		Net.OnInvoke("Buy", function(player, item) return ok, message end)
		Net.FireClient(player, "Notify", "hi")
		Net.FireAllClients("AnnounceWinner", player.Name)
		Net.FireOtherClients(player, "ChatMessage", text)

	Client:
		Net.OnClient("Notify", function(text) ... end)
		Net.FireServer("AwardCoin", 10)
		local ok, msg = Net.InvokeServer("Buy", "Sword")
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local ServerStorage     = game:GetService("ServerStorage")

local IS_SERVER : boolean = RunService:IsServer()

-- Sibling module: Constants (always present in Shared/).
local Constants : any = require(script.Parent:WaitForChild("Constants"))

local DEFAULT_RATE  : number = (Constants.REMOTE_RATE_LIMIT_DEFAULT :: any) or 10
local DEFAULT_BURST : number = (Constants.REMOTE_RATE_BURST :: any) or 20

-- ── Types ──

export type RemoteOpts = {
	rate  : number?,                        -- requests per second (token refill rate)
	burst : number?,                        -- bucket capacity (max queue before throttle)
	-- One predicate per positional arg; a falsy first return rejects (HARD flag +
	-- drop). Gaxia.Guard checks plug in directly — they return (ok, err) and Net
	-- only reads the truthy `ok`. For a single table payload validate its SHAPE:
	--   { validators = { Guard.strictInterface({ id = Guard.string, qty = Guard.integer }) } }
	validators : { (any) -> boolean }?,
}

-- ── Folder bootstrap ──

-- Server creates Events/Net lazily; clients wait for replication.
local netFolder : Folder
do
	local events : Instance?
	if IS_SERVER then
		events = ReplicatedStorage:FindFirstChild("Events")
		if not events then
			events = Instance.new("Folder")
			events.Name = "Events"
			events.Parent = ReplicatedStorage
		end
	else
		events = ReplicatedStorage:WaitForChild("Events", 10)
	end
	assert(events, "[NetService] ReplicatedStorage.Events folder missing")

	local found = events:FindFirstChild("Net")
	if not found then
		if IS_SERVER then
			found = Instance.new("Folder")
			found.Name = "Net"
			found.Parent = events
		else
			found = events:WaitForChild("Net", 10)
		end
	end
	assert(found, "[NetService] Events.Net folder missing on client")
	netFolder = found :: Folder
end

-- ── Per-player token-bucket rate limit ──
-- Weak keys so GC collects entries when the Player Instance is GC'd.
type Bucket = { tokens: number, lastClock: number }
local buckets : { [Player]: { [string]: Bucket } } = setmetatable({}, { __mode = "k" }) :: any

local function getBucket(player: Player, name: string, rate: number, burst: number): Bucket
	local perPlayer = buckets[player]
	if not perPlayer then
		perPlayer = {}
		buckets[player] = perPlayer
	end
	local b = perPlayer[name]
	if not b then
		b = { tokens = burst, lastClock = os.clock() }
		perPlayer[name] = b
	end
	-- Refill: linear top-up at `rate` tokens/sec, capped at `burst`.
	local now = os.clock()
	b.tokens = math.min(burst, b.tokens + (now - b.lastClock) * rate)
	b.lastClock = now
	return b
end

-- ── AntiCheat lazy reference ──
-- Direct path require so we don't form a recursion cycle with GaxiaServer's
-- __index lazy-load when called from inside AntiCheat init's load chain.
local _antiCheatRef : any = nil
local function getAntiCheat(): any
	if not IS_SERVER then return nil end
	if _antiCheatRef ~= nil then return _antiCheatRef end
	local pkg = ServerStorage:FindFirstChild("Gaxia_Packages_Server")
	if not pkg then return nil end
	local acFolder = pkg:FindFirstChild("AntiCheat")
	local acInit = acFolder and acFolder
	if acInit and acInit:IsA("ModuleScript") then
		local ok, mod = pcall(require, acInit)
		if ok then _antiCheatRef = mod end
	end
	return _antiCheatRef
end

-- ── Internal helpers ──

local function consume(player: Player, name: string, opts: RemoteOpts?): boolean
	local rate  = (opts and opts.rate) or DEFAULT_RATE
	local burst = (opts and opts.burst) or DEFAULT_BURST
	local b = getBucket(player, name, rate, burst)
	if b.tokens >= 1 then
		b.tokens -= 1
		return true
	end
	-- Out of budget — feed AntiCheat (its threshold ladder decides escalation).
	local ac = getAntiCheat()
	if ac then ac.Flag(player, `RemoteRate:{name}`, "soft") end
	return false
end

local function validateArgs(validators: { (any) -> boolean }?, args: { any }): boolean
	if not validators then return true end
	for i, predicate in ipairs(validators) do
		if not predicate(args[i]) then return false end
	end
	return true
end

-- Get-or-create remote of the requested class under Net folder. On the client
-- this waits up to 10s for replication; on the server it creates immediately.
local function getOrCreate(className: string, name: string): Instance
	local existing = netFolder:FindFirstChild(name)
	if existing then
		assert(existing.ClassName == className,
			`[NetService] '{name}' is a {existing.ClassName}, expected {className}`)
		return existing
	end
	if IS_SERVER then
		local inst = Instance.new(className)
		inst.Name = name
		inst.Parent = netFolder
		return inst
	end
	local waited = netFolder:WaitForChild(name, 10)
	if not waited then
		error(`[NetService] Remote '{name}' not registered by server`)
	end
	return waited
end

-- ── Module ──

local Net = {}

-- ── Server API ──

function Net.OnServer(name: string, handler: (player: Player, ...any) -> (), opts: RemoteOpts?): RemoteEvent
	assert(IS_SERVER, "Net.OnServer is server-only")
	local re = getOrCreate("RemoteEvent", name) :: RemoteEvent
	re.OnServerEvent:Connect(function(player: Player, ...: any)
		if not consume(player, name, opts) then return end
		if not validateArgs(opts and opts.validators, { ... }) then
			local ac = getAntiCheat()
			if ac then ac.Flag(player, `RemoteValidation:{name}`, "hard") end
			return
		end
		handler(player, ...)
	end)
	return re
end

function Net.OnInvoke(name: string, handler: (player: Player, ...any) -> ...any, opts: RemoteOpts?): RemoteFunction
	assert(IS_SERVER, "Net.OnInvoke is server-only")
	local rf = getOrCreate("RemoteFunction", name) :: RemoteFunction
	rf.OnServerInvoke = function(player: Player, ...: any)
		if not consume(player, name, opts) then return nil end
		if not validateArgs(opts and opts.validators, { ... }) then
			local ac = getAntiCheat()
			if ac then ac.Flag(player, `RemoteValidation:{name}`, "hard") end
			return nil
		end
		return handler(player, ...)
	end
	return rf
end

function Net.FireClient(player: Player, name: string, ...: any): ()
	assert(IS_SERVER, "Net.FireClient is server-only")
	local re = getOrCreate("RemoteEvent", name) :: RemoteEvent
	re:FireClient(player, ...)
end

function Net.FireAllClients(name: string, ...: any): ()
	assert(IS_SERVER, "Net.FireAllClients is server-only")
	local re = getOrCreate("RemoteEvent", name) :: RemoteEvent
	re:FireAllClients(...)
end

function Net.FireOtherClients(exceptPlayer: Player, name: string, ...: any): ()
	assert(IS_SERVER, "Net.FireOtherClients is server-only")
	local re = getOrCreate("RemoteEvent", name) :: RemoteEvent
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= exceptPlayer then re:FireClient(p, ...) end
	end
end

-- ── Client API ──

function Net.OnClient(name: string, handler: (...any) -> ()): RemoteEvent
	assert(not IS_SERVER, "Net.OnClient is client-only")
	local re = getOrCreate("RemoteEvent", name) :: RemoteEvent
	re.OnClientEvent:Connect(handler)
	return re
end

function Net.FireServer(name: string, ...: any): ()
	assert(not IS_SERVER, "Net.FireServer is client-only")
	local re = getOrCreate("RemoteEvent", name) :: RemoteEvent
	re:FireServer(...)
end

function Net.InvokeServer(name: string, ...: any): any
	assert(not IS_SERVER, "Net.InvokeServer is client-only")
	local rf = getOrCreate("RemoteFunction", name) :: RemoteFunction
	return rf:InvokeServer(...)
end

return Net
