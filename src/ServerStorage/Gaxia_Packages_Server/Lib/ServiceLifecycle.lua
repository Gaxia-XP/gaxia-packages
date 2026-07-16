--!strict
-- ─────────────────────────────────────────────────────────────
-- ServiceLifecycle.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/ServiceLifecycle
-- Purpose : Opt-in two-phase boot ordering (Init → Start) for services that
--           need a deterministic startup, on top of the lazy __index loader.
--           Phase 1 Init() runs for EVERY registered service (set up state /
--           create remotes) before Phase 2 Start() runs for any (cross-service
--           wiring), so a service can safely use another in Start(). Existing
--           self-initialising services keep working unchanged — this is additive.
--
-- Access  : Gaxia.Lifecycle  (server)
--   Gaxia.Lifecycle.RegisterMany({ require(A), require(B) })  -- A before B = A's deps first
--   Gaxia.Lifecycle.Start()                                   -- Init all, then Start all
--   Gaxia.Lifecycle.OnStarted(function() print("all services up") end)
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

export type Service = {
	Name: string?,
	Init: ((self: any) -> ())?,
	Start: ((self: any) -> ())?,
	[any]: any,
}

local ServiceLifecycle = {}

local queue: { Service } = {}
local onStartedCbs: { () -> () } = {}
local started = false
local starting = false

local function nameOf(svc: Service, index: number): string
	return svc.Name or `#{index}`
end

-- ── Public API ──

-- Queue a service. Registration ORDER is the dependency order (register a
-- service after the ones it depends on).
function ServiceLifecycle.Register(service: Service): ()
	if type(service) ~= "table" then
		warn("[Lifecycle] Register expects a table service")
		return
	end
	if started or starting then
		warn(`[Lifecycle] Register('{service.Name or "?"}') after Start() — ignored`)
		return
	end
	table.insert(queue, service)
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
	if started or starting then
		return
	end
	starting = true

	for i, svc in ipairs(queue) do
		if type(svc.Init) == "function" then
			local ok, err = pcall(svc.Init, svc)
			if not ok then
				warn(`[Lifecycle] {nameOf(svc, i)}.Init failed: {err}`)
			end
		end
	end

	for i, svc in ipairs(queue) do
		if type(svc.Start) == "function" then
			local ok, err = pcall(svc.Start, svc)
			if not ok then
				warn(`[Lifecycle] {nameOf(svc, i)}.Start failed: {err}`)
			end
		end
	end

	started = true
	starting = false

	for _, fn in ipairs(onStartedCbs) do
		task.spawn(fn)
	end
	table.clear(onStartedCbs)
end

function ServiceLifecycle.IsStarted(): boolean
	return started
end

-- Run `fn` after Start() completes (immediately, on a fresh thread, if already started).
function ServiceLifecycle.OnStarted(fn: () -> ()): ()
	if type(fn) ~= "function" then
		return
	end
	if started then
		task.spawn(fn)
	else
		table.insert(onStartedCbs, fn)
	end
end

return ServiceLifecycle
