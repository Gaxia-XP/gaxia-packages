--!nocheck
-- Simulated-time scheduler: every game thread is a coroutine created here.
-- Time only moves when step() runs a frame (60 per simulated second), so a
-- 10 s scenario runs in well under a second of real time and always the same way.
local H = require("./state")

local S = {}
H.sched = S

S.clock = 0 -- simulated seconds since the server started
S.frame = 0
S.FRAME = 1 / 60
S.intra = 0 -- os.clock() creeps forward inside a frame so busy-wait loops end

local ERR = newproxy(false) -- a wrapped thread returns this when its body errored
S.ERR = ERR
local threadErr = setmetatable({}, { __mode = "k" }) -- co -> { value, trace }
S.threadErr = threadErr
-- co -> { world = world, token = number?, waiting = desc? }
local info = setmetatable({}, { __mode = "k" })
S.info = info

local seq = 0
local sleepers = {} -- { w = waker, at = number, seq = number, args = pack? }
local deferq = {}
local dHead, dTail = 1, 0

-- ── traceback formatting ─────────────────────────────────────────────────────
-- Game chunks are named after the script's full name ("ServerScriptService.Foo");
-- harness chunks are file paths. Keep only game frames.
local function isGameSource(src: string): boolean
	local c = string.sub(src, 1, 1)
	return src ~= "" and c ~= "/" and c ~= "." and c ~= "[" and c ~= "@" and c ~= "=" and not string.find(src, "__mlua", 1, true)
		and not string.find(src, "tools/harness", 1, true)
end
S.isGameSource = isGameSource

function S.formatTrace(trace: string?): string?
	if trace == nil then
		return nil
	end
	local out = {}
	for line in string.gmatch(trace, "[^\n]+") do
		line = string.gsub(line, "^%s+", "")
		if line ~= "stack traceback:" then
			-- "Src:12: in function 'f'" (Lua style) or "Src:12 function f" (Luau style)
			local src, ln, rest = string.match(line, "^(.-):(%d+):?%s*(.*)$")
			if src and isGameSource(src) then
				rest = string.gsub(rest, "^in ", "")
				rest = string.gsub(rest, "^function '(.-)'", "function %1")
				if rest == "?" or rest == "" then
					table.insert(out, string.format("%s:%s", src, ln))
				else
					table.insert(out, string.format("%s:%s %s", src, ln, rest))
				end
			end
		end
	end
	if #out == 0 then
		return nil
	end
	return table.concat(out, "\n")
end

function S.cleanMessage(v): string
	local msg = if type(v) == "string" then v else tostring(v)
	msg = string.gsub(msg, "^runtime error: ", "")
	msg = string.gsub(msg, "^syntax error: ", "")
	-- mlua appends its own traceback to errors that crossed a Rust boundary
	for _, marker in { "\nstack traceback:", "\n[Stack Begin]" } do
		local cut = string.find(msg, marker, 1, true)
		if cut then
			msg = string.sub(msg, 1, cut - 1)
		end
	end
	return msg
end

-- Lune's datatypes (Color3, Vector3, UDim2, ...) raise errors as an "error"
-- userdata whose tostring carries "runtime error: " and a traceback. Roblox code
-- always sees a string such as "Script:1: message": convert it.
function S.normalizeError(e)
	if type(e) ~= "userdata" or typeof(e) ~= "error" then
		return e
	end
	local full = tostring(e)
	local first = string.match(full, "^[^\n]*") or full
	first = string.gsub(first, "^runtime error: ", "")
	first = string.gsub(first, "^callback error: ", "")
	if string.match(first, "^[^:]+:%d+: ") then
		return first
	end
	for line in string.gmatch(full, "[^\n]+") do
		local src, ln = string.match(line, "^%s*(.-):(%d+):")
		if src and isGameSource(src) then
			return src .. ":" .. ln .. ": " .. first
		end
	end
	return first
end

function S.worldOf(co)
	local i = info[co]
	return i and i.world
end

function S.reportError(co, value, trace)
	local w = S.worldOf(co)
	if w and w.dead then
		return
	end
	local msg = S.cleanMessage(value)
	if trace == nil and type(value) == "string" then
		local cut = string.find(value, "\nstack traceback:", 1, true)
		if cut then
			trace = string.sub(value, cut + 1)
		end
	end
	H.gameError(if w then w.id else "?", msg, S.formatTrace(trace))
end

-- ── threads ──────────────────────────────────────────────────────────────────
function S.create(fn, world, origin)
	local co
	co = coroutine.create(function(...)
		local r = table.pack(xpcall(fn, function(e)
			threadErr[co] = { value = e, trace = debug.traceback(nil, 2) }
			return e
		end, ...))
		if r[1] then
			return table.unpack(r, 2, r.n)
		end
		return ERR
	end)
	local src = debug.info(origin or fn, "s")
	info[co] = { world = world, src = if src and isGameSource(src) then src else nil }
	return co
end

-- Which script is running now, for tools/run-game.mjs's timeout message: a
-- "@@R world|script" line each time the running (world, script) changes. When
-- a thread never yields, the last such line names it.
local runKey = nil
local function announce(key)
	if key ~= runKey then
		runKey = key
		print("@@R " .. key)
	end
end
local function keyOf(co)
	local i = info[co]
	if not i then
		return "?|?"
	end
	return (if i.world then i.world.id else "?") .. "|" .. (i.src or "?")
end

