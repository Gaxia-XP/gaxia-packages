--!strict
-- ─────────────────────────────────────────────────────────────
-- ServiceLifecycle.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/ServiceLifecycle
-- Purpose : Starts framework services in dependency order, only when they are
--           used. A service module stays side-effect free when required and
--           registers its lifecycle with Define() as its LAST statement:
--
--             Lifecycle.Define(EconomyService, {
--                 Name  = "Economy",        -- its GaxiaServer.<Name> key
--                 Needs = { DataManager },  -- modules whose Init must run first ({} if none)
--                 Init  = function() ... end,   -- sync; must NOT yield
--                 Start = function() ... end,   -- own thread, after the Init batch; may yield
--             })
--             return EconomyService
--
--           A service starts (Init, then Start) when the first of these happens:
--             • it is listed in Features (Boot, at server start);
--             • game code first touches GaxiaServer.<Name> (the loader Ensures it);
--             • any of its functions is first called, by any path (Define wraps them) —
--               unless the spec says AutoStart = false (then only Features/Boot/Ensure).
--           Needs are started first. A failed Init is warned once and cached (no
--           retry); modules that need it still start ("fail-open", like the old
--           independent module bodies).
--
-- Access  : GaxiaServer.Lifecycle
--
-- Legacy  : Register / RegisterMany / Start / IsStarted / OnStarted keep their
--           original (MANUAL §8.21) semantics on a separate queue for game code.
-- ─────────────────────────────────────────────────────────────

local Types = require(script.Parent.Parent.Types)

export type Spec = {
	Name: Types.ServiceName,
	Needs: { {} },
	Init: (() -> ())?,
	Start: (() -> ())?,
	AutoStart: boolean?,
}
export type State = "defined" | "initializing" | "initialized" | "failed"

type Record = {
	module: { [any]: any },
	spec: Spec,
	state: State,
	originals: { [any]: (...any) -> ...any },
}

local ServiceLifecycle = {}

local records: { [{}]: Record } = {}
local byName: { [string]: Record } = {}
local initializedOrder: { string } = {}
local booted = false
local bootedCallbacks: { () -> () } = {}
local initCallbacks: { [Record]: { () -> () } } = {}
local anyInitCallbacks: { (name: string) -> () } = {}

-- ── Internals ──

local function restoreOriginals(rec: Record): ()
	for key, fn in rec.originals do
		rec.module[key] = fn
	end
	table.clear(rec.originals)
end

-- Collect `module` and its not-yet-initialised Needs, dependencies first, into `out`.
-- `onStack` detects cycles; `emitted` dedupes shared dependencies.
local function collect(module: {}, onStack: { [Record]: boolean }, emitted: { [Record]: boolean }, path: { string }, out: { Record }): ()
	local rec = records[module]
	if rec == nil or rec.state ~= "defined" or emitted[rec] then
		return
	end
	if onStack[rec] then
		error(`[Lifecycle] dependency cycle: {table.concat(path, " -> ")} -> {rec.spec.Name}`, 0)
	end
	onStack[rec] = true
	table.insert(path, rec.spec.Name)
	for _, need in rec.spec.Needs do
		collect(need, onStack, emitted, path, out)
	end
	table.remove(path)
	onStack[rec] = nil
	emitted[rec] = true
	table.insert(out, rec)
end

-- Run Init on its own thread so a yield is detected the same way whether we are
-- booting from a Script or starting lazily inside the loader's __index metamethod.
local function runInit(rec: Record): boolean
	rec.state = "initializing"
	local name = rec.spec.Name
	for _, need in rec.spec.Needs do
		local needRec = records[need]
		if needRec and needRec.state == "failed" then
			warn(`[Lifecycle] {name}: needed service {needRec.spec.Name} failed to start — starting {name} anyway`)
		end
	end

	local init = rec.spec.Init
	if init then
		local finished = false
		local ok, err = true, nil
		local thread = task.spawn(function()
			ok, err = xpcall(init, debug.traceback)
			finished = true
		end)
		if not finished then
			task.cancel(thread)
			ok, err = false, "Init yielded — Init must not yield (move waits and loops into Start)"
		end
		if not ok then
			rec.state = "failed"
			warn(`[Lifecycle] {name}.Init failed: {err}`)
			return false
		end
	end

	rec.state = "initialized"
	restoreOriginals(rec)
	table.insert(initializedOrder, name)
	local cbs = initCallbacks[rec]
	initCallbacks[rec] = nil
	if cbs then
		for _, fn in cbs do
			task.spawn(fn)
		end
	end
	for _, fn in anyInitCallbacks do
		task.spawn(fn, name)
	end
	return true
