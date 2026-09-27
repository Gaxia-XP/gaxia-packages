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

local IS_SERVER : boolean = RunService:IsServer()

-- Sibling module: Constants (pure frozen table; typed, so its keys autocomplete).
local Constants = require(script.Parent.Constants)

local DEFAULT_RATE  : number = Constants.REMOTE_RATE_LIMIT_DEFAULT or 10
local DEFAULT_BURST : number = Constants.REMOTE_RATE_BURST or 20

-- ── Types ──

export type RemoteOpts = {
	rate  : number?,                        -- requests per second (token refill rate)
	burst : number?,                        -- bucket capacity (max queue before throttle)
	-- One predicate per positional arg; a falsy first return rejects (HARD flag +
	-- drop). Gaxia.Guard checks plug in directly — they return (ok, err) and Net
	-- only reads the truthy `ok`. For a single table payload validate its SHAPE:
	--   { validators = { Guard.strictInterface({ id = Guard.string, qty = Guard.integer }) } }
	-- (typed `-> (boolean, ...any)` so both plain predicates and Guard checks fit)
	validators : { (any) -> (boolean, ...any) }?,
}

-- ── Folder bootstrap ──

-- Server creates Events/Net lazily; clients wait for replication.
-- (player, reason, severity) — installed by the server's AntiCheat (Init), which
-- decides escalation. Kept as a hook so this shared module never reaches into
-- ServerStorage. Violations before a handler is installed are dropped.
export type ViolationHandler = (player: Player, reason: string, severity: "soft" | "hard") -> ()

-- ReplicatedStorage.Events/Net. The server creates it when NetService is first
-- required (the server loader does that before any player joins). The client
-- resolves it on first use instead of in this module body, which can run inside
-- the Gaxia loader's __index metamethod where waiting is not allowed; by then the
-- folder has replicated, so the lookup normally finds it without waiting.
local netFolder : Folder? = nil

local function ensureServerFolders(): Folder
	local events = ReplicatedStorage:FindFirstChild("Events")
	if not events then
		events = Instance.new("Folder")
		events.Name = "Events"
		events.Parent = ReplicatedStorage
	end
	local found = (events :: Instance):FindFirstChild("Net")
	if not found then
		local net = Instance.new("Folder")
		net.Name = "Net"
		net.Parent = events
		found = net
	end
	return found :: Folder
end

local function getNetFolder(): Folder
	local cached = netFolder
	if cached then
		return cached
	end
	local folder: Folder
	if IS_SERVER then
		folder = ensureServerFolders()
	else
		local events = ReplicatedStorage:FindFirstChild("Events") or ReplicatedStorage:WaitForChild("Events", 10)
		assert(events, "[NetService] ReplicatedStorage.Events folder missing")
		local found = events:FindFirstChild("Net") or events:WaitForChild("Net", 10)
		assert(found, "[NetService] Events.Net folder missing on client")
		folder = found :: Folder
	end
	netFolder = folder
	return folder
end

if IS_SERVER then
	getNetFolder()
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

local violationHandler : ViolationHandler? = nil

local function reportViolation(player: Player, reason: string, severity: "soft" | "hard"): ()
	local handler = violationHandler
	if handler then
		handler(player, reason, severity)
	end
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
	reportViolation(player, `RemoteRate:{name}`, "soft")
	return false
end

local function validateArgs(validators: { (any) -> (boolean, ...any) }?, args: { any }): boolean
	if not validators then return true end
	for i, predicate in ipairs(validators) do
		if not predicate(args[i]) then return false end
	end
	return true
end

-- Get-or-create remote of the requested class under Net folder. On the client
-- this waits up to 10s for replication; on the server it creates immediately.
local function getOrCreate(className: string, name: string): Instance
	local folder = getNetFolder()
	local existing = folder:FindFirstChild(name)
	if existing then
		assert(existing.ClassName == className,
			`[NetService] '{name}' is a {existing.ClassName}, expected {className}`)
		return existing
	end
	if IS_SERVER then
		local inst = Instance.new(className)
		inst.Name = name
		inst.Parent = folder
		return inst
	end
	local waited = folder:WaitForChild(name, 10)
	if not waited then
		error(`[NetService] Remote '{name}' not registered by server`)
	end
	return waited
end

-- ── Module ──

local Net = {}

-- Server: route rate-limit ("soft") and argument-validation ("hard") violations to
-- `handler`. The AntiCheat orchestrator installs this in its Init.
function Net.SetViolationHandler(handler: ViolationHandler?): ()
	assert(IS_SERVER, "Net.SetViolationHandler is server-only")
	violationHandler = handler
end

-- ── Server API ──

function Net.OnServer(name: string, handler: (player: Player, ...any) -> (), opts: RemoteOpts?): RemoteEvent
	assert(IS_SERVER, "Net.OnServer is server-only")
	local re = getOrCreate("RemoteEvent", name) :: RemoteEvent
	re.OnServerEvent:Connect(function(player: Player, ...: any)
		if not consume(player, name, opts) then return end
		if not validateArgs(opts and opts.validators, { ... }) then
			reportViolation(player, `RemoteValidation:{name}`, "hard")
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
			reportViolation(player, `RemoteValidation:{name}`, "hard")
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

-- Returns whatever the server's OnInvoke handler returned (all values).
function Net.InvokeServer(name: string, ...: any): ...any
	assert(not IS_SERVER, "Net.InvokeServer is client-only")
	local rf = getOrCreate("RemoteFunction", name) :: RemoteFunction
	return rf:InvokeServer(...)
end

return Net
