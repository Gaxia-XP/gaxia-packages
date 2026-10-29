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
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Shared    = ReplicatedStorage.Gaxia_Packages.Shared
local Signal    = require(Shared.Signal)
local Lifecycle = require(script.Parent.ServiceLifecycle)
local Config    = require(script.Parent.Parent.Config)
local EConfig   = require(script.Parent.EffectiveConfig)

local TICK : number = 5 -- seconds between window checks (Config-overridable; see tickInterval())

-- Poll interval read per-tick so a live Flag override (Event.TickInterval) takes
-- effect on the next loop without restarting the ticker. Default stays TICK (5).
local function tickInterval(): number
	return EConfig.Get("Event.TickInterval", Config.Event.TickInterval or TICK)
end

-- Data is the game's own payload (a multiplier, a shop id, ...), passed through as-is.
export type EventDef = { StartsAt: number, EndsAt: number, Data: any? }

local EventService = {}

-- (eventId, data) once when an event's window opens (data = its EventDef.Data)
EventService.OnEventStart = Signal.new() :: Signal.Signal<string, any>
-- (eventId, data) once when an event's window closes
EventService.OnEventEnd = Signal.new() :: Signal.Signal<string, any>

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
-- Exposed so it's directly testable; the ticker (lifecycle Start) calls it on a loop.
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

-- EventService.Define above registers a live-ops event; Lifecycle.Define registers
-- the service. Start runs the ticker forever (first poll immediately, as the old
-- load-time task.spawn did); the interval is re-read every tick.
Lifecycle.Define(EventService, {
	Name = "Event",
	Needs = {},
	Start = function()
		while true do
			EventService.PollTransitions()
			task.wait(tickInterval())
		end
	end,
})

return EventService