end

local function runStart(rec: Record): ()
	local start = rec.spec.Start
	if start then
		local name = rec.spec.Name
		task.spawn(function()
			local ok, err = xpcall(start, debug.traceback)
			if not ok then
				warn(`[Lifecycle] {name}.Start failed: {err}`)
			end
		end)
	end
end

-- The one start path shared by Boot and Ensure: every Init of the closure (in
-- dependency order), then every Start in the same order.
local function startClosure(roots: { {} }): ()
	local out: { Record } = {}
	local emitted: { [Record]: boolean } = {}
	for _, module in roots do
		local ok, err = pcall(collect, module, {}, emitted, {}, out)
		if not ok then
			warn(err)
		end
	end
	local initialised: { Record } = {}
	for _, rec in out do
		if rec.state == "defined" and runInit(rec) then
			table.insert(initialised, rec)
		end
	end
	for _, rec in initialised do
		runStart(rec)
	end
end

-- Replace each function field with a wrapper that starts the service on first
-- call, so a service used through a direct require or another service's call
-- still starts like it did when module bodies ran their own setup. Restored to
-- the original functions once the service is initialised.
local function wrapFunctions(rec: Record): ()
	local module = rec.module
	if table.isfrozen(module) then
		return
	end
	for key, value in pairs(module) do
		if type(value) == "function" then
			local original = value :: (...any) -> ...any
			rec.originals[key] = original
			module[key] = function(...: any): ...any
				if rec.state == "defined" then
					startClosure({ module })
				end
				return original(...)
			end
		end
	end
end

-- ── Public API ──

-- Register a service's lifecycle. Call it as the module's LAST statement (after
-- every function is defined) — it is pure metadata and starts nothing.
function ServiceLifecycle.Define(module: {}, spec: Spec): ()
	assert(type(module) == "table", "[Lifecycle] Define expects the module table")
	assert(type(spec) == "table" and type(spec.Name) == "string", "[Lifecycle] Define expects a spec with a Name")
	assert(type(spec.Needs) == "table", `[Lifecycle] {spec.Name}: Needs is required (use \{})`)
	for i, need in spec.Needs do
		assert(type(need) == "table", `[Lifecycle] {spec.Name}.Needs[{i}] must be a required module table`)
	end
	local existing = records[module]
	if existing then
		if existing.spec == spec then
			return
		end
		error(`[Lifecycle] {spec.Name} is defined twice`, 2)
	end
	if byName[spec.Name] then
		error(`[Lifecycle] two modules define the service name "{spec.Name}"`, 2)
	end
	local rec: Record = { module = module :: any, spec = spec, state = "defined", originals = {} }
	records[module] = rec
	byName[spec.Name] = rec
	-- Pure services (no Init/Start) are wrapped too, so their first direct call
	-- marks them started and IsEnabled / GaxiaServerFeatures count them.
	if spec.AutoStart ~= false then
		wrapFunctions(rec)
	end
end

-- Start `module` (and its Needs) now if it has a spec and has not started yet.
-- Returns true when the module is initialised (or has no spec).
function ServiceLifecycle.Ensure(module: {}): boolean
	local rec = records[module]
	if rec == nil then
		return true
	end
	startClosure({ module })
	return rec.state == "initialized" or rec.state == "initializing"
end

-- The loader's start-on-access: like Ensure, but respects AutoStart = false.
function ServiceLifecycle.EnsureAuto(module: {}): boolean
	local rec = records[module]
	if rec == nil then
		return true
	end
	if rec.spec.AutoStart == false and rec.state == "defined" then
		return true
	end
	return ServiceLifecycle.Ensure(module)
end

-- Start every module in `modules` (Features order, Needs first): all Inits, then all Starts.
function ServiceLifecycle.Boot(modules: { {} }): ()
	startClosure(modules)
	if not booted then
		booted = true
		for _, fn in bootedCallbacks do
			task.spawn(fn)
		end
		table.clear(bootedCallbacks)
	end
