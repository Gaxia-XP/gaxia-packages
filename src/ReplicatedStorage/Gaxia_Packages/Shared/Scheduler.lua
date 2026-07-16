--!strict
-- ─────────────────────────────────────────────────────────────
-- Scheduler.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Shared/Scheduler
-- Purpose : Timing helpers — After / Every / Debounce / Throttle / Stopwatch —
--           so callers stop re-rolling their own task.delay + debounce flags.
--
-- Access  : Gaxia.Scheduler  (shared)
--   local cancel = Gaxia.Scheduler.Every(5, function() heartbeat() end)
--   local onType = Gaxia.Scheduler.Debounce(save, 0.5)  -- fires 0.5s after the last call
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local Scheduler = {}

-- Run `fn` once after `delaySec`. Returns a cancel() that prevents it firing.
function Scheduler.After(delaySec: number, fn: () -> ()): () -> ()
	local cancelled = false
	task.delay(delaySec, function()
		if not cancelled then
			fn()
		end
	end)
	return function()
		cancelled = true
	end
end

-- Run `fn` every `intervalSec` until cancelled. Returns cancel().
function Scheduler.Every(intervalSec: number, fn: () -> ()): () -> ()
	local cancelled = false
	task.spawn(function()
		while not cancelled do
			task.wait(intervalSec)
			if cancelled then
				break
			end
			fn()
		end
	end)
	return function()
		cancelled = true
	end
end

-- Returns a wrapper that delays `fn` until `waitSec` after its LAST invocation
-- (trailing debounce) — e.g. save-on-stop-typing.
function Scheduler.Debounce(fn: (...any) -> (), waitSec: number): (...any) -> ()
	local token: {}? = nil
	return function(...)
		local args = table.pack(...)
		local mine = {}
		token = mine
		task.delay(waitSec, function()
			if token == mine then
				token = nil
				fn(table.unpack(args, 1, args.n))
			end
		end)
	end
end

-- Returns a wrapper that calls `fn` at most once per `intervalSec` (leading throttle).
function Scheduler.Throttle(fn: (...any) -> (), intervalSec: number): (...any) -> ()
	local lastCall = -math.huge
	return function(...)
		local now = os.clock()
		if now - lastCall >= intervalSec then
			lastCall = now
			fn(...)
		end
	end
end

export type Stopwatch = {
	Elapsed: () -> number,
	Reset: () -> (),
}

-- Simple elapsed-time clock.
function Scheduler.Stopwatch(): Stopwatch
	local start = os.clock()
	return {
		Elapsed = function(): number
			return os.clock() - start
		end,
		Reset = function(): ()
			start = os.clock()
		end,
	}
end

return Scheduler