-- Resume a thread from the engine (scheduler, signal, task.spawn). An error that
-- escapes the thread is reported like Roblox Output does; it never stops the run.
function S.resume(co, ...)
	if coroutine.status(co) ~= "suspended" then
		return false
	end
	local i = info[co]
	if i then
		if i.world and i.world.dead then
			return false
		end
		i.token = nil
		i.waiting = nil
	end
	local running = coroutine.running()
	local outer = if info[running] then keyOf(running) else "-|engine"
	announce(keyOf(co))
	local r = table.pack(coroutine.resume(co, ...))
	announce(outer)
	if not r[1] then
		S.reportError(co, r[2], nil)
	elseif r[2] == ERR and coroutine.status(co) == "dead" then
		local e = threadErr[co]
		threadErr[co] = nil
		if e then
			S.reportError(co, e.value, e.trace)
		end
	end
	return true
end

function S.spawn(fn, world, ...)
	local co = S.create(fn, world)
	S.resume(co, ...)
	return co
end

-- ── suspending ───────────────────────────────────────────────────────────────
-- A waker identifies one suspension of one thread; waking a stale waker (the
-- thread was cancelled or resumed by something else) does nothing.
function S.suspend(desc)
	local co = coroutine.running()
	local i = info[co]
	if not i then
		i = {}
		info[co] = i
	end
	seq += 1
	i.token = seq
	i.waiting = desc
	return { co = co, token = seq }
end

function S.valid(w): boolean
	local i = info[w.co]
	return i ~= nil and i.token == w.token and coroutine.status(w.co) == "suspended"
end

function S.wake(w, ...)
	if S.valid(w) then
		S.resume(w.co, ...)
	end
end

function S.wakeDeferred(w, ...)
	dTail += 1
	deferq[dTail] = { w = w, args = table.pack(...) }
end

function S.deferThread(co, ...)
	local i = info[co]
	if not i then
		i = {}
		info[co] = i
	end
	seq += 1
	i.token = seq
	dTail += 1
	deferq[dTail] = { w = { co = co, token = seq }, args = table.pack(...) }
end

function S.sleep(w, seconds: number, args)
	seq += 1
	table.insert(sleepers, { w = w, at = S.clock + math.max(seconds or 0, 0), seq = seq, args = args })
end

function S.delayThread(co, seconds: number, args)
	local i = info[co]
	if not i then
		i = {}
		info[co] = i
	end
	seq += 1
	i.token = seq
	S.sleep({ co = co, token = seq }, seconds, args)
end

-- task.wait / wait: yield the running thread for `seconds` of simulated time.
function S.waitFor(seconds: number?): number
	local start = S.clock
	local w = S.suspend(nil)
	S.sleep(w, seconds or 0)
	coroutine.yield()
	return S.clock - start
end

-- Engine signal handler: Deferred signal behaviour (Roblox default) queues it.
function S.runHandler(fn, world, args, origin)
	local co = S.create(fn, world, origin)
	if H.options.signalBehavior == "immediate" then
		S.resume(co, table.unpack(args, 1, args.n))
	else
		S.deferThread(co, table.unpack(args, 1, args.n))
	end
end

function S.flush()
	local n = 0
	while dHead <= dTail do
		local e = deferq[dHead]
		deferq[dHead] = nil
		dHead += 1
		if S.valid(e.w) then
			S.resume(e.w.co, table.unpack(e.args, 1, e.args.n))
		end
		n += 1
		if n > 500000 then
			H.harnessError("the deferred thread queue did not drain (500000 resumes in one frame)")
			deferq = {}
			dHead, dTail = 1, 0
			return
		end
	end
end

-- Run one simulated frame.
S.frameHooks = {} -- { phase = "render"|"stepped"|"heartbeat", fn = function(dt) }
function S.step()
	S.frame += 1
	S.clock = S.frame * S.FRAME
	if S.frame % 60 == 0 then
		-- progress for tools/run-game.mjs's watchdog (it stops a run only when
		-- no progress is seen for --timeout ms)
		print("@@T " .. S.frame // 60)
	end
	S.intra = 0
	for _, hook in S.frameHooks do
		if hook.phase ~= "heartbeat" then
			hook.fn(S.FRAME)
			S.flush()
		end
	end
	-- resume sleepers that are due, in wake-time order
	local due, keep = {}, {}
	for _, s in sleepers do
		if s.at <= S.clock + 1e-9 then
			table.insert(due, s)
		else
			table.insert(keep, s)
		end
	end
	sleepers = keep
	table.sort(due, function(a, b)
		if a.at ~= b.at then
			return a.at < b.at
		end
		return a.seq < b.seq
	end)
	for _, s in due do
		if S.valid(s.w) then
			if s.args then
				S.resume(s.w.co, table.unpack(s.args, 1, s.args.n))
			else
				S.resume(s.w.co)
			end
			S.flush()
		end
	end
	for _, hook in S.frameHooks do
		if hook.phase == "heartbeat" then
			hook.fn(S.FRAME)
			S.flush()
		end
	end
end

function S.advance(seconds: number)
	local target = S.frame + math.max(1, math.floor(seconds / S.FRAME + 0.5))
	while S.frame < target do
		S.step()
	end
end

-- Threads still blocked on something that can never happen by itself.
function S.blocked()
	local out = {}
	for co, i in info do
		if i.waiting and i.token and coroutine.status(co) == "suspended" and not (i.world and i.world.dead) then
			table.insert(out, { co = co, info = i })
		end
	end
	table.sort(out, function(a, b)
		return (a.info.waiting.since or 0) < (b.info.waiting.since or 0)
			or ((a.info.waiting.since or 0) == (b.info.waiting.since or 0) and (a.info.waiting.text or "") < (b.info.waiting.text or ""))
	end)
	return out
end

function S.pendingSleepers(): number
	local n = 0
	for _, s in sleepers do
		if S.valid(s.w) then
			n += 1
		end
	end
	return n
end

return S
