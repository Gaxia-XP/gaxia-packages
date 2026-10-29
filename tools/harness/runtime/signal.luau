--!nocheck
-- RBXScriptSignal / RBXScriptConnection. A raw signal is shared by all worlds;
-- each world gets its own proxy, and each connection remembers its world, so a
-- handler only ever receives values (Instances) of its own world.
local H = require("./state")

local Sig = {}
H.sig = Sig
H.typeNames = setmetatable({}, { __mode = "k" }) -- object -> typeof() name

local proxyRaw = setmetatable({}, { __mode = "k" }) -- signal proxy -> { raw, world }
local connOf = setmetatable({}, { __mode = "k" }) -- connection object -> conn

function Sig.new(name: string, owner)
	return { name = name, conns = {}, owner = owner, proxies = {} }
end

local function disconnect(c)
	if not c.connected then
		return
	end
	c.connected = false
	local list = c.sig.conns
	for i, x in list do
		if x == c then
			table.remove(list, i)
			break
		end
	end
end
Sig.disconnect = disconnect

function Sig.disconnectAll(raw)
	for _, c in table.clone(raw.conns) do
		disconnect(c)
	end
end

local ConnMT = {}
local function connDisconnect(self)
	local c = connOf[self]
	if not c then
		error("Expected ':' not '.' calling member function Disconnect", 2)
	end
	disconnect(c)
end
ConnMT.__index = function(self, key)
	local c = connOf[self]
	if key == "Connected" then
		return c.connected
	elseif key == "Disconnect" or key == "disconnect" then
		return connDisconnect
	end
	error(string.format("%s is not a valid member of RBXScriptConnection", tostring(key)), 2)
end
ConnMT.__newindex = function(_, key)
	error(string.format("%s cannot be assigned to", tostring(key)), 2)
end
ConnMT.__tostring = function()
	return "Connection"
end
ConnMT.__metatable = "The metatable is locked"

local function newConnObject(c)
	local obj = setmetatable({}, ConnMT)
	connOf[obj] = c
	H.typeNames[obj] = "RBXScriptConnection"
	return obj
end

local function selfOf(self, method)
	local p = proxyRaw[self]
	if not p then
		error(string.format("Expected ':' not '.' calling member function %s", method), 3)
	end
	return p.raw, p.world
end

local function connect(self, fn, once)
	local raw, world = selfOf(self, if once then "Once" else "Connect")
	if type(fn) ~= "function" then
		error("Attempt to connect failed: Passed value is not a function", 3)
	end
	local c = { fn = fn, world = world, connected = true, once = once, sig = raw }
	table.insert(raw.conns, c)
	if raw.onConnect then
		raw.onConnect(c)
	end
	return newConnObject(c)
end

local methods = {}
function methods.Connect(self, fn)
	return connect(self, fn, false)
end
methods.connect = methods.Connect
methods.ConnectParallel = methods.Connect
function methods.Once(self, fn)
	return connect(self, fn, true)
end
function methods.Wait(self)
	local raw, world = selfOf(self, "Wait")
	local S = H.sched
	local w = S.suspend({ kind = "signal", text = "Signal " .. raw.name .. ":Wait()", since = S.clock })
	local c = { waker = w, world = world, connected = true, once = true, sig = raw }
	table.insert(raw.conns, c)
	if raw.onConnect then
		raw.onConnect(c)
	end
	return coroutine.yield()
end
methods.wait = methods.Wait

local SigMT = {}
SigMT.__index = function(self, key)
	local m = methods[key]
	if m then
		return m
	end
	error(string.format("%s is not a valid member of RBXScriptSignal", tostring(key)), 2)
end
SigMT.__newindex = function(_, key)
	error(string.format("%s cannot be assigned to", tostring(key)), 2)
end
SigMT.__tostring = function(self)
	return "Signal " .. proxyRaw[self].raw.name
end
SigMT.__metatable = "The metatable is locked"

function Sig.proxy(world, raw)
	local p = raw.proxies[world]
	if p then
		return p
	end
	p = setmetatable({}, SigMT)
	proxyRaw[p] = { raw = raw, world = world }
	H.typeNames[p] = "RBXScriptSignal"
	raw.proxies[world] = p
	return p
end

-- Deliver one firing to one connection. `args` is a packed list in engine form
-- (raw Instances); it is converted to the connection's world here.
function Sig.deliver(c, args)
	if not c.connected or c.world.dead then
		return
	end
	if c.once then
		disconnect(c)
	end
	local converted = H.inst.exportArgs(c.world, args)
	if c.waker then
		if H.options.signalBehavior == "immediate" then
			H.sched.wake(c.waker, table.unpack(converted, 1, converted.n))
		else
			H.sched.wakeDeferred(c.waker, table.unpack(converted, 1, converted.n))
		end
	else
		local fn = c.fn
		H.sched.runHandler(function(...)
			-- a connection disconnected before a deferred handler ran is skipped
			if not c.once and not c.connected then
				return
			end
			return fn(...)
		end, c.world, converted)
	end
end

-- Fire to every connection (optionally only those of `onlyWorld`, and only
-- worlds that can see `subject`, an Instance the event is about).
function Sig.fire(raw, ...)
	if raw == nil or #raw.conns == 0 then
		return
	end
	local args = table.pack(...)
	for _, c in table.clone(raw.conns) do
		if raw.filter == nil or raw.filter(c.world, args) then
			Sig.deliver(c, args)
		end
	end
end

function Sig.fireWorld(raw, world, ...)
	if raw == nil or #raw.conns == 0 then
		return
	end
	local args = table.pack(...)
	for _, c in table.clone(raw.conns) do
		if c.world == world then
			Sig.deliver(c, args)
		end
	end
end

function Sig.fireVisible(raw, subject, ...)
	if raw == nil or #raw.conns == 0 then
		return
	end
	local args = table.pack(...)
	for _, c in table.clone(raw.conns) do
		if H.inst.visible(subject, c.world) then
			Sig.deliver(c, args)
		end
	end
end

function Sig.hasConnections(raw, world): boolean
	if raw == nil then
		return false
	end
	for _, c in raw.conns do
		if world == nil or c.world == world then
			return true
		end
	end
	return false
end

return Sig
