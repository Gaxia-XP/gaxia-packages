--!nocheck
-- Shared harness state + the event stream read by tools/run-game.mjs.
-- Every runtime module requires this and hangs its functions on it (H.sched,
-- H.inst, H.sig, ...), so modules can call each other without require cycles.
local serde = require("@lune/serde")

local H = {}

H.options = {}
H.worlds = {} -- id -> world
H.notes = {} -- "unmodeled class Foo" -> true (emitted once)
H.counts = { prints = 0, warnings = 0, errors = 0, remoteCalls = 0, dataStoreCalls = 0, kicks = 0 }

-- Strip "0x..." addresses so the same game gives the same output every run.
local function stable(s: string): string
	return (string.gsub(s, "0x%x+", "0x..."))
end
H.stable = stable

local seenText: { [string]: number } = {}
local PER_TEXT_LIMIT = 3

function H.emit(ev)
	local ok, text = pcall(serde.encode, "json", ev)
	if not ok then
		text = serde.encode("json", { t = "harness", message = "could not encode event: " .. tostring(text) })
	end
	-- print, not stdio.write: stdio.write yields, and this runs inside game threads
	print("@@EV " .. text)
end

-- Repeated identical lines (same kind + world + text) are emitted PER_TEXT_LIMIT
-- times; the rest are only counted (sent at the end as "repeat" events).
local function limited(kind: string, world: string, text: string): boolean
	local key = kind .. "\0" .. world .. "\0" .. text
	local n = (seenText[key] or 0) + 1
	seenText[key] = n
	return n <= PER_TEXT_LIMIT
end

function H.flushRepeats()
	for key, n in seenText do
		if n > PER_TEXT_LIMIT then
			local kind, world, text = string.match(key, "^(.-)%z(.-)%z(.*)$")
			H.emit({ t = "repeat", kind = kind, world = world, text = text, count = n })
		end
	end
end

function H.now(): number
	return if H.sched then H.sched.clock else 0
end

function H.print(world: string, text: string, source: string?)
	H.counts.prints += 1
	text = stable(text)
	if H.counts.prints <= 5000 and limited("print", world, text) then
		H.emit({ t = "print", world = world, time = H.now(), text = text, source = source })
	end
end

function H.warn(world: string, text: string, source: string?, trace: string?)
	H.counts.warnings += 1
	text = stable(text)
	if limited("warn", world, text) then
		H.emit({ t = "warn", world = world, time = H.now(), text = text, source = source, trace = trace })
	end
end

-- An error raised inside the harness's own Luau files is a harness bug, even
-- when a game thread hit it: never blame the game for it.
local function fromHarness(message: string): boolean
	local loc = string.match(message, "^(.-):%d+:")
	return loc ~= nil and (string.find(loc, "tools/harness", 1, true) ~= nil or string.sub(loc, 1, 1) == "/")
end

-- A game error (what Roblox Output shows in red).
function H.gameError(world: string, message: string, trace: string?, context: string?)
	if fromHarness(message) then
		H.harnessError(string.format("[%s] %s%s", world, message, if trace then "\n" .. trace else ""))
		return
	end
	H.counts.errors += 1
	message = stable(message)
	local key = message .. "\0" .. (trace or "")
	if limited("error", world, key) then
		H.emit({ t = "error", world = world, time = H.now(), message = message, trace = trace, context = context })
	end
	if H.onGameError then
		H.onGameError(world, message, trace)
	end
end

function H.note(text: string)
	if not H.notes[text] then
		H.notes[text] = true
		H.emit({ t = "note", text = text })
	end
end

function H.record(kind: string, data)
	data.t = kind
	data.time = H.now()
	H.emit(data)
end

-- A bug in the harness itself (not in the game). Shown as HARNESS ERROR.
function H.harnessError(text: string)
	H.emit({ t = "harness", message = text })
end

return H