end

function ServiceLifecycle.GetState(module: {}): State?
	local rec = records[module]
	return if rec then rec.state else nil
end

function ServiceLifecycle.GetStateByName(name: string): State?
	local rec = byName[name]
	return if rec then rec.state else nil
end

-- Names of initialised services, in the order they started.
function ServiceLifecycle.GetStarted(): { string }
	return table.clone(initializedOrder)
end

function ServiceLifecycle.IsBooted(): boolean
	return booted
end

function ServiceLifecycle.OnBooted(fn: () -> ()): ()
	if booted then
		task.spawn(fn)
	else
		table.insert(bootedCallbacks, fn)
	end
end

-- Run `fn` once `module` is initialised (now, on a new thread, if it already is),
-- however it gets started — for soft dependencies ("use it if it runs").
function ServiceLifecycle.OnInitialized(module: {}, fn: () -> ()): ()
	local rec = records[module]
	if rec and rec.state == "initialized" then
		task.spawn(fn)
		return
	end
	if rec == nil then
		warn("[Lifecycle] OnInitialized: module has no Define — callback never fires")
		return
	end
	initCallbacks[rec] = initCallbacks[rec] or {}
	table.insert(initCallbacks[rec], fn)
end

-- Run `fn(name)` every time any service finishes Init (used by the loader to
-- publish the started set to clients).
function ServiceLifecycle.OnAnyInitialized(fn: (name: string) -> ()): ()
	table.insert(anyInitCallbacks, fn)
end

-- ── Legacy API (MANUAL §8.21) — unchanged semantics, separate state ──
-- For game code that registers its own services: Start() runs every Init, then
-- every Start, synchronously in the caller's thread; OnStarted fires after.

export type Service = {
	Name: string?,
	Init: ((self: any) -> ())?,
	Start: ((self: any) -> ())?,
	[any]: any,
}

local legacyQueue: { Service } = {}
local legacyOnStarted: { () -> () } = {}
local legacyStarted = false
local legacyStarting = false

local function legacyName(svc: Service, index: number): string
	return svc.Name or `#{index}`
end

-- Queue a service. Registration ORDER is the dependency order (register a
-- service after the ones it depends on).
function ServiceLifecycle.Register(service: Service): ()
	if type(service) ~= "table" then
		warn("[Lifecycle] Register expects a table service")
		return
	end
	if legacyStarted or legacyStarting then
		warn(`[Lifecycle] Register('{service.Name or "?"}') after Start() — ignored`)
		return
	end
	table.insert(legacyQueue, service)
end

function ServiceLifecycle.RegisterMany(services: { Service }): ()
	for _, svc in ipairs(services) do
		ServiceLifecycle.Register(svc)
	end
end

-- Run Init() on every queued service (in order), THEN Start() on every service.
-- Idempotent — a second call is a no-op. pcall-isolated so one broken service
-- can't abort the rest.
function ServiceLifecycle.Start(): ()
	if legacyStarted or legacyStarting then
		return
	end
	legacyStarting = true

	for i, svc in ipairs(legacyQueue) do
		if type(svc.Init) == "function" then
			local ok, err = pcall(svc.Init, svc)
			if not ok then
				warn(`[Lifecycle] {legacyName(svc, i)}.Init failed: {err}`)
			end
		end
	end

	for i, svc in ipairs(legacyQueue) do
		if type(svc.Start) == "function" then
			local ok, err = pcall(svc.Start, svc)
			if not ok then
				warn(`[Lifecycle] {legacyName(svc, i)}.Start failed: {err}`)
			end
		end
	end

	legacyStarted = true
	legacyStarting = false

	for _, fn in ipairs(legacyOnStarted) do
		task.spawn(fn)
	end
	table.clear(legacyOnStarted)
end

function ServiceLifecycle.IsStarted(): boolean
	return legacyStarted
end

-- Run `fn` after Start() completes (immediately, on a fresh thread, if already started).
function ServiceLifecycle.OnStarted(fn: () -> ()): ()
	if type(fn) ~= "function" then
		return
	end
	if legacyStarted then
		task.spawn(fn)
	else
		table.insert(legacyOnStarted, fn)
	end
end

return ServiceLifecycle
