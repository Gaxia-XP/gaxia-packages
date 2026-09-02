local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local function expect(condition: boolean, message: string)
	if not condition then
		error(message, 2)
	end
end

local function expectResolved(promise: any, expected: any, label: string)
	local success, value = promise:await()
	expect(success, `{label} rejected: {value}`)
	expect(value == expected, `{label} resolved with {value}, expected {expected}`)
end

local function run()
	local root = ReplicatedStorage:WaitForChild("Gaxia_Packages")
	local shared = root:WaitForChild("Shared")
	local packages = root:WaitForChild("Packages")
	local serverRoot = game:GetService("ServerStorage"):WaitForChild("Gaxia_Packages_Server")
	local serverPackages = serverRoot:WaitForChild("ServerPackages")

	local Gaxia = require(root)
	local ServerZone = require(serverRoot:WaitForChild("Lib"):WaitForChild("ZoneService"))
	local Promise = require(shared:WaitForChild("Promise"))
	local PackagePromise = require(packages:WaitForChild("Promise"))
	local PackageComponent = require(packages:WaitForChild("Component"))
	local ZonePlus = require(packages:WaitForChild("ZonePlus"))
	local PackageSymbol = require(packages:WaitForChild("Symbol"))
	local PackageSpring = require(packages:WaitForChild("Spring"))
	local PackageTableUtil = require(packages:WaitForChild("TableUtil"))
	local PackageT = require(packages:WaitForChild("T"))
	local ProfileStore = require(serverPackages:WaitForChild("ProfileStore"))
	local Janitor = require(shared:WaitForChild("Janitor"))
	expect(type(ZonePlus.new) == "function", "ZonePlus package is unavailable")
	expect(
		serverPackages:WaitForChild("ProfileStore"):IsA("ModuleScript"),
		"server-only ProfileStore package is unavailable"
	)

	local profileStore = ProfileStore.New("GaxiaOssSmoke", {
		Coins = 0,
		Settings = { Music = true },
	})
	local profile = profileStore.Mock:StartSessionAsync("player-1")
	expect(profile ~= nil, "ProfileStore mock session did not start")
	profile.Data.Coins = 25
	profile:Reconcile()
	expect(profile.Data.Settings.Music == true, "ProfileStore reconcile failed")

	local sessionEnded = false
	local finalSaveFinished = false
	profile.OnSessionEnd:Connect(function()
		sessionEnded = true
	end)
	profile.OnAfterSave:Connect(function()
		finalSaveFinished = true
	end)
	profile:EndSession()
	local profileDeadline = os.clock() + 5
	while (not sessionEnded or not finalSaveFinished) and os.clock() < profileDeadline do
		task.wait()
	end
	expect(sessionEnded, "ProfileStore EndSession did not fire OnSessionEnd")
	expect(finalSaveFinished, "ProfileStore EndSession did not finish its final mock save")

	local reloadedProfile = profileStore.Mock:StartSessionAsync("player-1")
	expect(reloadedProfile ~= nil, "ProfileStore mock profile did not reload")
	expect(reloadedProfile.Data.Coins == 25, "ProfileStore mock data did not persist")
	local reloadSaveFinished = false
	reloadedProfile.OnAfterSave:Connect(function()
		reloadSaveFinished = true
	end)
	reloadedProfile:EndSession()
	profileDeadline = os.clock() + 5
	while not reloadSaveFinished and os.clock() < profileDeadline do
		task.wait()
	end
	expect(reloadSaveFinished, "reloaded ProfileStore mock session did not finish saving")

	expect(Gaxia.Promise == Promise, "Gaxia.Promise did not preserve the public compatibility path")
	expect(
		Promise ~= PackagePromise,
		"compatibility Promise unexpectedly resolved to the tagged Wally release"
	)

	for _, packageName in { "Comm", "Component", "Janitor", "Signal", "Trove" } do
		local compatibilityModule = require(shared:WaitForChild(packageName))
		local packageModule = require(packages:WaitForChild(packageName))
		expect(
			compatibilityModule == packageModule,
			`Shared.{packageName} did not resolve to Packages.{packageName}`
		)
	end

	local ComponentLegacy = Gaxia.ComponentLegacy
	expect(ComponentLegacy == PackageComponent, "ComponentLegacy did not resolve to Component")

	local Symbol = require(shared:WaitForChild("Symbol"))
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
	expectResolved(
		Promise.resolve(PackagePromise.resolve("package-to-compat")),
		"package-to-compat",
		"cross-copy resolve"
	)
	expectResolved(
		PackagePromise.resolve(Promise.resolve("compat-to-package")),
		"compat-to-package",
		"reverse resolve"
	)

	local deferredRan = false
	local deferred = Promise.defer(function(resolve: (any) -> ())
		deferredRan = true
		resolve("deferred")
	end)
	expect(not deferredRan, "Promise.defer ran synchronously")
	expectResolved(deferred, "deferred", "Promise.defer")

	local delaySuccess, elapsed = Promise.delay(0.01):await()
	expect(delaySuccess, `Promise.delay rejected: {elapsed}`)
	expect(
		type(elapsed) == "number" and elapsed >= 0,
		"Promise.delay returned an invalid elapsed time"
	)

	-- This behavior exists in the post-tag snapshot but not the published 4.0.0
	-- package: an error thrown by a finally handler rejects the returned Promise.
	local finallySuccess, finallyError = Promise.resolve("value")
		:finally(function()
			error("finally smoke failure")
		end)
		:await()
	expect(not finallySuccess, "Promise.finally swallowed a handler error")
	expect(
		string.find(tostring(finallyError), "finally smoke failure", 1, true) ~= nil,
		"Promise.finally rejected with the wrong error"
	)

	local cancelled = false
	local pending = Promise.new(
		function(_resolve: (any) -> (), _reject: (any) -> (), onCancel: ((() -> ())?) -> boolean)
			onCancel(function()
				cancelled = true
			end)
		end
	)
	local janitor = Janitor.new()
	local tracked = janitor:AddPromise(pending)
	expect(Promise.is(tracked), "Janitor:AddPromise returned an incompatible Promise")
	janitor:Cleanup()
	task.wait()
	expect(cancelled, "Janitor did not cancel a compatibility Promise")
	expect(
		pending:getStatus() == Promise.Status.Cancelled,
		"compatibility Promise did not enter Cancelled status"
	)

	local Maid = Gaxia.Maid
	expect(Maid == Janitor, "Gaxia.Maid did not resolve directly to Janitor")
	expect(ServerZone == ZonePlus, "GaxiaServer.Zone module did not resolve directly to ZonePlus")

	local region = Instance.new("Part")
	region.Anchored = true
	region.Size = Vector3.new(8, 8, 8)
	region.Parent = workspace
	local zone = ZonePlus.new(region)
	expect(#zone:getPlayers() == 0, "new ZonePlus zone unexpectedly contains players")
	zone:destroy()
	region:Destroy()
end

local startedRunService = not RunService:IsRunning()
if startedRunService then
	RunService:Run()
end

local success, failure = xpcall(run, debug.traceback)

if startedRunService and RunService:IsRunning() then
	RunService:Stop()
end

if not success then
	error(`[OSS_SMOKE] FAIL\n{failure}`, 0)
end

print("[OSS_SMOKE]" .. " PASS")
