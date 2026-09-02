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
	local serverPackages = game:GetService("ServerStorage")
		:WaitForChild("Gaxia_Packages_Server")
		:WaitForChild("ServerPackages")

	local Gaxia = require(root)
	local Promise = require(shared:WaitForChild("Promise"))
	local PackagePromise = require(packages:WaitForChild("Promise"))
	local ZonePlus = require(packages:WaitForChild("ZonePlus"))
	local PackageSymbol = require(packages:WaitForChild("Symbol"))
	local PackageTableUtil = require(packages:WaitForChild("TableUtil"))
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

	local ComponentLegacy = require(shared:WaitForChild("ComponentLegacy"))
	expect(type(ComponentLegacy.Bind) == "function", "ComponentLegacy public path is missing Bind")

	local Symbol = require(shared:WaitForChild("Symbol"))
	expect(Symbol == PackageSymbol, "Gaxia.Symbol did not resolve to the Wally package")
	expect(Symbol("smoke") ~= Symbol("smoke"), "Symbol calls must produce unique values")

	local Table = require(shared:WaitForChild("Util"):WaitForChild("Table"))
	expect(type(PackageTableUtil.Reconcile) == "function", "TableUtil package is unavailable")
	local cyclic = { value = 1 }
	cyclic.self = cyclic
	local cyclicCopy = Table.DeepCopy(cyclic)
	expect(
		cyclicCopy ~= cyclic and cyclicCopy.self == cyclicCopy,
		"Table.DeepCopy lost cycle safety"
	)
	local nested = { existing = true }
	local target = { nested = nested }
	local template = { nested = { existing = false, added = true }, other = { value = 1 } }
	expect(Table.Reconcile(target, template) == target, "Table.Reconcile replaced the root table")
	expect(
		target.nested == nested and target.nested.added == true,
		"Table.Reconcile replaced nested identity"
	)
	expect(target.other ~= template.other, "Table.Reconcile retained a template table reference")
	local sparse = { [1] = "keep", [3] = "also keep" }
	local filtered = Table.Filter(sparse, function()
		return true
	end)
	expect(
		filtered[1] == "keep" and filtered[3] == "also keep",
		"Table.Filter compacted sparse keys"
	)
	expect(Table.Count(sparse) == 2, "Table.Count skipped sparse keys")
	local reduced = Table.Reduce(sparse, function(result, value)
		return result .. value
	end, "")
	expect(
		string.find(reduced, "keep", 1, true) ~= nil,
		"Table.Reduce skipped the first sparse value"
	)
	expect(string.find(reduced, "also keep", 1, true) ~= nil, "Table.Reduce skipped a sparse value")
	local shuffled = { 1, 2, 3 }
	expect(Table.Shuffle(shuffled) == shuffled, "Table.Shuffle no longer mutates in place")
	expect(Table.Contains(shuffled, 2), "Table.Contains failed through TableUtil")
	expect(Table.Count(shuffled) == 3, "Table.Count failed through TableUtil")
	local flattened = Table.Flatten({ 1, { 2, { 3 } } })
	expect(#flattened == 3 and flattened[3] == 3, "Table.Flatten lost its recursive default")

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

	local Maid = require(shared:WaitForChild("Maid"))
	local cleanupOrder = {}
	local maid = Maid.new()
	maid:GiveTask(function()
		table.insert(cleanupOrder, 1)
	end)
	maid:GiveTask(function()
		table.insert(cleanupOrder, 2)
	end)
	maid:Destroy()
	expect(
		cleanupOrder[1] == 2 and cleanupOrder[2] == 1,
		"Maid facade did not preserve LIFO cleanup"
	)

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
