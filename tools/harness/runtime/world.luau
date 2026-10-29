--!nocheck
-- Worlds (the server and one per player client): each has its own globals,
-- require cache, _G/shared and Instance proxies. Scripts run in the world that
-- would run them in Roblox, as soon as they are in a place where they run.
local luau = require("@lune/luau")
local H = require("./state")
local S = require("./sched")
local I = require("./instance")
local D = require("./datatypes")

local W = {}
H.world = W
H.worldList = {}

-- ── compile ──────────────────────────────────────────────────────────────────
local function compile(raw, world)
	local env = setmetatable({}, { __index = world.globals })
	env.script = I.wrap(world, raw)
	local name = I.fullName(raw)
	if raw.source == nil then
		return nil, name .. ": the script has no source"
	end
	local ok, fn = pcall(luau.load, raw.source, { debugName = "=" .. name, environment = env, injectGlobals = false })
	if not ok then
		return nil, S.cleanMessage(fn)
	end
	return fn
end

-- ── require ──────────────────────────────────────────────────────────────────
local MODULE_FAILED = "Requested module experienced an error while loading"

function W.require(world, raw)
	local rec = world.modules[raw]
	while rec and rec.state == "loading" do
		if rec.thread == coroutine.running() then
			error("Requested module was required recursively", 3)
		end
		local w = S.suspend({ kind = "require", text = "require(" .. I.fullName(raw) .. ") waits for the module to finish loading", since = S.clock })
		table.insert(rec.waiters, w)
		coroutine.yield()
		rec = world.modules[raw]
	end
	if rec then
		if rec.state == "done" then
			return rec.value
		end
		error(rec.message or MODULE_FAILED, 3)
	end
	rec = { state = "loading", waiters = {}, thread = coroutine.running() }
	world.modules[raw] = rec
	local function finish(state, value, message)
		rec.state = state
		rec.value = value
		rec.message = message
		for _, w in rec.waiters do
			S.wakeDeferred(w)
		end
		rec.waiters = {}
	end
	local fn, err = compile(raw, world)
	if not fn then
		H.gameError(world.id, err, nil, "require")
		finish("error", nil, MODULE_FAILED)
		error(MODULE_FAILED, 3)
	end
	local r = table.pack(xpcall(fn, function(e)
		return { e, debug.traceback(nil, 2) }
	end))
	if not r[1] then
		local e = r[2]
		H.gameError(world.id, S.cleanMessage(e[1]), S.formatTrace(e[2]), "require")
		finish("error", nil, MODULE_FAILED)
		error(MODULE_FAILED, 3)
	end
	if r.n ~= 2 then
		local msg = "Module code did not return exactly one value"
		finish("error", nil, msg)
		error(msg, 3)
	end
	finish("done", r[2])
	return r[2]
end

-- ── globals ──────────────────────────────────────────────────────────────────
local function joinArgs(...)
	local n = select("#", ...)
	local parts = table.create(n)
	for i = 1, n do
		parts[i] = D.tostring((select(i, ...)))
	end
	return table.concat(parts, " ")
end

local function callerSource(level: number): string?
	for l = level, level + 6 do
		local src, line = debug.info(l, "sl")
		if src == nil then
			return nil
		end
		if S.isGameSource(src) then
			return src .. ":" .. tostring(line)
		end
	end
	return nil
end

local START_TIME = nil

