--!strict
--[[
	Module : NetService
	Location: ReplicatedStorage/Gaxia_Packages/Shared/NetService
	Purpose : Centralised RemoteEvent/RemoteFunction wrapper. Auto-creates
	          remotes under ReplicatedStorage.Events.Net and owns their inbound
	          connections. Before a gameplay handler runs, the server applies a
	          global + per-RPC rate gate, a bounded decode, replay blocking,
	          structural validation, argument validators and a per-RPC
	          concurrency limit. Transport obfuscation is only a deterrent, never
	          authentication: the server must still validate every request.

	Server:
		Net.OnServer("AwardCoin", function(player, amount) ... end, { rate=5 })
		Net.OnInvoke("Buy", function(player, item) return ok, message end)
		Net.FireClient(player, "Notify", "hi")
		Net.FireAllClients("AnnounceWinner", player.Name)
		Net.FireOtherClients(player, "ChatMessage", text)
		Net.DeclareEvent("Announce")  -- server → client only: create it so clients can listen

	Client:
		Net.OnClient("Notify", function(text) ... end)
		Net.FireServer("AwardCoin", 10)
		local ok, msg = Net.InvokeServer("Buy", "Sword")

	Definition API (one table payload, schema required, returns a handle):
		Net.Server.RegisterEvent("PetEquip", { schema = ..., handler = function(context, payload) end })
		Net.Server.RegisterFunction("PetGetState", { schema = ..., handler = ... })
		Net.Client.Fire("PetEquip", { uid = uid })
		local result = Net.Client.Invoke("PetGetState", {}) -- { ok = true, data = ... } | { ok = false, code = "..." }
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- WHY the extra Studio clause: in Edit mode via tooling (plugin runners, MCP
-- tests) IsServer()/IsClient() are BOTH false — the module would take the
-- client path, stall on WaitForChild("Events"), and assert. Edit mode has no
-- real client, so server semantics are the correct default there. Play mode
-- and live servers are unaffected (IsRunning() gates the clause off).
local IS_SERVER: boolean = RunService:IsServer()
	or (RunService:IsStudio() and not RunService:IsRunning())

-- Sibling modules (typed static requires; Constants keys autocomplete).
local Constants = require(script.Parent.Constants)
local NetProtocol = require(script.Parent.NetProtocol)
local RemoteObfuscator = require(script.Parent.RemoteObfuscator)

local DEFAULT_RATE: number = Constants.REMOTE_RATE_LIMIT_DEFAULT or 10
local DEFAULT_BURST: number = Constants.REMOTE_RATE_BURST or 20
local GLOBAL_RATE: number = Constants.REMOTE_GLOBAL_RATE_LIMIT_DEFAULT or 60
local GLOBAL_BURST: number = Constants.REMOTE_GLOBAL_RATE_BURST or 100
local DEFAULT_CONCURRENCY: number = Constants.REMOTE_CONCURRENCY_DEFAULT or 4
local HANDSHAKE_NAME: string = "_gxk"
local MAX_ARGUMENTS: number = 64

-- ── Types ──

export type RemoteOpts = {
	rate: number?, -- requests per second (token refill rate)
	burst: number?, -- bucket capacity (max queue before throttle)
	budget: string?, -- NetProtocol payload profile: "tiny" | "small" (default) | "medium"
	concurrency: number?, -- max in-flight handlers per player/RPC (default 4)
	-- One predicate per positional arg; a falsy first return rejects (drop + a
	-- `RemoteValidation:<name>` flag of `validationSeverity`). A predicate that
	-- errors also rejects (no flag; a warning names the remote). Gaxia.Guard checks
	-- plug in directly — they return (ok, err) and Net only reads the truthy `ok`.
	-- For a single table payload validate its SHAPE:
	--   { validators = { Guard.strictInterface({ id = Guard.string, qty = Guard.integer }) } }
	-- (typed `-> (boolean, ...any)` so both plain predicates and Guard checks fit)
	validators: { (any) -> (boolean, ...any) }?,
	-- Severity of the AntiCheat flag when a validator rejects: "soft" (default,
	-- counts toward the threshold ladder) or "hard" (escalates at once).
	validationSeverity: ("soft" | "hard")?,
	-- Internal (definition API): builds the response a rejected invoke returns.
	-- Without it a rejected Net.InvokeServer returns nil, as it always has.
	reject: ((code: string) -> ...any)?,
	-- Internal (definition API): exact positional argument count.
	argumentCount: number?,
}

-- Who produced the evidence. Every NetService violation comes from what a
-- client sent, so it is "client": telemetry for AntiCheat, never enough to
-- punish a player by itself.
export type ViolationSource = "client"

-- (player, reason, severity, source) — installed by the server's AntiCheat
-- (Init), which decides escalation. Kept as a hook so this shared module never
-- reaches into ServerStorage. Violations before a handler is installed are dropped.
export type ViolationHandler = (player: Player, reason: string, severity: "soft" | "hard", source: ViolationSource) -> ()

-- Passed to definition-API handlers and context validators.
export type RpcContext = {
	player: Player,
	name: string,
}

-- A definition-API endpoint. `schema` validates the payload table; `validate`
-- checks server-side context (permission, ownership, state). A `mutation`
-- endpoint must have `validate` and `concurrency = 1`; repeated request ids
-- within 30 s run its handler once.
export type RpcDefinition = {
	schema: (payload: any) -> (boolean, ...any), -- a Gaxia.Guard check fits
	handler: (context: RpcContext, payload: any) -> ...any,
	validate: ((context: RpcContext, payload: any) -> boolean)?,
	mutation: boolean?,
	rate: number?,
	burst: number?,
	budget: string?,
	concurrency: number?,
}

-- What Net.Client.Invoke returns: `{ ok = true, data = ... }` or `{ ok = false, code = "..." }`
-- (code is one of NetProtocol.Code).
export type RpcResult = { [string]: any }

-- Returned by Net.Server.RegisterEvent / RegisterFunction.
export type RegistrationHandle = {
	-- Stops the endpoint; the same name can then be registered again.
	Destroy: (self: RegistrationHandle) -> (),
	IsActive: (self: RegistrationHandle) -> boolean,
}

export type RpcMetrics = {
	received: number,
	accepted: number,
	rejected: number,
	inFlight: number,
	handlerErrors: number,
	idempotentHits: number,
	totalHandlerSeconds: number,
	maxHandlerSeconds: number,
	reasons: { [string]: number },
}

-- ── Folder bootstrap ──

-- ReplicatedStorage.Events/Net. The server creates it when NetService is first
-- required (the server loader does that before any player joins). The client
-- resolves it on first use instead of in this module body, which can run inside
-- the Gaxia loader's __index metamethod where waiting is not allowed; by then the
-- folder has replicated, so the lookup normally finds it without waiting.
local netFolder: Folder? = nil

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

-- ── Per-player request state ──
-- Weak keys so GC collects entries when the Player Instance is GC'd (and
-- PlayerRemoving clears them at once).
type Bucket = { tokens: number, lastClock: number }
-- Each registration gets a monotonically increasing scope. A logical RPC name
-- can be destroyed and re-registered, so its mutable request state must never
-- be keyed by that reusable name.
type RegistrationScope = number

local buckets: { [Player]: { [RegistrationScope]: Bucket } } = setmetatable({}, { __mode = "k" }) :: any
local globalBuckets: { [Player]: Bucket } = setmetatable({}, { __mode = "k" }) :: any
local sessionKeys: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any
local replayWindows: { [Player]: { [RegistrationScope]: any } } = setmetatable({}, { __mode = "k" }) :: any
local inFlight: { [Player]: { [RegistrationScope]: number } } = setmetatable({}, { __mode = "k" }) :: any
-- A destroy/re-register cycle receives a new scope for replay/cache isolation,
-- but it must not let a new definition bypass work already in progress for the
-- same logical RPC.
local logicalInFlight: { [Player]: { [string]: number } } = setmetatable({}, { __mode = "k" }) :: any
local requestCaches: { [Player]: { [RegistrationScope]: any } } = setmetatable({}, { __mode = "k" }) :: any
local clientSessionKey: number? = nil
local sessionRng = Random.new()
local wireNameOwners: { [string]: string } = {}
local metricsByName: { [string]: RpcMetrics } = {}

local function metricsFor(name: string): RpcMetrics
	local existing = metricsByName[name]
	if existing then
		return existing
	end
	local metrics: RpcMetrics = {
		received = 0,
		accepted = 0,
		rejected = 0,
		inFlight = 0,
		handlerErrors = 0,
		idempotentHits = 0,
		totalHandlerSeconds = 0,
		maxHandlerSeconds = 0,
		reasons = {},
	}
	metricsByName[name] = metrics
	return metrics
end

local function recordReceived(name: string): ()
	metricsFor(name).received += 1
end

local function recordAccepted(name: string): ()
	metricsFor(name).accepted += 1
end

local function recordRejected(name: string, code: string): ()
	local metrics = metricsFor(name)
	metrics.rejected += 1
	metrics.reasons[code] = (metrics.reasons[code] or 0) + 1
end

local function recordHandlerResult(name: string, elapsed: number, succeeded: boolean): ()
	local metrics = metricsFor(name)
	metrics.totalHandlerSeconds += elapsed
	metrics.maxHandlerSeconds = math.max(metrics.maxHandlerSeconds, elapsed)
	if not succeeded then
		metrics.handlerErrors += 1
	end
end

local function getBucket(player: Player, scope: RegistrationScope, burst: number): Bucket
	local perPlayer = buckets[player]
	if not perPlayer then
		perPlayer = {}
		buckets[player] = perPlayer
	end
	local b = perPlayer[scope]
	if not b then
		b = { tokens = burst, lastClock = os.clock() }
		perPlayer[scope] = b
	end
	return b
end

-- Refill (linear top-up at `rate` tokens/sec, capped at `burst`), then take one.
local function consumeBucket(bucket: Bucket, rate: number, burst: number): boolean
	local now = os.clock()
	bucket.tokens = math.min(burst, bucket.tokens + (now - bucket.lastClock) * rate)
	bucket.lastClock = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

-- ── Violations (AntiCheat hook) ──

local violationHandler: ViolationHandler? = nil

local function reportViolation(player: Player, reason: string, severity: "soft" | "hard"): ()
	local handler = violationHandler
	if handler then
		handler(player, reason, severity, "client")
	end
end

-- Warnings a client can trigger (a validator that errors on its input) are
-- throttled per remote so a spamming client cannot flood Output.
local WARN_INTERVAL: number = 10
local lastWarn: { [string]: number } = {}

local function throttledWarn(key: string, message: string): ()
	local now = os.clock()
	local last = lastWarn[key]
	if last and now - last < WARN_INTERVAL then
		return
	end
	lastWarn[key] = now
	warn(message)
end

-- ── Internal helpers ──

-- Global bucket first (all of a player's remotes together), then the RPC's own.
-- Returns the violation category on failure: "GlobalRate" | "Rate".
local function consume(player: Player, scope: RegistrationScope, opts: RemoteOpts?): (boolean, string?)
	local global = globalBuckets[player]
	if not global then
		global = { tokens = GLOBAL_BURST, lastClock = os.clock() }
		globalBuckets[player] = global
	end
	if not consumeBucket(global, GLOBAL_RATE, GLOBAL_BURST) then
		return false, "GlobalRate"
	end
	local rate = (opts and opts.rate) or DEFAULT_RATE
	local burst = (opts and opts.burst) or DEFAULT_BURST
	if consumeBucket(getBucket(player, scope, burst), rate, burst) then
		return true, nil
	end
	return false, "Rate"
end

-- "ok" | "rejected" | "errored". A predicate that errors rejects the request.
local function validateArgs(name: string, validators: { (any) -> (boolean, ...any) }?, args: { any }): "ok" | "rejected" | "errored"
	if not validators then
		return "ok"
	end
	for i, predicate in ipairs(validators) do
		local called, passed = pcall(predicate, args[i])
		if not called then
			throttledWarn(`validator:{name}`, `[NetService] validator {i} of remote '{name}' errored (request rejected): {tostring(passed)}`)
			return "errored"
		end
		if not passed then
			return "rejected"
		end
	end
	return "ok"
end

local function getServerSessionKey(player: Player): number
	local existing = sessionKeys[player]
	if existing then
		return existing
	end
	local key = sessionRng:NextInteger(1, 0x7FFFFFFF)
	sessionKeys[player] = key
	return key
end

local function deriveTransportKey(sessionKey: number, name: string): number
	local hash = 5381
	for index = 1, #name do
		hash = bit32.band(hash * 33 + string.byte(name, index), 0xFFFFFFFF)
	end
	local derived = bit32.bxor(sessionKey, hash)
	return if derived == 0 then 0xA341316C else derived
end

local function decodeArguments(key: number, name: string, envelope: any, budgetName: string?): (boolean, { any }?)
	-- Server-side inbound requests are decoded against the endpoint's eventual
	-- payload budget before strings or tables are rebuilt. Client-side decoding
	-- accepts trusted server responses under RemoteObfuscator's global bounds so
	-- a valid read response is not accidentally constrained by the C2S budget.
	local limits = if IS_SERVER then NetProtocol.GetBudget(budgetName) else nil
	local ok, decoded = pcall(RemoteObfuscator.Decode, deriveTransportKey(key, name), envelope, limits)
	if not ok or typeof(decoded) ~= "table" then
		return false, nil
	end
	local count = decoded.n
	if typeof(count) ~= "number" or count % 1 ~= 0 or count < 0 or count > MAX_ARGUMENTS then
		return false, nil
	end
	for argumentKey in pairs(decoded) do
		if argumentKey ~= "n" then
			if typeof(argumentKey) ~= "number" or argumentKey % 1 ~= 0 or argumentKey < 1 or argumentKey > count then
				return false, nil
			end
		end
	end
	return true, decoded
end

local function encodeArguments(key: number, name: string, args: { any }): { any }
	return RemoteObfuscator.Encode(deriveTransportKey(key, name), args)
end

local function encodeReject(key: number, name: string, opts: RemoteOpts?, code: string): { any }
	local reject = opts and opts.reject
	if reject then
		local result = table.pack(pcall(reject, code))
		if result[1] then
			return encodeArguments(key, name, table.pack(table.unpack(result, 2, result.n)))
		end
		warn(`[NetService] rejection formatter for '{name}' errored: {tostring(result[2])}`)
	end
	return encodeArguments(key, name, table.pack(nil))
end

local function acceptNonce(player: Player, scope: RegistrationScope, envelope: any): boolean
	local nonce = typeof(envelope) == "table" and envelope[2] or nil
	if not NetProtocol.IsValidNonce(nonce) then
		return false
	end
	local perPlayer = replayWindows[player]
	if not perPlayer then
		perPlayer = {}
		replayWindows[player] = perPlayer
	end
	local window = perPlayer[scope]
	if not window then
		window = NetProtocol.NewReplayWindow()
		perPlayer[scope] = window
	end
	return NetProtocol.RememberNonce(window, nonce)
end

local function tryAcquire(player: Player, scope: RegistrationScope, name: string, opts: RemoteOpts?): boolean
	local limit = math.floor((opts and opts.concurrency) or DEFAULT_CONCURRENCY)
	if limit < 1 then
		return false
	end
	local perPlayer = inFlight[player]
	if not perPlayer then
		perPlayer = {}
		inFlight[player] = perPlayer
	end
	local perLogical = logicalInFlight[player]
	if not perLogical then
		perLogical = {}
		logicalInFlight[player] = perLogical
	end
	local current = perPlayer[scope] or 0
	local logicalCurrent = perLogical[name] or 0
	if current >= limit or logicalCurrent >= limit then
		return false
	end
	perPlayer[scope] = current + 1
	perLogical[name] = logicalCurrent + 1
	metricsFor(name).inFlight += 1
	return true
end

local function release(player: Player, scope: RegistrationScope, name: string): ()
	local perPlayer = inFlight[player]
	if perPlayer then
		local current = perPlayer[scope]
		if current and current > 0 then
			if current == 1 then
				perPlayer[scope] = nil
			else
				perPlayer[scope] = current - 1
			end
		end
	end
	local perLogical = logicalInFlight[player]
	if perLogical then
		local current = perLogical[name]
		if current and current > 0 then
			if current == 1 then
				perLogical[name] = nil
			else
				perLogical[name] = current - 1
			end
		end
	end
	-- release is called exactly once after a successful tryAcquire. PlayerRemoving
	-- may have cleared the per-player table while a yielding handler completes,
	-- but that must not leave the aggregate metric permanently elevated.
	local metrics = metricsFor(name)
	metrics.inFlight = math.max(0, metrics.inFlight - 1)
end

-- AntiCheat reason category for a NetProtocol structural rejection code.
local STRUCTURE_CATEGORY: { [string]: string } = {
	[NetProtocol.Code.BUDGET] = "Budget",
	[NetProtocol.Code.INVALID_NUMBER] = "InvalidNumber",
	[NetProtocol.Code.UNSUPPORTED_TYPE] = "UnsupportedType",
	[NetProtocol.Code.MALFORMED] = "Malformed",
}

-- Rejects with (`Remote<category>:<name>`, "soft") and records the metric code.
local function rejectInbound(player: Player, name: string, category: string, code: string): ()
	reportViolation(player, `Remote{category}:{name}`, "soft")
	recordRejected(name, code)
end

-- The gates every inbound request passes, in this order: rate (global, then
-- per-RPC), bounded decode, structural budget, argument count, validators,
-- replay. Returns the decoded args, or nil and the NetProtocol rejection code.
local function validateInbound(player: Player, name: string, scope: RegistrationScope, envelope: any, opts: RemoteOpts?): ({ any }?, string?)
	local consumed, rateCategory = consume(player, scope, opts)
	if not consumed then
		local category = rateCategory or "Rate"
		rejectInbound(player, name, category, if category == "GlobalRate" then "GLOBAL_RATE" else "RPC_RATE")
		return nil, NetProtocol.Code.RATE_LIMITED
	end
	local decoded, args = decodeArguments(getServerSessionKey(player), name, envelope, opts and opts.budget)
	if not decoded or not args then
		rejectInbound(player, name, "Malformed", NetProtocol.Code.MALFORMED)
		return nil, NetProtocol.Code.MALFORMED
	end
	local structurallyValid, structureCode = NetProtocol.ValidatePayload(args, opts and opts.budget)
	if not structurallyValid then
		local code = structureCode or NetProtocol.Code.BUDGET
		rejectInbound(player, name, STRUCTURE_CATEGORY[code] or "Budget", code)
		return nil, code
	end
	if opts and opts.argumentCount ~= nil and (args :: any).n ~= opts.argumentCount then
		rejectInbound(player, name, "ArgumentCount", NetProtocol.Code.SCHEMA)
		return nil, NetProtocol.Code.SCHEMA
	end
	local verdict = validateArgs(name, opts and opts.validators, args)
	if verdict ~= "ok" then
		-- A validator that errors already warned (throttled); it is not the
		-- client's fault, so only a plain rejection raises an AntiCheat flag.
		if verdict == "rejected" then
			reportViolation(player, `RemoteValidation:{name}`, (opts and opts.validationSeverity) or "soft")
		end
		recordRejected(name, NetProtocol.Code.SCHEMA)
		return nil, NetProtocol.Code.SCHEMA
	end
	-- Only a fully decoded, structurally valid and schema-valid request may
	-- consume replay state. Otherwise forged malformed envelopes could evict a
	-- player's valid nonce window without ever being eligible for a handler.
	if not acceptNonce(player, scope, envelope) then
		rejectInbound(player, name, "Replay", NetProtocol.Code.REPLAY)
		return nil, NetProtocol.Code.REPLAY
	end
	return args, nil
end

-- Remote instances are named by a hash of the logical name ("r%08x"), so the
-- Explorer does not list every RPC by name. The handshake keeps its own name.
local function wireName(name: string): string
	assert(#name > 0, "[NetService] remote name cannot be empty")
	if name == HANDSHAKE_NAME then
		return name
	end
	local hash = 5381
	for index = 1, #name do
		hash = bit32.band(hash * 33 + string.byte(name, index), 0xFFFFFFFF)
	end
	local encoded = string.format("r%08x", hash)
	if IS_SERVER then
		local owner = wireNameOwners[encoded]
		assert(not owner or owner == name, `[NetService] remote name hash collision: '{owner}' and '{name}'`)
		wireNameOwners[encoded] = name
	end
	return encoded
end

-- Get-or-create remote of the requested class under Net folder. On the client
-- this waits up to 10s for replication; on the server it creates immediately.
local function getOrCreate(className: string, name: string): Instance
	if name == HANDSHAKE_NAME then
		assert(className == "RemoteFunction", `[NetService] RPC '{HANDSHAKE_NAME}' is reserved for the session handshake`)
	end
	local folder = getNetFolder()
	local instanceName = wireName(name)
	local existing = folder:FindFirstChild(instanceName)
	if existing then
		assert(
			existing.ClassName == className,
			`[NetService] '{name}' is a {existing.ClassName}, expected {className} (changing remote kind is not supported)`
		)
		return existing
	end
	if IS_SERVER then
		local inst = Instance.new(className)
		inst.Name = instanceName
		inst.Parent = folder
		return inst
	end
	local waited = folder:WaitForChild(instanceName, 10)
	if not waited then
		error(`[NetService] Remote '{name}' not registered by server`)
	end
	return waited
end

-- Client: wait (without a time limit) for the server to create remote `name`.
-- Warns once after a few seconds, naming the remote and how to declare it.
local CLIENT_WAIT_WARN_AFTER: number = 5

local function waitForClientRemote(className: string, name: string, caller: string): Instance
	local folder = getNetFolder()
	local instanceName = wireName(name)
	local found = folder:FindFirstChild(instanceName)
	if not found then
		local warnThread = task.delay(CLIENT_WAIT_WARN_AFTER, function()
			warn(
				`[NetService] {caller}('{name}') is still waiting: the server has not created remote '{name}'. The server must declare it at the top level of a Script: Net.DeclareEvent("{name}") (server → client only) or Net.OnServer("{name}", handler).`
			)
		end)
		-- No timeout: a remote the server never creates shows up as a stuck thread
		-- (Roblox also prints its "Infinite yield possible" line).
		found = folder:WaitForChild(instanceName)
		task.cancel(warnThread)
	end
	local inst = found :: Instance
	assert(inst.ClassName == className, `[NetService] '{name}' is a {inst.ClassName}, expected {className}`)
	return inst
end

-- xpcall handler for server handlers: the error text first (so Output links its
-- script line), then the handler's stack.
local function handlerTraceback(err: any): string
	return `{tostring(err)}\n{debug.traceback("Stack:", 2)}`
end

-- Red in Output on its own thread, so the request itself still completes.
local function reportHandlerError(trace: any, note: string): ()
	task.spawn(error, `{tostring(trace)}\n[NetService] ({note})`, 0)
end

-- ── Module ──

local Net = {}

Net.Server = {}
Net.Client = {}

-- ── Registrations ──

type RegistrationState = {
	kind: "event" | "function",
	api: "legacy" | "definition",
	active: boolean,
	scope: RegistrationScope,
	connection: RBXScriptConnection?,
	remoteFunction: RemoteFunction?,
}

type Drain = { connection: RBXScriptConnection, scope: RegistrationScope }

-- The current registration per logical name, and the draining listeners
-- DeclareEvent installed (removed once a handler registers).
local registrations: { [string]: RegistrationState } = {}
local drains: { [string]: Drain } = {}
local nextRegistrationScope: RegistrationScope = 0

local function newScope(): RegistrationScope
	nextRegistrationScope += 1
	return nextRegistrationScope
end

local function isPositiveFinite(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value > 0
end

local function clearRegistrationState(scope: RegistrationScope): ()
	for _, perPlayer in pairs(buckets) do
		perPlayer[scope] = nil
	end
	for _, perPlayer in pairs(replayWindows) do
		perPlayer[scope] = nil
	end
	for _, perPlayer in pairs(inFlight) do
		perPlayer[scope] = nil
	end
	for _, perPlayer in pairs(requestCaches) do
		perPlayer[scope] = nil
	end
end

local function deactivateRegistration(name: string, state: RegistrationState): ()
	if not state.active then
		return
	end
	state.active = false
	if state.connection then
		state.connection:Disconnect()
		state.connection = nil
	end
	local remoteFunction = state.remoteFunction
	if remoteFunction then
		-- (the definitions type OnServerInvoke as non-optional; nil unbinds it)
		(remoteFunction :: any).OnServerInvoke = nil
		state.remoteFunction = nil
	end
	clearRegistrationState(state.scope)
	if registrations[name] == state then
		registrations[name] = nil
	end
end

local function removeDrain(name: string): ()
	local drain = drains[name]
	if drain then
		drain.connection:Disconnect()
		clearRegistrationState(drain.scope)
		drains[name] = nil
	end
end

-- Claims `name` for a new registration. Definition endpoints fail closed on any
-- duplicate. Legacy Net.OnServer / Net.OnInvoke keep their documented behaviour:
-- a second Net.OnServer warns and both handlers run; a second Net.OnInvoke
-- warns and replaces the first.
local function claimRegistration(name: string, kind: "event" | "function", api: "legacy" | "definition"): RegistrationState
	assert(typeof(name) == "string" and #name > 0, "RPC name must be a non-empty string")
	assert(name ~= HANDSHAKE_NAME, `[NetService] RPC '{HANDSHAKE_NAME}' is reserved`)
	local previous = registrations[name]
	if previous then
		assert(
			previous.api == "legacy" and api == "legacy",
			`[NetService] RPC '{name}' is already registered`
		)
		assert(
			previous.kind == kind,
			`[NetService] RPC '{name}' is already registered as a {previous.kind}; changing remote kind is not supported`
		)
		if kind == "event" then
			warn(
				`[NetService] Net.OnServer('{name}') registered twice: every handler runs for each event. Register each remote once, at the top level of a Script.`
			)
		else
			warn(
				`[NetService] Net.OnInvoke('{name}') registered twice: the new handler replaces the previous one. Register each remote once, at the top level of a Script.`
			)
			deactivateRegistration(name, previous)
		end
	end
	if kind == "event" then
		removeDrain(name)
	end
	local state: RegistrationState = {
		kind = kind,
		api = api,
		active = true,
		scope = newScope(),
		connection = nil,
		remoteFunction = nil,
	}
	registrations[name] = state
	return state
end

local function assertDefinition(name: string, definition: RpcDefinition, kind: "event" | "function"): RegistrationState
	assert(typeof(name) == "string" and #name > 0, "RPC name must be a non-empty string")
	assert(typeof(definition) == "table", "RPC definition must be a table")
	assert(typeof(definition.schema) == "function", `[NetService] RPC '{name}' requires schema`)
	assert(typeof(definition.handler) == "function", `[NetService] RPC '{name}' requires handler`)
	if definition.mutation then
		assert(typeof(definition.validate) == "function", `[NetService] mutation RPC '{name}' requires context validation`)
		assert(definition.concurrency == 1, `[NetService] mutation RPC '{name}' must use concurrency = 1`)
	end
	assert(NetProtocol.IsBudgetName(definition.budget or "small"), `[NetService] RPC '{name}' uses an unknown budget profile`)
	if definition.rate ~= nil then
		assert(isPositiveFinite(definition.rate), `[NetService] RPC '{name}' rate must be positive and finite`)
	end
	if definition.burst ~= nil then
		assert(isPositiveFinite(definition.burst), `[NetService] RPC '{name}' burst must be positive and finite`)
	end
	if definition.concurrency ~= nil then
		assert(
			isPositiveFinite(definition.concurrency) and (definition.concurrency :: number) % 1 == 0,
			`[NetService] RPC '{name}' concurrency must be a positive integer`
		)
	end
	return claimRegistration(name, kind, "definition")
end

local function requestEnvelope(value: any): boolean
	if typeof(value) ~= "table" or not NetProtocol.IsValidRequestId(value.requestId) then
		return false
	end
	for key in pairs(value) do
		if key ~= "requestId" and key ~= "payload" then
			return false
		end
	end
	return true
end

local function definitionOpts(definition: RpcDefinition): RemoteOpts
	return {
		rate = definition.rate,
		burst = definition.burst,
		budget = definition.budget or "small",
		concurrency = definition.concurrency,
		argumentCount = 1,
		validators = {
			function(value: any): boolean
				return requestEnvelope(value) and definition.schema(value.payload)
			end,
		},
		reject = function(code: string)
			return { ok = false, code = code }
		end,
	}
end

local function requestCacheFor(player: Player, scope: RegistrationScope): any
	local perPlayer = requestCaches[player]
	if not perPlayer then
		perPlayer = {}
		requestCaches[player] = perPlayer
	end
	local cache = perPlayer[scope]
	if not cache then
		cache = NetProtocol.NewRequestCache()
		perPlayer[scope] = cache
	end
	return cache
end

local function contextIsAllowed(definition: RpcDefinition, player: Player, name: string, payload: any): (boolean, RpcContext)
	local context: RpcContext = { player = player, name = name }
	local validate = definition.validate
	if not validate then
		return true, context
	end
	local ok, allowed = xpcall(function()
		return validate(context, payload)
	end, debug.traceback)
	if ok and allowed == true then
		return true, context
	end
	if not ok then
		throttledWarn(`context:{name}`, `[NetService] context validator for '{name}' errored: {tostring(allowed)}`)
	end
	rejectInbound(player, name, "Forbidden", NetProtocol.Code.FORBIDDEN)
	return false, context
end

local function bindWithRollback(name: string, state: RegistrationState, binder: () -> Instance): Instance
	local ok, result = xpcall(binder, debug.traceback)
	if ok then
		return result
	end
	deactivateRegistration(name, state)
	error(result, 0)
end

local function registrationHandle(name: string, state: RegistrationState): RegistrationHandle
	local handle = {}
	function handle.Destroy(_self: RegistrationHandle): ()
		deactivateRegistration(name, state)
	end
	function handle.IsActive(_self: RegistrationHandle): boolean
		return state.active
	end
	return handle :: any
end

-- The key only deters basic inspection. Because it is delivered to client code,
-- it must never be treated as authentication or replace server validation.
if IS_SERVER then
	local folder = getNetFolder()
	local existing = folder:FindFirstChild(HANDSHAKE_NAME)
	assert(not existing or existing:IsA("RemoteFunction"), "[NetService] handshake name collision")
	local handshake = (existing or Instance.new("RemoteFunction")) :: RemoteFunction
	handshake.Name = HANDSHAKE_NAME
	handshake.OnServerInvoke = function(player: Player): number
		return getServerSessionKey(player)
	end
	handshake.Parent = folder
	Players.PlayerRemoving:Connect(function(player: Player)
		sessionKeys[player] = nil
		buckets[player] = nil
		globalBuckets[player] = nil
		replayWindows[player] = nil
		inFlight[player] = nil
		logicalInFlight[player] = nil
		requestCaches[player] = nil
	end)
end

local function getClientSessionKey(): number
	local cached = clientSessionKey
	if cached then
		return cached
	end
	local handshake = getOrCreate("RemoteFunction", HANDSHAKE_NAME) :: RemoteFunction
	local key = handshake:InvokeServer()
	assert(typeof(key) == "number", "[NetService] server returned an invalid session key")
	clientSessionKey = key
	return key
end

-- Server: route remote violations to `handler` as (player, reason, severity,
-- "client"). Rate limits, malformed / oversized / replayed requests, busy
-- endpoints and failed context checks are "soft"; argument validators use
-- opts.validationSeverity (default "soft"). The AntiCheat orchestrator installs
-- this in its Init.
function Net.SetViolationHandler(handler: ViolationHandler?): ()
	assert(IS_SERVER, "Net.SetViolationHandler is server-only")
	violationHandler = handler
end

-- ── Server API ──

local function bindServerEvent(
	name: string,
	handler: (player: Player, ...any) -> (),
	opts: RemoteOpts?,
	state: RegistrationState,
	label: string
): RemoteEvent
	local re = getOrCreate("RemoteEvent", name) :: RemoteEvent
	state.connection = re.OnServerEvent:Connect(function(player: Player, envelope: any)
		if not state.active then
			return
		end
		recordReceived(name)
		local args = validateInbound(player, name, state.scope, envelope, opts)
		if not args then
			return
		end
		if not tryAcquire(player, state.scope, name, opts) then
			rejectInbound(player, name, "Busy", NetProtocol.Code.BUSY)
			return
		end
		recordAccepted(name)
		local startedAt = os.clock()
		local ok, err = xpcall(function()
			handler(player, table.unpack(args, 1, (args :: any).n))
		end, handlerTraceback)
		release(player, state.scope, name)
		recordHandlerResult(name, os.clock() - startedAt, ok)
		if not ok then
			reportHandlerError(err, `error in the {label}('{name}') handler`)
		end
	end)
	return re
end

local function bindServerInvoke(
	name: string,
	handler: (player: Player, ...any) -> ...any,
	opts: RemoteOpts?,
	state: RegistrationState,
	label: string
): RemoteFunction
	local rf = getOrCreate("RemoteFunction", name) :: RemoteFunction
	state.remoteFunction = rf
	local clientGot = if opts and opts.reject then "an INTERNAL error" else "nil"
	rf.OnServerInvoke = function(player: Player, envelope: any)
		local key = getServerSessionKey(player)
		if not state.active then
			return encodeReject(key, name, opts, NetProtocol.Code.FORBIDDEN)
		end
		recordReceived(name)
		local args, rejection = validateInbound(player, name, state.scope, envelope, opts)
		if not args then
			return encodeReject(key, name, opts, rejection or NetProtocol.Code.MALFORMED)
		end
		if not tryAcquire(player, state.scope, name, opts) then
			rejectInbound(player, name, "Busy", NetProtocol.Code.BUSY)
			return encodeReject(key, name, opts, NetProtocol.Code.BUSY)
		end
		recordAccepted(name)
		local startedAt = os.clock()
		local results = table.pack(xpcall(function()
			return handler(player, table.unpack(args, 1, (args :: any).n))
		end, handlerTraceback))
		release(player, state.scope, name)
		recordHandlerResult(name, os.clock() - startedAt, results[1])
		if not results[1] then
			-- Red in Output (this request still answers), instead of an error
			-- re-raised inside the client's InvokeServer.
			reportHandlerError(results[2], `error in the {label}('{name}') handler; the client got {clientGot}`)
			return encodeReject(key, name, opts, NetProtocol.Code.INTERNAL)
		end
		local encodedOk, encoded = xpcall(function()
			return encodeArguments(key, name, table.pack(table.unpack(results, 2, results.n)))
		end, debug.traceback)
		if not encodedOk then
			warn(`[NetService] response for '{name}' could not be encoded: {tostring(encoded)}`)
			return encodeReject(key, name, opts, NetProtocol.Code.INTERNAL)
		end
		return encoded
	end
	return rf
end

-- Server: run `handler` for each client FireServer of `name` (rate-limited, validated). Register once per name: a second registration warns and both handlers run. A handler error is red in Output (remote name + traceback).
function Net.OnServer(name: string, handler: (player: Player, ...any) -> (), opts: RemoteOpts?): RemoteEvent
	assert(IS_SERVER, "Net.OnServer is server-only")
	assert(typeof(handler) == "function", "Net.OnServer requires a handler")
	local state = claimRegistration(name, "event", "legacy")
	return bindWithRollback(name, state, function()
		return bindServerEvent(name, handler, opts, state, "Net.OnServer")
	end) :: RemoteEvent
end

-- Server: answer client InvokeServer calls of `name`. If `handler` errors, the error (remote name + traceback) is reported in Output and the client gets nil. A second registration warns and replaces the first.
function Net.OnInvoke(name: string, handler: (player: Player, ...any) -> ...any, opts: RemoteOpts?): RemoteFunction
	assert(IS_SERVER, "Net.OnInvoke is server-only")
	assert(typeof(handler) == "function", "Net.OnInvoke requires a handler")
	local state = claimRegistration(name, "function", "legacy")
	return bindWithRollback(name, state, function()
		return bindServerInvoke(name, handler, opts, state, "Net.OnInvoke")
	end) :: RemoteFunction
end

-- Server: create RemoteEvent `name` without a server handler, for events only the server fires (FireClient / FireAllClients). Clients can then Net.OnClient it at once. Client FireServer calls are drained (rate-limited by `opts`) so they never queue up. A later Net.OnServer for the same name takes over.
function Net.DeclareEvent(name: string, opts: RemoteOpts?): RemoteEvent
	assert(IS_SERVER, "Net.DeclareEvent is server-only")
	local re = getOrCreate("RemoteEvent", name) :: RemoteEvent
	if registrations[name] == nil and not drains[name] then
		local scope = newScope()
		drains[name] = {
			scope = scope,
			connection = re.OnServerEvent:Connect(function(player: Player)
				local consumed, category = consume(player, scope, opts)
				if not consumed then
					reportViolation(player, `Remote{category or "Rate"}:{name}`, "soft")
				end
			end),
		}
	end
	return re
end

-- Server: fire `name` to one client.
function Net.FireClient(player: Player, name: string, ...: any): ()
	assert(IS_SERVER, "Net.FireClient is server-only")
	local re = getOrCreate("RemoteEvent", name) :: RemoteEvent
	re:FireClient(player, encodeArguments(getServerSessionKey(player), name, table.pack(...)))
end

-- Server: fire `name` to every client (each gets its own session-keyed envelope).
function Net.FireAllClients(name: string, ...: any): ()
	assert(IS_SERVER, "Net.FireAllClients is server-only")
	local re = getOrCreate("RemoteEvent", name) :: RemoteEvent
	local args = table.pack(...)
	for _, player in ipairs(Players:GetPlayers()) do
		re:FireClient(player, encodeArguments(getServerSessionKey(player), name, args))
	end
end

-- Server: fire `name` to every client except `exceptPlayer`.
function Net.FireOtherClients(exceptPlayer: Player, name: string, ...: any): ()
	assert(IS_SERVER, "Net.FireOtherClients is server-only")
	local re = getOrCreate("RemoteEvent", name) :: RemoteEvent
	local args = table.pack(...)
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= exceptPlayer then
			re:FireClient(p, encodeArguments(getServerSessionKey(p), name, args))
		end
	end
end

-- Server: per-RPC counters (received, accepted, rejected by code, in-flight,
-- handler errors, idempotent hits, handler time). No request payloads are kept.
-- With `name`, that RPC's counters ({} if none); without, a map of every RPC.
function Net.Server.GetMetrics(name: string?): { [string]: any }
	assert(IS_SERVER, "Net.Server.GetMetrics is server-only")
	local function copy(metrics: RpcMetrics): { [string]: any }
		return {
			received = metrics.received,
			accepted = metrics.accepted,
			rejected = metrics.rejected,
			inFlight = metrics.inFlight,
			handlerErrors = metrics.handlerErrors,
			idempotentHits = metrics.idempotentHits,
			totalHandlerSeconds = metrics.totalHandlerSeconds,
			maxHandlerSeconds = metrics.maxHandlerSeconds,
			reasons = table.clone(metrics.reasons),
		}
	end
	if name then
		local metrics = metricsByName[name]
		return if metrics then copy(metrics) else {}
	end
	local result: { [string]: any } = {}
	for rpcName, metrics in pairs(metricsByName) do
		result[rpcName] = copy(metrics)
	end
	return result
end

-- ── Client API ──

-- Client: run `handler` for each server FireClient / FireAllClients of `name`. Waits (yields) until the server has created the remote; after 5 s it warns once, naming the remote.
function Net.OnClient(name: string, handler: (...any) -> ()): RemoteEvent
	assert(not IS_SERVER, "Net.OnClient is client-only")
	local re = waitForClientRemote("RemoteEvent", name, "Net.OnClient") :: RemoteEvent
	local key = getClientSessionKey()
	re.OnClientEvent:Connect(function(envelope: any)
		local decoded, args = decodeArguments(key, name, envelope)
		if decoded and args then
			handler(table.unpack(args, 1, (args :: any).n))
		else
			warn(`[NetService] Dropped malformed server payload for '{name}'`)
		end
	end)
	return re
end

-- Client: fire `name` to the server's Net.OnServer handler.
function Net.FireServer(name: string, ...: any): ()
	assert(not IS_SERVER, "Net.FireServer is client-only")
	local re = getOrCreate("RemoteEvent", name) :: RemoteEvent
	re:FireServer(encodeArguments(getClientSessionKey(), name, table.pack(...)))
end

-- Returns whatever the server's OnInvoke handler returned (all values); nil when the server rejected the request or its handler errored.
function Net.InvokeServer(name: string, ...: any): ...any
	assert(not IS_SERVER, "Net.InvokeServer is client-only")
	local rf = getOrCreate("RemoteFunction", name) :: RemoteFunction
	local key = getClientSessionKey()
	local envelope = rf:InvokeServer(encodeArguments(key, name, table.pack(...)))
	local decoded, args = decodeArguments(key, name, envelope)
	if not decoded or not args then
		error(`[NetService] Server returned a malformed payload for '{name}'`)
	end
	return table.unpack(args, 1, (args :: any).n)
end

-- ── Definition-based API ──
-- New endpoints use this API so service modules never own a Remote connection
-- or receive a raw Remote Instance. The legacy API above stays for existing
-- games. A name registered here cannot also be registered with the legacy API.

-- Server: register client → server event `name`. The payload must pass
-- `definition.schema`, then `definition.validate` (if any), before `handler`
-- runs. Errors on a duplicate name, a missing schema/handler, or a mutation
-- endpoint without `validate` / with `concurrency ~= 1`.
function Net.Server.RegisterEvent(name: string, definition: RpcDefinition): RegistrationHandle
	assert(IS_SERVER, "Net.Server.RegisterEvent is server-only")
	local state = assertDefinition(name, definition, "event")
	bindWithRollback(name, state, function()
		return bindServerEvent(name, function(player: Player, request: any)
			if not state.active then
				return
			end
			local payload = request.payload
			-- A player must still be connected after decode before any cache or
			-- handler side effect is considered.
			if player.Parent ~= Players then
				return
			end
			if definition.mutation then
				local cache = requestCacheFor(player, state.scope)
				if NetProtocol.GetCached(cache, request.requestId) ~= nil then
					metricsFor(name).idempotentHits += 1
					return
				end
			end
			local allowed, context = contextIsAllowed(definition, player, name, payload)
			if not allowed or not state.active or player.Parent ~= Players then
				return
			end
			if definition.mutation then
				local cache = requestCacheFor(player, state.scope)
				definition.handler(context, payload)
				NetProtocol.PutCached(cache, request.requestId, true)
				return
			end
			definition.handler(context, payload)
		end, definitionOpts(definition), state, "Net.Server.RegisterEvent")
	end)
	return registrationHandle(name, state)
end

-- Server: register client → server function `name`. The client's
-- Net.Client.Invoke gets `{ ok = true, data = handler(...) }`, or
-- `{ ok = false, code = ... }` when a gate rejects or the handler errors.
function Net.Server.RegisterFunction(name: string, definition: RpcDefinition): RegistrationHandle
	assert(IS_SERVER, "Net.Server.RegisterFunction is server-only")
	local state = assertDefinition(name, definition, "function")
	bindWithRollback(name, state, function()
		return bindServerInvoke(name, function(player: Player, request: any): any
			if not state.active then
				return { ok = false, code = NetProtocol.Code.FORBIDDEN }
			end
			local payload = request.payload
			if player.Parent ~= Players then
				return { ok = false, code = NetProtocol.Code.FORBIDDEN }
			end
			local cache = if definition.mutation then requestCacheFor(player, state.scope) else nil
			if cache then
				local cached = NetProtocol.GetCached(cache, request.requestId)
				if cached ~= nil then
					metricsFor(name).idempotentHits += 1
					return cached
				end
			end
			local allowed, context = contextIsAllowed(definition, player, name, payload)
			if not allowed or not state.active or player.Parent ~= Players then
				return { ok = false, code = NetProtocol.Code.FORBIDDEN }
			end
			local response = { ok = true, data = definition.handler(context, payload) }
			if cache then
				NetProtocol.PutCached(cache, request.requestId, response)
			end
			return response
		end, definitionOpts(definition), state, "Net.Server.RegisterFunction")
	end)
	return registrationHandle(name, state)
end

-- Client: fire definition-API event `name` with one payload table. Pass the
-- same `requestId` to retry a mutation without running it twice.
function Net.Client.Fire(name: string, payload: any, requestId: string?): ()
	assert(not IS_SERVER, "Net.Client.Fire is client-only")
	local id = requestId or HttpService:GenerateGUID(false)
	assert(NetProtocol.IsValidRequestId(id), "Net.Client.Fire received an invalid request id")
	Net.FireServer(name, { requestId = id, payload = payload })
end

-- Client: invoke definition-API function `name`. Returns `{ ok = true, data = ... }`
-- or `{ ok = false, code = ... }` (never errors on a server rejection).
function Net.Client.Invoke(name: string, payload: any, requestId: string?): RpcResult
	assert(not IS_SERVER, "Net.Client.Invoke is client-only")
	local id = requestId or HttpService:GenerateGUID(false)
	assert(NetProtocol.IsValidRequestId(id), "Net.Client.Invoke received an invalid request id")
	local result = Net.InvokeServer(name, { requestId = id, payload = payload })
	if typeof(result) ~= "table" or typeof(result.ok) ~= "boolean" then
		return { ok = false, code = NetProtocol.Code.INTERNAL }
	end
	return result
end

return Net
