local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local function expect(condition: boolean, message: string)
	if not condition then
		error(message, 2)
	end
end

local function containsValue(root: any, expected: any): boolean
	if root == expected then
		return true
	end
	if typeof(root) == "table" then
		for key, value in pairs(root) do
			if containsValue(key, expected) or containsValue(value, expected) then
				return true
			end
		end
	end
	return false
end

local function expectChild(parent: Instance, name: string, className: string): Instance
	local child = parent:FindFirstChild(name)
	expect(
		child ~= nil and child:IsA(className),
		`{parent:GetFullName()}.{name} must be a {className}`
	)
	return child :: Instance
end

local function requireChild(parent: Instance, name: string): any
	return require(expectChild(parent, name, "ModuleScript") :: ModuleScript)
end

local function run()
	-- The runner builds tests/oss_dependencies.project.json, which deliberately
	-- contains no game bootstraps. RunScript ends its command-bar task when that
	-- task yields, so every prerequisite below is a non-yielding lookup with an
	-- explicit failure. Some packages schedule their own background work; this
	-- smoke neither waits for nor claims to verify that asynchronous behavior.
	local root = expectChild(ReplicatedStorage, "Gaxia_Packages", "ModuleScript")
	local shared = expectChild(root, "Shared", "Folder")
	local packages = expectChild(root, "Packages", "Folder")
	local serverRoot = expectChild(ServerStorage, "Gaxia_Packages_Server", "ModuleScript")
	local serverPackages = expectChild(serverRoot, "ServerPackages", "Folder")
	local serverLib = expectChild(serverRoot, "Lib", "Folder")
	local Net = requireChild(shared, "NetService")
	local Promise = requireChild(shared, "Promise")
	local RemoteObfuscator = requireChild(shared, "RemoteObfuscator")
	local NetProtocol = requireChild(shared, "NetProtocol")
	local PackagePromise = requireChild(packages, "Promise")
	local PackageComponent = requireChild(packages, "Component")
	local PackageObservers = requireChild(packages, "Observers")
	local ZonePlusModule = expectChild(packages, "ZonePlus", "ModuleScript")
	local PackageSymbol = requireChild(packages, "Symbol")
	local PackageSpring = requireChild(packages, "Spring")
	local PackageTableUtil = requireChild(packages, "TableUtil")
	local PackageT = requireChild(packages, "T")
	local Janitor = requireChild(shared, "Janitor")
	local Gaxia = require(root :: ModuleScript)
	local AntiCheat = requireChild(serverRoot, "AntiCheat")
	local Enforcement = requireChild(serverLib, "AntiCheatEnforcement")
	local MockPlayer = requireChild(shared, "MockPlayer")

	-- The RunScript CLI terminates as soon as its command-bar script yields, so
	-- this smoke deliberately covers only synchronous loading and pure behavior.
	-- Signal delivery, ProfileStore sessions, and scheduled work must be covered
	-- by a normal multi-client Studio integration playtest.
	local mockPlayer = MockPlayer.new({ name = "AntiCheatSmoke", userId = -1701 })
	local clientReason = "ClientReport:SmokeOnly"
	local unknownReason = "UnknownSource:SmokeOnly"
	local mixedReason = "ClientAndServer:SmokeOnly"
	local mixedSeverityReason = "MixedSeverity:SmokeOnly"
	local serverReason = "ServerSmoke"
	for _ = 1, 10 do
		AntiCheat.Flag(mockPlayer, clientReason, "hard", "client")
	end
	expect(
		AntiCheat.GetFlagCount(mockPlayer, clientReason) == 10,
		"AntiCheat did not journal client telemetry"
	)
	for _ = 1, 10 do
		AntiCheat.Flag(mockPlayer, unknownReason, "hard")
	end
	expect(
		AntiCheat.GetFlagCount(mockPlayer, unknownReason) == 10,
		"AntiCheat did not journal missing-provenance telemetry"
	)
	for _ = 1, 4 do
		AntiCheat.Flag(mockPlayer, mixedReason, "hard", "client")
	end
	AntiCheat.Flag(mockPlayer, mixedReason, "hard", "server")
	expect(
		AntiCheat.GetFlagCount(mockPlayer, mixedReason) == 5,
		"AntiCheat did not journal mixed-source telemetry"
	)
	for _ = 1, 4 do
		AntiCheat.Flag(mockPlayer, mixedReason, "hard", "server")
	end
	expect(
		AntiCheat.GetFlagCount(mockPlayer, mixedReason) == 9,
		"AntiCheat did not retain trusted evidence"
	)
	for _ = 1, 4 do
		AntiCheat.Flag(mockPlayer, mixedSeverityReason, "soft", "server")
	end
	AntiCheat.Flag(mockPlayer, mixedSeverityReason, "hard", "server")
	expect(
		AntiCheat.GetFlagCount(mockPlayer, mixedSeverityReason) == 5,
		"AntiCheat did not journal mixed-severity trusted evidence"
	)
	for _ = 1, 4 do
		AntiCheat.Flag(mockPlayer, mixedSeverityReason, "hard", "server")
	end
	expect(
		AntiCheat.GetFlagCount(mockPlayer, mixedSeverityReason) == 9,
		"AntiCheat did not retain hard trusted evidence"
	)
	AntiCheat.Flag(mockPlayer, serverReason, "hard", "server")
	expect(
		AntiCheat.GetFlagCount(mockPlayer, serverReason) == 1,
		"AntiCheat did not journal trusted server evidence"
	)
	expect(Enforcement.GetMode() == "observe", "AntiCheat enforcement must start in observe mode")
	AntiCheat.ClearFlags(mockPlayer)

	local encodedPayload = RemoteObfuscator.Encode(
		1234567,
		table.pack("BuyEgg", {
			egg = "BasicEgg",
			quantity = 2,
			enabled = true,
		}, nil),
		7654321
	)
	expect(encodedPayload[3][1] == 4, "RemoteObfuscator did not encode the argument table")
	expect(
		not containsValue(encodedPayload, "BasicEgg"),
		"RemoteObfuscator exposed plaintext in the envelope"
	)
	local decodedPayload = RemoteObfuscator.Decode(1234567, encodedPayload)
	expect(decodedPayload.n == 3, "RemoteObfuscator lost packed nil arguments")
	expect(decodedPayload[1] == "BuyEgg", "RemoteObfuscator changed a string argument")
	expect(decodedPayload[2].egg == "BasicEgg", "RemoteObfuscator changed a table field")
	expect(decodedPayload[2].quantity == 2, "RemoteObfuscator changed a number field")
	expect(decodedPayload[2].enabled == true, "RemoteObfuscator changed a boolean field")
	expect(decodedPayload[3] == nil, "RemoteObfuscator changed a nil argument")
	local paddedEnvelope = table.clone(encodedPayload)
	paddedEnvelope[4] = "unexpected"
	expect(
		not pcall(RemoteObfuscator.Decode, 1234567, paddedEnvelope),
		"RemoteObfuscator accepted an envelope with unexpected fields"
	)
	local paddedNodeEnvelope = table.clone(encodedPayload)
	local paddedNode = table.clone(paddedNodeEnvelope[3])
	paddedNode[3] = "unexpected"
	paddedNodeEnvelope[3] = paddedNode
	expect(
		not pcall(RemoteObfuscator.Decode, 1234567, paddedNodeEnvelope),
		"RemoteObfuscator accepted an encoded node with unexpected fields"
	)
	local oversizedEncoded = RemoteObfuscator.Encode(7654321, string.rep("x", 129), 42)
	local boundedDecode =
		pcall(RemoteObfuscator.Decode, 7654321, oversizedEncoded, NetProtocol.GetBudget("tiny"))
	expect(not boundedDecode, "RemoteObfuscator decoded an oversized payload before NetProtocol")
	local aggregateEncoded = RemoteObfuscator.Encode(7654321, {
		string.rep("x", 128),
		string.rep("x", 128),
		string.rep("x", 128),
		string.rep("x", 128),
		string.rep("x", 128),
	}, 43)
	expect(
		not pcall(RemoteObfuscator.Decode, 7654321, aggregateEncoded, NetProtocol.GetBudget("tiny")),
		"RemoteObfuscator decoded strings exceeding the aggregate budget"
	)
	local tinyBuffer = RemoteObfuscator.Encode(7654321, buffer.create(1), 44)
	expect(
		not pcall(RemoteObfuscator.Decode, 7654321, tinyBuffer, NetProtocol.GetBudget("tiny")),
		"RemoteObfuscator decoded a buffer exceeding the endpoint budget"
	)

	local validPayload, validCode =
		NetProtocol.ValidatePayload({ egg = "BasicEgg", quantity = 2 }, "small")
	expect(validPayload and validCode == nil, "NetProtocol rejected a bounded payload")
	local invalidNumber, invalidNumberCode = NetProtocol.ValidatePayload(0 / 0, "small")
	expect(
		not invalidNumber and invalidNumberCode == NetProtocol.Code.INVALID_NUMBER,
		"NetProtocol accepted a non-finite number"
	)
	local oversizedString, oversizedStringCode =
		NetProtocol.ValidatePayload(string.rep("x", 129), "tiny")
	expect(
		not oversizedString and oversizedStringCode == NetProtocol.Code.BUDGET,
		"NetProtocol accepted an oversized string"
	)
	local cyclicPayload: { [string]: any } = {}
	cyclicPayload.self = cyclicPayload
	local cyclicOk, cyclicCode = NetProtocol.ValidatePayload(cyclicPayload, "small")
	expect(
		not cyclicOk and cyclicCode == NetProtocol.Code.MALFORMED,
		"NetProtocol accepted a cyclic table"
	)
	local unsupportedOk, unsupportedCode = NetProtocol.ValidatePayload(workspace, "small")
	expect(
		not unsupportedOk and unsupportedCode == NetProtocol.Code.UNSUPPORTED_TYPE,
		"NetProtocol accepted an Instance payload"
	)
	local replay = NetProtocol.NewReplayWindow(2)
	expect(NetProtocol.RememberNonce(replay, 10), "NetProtocol rejected a new nonce")
	expect(not NetProtocol.RememberNonce(replay, 10), "NetProtocol accepted a replayed nonce")
	expect(NetProtocol.RememberNonce(replay, 11), "NetProtocol rejected an out-of-order nonce")
	expect(NetProtocol.RememberNonce(replay, 12), "NetProtocol rejected a later nonce")
	expect(NetProtocol.RememberNonce(replay, 10), "NetProtocol did not evict an old replay nonce")
	local rotatingReplay = NetProtocol.NewReplayWindow(2)
	for nonce = 1, 512 do
		expect(
			NetProtocol.RememberNonce(rotatingReplay, nonce),
			"NetProtocol rejected a new rotating nonce"
		)
	end
	expect(
		not NetProtocol.RememberNonce(rotatingReplay, 511),
		"NetProtocol forgot a recent replay nonce"
	)
	expect(
		not NetProtocol.RememberNonce(rotatingReplay, 512),
		"NetProtocol forgot the latest replay nonce"
	)
	expect(
		NetProtocol.RememberNonce(rotatingReplay, 510),
		"NetProtocol retained an evicted replay nonce"
	)
	local requestCache = NetProtocol.NewRequestCache(1, 10)
	NetProtocol.PutCached(requestCache, "request_a", { ok = true }, 100)
	expect(
		NetProtocol.GetCached(requestCache, "request_a", 101).ok,
		"NetProtocol lost a cached request"
	)
	NetProtocol.PutCached(requestCache, "request_b", { ok = true }, 102)
	expect(
		NetProtocol.GetCached(requestCache, "request_a", 102) == nil,
		"NetProtocol cache exceeded its bound"
	)
	expect(
		NetProtocol.GetCached(requestCache, "request_b", 113) == nil,
		"NetProtocol cache ignored TTL"
	)
	local duplicateCache = NetProtocol.NewRequestCache(1, 10)
	NetProtocol.PutCached(duplicateCache, "same_request", { value = 1 }, 100)
	NetProtocol.PutCached(duplicateCache, "same_request", { value = 2 }, 100)
	expect(
		NetProtocol.GetCached(duplicateCache, "same_request", 101).value == 2,
		"NetProtocol discarded a newer cache entry with the same expiry"
	)
	local rotatingCache = NetProtocol.NewRequestCache(2, 10)
	for index = 1, 512 do
		NetProtocol.PutCached(rotatingCache, `rotate_{index}`, { index = index }, 100)
	end
	expect(
		NetProtocol.GetCached(rotatingCache, "rotate_511", 101).index == 511,
		"NetProtocol lost a recent cache entry during rotation"
	)
	expect(
		NetProtocol.GetCached(rotatingCache, "rotate_512", 101).index == 512,
		"NetProtocol lost the latest cache entry during rotation"
	)
	expect(
		NetProtocol.GetCached(rotatingCache, "rotate_510", 101) == nil,
		"NetProtocol retained an evicted cache entry during rotation"
	)
	expect(NetProtocol.IsValidRequestId("req_01-safe"), "NetProtocol rejected a valid request id")
	expect(
		not NetProtocol.IsValidRequestId("contains space"),
		"NetProtocol accepted an invalid request id"
	)
	Net.FireAllClients("ReadableRemoteName", "plaintext")
	local eventsFolder = expectChild(ReplicatedStorage, "Events", "Folder")
	local netFolder = expectChild(eventsFolder, "Net", "Folder")
	expect(
		netFolder:FindFirstChild("ReadableRemoteName") == nil,
		"NetService exposed the logical remote name"
	)
	-- RunScript cannot exercise a real client-to-server RemoteFunction call.
	-- Keep this smoke at the public registration lifecycle boundary; replay and
	-- idempotency behavior are covered by the pure NetProtocol checks above and
	-- require a separate multi-client integration playtest.
	local registrationName = "Smoke.ReRegister"
	local firstRegistration = Net.Server.RegisterFunction(registrationName, {
		schema = function(payload: any): boolean
			return typeof(payload) == "table" and next(payload) == nil
		end,
		validate = function(): boolean
			return true
		end,
		mutation = true,
		concurrency = 1,
		handler = function(): string
			return "first"
		end,
	})
	expect(firstRegistration:IsActive(), "NetService did not activate the first registration")
	firstRegistration:Destroy()
	expect(not firstRegistration:IsActive(), "NetService did not deactivate the first registration")
	expect(not pcall(function()
		Net.Server.RegisterEvent(registrationName, {
			schema = function(payload: any): boolean
				return typeof(payload) == "table" and next(payload) == nil
			end,
			handler = function() end,
		})
	end), "NetService allowed a registration to change an existing remote kind")

	local secondRegistration = Net.Server.RegisterFunction(registrationName, {
		schema = function(payload: any): boolean
			return typeof(payload) == "table" and next(payload) == nil
		end,
		validate = function(): boolean
			return true
		end,
		mutation = true,
		concurrency = 1,
		handler = function(): string
			return "second"
		end,
	})
	expect(secondRegistration:IsActive(), "NetService did not allow re-registering a destroyed RPC")
	secondRegistration:Destroy()
	expect(not pcall(function()
		Net.Server.RegisterFunction("_gxk", {
			schema = function(): boolean
				return true
			end,
			handler = function()
				return nil
			end,
		})
	end), "NetService allowed a registration to overwrite its handshake")
	-- ZonePlus owns a cross-context singleton. Studio's RunScript task reports
	-- both client and server, so requiring it again after the server bootstrap
	-- would recursively require that singleton. Verify its package mount here;
	-- normal server/client ZonePlus behavior belongs in an integration playtest.
	expect(ZonePlusModule:IsA("ModuleScript"), "ZonePlus package is unavailable")
	expectChild(serverPackages, "ProfileStore", "ModuleScript")

	expect(Gaxia.Promise == Promise, "Gaxia.Promise did not preserve the public compatibility path")
	expect(
		Gaxia.Observers == PackageObservers,
		"Gaxia.Observers did not resolve directly to Observers"
	)

	expect(type(PackageObservers.observeTag) == "function", "Observers did not expose observeTag")

	local central = Gaxia.Central
	local centralHandle = central:Register({
		name = "oss-smoke-central",
		duration = 1,
		priority = 10,
	}, function() end)
	expect(centralHandle:IsActive(), "Central did not activate a registered task")
	centralHandle:Pause()
	expect(centralHandle:IsActive(), "Central deactivated a paused task")
	centralHandle:Resume()
	expect(centralHandle:IsActive(), "Central did not resume a paused task")
	centralHandle:Cancel()
	expect(not centralHandle:IsActive(), "Central handle remained active after cancellation")
	expect(
		Promise ~= PackagePromise,
		"compatibility Promise unexpectedly resolved to the tagged Wally release"
	)

	for _, packageName in { "Comm", "Component", "Janitor", "Signal", "Trove" } do
		local compatibilityModule = requireChild(shared, packageName)
		local packageModule = requireChild(packages, packageName)
		expect(
			compatibilityModule == packageModule,
			`Shared.{packageName} did not resolve to Packages.{packageName}`
		)
	end

	local ComponentLegacy = Gaxia.ComponentLegacy
	expect(ComponentLegacy == PackageComponent, "ComponentLegacy did not resolve to Component")

	local Symbol = requireChild(shared, "Symbol")
	expect(Symbol == PackageSymbol, "Gaxia.Symbol did not resolve to the Wally package")
	expect(Symbol("smoke") ~= Symbol("smoke"), "Symbol calls must produce unique values")

	local Spring = Gaxia.Spring
	expect(Spring == PackageSpring, "Gaxia.Spring did not resolve directly to the Wally package")
	local spring = Spring.new(0, 0.1)
	spring.Target = 1
	expect(type(spring:Update(1 / 60)) == "number", "Spring.Update returned a non-number")
	spring:Impulse(1)
	spring:Reset(0)
	expect(spring.Current == 0 and spring.Target == 0, "Spring.Reset failed")

	local Guard = Gaxia.Guard
	expect(type(PackageT.strictInterface) == "function", "t package is unavailable")
	expect(Guard == PackageT, "Gaxia.Guard did not resolve directly to the t package")
	expect(not Guard.any(nil), "t.any unexpectedly accepted nil")
	expect(Guard.number(1), "Guard.number rejected a number")
	expect(not Guard.number("1"), "Guard.number accepted a string")
	expect(Guard.numberConstrained(1, 3)(2), "t.numberConstrained rejected an in-range number")
	expect(
		not Guard.numberConstrained(1, 3)(4),
		"t.numberConstrained accepted an out-of-range number"
	)
	expect(Guard.optional(Guard.string)(nil), "Guard.optional rejected nil")
	expect(Guard.union(Guard.string, Guard.number)(2), "Guard.union rejected a matching value")
	expect(Guard.literal("ready")("ready"), "Guard.literal rejected its literal")
	expect(not Guard.integer(1.5), "Guard.integer accepted a float")
	expect(Guard.map(Guard.string, Guard.number)({ coins = 5 }), "Guard.map rejected a valid map")
	expect(
		Guard.interface({ id = Guard.string })({ id = "egg", extra = true }),
		"Guard.interface rejected an extra field"
	)
	expect(Guard.Vector3(Vector3.zero), "Guard.Vector3 rejected a Vector3")
	local instance = Instance.new("Folder")
	expect(Guard.Instance(instance), "Guard.Instance rejected an Instance")
	instance:Destroy()
	local payloadCheck = Guard.strictInterface({ id = Guard.string, qty = Guard.integer })
	expect(payloadCheck({ id = "egg", qty = 1 }), "Guard.strictInterface rejected a valid payload")
	expect(
		not payloadCheck({ id = "egg", qty = 1, injected = true }),
		"Guard.strictInterface accepted an unexpected payload field"
	)
	expect(
		not Guard.array(Guard.string)({ [1] = "a", [3] = "b" }),
		"Guard.array accepted a sparse array"
	)

	local Table = Gaxia.Util.Table
	expect(type(PackageTableUtil.Reconcile) == "function", "TableUtil package is unavailable")
	expect(Table == PackageTableUtil, "Gaxia.Util.Table did not resolve directly to TableUtil")
	local source = { nested = { value = 1 } }
	local copy = Table.Copy(source, true)
	expect(copy ~= source and copy.nested ~= source.nested, "TableUtil.Copy deep copy failed")
	local target = { nested = { existing = true } }
	local template = { nested = { existing = false, added = true }, other = { value = 1 } }
	local reconciled = Table.Reconcile(target, template)
	expect(
		reconciled ~= target and target.nested.added == nil,
		"TableUtil.Reconcile mutated its input"
	)
	expect(reconciled.nested.added == true, "TableUtil.Reconcile omitted a nested default")
	expect(reconciled.other ~= template.other, "TableUtil.Reconcile retained a template reference")
	local filtered = Table.Filter({ 1, 2, 3 }, function(value)
		return value > 1
	end)
	expect(#filtered == 2 and filtered[1] == 2, "TableUtil.Filter failed")
	local reduced = Table.Reduce({ 1, 2, 3 }, function(result, value)
		return result + value
	end, 0)
	expect(reduced == 6, "TableUtil.Reduce failed")
	local shuffled = { 1, 2, 3 }
	expect(Table.Shuffle(shuffled) ~= shuffled, "TableUtil.Shuffle mutated its input")
	expect(
		Table.Some(shuffled, function(value)
			return value == 2
		end),
		"TableUtil.Some failed"
	)
	expect(#Table.Keys(shuffled) == 3, "TableUtil.Keys failed")
	local flattened = Table.Flat({ 1, { 2, { 3 } } }, math.huge)
	expect(#flattened == 3 and flattened[3] == 3, "TableUtil.Flat failed")

	-- The compatibility snapshot and tagged Wally copy deliberately coexist.
	-- Both versions duck-type Promise objects, so cross-copy adoption must work.
	expect(
		Promise.is(PackagePromise.resolve("package")),
		"compatibility Promise rejected a package Promise"
	)
	expect(
		PackagePromise.is(Promise.resolve("compat")),
		"package Promise rejected a compatibility Promise"
	)

	local Maid = Gaxia.Maid
	expect(Maid == Janitor, "Gaxia.Maid did not resolve directly to Janitor")
end

local success, failure = xpcall(run, debug.traceback)

if not success then
	error(`[OSS_SMOKE] FAIL\n{failure}`, 0)
end

print("[OSS_SMOKE]" .. " PASS")