function W.makeGlobals(world)
	local g = {}
	g.assert, g.error, g.ipairs, g.next, g.pairs, g.pcall = assert, error, ipairs, next, pairs, pcall
	g.rawequal, g.rawget, g.rawlen, g.rawset, g.select = rawequal, rawget, rawlen, rawset, select
	g.setmetatable, g.getmetatable, g.tonumber, g.xpcall, g.newproxy = setmetatable, getmetatable, tonumber, xpcall, newproxy
	g.gcinfo, g.getfenv, g.setfenv, g.type = gcinfo, getfenv, setfenv, type
	g.unpack = table.unpack
	g.ypcall = pcall
	g.string, g.table, g.utf8, g.bit32, g.buffer = string, table, utf8, bit32, buffer
	g.vector = vector
	g._VERSION = "Luau"
	g.math = D.makeMath(#H.worldList)
	local dbg = table.clone(debug)
	dbg.profilebegin = function() end
	dbg.profileend = function() end
	dbg.setmemorycategory = function() end
	dbg.resetmemorycategory = function() end
	dbg.getmemorycategory = function()
		return "Default"
	end
	dbg.dumpcodesize = function() end
	g.debug = dbg
	g.collectgarbage = function(opt)
		if opt == "count" then
			return gcinfo()
		end
		error("collectgarbage must be called with 'count'; use gcinfo() instead", 2)
	end
	g.loadstring = function()
		return nil, "loadstring() is not available"
	end
	g.typeof = H.typeof
	g.tostring = D.tostring

	-- coroutine: threads made here keep Roblox error semantics (a table error
	-- stays a table) and belong to this world's scheduler
	local co = table.clone(coroutine)
	co.create = function(f)
		if type(f) ~= "function" then
			error("invalid argument #1 to 'create' (function expected, got " .. H.typeof(f) .. ")", 2)
		end
		return S.create(f, world)
	end
	local function finishResume(thread, r)
		if not r[1] then
			return false, S.cleanMessage(r[2])
		end
		if r[2] == S.ERR and coroutine.status(thread) == "dead" then
			local e = S.threadErr[thread]
			S.threadErr[thread] = nil
			return false, if e then e.value else "error"
		end
		return table.unpack(r, 1, r.n)
	end
	co.resume = function(thread, ...)
		local i = S.info[thread]
		if i then
			i.token = nil
			i.waiting = nil
		end
		return finishResume(thread, table.pack(coroutine.resume(thread, ...)))
	end
	co.wrap = function(f)
		if type(f) ~= "function" then
			error("invalid argument #1 to 'wrap' (function expected, got " .. H.typeof(f) .. ")", 2)
		end
		local thread = S.create(f, world)
		return function(...)
			local i = S.info[thread]
			if i then
				i.token = nil
				i.waiting = nil
			end
			local r = table.pack(finishResume(thread, table.pack(coroutine.resume(thread, ...))))
			if r[1] == false then
				error(r[2], 0)
			end
			return table.unpack(r, 2, r.n)
		end
	end
	g.coroutine = co

	-- task library + legacy scheduling globals
	local task = {}
	task.spawn = function(f, ...)
		if type(f) == "thread" then
			S.resume(f, ...)
			return f
		end
		if type(f) ~= "function" then
			error("invalid argument #1 to 'spawn' (function or thread expected)", 2)
		end
		return S.spawn(f, world, ...)
	end
	task.defer = function(f, ...)
		local thread = f
		if type(f) == "function" then
			thread = S.create(f, world)
		elseif type(f) ~= "thread" then
			error("invalid argument #1 to 'defer' (function or thread expected)", 2)
		end
		S.deferThread(thread, ...)
		return thread
	end
	task.delay = function(t, f, ...)
		local thread = f
		if type(f) == "function" then
			thread = S.create(f, world)
		elseif type(f) ~= "thread" then
			error("invalid argument #2 to 'delay' (function or thread expected)", 2)
		end
		S.delayThread(thread, tonumber(t) or 0, table.pack(...))
		return thread
	end
	task.wait = function(t)
		if t ~= nil and type(t) ~= "number" then
			error("invalid argument #1 to 'wait' (number expected, got " .. H.typeof(t) .. ")", 2)
		end
		return S.waitFor(t)
	end
	task.cancel = function(thread)
		if type(thread) ~= "thread" then
			error("invalid argument #1 to 'cancel' (thread expected)", 2)
		end
		local i = S.info[thread]
		if i then
			i.token = nil
			i.waiting = nil
		end
		if coroutine.status(thread) == "running" then
			error("cannot cancel thread", 2)
		end
		pcall(coroutine.close, thread)
	end
	task.synchronize = function() end
	task.desynchronize = function() end
	g.task = task
	g.wait = function(t)
		local e = S.waitFor(math.max(tonumber(t) or 0, 0.03))
		return e, S.clock
	end
	g.Wait = g.wait
	g.delay = function(t, f)
		return task.delay(math.max(tonumber(t) or 0, 0.03), f)
	end
	g.Delay = g.delay
	g.spawn = function(f)
		return task.delay(0.03, f)
	end
	g.Spawn = g.spawn
	g.tick = function()
		return H.epoch() + S.clock + S.intra
	end
	g.time = function()
		return S.clock
	end
	g.elapsedTime = g.time
	g.ElapsedTime = g.time
	g.os = {
		time = function(t)
			if t ~= nil then
				return os.time(t)
			end
			return math.floor(H.epoch() + S.clock)
		end,
		-- Roblox's os.clock() counts from process start, so it is already large
		-- when a game starts (code like `os.clock() - 0 > cooldown` relies on it)
		clock = function()
			S.intra = math.min(S.intra + 1e-6, S.FRAME * 0.5)
			return 1000 + S.clock + S.intra
		end,
		date = function(fmt, t)
			return os.date(fmt, t or math.floor(H.epoch() + S.clock))
		end,
		difftime = os.difftime,
	}

	-- output
	g.print = function(...)
		local text = joinArgs(...)
		H.print(world.id, text, callerSource(2))
		if H.onOutput then
			H.onOutput(world, text, "MessageOutput")
		end
	end
	g.warn = function(...)
		local text = joinArgs(...)
		H.warn(world.id, text, callerSource(2))
		if H.onOutput then
			H.onOutput(world, text, "MessageWarning")
		end
	end
	g.printidentity = function(prefix)
		H.print(world.id, (prefix or "Current identity is") .. " 2", callerSource(2))
	end
	g.version = function()
		return "0.700.0.7000000"
	end

	-- Roblox world
	g.require = function(m)
		if type(m) == "number" then
			H.note("unmodeled require(assetId) — the harness cannot load modules from the website")
			error("require(assetId) cannot load from the website in the harness", 2)
		end
		if type(m) == "string" then
			H.note("unmodeled require(\"path\") (string require)")
			error("Attempted to call require with invalid argument(s).", 2)
		end
		local raw = I.rawOf(m)
		if raw == nil or raw.ClassName ~= "ModuleScript" then
			error("Attempted to call require with invalid argument(s).", 2)
		end
		return W.require(world, raw)
	end
	g.game = I.wrap(world, H.game)
	g.Game = g.game
	g.workspace = I.wrap(world, I.service("Workspace"))
	g.Workspace = g.workspace
	g._G = world.G
	g.shared = world.shared
	g.plugin = nil
	g.settings = function()
		return I.wrap(world, H.settingsRaw)
	end
	g.UserSettings = function()
		return I.wrap(world, H.userSettingsRaw)
	end
	g.stats = function()
		return I.wrap(world, I.service("Stats"))
	end
	g.Stats = g.stats

	g.Instance = {
		new = function(className, parent)
			if type(className) ~= "string" then
				error("invalid argument #1 to 'new' (string expected, got " .. H.typeof(className) .. ")", 2)
			end
			local cls = I.class(className)
			if cls.known and (cls.notCreatable or cls.service) then
				error(string.format("Unable to create an Instance of type \"%s\"", className), 2)
			end
			if not cls.known then
				H.note("unmodeled class " .. className .. " (generic instance that accepts any property)")
			end
			local raw = I.new(className, H.ownerFor(world))
			if parent ~= nil then
				local p = I.rawOf(parent)
				if p == nil then
					error("invalid argument #2 to 'new' (Instance expected, got " .. H.typeof(parent) .. ")", 2)
				end
				I.setParent(raw, p)
			end
			return I.wrap(world, raw)
		end,
		fromExisting = function(inst)
			local raw = I.rawOf(inst)
			if raw == nil then
				error("invalid argument #1 to 'fromExisting' (Instance expected)", 2)
			end
			local copy = I.new(raw.ClassName, H.ownerFor(world))
			copy.Name = raw.Name
			copy.props = table.clone(raw.props)
			copy.attrs = table.clone(raw.attrs)
			return I.wrap(world, copy)
		end,
	}
	for _, name in { "Vector3", "Vector2", "CFrame", "Color3", "UDim", "UDim2", "NumberSequence", "NumberSequenceKeypoint",
		"ColorSequence", "ColorSequenceKeypoint", "NumberRange", "Rect", "BrickColor", "Ray", "Region3", "Region3int16",
		"Vector3int16", "Vector2int16", "Font", "Faces", "Axes", "PhysicalProperties", "TweenInfo", "Random", "DateTime",
		"RaycastParams", "OverlapParams", "Enum" } do
		g[name] = D[name]
	end
	g.PathWaypoint = {
		new = function(pos, action, label)
			return { Position = pos, Action = action, Label = label or "" }
		end,
	}
	g.SharedTable = setmetatable({}, {
		__index = function()
			H.note("unmodeled SharedTable")
			return nil
		end,
	})
	return g
end

function W.new(id: string, kind: string, player)
	local world = { id = id, kind = kind, player = player, proxies = {}, modules = {}, G = {}, shared = {} }
	H.worlds[id] = world
	table.insert(H.worldList, world)
	world.globals = W.makeGlobals(world)
	return world
end

-- ── running scripts ──────────────────────────────────────────────────────────
function W.runScript(raw, world)
	raw.ran = raw.ran or {}
	if raw.ran[world] then
		return
	end
	raw.ran[world] = true
	local fn, err = compile(raw, world)
	if not fn then
		H.gameError(world.id, err, nil, "compile")
		return
	end
	H.emit({ t = "script", world = world.id, name = I.fullName(raw), time = S.clock })
	local co = S.create(fn, world)
	S.deferThread(co)
end

local function enabled(raw): boolean
	return raw.props.Enabled ~= false and raw.props.Disabled ~= true
end

local function under(raw, service): boolean
	return service ~= nil and I.isDescendantOf(raw, service)
end

-- The player whose client runs LocalScripts inside `raw` (PlayerGui, Backpack,
-- PlayerScripts, or the player's character), else nil.
local function clientOwner(raw)
	local p = raw.Parent
	while p do
		if p.ClassName == "Player" then
			return p
		end
		if p.ClassName == "Model" and H.playerFromCharacter then
			local plr = H.playerFromCharacter(p)
			if plr then
				return plr
			end
		end
		p = p.Parent
	end
	return nil
end

local function considerScript(r)
	if not H.running or not enabled(r) or r.source == nil then
		return
	end
	if not I.inGame(r) then
		return
	end
	local cls = r.ClassName
	if cls == "Script" then
		local ctx = r.props.RunContext
		local ctxName = if ctx then tostring(ctx.Name) else "Legacy"
		if ctxName == "Client" then
			for _, w in H.worldList do
				if w.kind == "client" and not w.dead and I.visible(r, w) then
					W.runScript(r, w)
				end
			end
			return
		end
		if r.owner ~= nil then
			return
		end
		local ok = if ctxName == "Server"
			then not under(r, I.service("ServerStorage"))
			else under(r, I.service("Workspace")) or under(r, I.service("ServerScriptService"))
		if ok then
			W.runScript(r, H.worlds.server)
		end
	elseif cls == "LocalScript" then
		local plr = clientOwner(r)
		if plr and plr.clientWorld and not plr.clientWorld.dead and I.visible(r, plr.clientWorld) then
			if under(r, I.service("Players")) or (plr.props.Character and I.isDescendantOf(r, plr.props.Character)) then
				W.runScript(r, plr.clientWorld)
			end
		end
	end
end
W.considerScript = considerScript

function W.considerTree(raw)
	considerScript(raw)
	for _, d in I.descendants(raw) do
		considerScript(d)
	end
end

H.onParented = function(raw)
	if H.running then
		W.considerTree(raw)
	end
end
H.onScriptEnabled = function(raw)
	considerScript(raw)
end

return W
