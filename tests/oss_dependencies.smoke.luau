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

	local Gaxia = require(root)
	local Promise = require(shared:WaitForChild("Promise"))
	local PackagePromise = require(packages:WaitForChild("Promise"))
	local ZonePlus = require(packages:WaitForChild("ZonePlus"))
	local Janitor = require(shared:WaitForChild("Janitor"))
	expect(type(ZonePlus.new) == "function", "ZonePlus package is unavailable")

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
	expect(type(Symbol.new) == "function", "local Symbol.new compatibility API is missing")
	expect(Symbol("smoke") ~= Symbol("smoke"), "Symbol calls must produce unique values")

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
