--!nocheck
-- RemoteEvent / UnreliableRemoteEvent / RemoteFunction (cross the client <->
-- server boundary, with Roblox's argument copying) and BindableEvent /
-- BindableFunction (same world only).
local H = require("./state")
local S = require("./sched")
local I = require("./instance")

local wrap, self_ = I.wrap, I.self

-- Copy a value to another world the way Roblox serializes remote arguments:
-- Instances by reference (nil if the receiver cannot see them), tables deep-copied
-- without metatables, functions and threads dropped.
local function copyValue(v, dst, seen, mode)
	local t = type(v)
	if t == "nil" or t == "boolean" or t == "number" or t == "string" or t == "vector" or t == "buffer" then
		return v
	elseif t == "userdata" then
		local raw = I.rawOf(v)
		if raw then
			if mode == "remote" and not I.visible(raw, dst) then
				return nil
			end
			return wrap(dst, raw)
		end
		local tn = H.typeNames[v]
		if tn == "RBXScriptSignal" or tn == "RBXScriptConnection" then
			return nil
		end
		return v
	elseif t == "table" then
		local tn = H.typeNames[v]
		if tn == "RBXScriptSignal" or tn == "RBXScriptConnection" then
			return nil
		end
		if seen[v] then
			if mode == "remote" then
				error("Tables cannot be cyclic", 0)
			end
			return seen[v]
		end
		local out = {}
		seen[v] = out
		for k, val in v do
			local ck = copyValue(k, dst, seen, mode)
			local cv = copyValue(val, dst, seen, mode)
			if ck ~= nil and cv ~= nil then
				out[ck] = cv
			end
		end
		seen[v] = nil
		return out
	elseif t == "function" then
		if mode == "bindable" then
			return v
		end
		return nil
	end
	return nil
end

local function copyArgs(dst, mode, ...)
	local n = select("#", ...)
	local out = { n = n }
	for i = 1, n do
		out[i] = copyValue((select(i, ...)), dst, {}, mode)
	end
	return out
end
H.copyArgs = copyArgs

local function remoteName(raw)
	return I.fullName(raw)
end

local function countRemote(raw, kind, from)
	H.counts.remoteCalls += 1
	H.remoteStats = H.remoteStats or {}
	local key = kind .. " " .. remoteName(raw)
	H.remoteStats[key] = (H.remoteStats[key] or 0) + 1
end

-- Deliver a remote event firing to one world's connections of `sigName`.
-- Roblox queues events that arrive before anything is connected and delivers
-- them to the first connection.
local function deliverRemote(raw, sigName, world, args)
	local s = I.signal(raw, sigName)
	if world.dead then
		return
	end
	if H.sig.hasConnections(s, world) then
		for _, c in table.clone(s.conns) do
			if c.world == world then
				H.sig.deliver(c, args)
			end
		end
	else
		raw.queued = raw.queued or {}
		local key = sigName .. "\0" .. world.id
		raw.queued[key] = raw.queued[key] or {}
		table.insert(raw.queued[key], args)
		if #raw.queued[key] == 257 then
			H.warn(world.id, string.format("Remote event invocation queue exhausted for %s; did you forget to implement %s? (%d events dropped)", I.fullName(raw), sigName, 1))
		end
		if not s.onConnect then
			s.onConnect = function(c)
				local q = raw.queued and raw.queued[sigName .. "\0" .. c.world.id]
				if q and #q > 0 then
					raw.queued[sigName .. "\0" .. c.world.id] = nil
					for i, a in q do
						if i <= 256 then
							H.sig.deliver(c, a)
						end
					end
				end
			end
		end
	end
end

local function later(fn)
	-- network latency: one frame
	H.afterDelay(0, fn)
end

local function clientWorldOf(playerRaw)
	return playerRaw and playerRaw.clientWorld
end

local function checkPlayer(v, method, level)
	local p = I.rawOf(v)
	if p == nil or p.ClassName ~= "Player" then
		error(string.format("%s: player argument must be a Player object", method), level + 1)
	end
	return p
end

local remoteEventMethods = {
	FireServer = function(self, ...)
		local raw, world = self_(self, "FireServer")
		if world.kind ~= "client" then
			error("FireServer can only be called from the client", 2)
		end
		local server = H.worlds.server
		local args = copyArgs(server, "remote", ...)
		countRemote(raw, "FireServer")
		local playerRaw = world.player
		later(function()
			if playerRaw.Parent == nil then
				return
			end
			table.insert(args, 1, playerRaw)
			args.n += 1
			deliverRemote(raw, "OnServerEvent", server, args)
		end)
	end,
	FireClient = function(self, player, ...)
		local raw, world = self_(self, "FireClient")
		if world.kind ~= "server" then
			error("FireClient can only be called from the server", 2)
		end
		local p = checkPlayer(player, "FireClient", 2)
		local cw = clientWorldOf(p)
		countRemote(raw, "FireClient")
		if not cw then
			return
		end
		local args = copyArgs(cw, "remote", ...)
		later(function()
			deliverRemote(raw, "OnClientEvent", cw, args)
		end)
	end,
	FireAllClients = function(self, ...)
		local raw, world = self_(self, "FireAllClients")
		if world.kind ~= "server" then
			error("FireAllClients can only be called from the server", 2)
		end
		countRemote(raw, "FireAllClients")
		for _, cw in H.worldList do
			if cw.kind == "client" and not cw.dead then
				local args = copyArgs(cw, "remote", ...)
				later(function()
					deliverRemote(raw, "OnClientEvent", cw, args)
				end)
			end
		end
	end,
}

I.define("RemoteEvent", { methods = remoteEventMethods })
I.define("UnreliableRemoteEvent", { methods = remoteEventMethods })

-- ── RemoteFunction ───────────────────────────────────────────────────────────
local function callbackProp(name, side)
	return function(raw, world, fn)
		if fn ~= nil and type(fn) ~= "function" then
			error(string.format("%s must be a function", name), 3)
		end
		if side and world.kind ~= side then
			error(string.format("%s can only be implemented on the %s", name, side), 3)
		end
		-- every world sets its own callback (each client has its own copy)
		local key = name .. "\0" .. world.id
		raw.callbacks = raw.callbacks or {}
		raw.callbacks[key] = if fn then { fn = fn, world = world } else nil
		local waiting = raw.callbackWaiters and raw.callbackWaiters[key]
		if fn and waiting then
			raw.callbackWaiters[key] = nil
			for _, go in waiting do
				go()
			end
		end
	end
end
local function callbackGet(name, className)
	return function()
		error(string.format("%s is a callback member of %s; you can only set the callback value, get is not available", name, className), 3)
	end
end
H.callbackProp = callbackProp
H.callbackGet = callbackGet

-- Run `cb` (in its world) with args; then hand results (or the error) to `done`.
local function invokeCallback(cb, args, done)
	S.spawn(function()
		local r = table.pack(xpcall(cb.fn, function(e)
			return { e, debug.traceback(nil, 2) }
		end, table.unpack(args, 1, args.n)))
		if r[1] then
			done(true, table.pack(table.unpack(r, 2, r.n)))
		else
			done(false, r[2])
		end
	end, cb.world)
end

local function whenCallback(raw, name, world, go)
	local key = name .. "\0" .. world.id
	local cb = raw.callbacks and raw.callbacks[key]
	if cb then
		go(cb)
	else
		raw.callbackWaiters = raw.callbackWaiters or {}
		raw.callbackWaiters[key] = raw.callbackWaiters[key] or {}
		table.insert(raw.callbackWaiters[key], function()
			go(raw.callbacks[key])
		end)
	end
end

I.define("RemoteFunction", {
	set = {
		OnServerInvoke = callbackProp("OnServerInvoke", "server"),
		OnClientInvoke = callbackProp("OnClientInvoke", "client"),
	},
	get = {
		OnServerInvoke = callbackGet("OnServerInvoke", "RemoteFunction"),
		OnClientInvoke = callbackGet("OnClientInvoke", "RemoteFunction"),
	},
	methods = {
		InvokeServer = function(self, ...)
			local raw, world = self_(self, "InvokeServer")
			if world.kind ~= "client" then
				error("InvokeServer can only be called from the client", 2)
			end
			local server = H.worlds.server
			local args = copyArgs(server, "remote", ...)
			table.insert(args, 1, world.player)
			args.n += 1
			countRemote(raw, "InvokeServer")
			local w = S.suspend({ kind = "InvokeServer", text = string.format("%s:InvokeServer() waits for the server's OnServerInvoke", I.fullName(raw)), since = S.clock })
			later(function()
				whenCallback(raw, "OnServerInvoke", server, function(cb)
					args[1] = I.export(server, args[1])
					invokeCallback(cb, args, function(ok, res)
						if ok then
							local back = copyArgs(world, "remote", table.unpack(res, 1, res.n))
							later(function()
								S.wake(w, true, back)
							end)
						else
							local msg = S.cleanMessage(res[1])
							H.gameError("server", msg, S.formatTrace(res[2]), "OnServerInvoke")
							later(function()
								S.wake(w, false, msg)
							end)
						end
					end)
				end)
			end)
			local ok, res = coroutine.yield()
			if not ok then
				error(res, 2)
			end
			return table.unpack(res, 1, res.n)
		end,
		InvokeClient = function(self, player, ...)
			local raw, world = self_(self, "InvokeClient")
			if world.kind ~= "server" then
				error("InvokeClient can only be called from the server", 2)
			end
			local p = checkPlayer(player, "InvokeClient", 2)
			local cw = clientWorldOf(p)
			countRemote(raw, "InvokeClient")
			if not cw then
				error("Player has left the game", 2)
			end
			local args = copyArgs(cw, "remote", ...)
			local w = S.suspend({ kind = "InvokeClient", text = string.format("%s:InvokeClient() waits for the client's OnClientInvoke", I.fullName(raw)), since = S.clock })
			later(function()
				whenCallback(raw, "OnClientInvoke", cw, function(cb)
					invokeCallback(cb, args, function(ok, res)
						if ok then
							local back = copyArgs(H.worlds.server, "remote", table.unpack(res, 1, res.n))
							later(function()
								S.wake(w, true, back)
							end)
						else
							local msg = S.cleanMessage(res[1])
							H.gameError(cw.id, msg, S.formatTrace(res[2]), "OnClientInvoke")
							later(function()
								S.wake(w, false, msg)
							end)
						end
					end)
				end)
			end)
			local ok, res = coroutine.yield()
			if not ok then
				error(res, 2)
			end
			return table.unpack(res, 1, res.n)
		end,
	},
})

-- ── Bindables ────────────────────────────────────────────────────────────────
I.define("BindableEvent", {
	methods = {
		Fire = function(self, ...)
			local raw, world = self_(self, "Fire")
			local args = copyArgs(world, "bindable", ...)
			local s = raw.sigs and raw.sigs.Event
			if s then
				H.sig.fireWorld(s, world, table.unpack(args, 1, args.n))
			end
		end,
	},
})

I.define("BindableFunction", {
	set = { OnInvoke = callbackProp("OnInvoke", nil) },
	get = { OnInvoke = callbackGet("OnInvoke", "BindableFunction") },
	methods = {
		Invoke = function(self, ...)
			local raw, world = self_(self, "Invoke")
			local args = copyArgs(world, "bindable", ...)
			local key = "OnInvoke\0" .. world.id
			local cb = raw.callbacks and raw.callbacks[key]
			if cb == nil then
				local w = S.suspend({ kind = "Invoke", text = I.fullName(raw) .. ":Invoke() waits for OnInvoke to be set", since = S.clock })
				whenCallback(raw, "OnInvoke", world, function()
					S.wakeDeferred(w)
				end)
				coroutine.yield()
				cb = raw.callbacks[key]
			end
			local r = table.pack(cb.fn(table.unpack(args, 1, args.n)))
			local back = copyArgs(world, "bindable", table.unpack(r, 1, r.n))
			return table.unpack(back, 1, back.n)
		end,
	},
})

return {}
