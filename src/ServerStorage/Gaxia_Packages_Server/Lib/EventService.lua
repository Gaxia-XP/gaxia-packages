--!strict
-- ─────────────────────────────────────────────────────────────
-- EventService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/EventService
-- Purpose : Seasonal / timed live-ops windows. Define an event with an os.time
--           start/end (+ arbitrary Data payload like a multiplier or shop);
--           IsActive/GetActive answer "is it on right now", and a background
--           ticker fires OnEventStart/OnEventEnd exactly once as each window
--           opens and closes — so spawners, drop-rate boosts and seasonal UI all
--           hang off one clock instead of each polling os.time. Windows are
--           absolute timestamps, so they agree across every server.
--
-- Access  : Gaxia.Event  (server)
--   Gaxia.Event.Define("DoubleXP", { StartsAt = t0, EndsAt = t1, Data = { mult = 2 } })
--   if Gaxia.Event.IsActive("DoubleXP") then xp *= 2 end
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal = SharedPkg.Signal

local TICK : number = 5 -- seconds between window checks (Config-overridable; see tickInterval())

-- ── Lazy server (Config + EConfig) — resolved at CALL-TIME, never module load ──
local ServerStorage = game:GetService("ServerStorage")
local _server: any = nil
local function server(): any
	if not _server then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server")
		_server = require(serverInit :: any)
	end
	return _server
end
-- Poll interval read per-tick so a live Flag override (Event.TickInterval) takes
-- effect on the next loop without restarting the ticker. Default stays TICK (5).
local function tickInterval(): number
	local s = server()
	return s.EConfig.Get("Event.TickInterval", (s.Config.Event or {}).TickInterval or TICK)
end

export type EventDef = { StartsAt: number, EndsAt: number, Data: any? }

local EventService = {}

EventService.OnEventStart = Signal.new() -- (eventId, data)
EventService.OnEventEnd = Signal.new()   -- (eventId, data)

local events: { [string]: EventDef } = {}
local lastActive: { [string]: boolean } = {}

-- ── Registry ──

function EventService.Define(eventId: string, def: EventDef): ()
	events[eventId] = def
end

function EventService.GetData(eventId: string): any
	local e = events[eventId]
	return e and e.Data
end

-- ── Queries ──

function EventService.IsActive(eventId: string): boolean
	local e = events[eventId]
	if not e then
		return false
	end
	local now = os.time()
	return now >= e.StartsAt and now < e.EndsAt
end

function EventService.GetActive(): { string }
	local out: { string } = {}
	for id in pairs(events) do
		if EventService.IsActive(id) then
			table.insert(out, id)
		end
	end
	table.sort(out)
	return out
end

function EventService.GetTimeRemaining(eventId: string): number
	local e = events[eventId]
	if not e or not EventService.IsActive(eventId) then
		return 0
	end
	return math.max(0, e.EndsAt - os.time())
end

function EventService.GetTimeUntilStart(eventId: string): number
	local e = events[eventId]
	if not e then
		return 0
	end
	return math.max(0, e.StartsAt - os.time())
end

-- ── Transition detection (fire start/end once) ──
-- Exposed so it's directly testable; the ticker below calls it on a loop.
function EventService.PollTransitions(): ()
	for id, def in pairs(events) do
		local active = EventService.IsActive(id)
		local was = lastActive[id] == true
		if active and not was then
			EventService.OnEventStart:Fire(id, def.Data)
		elseif not active and was then
			EventService.OnEventEnd:Fire(id, def.Data)
		end
		lastActive[id] = active
	end
end

task.spawn(function()
	while true do
		EventService.PollTransitions()
		task.wait(tickInterval())
	end
end)

return EventService
