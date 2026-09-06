--!strict
--[[
	Module : NetService
	Location: ReplicatedStorage/Gaxia_Packages/Shared/NetService
	Purpose : Centralised RemoteEvent/RemoteFunction wrapper. Auto-creates
	          remotes under ReplicatedStorage.Events.Net and owns their inbound
	          connections. The server applies global + per-RPC rate gates before
	          decode, replay blocking, bounded structural validation, optional
	          schema validators and per-RPC concurrency before gameplay handlers.
	          Transport obfuscation is only a deterrent, never authentication.

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

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

-- WHY the extra Studio clause: in Edit mode via tooling (plugin runners, MCP
-- tests) IsServer()/IsClient() are BOTH false — the module would take the
-- client path, stall on WaitForChild("Events"), and assert. Edit mode has no
-- real client, so server semantics are the correct default there. Play mode
-- and live servers are unaffected (IsRunning() gates the clause off).
local IS_SERVER: boolean = RunService:IsServer()
	or (RunService:IsStudio() and not RunService:IsRunning())

-- Sibling module: Constants (always present in Shared/).
local Constants: any = require(script.Parent:WaitForChild("Constants"))
local RemoteObfuscator = require(script.Parent:WaitForChild("RemoteObfuscator"))
local NetProtocol = require(script.Parent:WaitForChild("NetProtocol"))

local DEFAULT_RATE: number = (Constants.REMOTE_RATE_LIMIT_DEFAULT :: any) or 10
local DEFAULT_BURST: number = (Constants.REMOTE_RATE_BURST :: any) or 20
local GLOBAL_RATE: number = (Constants.REMOTE_GLOBAL_RATE_LIMIT_DEFAULT :: any) or 60
local GLOBAL_BURST: number = (Constants.REMOTE_GLOBAL_RATE_BURST :: any) or 100
local DEFAULT_CONCURRENCY: number = (Constants.REMOTE_CONCURRENCY_DEFAULT :: any) or 4
local HANDSHAKE_NAME = "_gxk"
local MAX_ARGUMENTS = 64

-- ── Types ──

export type RemoteOpts = {
	rate: number?, -- requests per second (token refill rate)
	burst: number?, -- bucket capacity (max queue before throttle)
	budget: string?, -- NetProtocol profile: tiny | small | medium
	concurrency: number?, -- max in-flight handlers per player/RPC
	-- Optional stable rejection response for the definition-based API. Legacy
	-- callers keep receiving nil on rejection for backwards compatibility.
	reject: ((code: string) -> ...any)?,
	-- Internal cardinality gate used by the definition API. Legacy callers may
	-- continue to send any packed positional argument count.
	argumentCount: number?,
	-- One predicate per positional arg; a falsy first return records client
	-- telemetry and drops the request. Gaxia.Guard checks plug in directly —
	-- they return (ok, err) and Net
	-- only reads the truthy `ok`. For a single table payload validate its SHAPE:
	--   { validators = { Guard.strictInterface({ id = Guard.string, qty = Guard.integer }) } }
	validators: { (any) -> boolean }?,
}

export type RpcContext = {
	player: Player,
	name: string,
}

export type RpcDefinition = {
	schema: (payload: any) -> boolean,
	handler: (context: RpcContext, payload: any) -> any,
	validate: ((context: RpcContext, payload: any) -> boolean)?,
	mutation: boolean?,
	rate: number?,
	burst: number?,
	budget: string?,
	concurrency: number?,
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

-- Server creates Events/Net lazily; clients wait for replication.
local netFolder: Folder
do
	local events: Instance?
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

-- ── AntiCheat lazy reference ──
-- Direct path require so we don't form a recursion cycle with GaxiaServer's
-- __index lazy-load when called from inside AntiCheat init's load chain.
local _antiCheatRef: any = nil
local function getAntiCheat(): any
	if not IS_SERVER then
		return nil
	end
	if _antiCheatRef ~= nil then
		return _antiCheatRef
	end
	local pkg = ServerStorage:FindFirstChild("Gaxia_Packages_Server")
	if not pkg then
		return nil
	end
	local acInit = pkg:FindFirstChild("AntiCheat")
	if acInit and acInit:IsA("ModuleScript") then
		local ok, mod = pcall(require, acInit)
		if ok then
			_antiCheatRef = mod
		end
	end
	return _antiCheatRef
end

-- ── Internal helpers ──

local function consume(
	player: Player,
	scope: RegistrationScope,
	opts: RemoteOpts?
): (boolean, string?)
	local global = globalBuckets[player]
	if not global then
		global = { tokens = GLOBAL_BURST, lastClock = os.clock() }
		globalBuckets[player] = global
	end
	if not consumeBucket(global, GLOBAL_RATE, GLOBAL_BURST) then
		return false, "GLOBAL_RATE"
	end

	local rate = (opts and opts.rate) or DEFAULT_RATE
	local burst = (opts and opts.burst) or DEFAULT_BURST
	local b = getBucket(player, scope, burst)
	if consumeBucket(b, rate, burst) then
		return true, nil
	end
	return false, "RPC_RATE"
end

local function validateArgs(validators: { (any) -> boolean }?, args: { any }): boolean
	if not validators then
		return true
	end
	for i, predicate in ipairs(validators) do
		-- Endpoint schemas consume hostile input. A predicate error is a reject,
		-- not an exception that escapes Roblox's remote callback.
		local ok, valid = pcall(predicate, args[i])
		if not ok or not valid then
			return false
		end
	end
	return true
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

local function flagRejected(player: Player, name: string, category: string)
	local ac = getAntiCheat()
	if ac then
		-- A malformed or over-rate request is client-controlled input. It may be
		-- useful telemetry, but it is never enough to punish a player by itself.
		ac.Flag(player, `Remote{category}:{name}`, "soft", "client")
	end
end

local function deriveTransportKey(sessionKey: number, name: string): number
	local hash = 5381
	for index = 1, #name do
		hash = bit32.band(hash * 33 + string.byte(name, index), 0xFFFFFFFF)
	end
	local derived = bit32.bxor(sessionKey, hash)
	return if derived == 0 then 0xA341316C else derived
end

local function decodeArguments(
	key: number,
	name: string,
	envelope: any,
	budgetName: string?
): (boolean, { any }?)
	-- Server-side inbound requests are decoded against the endpoint's eventual
	-- payload budget before strings or tables are rebuilt. Client-side decoding
	-- accepts trusted server responses under RemoteObfuscator's global bounds so
	-- a valid read response is not accidentally constrained by the C2S budget.
	local limits = if IS_SERVER then NetProtocol.GetBudget(budgetName) else nil
	local ok, decoded =
		pcall(RemoteObfuscator.Decode, deriveTransportKey(key, name), envelope, limits)
	if not ok or typeof(decoded) ~= "table" then
		return false, nil
	end
	local count = decoded.n
	if typeof(count) ~= "number" or count % 1 ~= 0 or count < 0 or count > MAX_ARGUMENTS then
		return false, nil
	end
	for argumentKey in pairs(decoded) do
		if argumentKey ~= "n" then
			if
				typeof(argumentKey) ~= "number"
				or argumentKey % 1 ~= 0
				or argumentKey < 1
				or argumentKey > count
			then
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

local function tryAcquire(
	player: Player,
	scope: RegistrationScope,
	name: string,
	opts: RemoteOpts?
): boolean
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

local function validateInbound(
	player: Player,
	name: string,
	scope: RegistrationScope,
	envelope: any,
	opts: RemoteOpts?
): ({ any }?, string?)
	local consumed, rateReason = consume(player, scope, opts)
	if not consumed then
		flagRejected(player, name, rateReason or "Rate")
		recordRejected(name, rateReason or NetProtocol.Code.RATE_LIMITED)
		return nil, NetProtocol.Code.RATE_LIMITED
	end
	local decoded, args =
		decodeArguments(getServerSessionKey(player), name, envelope, opts and opts.budget)
	if not decoded or not args then
		flagRejected(player, name, "Malformed")
		recordRejected(name, NetProtocol.Code.MALFORMED)
		return nil, "MALFORMED"
	end
	local structurallyValid, structureCode = NetProtocol.ValidatePayload(args, opts and opts.budget)
	if not structurallyValid then
		flagRejected(player, name, structureCode or "Budget")
		recordRejected(name, structureCode or NetProtocol.Code.BUDGET)
		return nil, structureCode
	end
	if opts and opts.argumentCount ~= nil and (args :: any).n ~= opts.argumentCount then
		flagRejected(player, name, "ArgumentCount")
		recordRejected(name, NetProtocol.Code.SCHEMA)
		return nil, NetProtocol.Code.SCHEMA
	end
	if not validateArgs(opts and opts.validators, args) then
		flagRejected(player, name, "Validation")
		recordRejected(name, NetProtocol.Code.SCHEMA)
		return nil, "SCHEMA"
	end
	-- Only a fully decoded, structurally valid and schema-valid request may
	-- consume replay state. Otherwise forged malformed envelopes could evict a
	-- player's valid nonce window without ever being eligible for a handler.
	if not acceptNonce(player, scope, envelope) then
		flagRejected(player, name, "Replay")
		recordRejected(name, NetProtocol.Code.REPLAY)
		return nil, "REPLAY"
	end
	return args, nil
end

local function wireName(name: string): string
	assert(#name > 0, "[NetService] remote name cannot be empty")
	local hash = 5381
	for index = 1, #name do
		hash = bit32.band(hash * 33 + string.byte(name, index), 0xFFFFFFFF)
	end
	local encoded = string.format("r%08x", hash)
	if IS_SERVER then
		local owner = wireNameOwners[encoded]
		assert(
			not owner or owner == name,
			`[NetService] remote name hash collision: '{owner}' and '{name}'`
		)
		wireNameOwners[encoded] = name
	end
	return encoded
end

-- Get-or-create remote of the requested class under Net folder. On the client
-- this waits up to 10s for replication; on the server it creates immediately.
local function getOrCreate(className: string, name: string): Instance
	if name == HANDSHAKE_NAME then
		assert(
			className == "RemoteFunction",
			`[NetService] RPC '{HANDSHAKE_NAME}' is reserved for the session handshake`
		)
	end
	local instanceName = if name == HANDSHAKE_NAME then name else wireName(name)
	local existing = netFolder:FindFirstChild(instanceName)
	if existing then
		assert(
			existing.ClassName == className,
			`[NetService] RPC '{name}' is already a {existing.ClassName}; changing remote kind is not supported`
		)
		return existing
	end
	if IS_SERVER then
		local inst = Instance.new(className)
		inst.Name = instanceName
		inst.Parent = netFolder
		return inst
	end
	local waited = netFolder:WaitForChild(instanceName, 10)
	if not waited then
		error(`[NetService] Remote '{name}' not registered by server`)
	end
	return waited
end

-- ── Module ──

local Net = {}

Net.Server = {}
Net.Client = {}

type RegistrationState = {
	kind: "event" | "function",
	api: "legacy" | "definition",
	active: boolean,
	scope: RegistrationScope,
	connection: RBXScriptConnection?,
	remoteFunction: RemoteFunction?,
}

local registrations: { [string]: RegistrationState } = {}
local nextRegistrationScope: RegistrationScope = 0

local function isPositiveFinite(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value > 0
end

local function claimRegistration(
	name: string,
	kind: "event" | "function",
	api: "legacy" | "definition"
): RegistrationState
	assert(name ~= HANDSHAKE_NAME, `[NetService] RPC '{HANDSHAKE_NAME}' is reserved`)
	assert(not registrations[name], `[NetService] RPC '{name}' is already registered`)
	nextRegistrationScope += 1
	local state: RegistrationState = {
		kind = kind,
		api = api,
		active = true,
		scope = nextRegistrationScope,
		connection = nil,
		remoteFunction = nil,
	}
	registrations[name] = state
	return state
end

local function assertLegacyDefinition(name: string, kind: "event" | "function"): RegistrationState
	assert(typeof(name) == "string" and #name > 0, "RPC name must be a non-empty string")
	return claimRegistration(name, kind, "legacy")
end

local function assertDefinition(
	name: string,
	definition: RpcDefinition,
	kind: "event" | "function"
): RegistrationState
	assert(typeof(name) == "string" and #name > 0, "RPC name must be a non-empty string")
	assert(typeof(definition) == "table", "RPC definition must be a table")
	assert(typeof(definition.schema) == "function", `[NetService] RPC '{name}' requires schema`)
	assert(typeof(definition.handler) == "function", `[NetService] RPC '{name}' requires handler`)
	if definition.mutation then
		assert(
			typeof(definition.validate) == "function",
			`[NetService] mutation RPC '{name}' requires context validation`
		)
		assert(
			definition.concurrency == 1,
			`[NetService] mutation RPC '{name}' must use concurrency = 1`
		)
	end
	assert(
		NetProtocol.IsBudgetName(definition.budget or "small"),
		`[NetService] RPC '{name}' uses an unknown budget profile`
	)
	if definition.rate ~= nil then
		assert(
			isPositiveFinite(definition.rate),
			`[NetService] RPC '{name}' rate must be positive and finite`
		)
	end
	if definition.burst ~= nil then
		assert(
			isPositiveFinite(definition.burst),
			`[NetService] RPC '{name}' burst must be positive and finite`
		)
	end
	if definition.concurrency ~= nil then
		assert(
			isPositiveFinite(definition.concurrency) and definition.concurrency % 1 == 0,
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

local function contextIsAllowed(
	definition: RpcDefinition,
	player: Player,
	name: string,
	payload: any
): (boolean, RpcContext)
	local context: RpcContext = { player = player, name = name }
	if not definition.validate then
		return true, context
	end
	local ok, allowed = xpcall(function()
		return definition.validate(context, payload)
	end, debug.traceback)
	if ok and allowed == true then
		return true, context
	end
	if not ok then
		warn(`[NetService] context validator for '{name}' errored: {tostring(allowed)}`)
	end
	flagRejected(player, name, "Forbidden")
	recordRejected(name, NetProtocol.Code.FORBIDDEN)
	return false, context
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
	if state.remoteFunction then
		state.remoteFunction.OnServerInvoke = nil
		state.remoteFunction = nil
	end
	clearRegistrationState(state.scope)
	if registrations[name] == state then
		registrations[name] = nil
	end
end

local function bindWithRollback(
	name: string,
	state: RegistrationState,
	binder: () -> Instance
): Instance
	local ok, result = xpcall(binder, debug.traceback)
	if ok then
		return result
	end
	deactivateRegistration(name, state)
	error(result, 0)
end

local function registrationHandle(name: string, state: RegistrationState): any
	local handle = {}
	function handle:Destroy()
		deactivateRegistration(name, state)
	end
	function handle:IsActive(): boolean
		return state.active
	end
	return handle
end

-- The key only deters basic inspection. Because it is delivered to client code,
-- it must never be treated as authentication or replace server validation.
if IS_SERVER then
	local existing = netFolder:FindFirstChild(HANDSHAKE_NAME)
	assert(not existing or existing:IsA("RemoteFunction"), "[NetService] handshake name collision")
	local handshake = (existing or Instance.new("RemoteFunction")) :: RemoteFunction
	handshake.Name = HANDSHAKE_NAME
	handshake.OnServerInvoke = function(player: Player): number
		return getServerSessionKey(player)
	end
	handshake.Parent = netFolder
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

local function getClientSessionKey(): number
	if clientSessionKey then
		return clientSessionKey
	end
	local handshake = getOrCreate("RemoteFunction", HANDSHAKE_NAME) :: RemoteFunction
	local key = handshake:InvokeServer()
	assert(typeof(key) == "number", "[NetService] server returned an invalid session key")
	clientSessionKey = key
	return key
end

-- ── Server API ──

local function bindServerEvent(
	name: string,
	handler: (player: Player, ...any) -> (),
	opts: RemoteOpts?,
	state: RegistrationState
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
			flagRejected(player, name, "Busy")
			recordRejected(name, NetProtocol.Code.BUSY)
			return
		end
		recordAccepted(name)
		local startedAt = os.clock()
		local ok, err = xpcall(function()
			handler(player, table.unpack(args, 1, (args :: any).n))
		end, debug.traceback)
		release(player, state.scope, name)
		recordHandlerResult(name, os.clock() - startedAt, ok)
		if not ok then
			warn(`[NetService] handler for '{name}' errored: {tostring(err)}`)
		end
	end)
	return re
end

local function bindServerInvoke(
	name: string,
	handler: (player: Player, ...any) -> ...any,
	opts: RemoteOpts?,
	state: RegistrationState
): RemoteFunction
	local rf = getOrCreate("RemoteFunction", name) :: RemoteFunction
	state.remoteFunction = rf
	rf.OnServerInvoke = function(player: Player, envelope: any)
		if not state.active then
			return encodeReject(getServerSessionKey(player), name, opts, NetProtocol.Code.FORBIDDEN)
		end
		recordReceived(name)
		local key = getServerSessionKey(player)
		local args, rejection = validateInbound(player, name, state.scope, envelope, opts)
		if not args then
			return encodeReject(key, name, opts, rejection or NetProtocol.Code.MALFORMED)
		end
		if not tryAcquire(player, state.scope, name, opts) then
			flagRejected(player, name, "Busy")
			recordRejected(name, NetProtocol.Code.BUSY)
			return encodeReject(key, name, opts, NetProtocol.Code.BUSY)
		end
		recordAccepted(name)
		local startedAt = os.clock()
		local results = table.pack(xpcall(function()
			return handler(player, table.unpack(args, 1, (args :: any).n))
		end, debug.traceback))
		release(player, state.scope, name)
		recordHandlerResult(name, os.clock() - startedAt, results[1])
		if not results[1] then
			warn(`[NetService] handler for '{name}' errored: {tostring(results[2])}`)
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

function Net.OnServer(
	name: string,
	handler: (player: Player, ...any) -> (),
	opts: RemoteOpts?
): RemoteEvent
	assert(IS_SERVER, "Net.OnServer is server-only")
	assert(typeof(handler) == "function", "Net.OnServer requires a handler")
	local state = assertLegacyDefinition(name, "event")
	return bindWithRollback(name, state, function()
		return bindServerEvent(name, handler, opts, state)
	end) :: RemoteEvent
end

function Net.OnInvoke(
	name: string,
	handler: (player: Player, ...any) -> ...any,
	opts: RemoteOpts?
): RemoteFunction
	assert(IS_SERVER, "Net.OnInvoke is server-only")
	assert(typeof(handler) == "function", "Net.OnInvoke requires a handler")
	local state = assertLegacyDefinition(name, "function")
	return bindWithRollback(name, state, function()
		return bindServerInvoke(name, handler, opts, state)
	end) :: RemoteFunction
end

function Net.FireClient(player: Player, name: string, ...: any): ()
	assert(IS_SERVER, "Net.FireClient is server-only")
	local re = getOrCreate("RemoteEvent", name) :: RemoteEvent
	re:FireClient(player, encodeArguments(getServerSessionKey(player), name, table.pack(...)))
end

function Net.FireAllClients(name: string, ...: any): ()
	assert(IS_SERVER, "Net.FireAllClients is server-only")
	local re = getOrCreate("RemoteEvent", name) :: RemoteEvent
	local args = table.pack(...)
	for _, player in ipairs(Players:GetPlayers()) do
		re:FireClient(player, encodeArguments(getServerSessionKey(player), name, args))
	end
end

function Net.FireOtherClients(exceptPlayer: Player, name: string, ...: any): ()
	assert(IS_SERVER, "Net.FireOtherClients is server-only")
	local re = getOrCreate("RemoteEvent", name) :: RemoteEvent
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= exceptPlayer then
			re:FireClient(p, encodeArguments(getServerSessionKey(p), name, table.pack(...)))
		end
	end
end

-- ── Client API ──

function Net.OnClient(name: string, handler: (...any) -> ()): RemoteEvent
	assert(not IS_SERVER, "Net.OnClient is client-only")
	local re = getOrCreate("RemoteEvent", name) :: RemoteEvent
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

function Net.FireServer(name: string, ...: any): ()
	assert(not IS_SERVER, "Net.FireServer is client-only")
	local re = getOrCreate("RemoteEvent", name) :: RemoteEvent
	re:FireServer(encodeArguments(getClientSessionKey(), name, table.pack(...)))
end

function Net.InvokeServer(name: string, ...: any): any
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
-- or receive a raw Remote Instance. The legacy API above remains for existing
-- consumers while they migrate one endpoint at a time.

function Net.Server.RegisterEvent(name: string, definition: RpcDefinition): any
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
		end, definitionOpts(definition), state)
	end)
	return registrationHandle(name, state)
end

function Net.Server.RegisterFunction(name: string, definition: RpcDefinition): any
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
		end, definitionOpts(definition), state)
	end)
	return registrationHandle(name, state)
end

function Net.Client.Fire(name: string, payload: any, requestId: string?): ()
	assert(not IS_SERVER, "Net.Client.Fire is client-only")
	local id = requestId or HttpService:GenerateGUID(false)
	assert(NetProtocol.IsValidRequestId(id), "Net.Client.Fire received an invalid request id")
	Net.FireServer(name, { requestId = id, payload = payload })
end

function Net.Client.Invoke(name: string, payload: any, requestId: string?): { [string]: any }
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
