--!nocheck
-- Online services, in memory: DataStoreService, MemoryStoreService,
-- MessagingService, MarketplaceService, TeleportService, HttpService.
-- Every call is counted; --datastore fail|studio-off makes DataStore calls error,
-- --memorystore fail makes MemoryStore calls error.
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local H = require("./state")
local S = require("./sched")
local I = require("./instance")
local D = require("./datatypes")

local wrap, self_ = I.wrap, I.self
local Enum = roblox.Enum
local asyncYield = function()
	H.asyncYield()
end

-- ── value checks / copies ────────────────────────────────────────────────────
-- Returns nil when `v` can be saved, else Roblox's error message. It never
-- raises itself, so the caller raises once at the right level (the game line).
-- Roblox serializes a value to JSON: a table must be a pure array (1..n, no
-- holes) or a dictionary with only string keys.
-- (Message texts follow Roblox's "104: Cannot store X in data store" pattern;
-- confirm the exact wording in Studio before matching on it.)
local function storableErr(v, path, seen)
	local t = type(v)
	if t == "nil" or t == "boolean" or t == "string" then
		return nil
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			return "104: Cannot store " .. tostring(v) .. " in data store. Data stores can only accept valid UTF-8 characters."
		end
		return nil
	elseif t == "table" then
		if seen[v] then
			return "104: Cannot store a cyclic table in data store."
		end
		if getmetatable(v) ~= nil and H.typeNames[v] then
			return string.format("104: Cannot store %s in data store. Data stores can only accept valid UTF-8 characters.", H.typeof(v))
		end
		seen[v] = true
		local n = rawlen(v)
		local count, strKeys, numKeys = 0, 0, 0
		for k in v do
			count += 1
			if type(k) == "string" then
				strKeys += 1
			elseif type(k) == "number" then
				numKeys += 1
			else
				seen[v] = nil
				return "104: Cannot store Dictionary in data store. Data stores can only accept valid UTF-8 characters. (key of type " .. H.typeof(k) .. " at " .. path .. ")"
			end
		end
		if strKeys > 0 and numKeys > 0 then
			seen[v] = nil
			return "104: Cannot store Array in data store. Data stores can only accept valid UTF-8 characters. (" .. path .. " mixes number and string keys)"
		end
		if numKeys > 0 and (numKeys ~= n or count ~= n) then
			seen[v] = nil
			return "104: Cannot store Array in data store. Data stores can only accept valid UTF-8 characters. (" .. path
				.. " has number keys that are not 1, 2, 3, ... with no gaps; use string keys such as tostring(id))"
		end
		for k, x in v do
			local e = storableErr(x, path .. "." .. tostring(k), seen)
			if e then
				seen[v] = nil
				return e
			end
		end
		seen[v] = nil
		return nil
	end
	return string.format("104: Cannot store %s in data store. Data stores can only accept valid UTF-8 characters. (at %s)", H.typeof(v), path)
end

local MAX_VALUE_CHARS = 4194304
local function checkStorable(v, key, level)
	local e = storableErr(v, key, {})
	if e then
		error(e, level + 1)
	end
	local ok, encoded = pcall(serde.encode, "json", v)
	if ok and #encoded > MAX_VALUE_CHARS then
		error(string.format("105: Serialized value converted byte size exceeds max size 4194304 bytes (%d)", #encoded), level + 1)
	end
end

local function deepCopy(v)
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = deepCopy(x)
	end
	return out
end

local function checkKey(key, level)
	if type(key) == "number" then
		key = tostring(key)
	end
	if type(key) ~= "string" then
		error("Argument 1 missing or nil", level)
	end
	if key == "" then
		error("Key name can't be empty", level)
	end
	if #key > 50 then
		error("Key name exceeds the 50 character limit.", level)
	end
	return key
end

-- ── DataStoreService ─────────────────────────────────────────────────────────
local stores = {} -- "kind\0name\0scope" -> { entries = { key -> { value, version, created, updated, userIds, metadata } } }
H.dataStores = stores

local function dsCall(storeRaw, op, key, level)
	H.counts.dataStoreCalls += 1
	H.dsStats = H.dsStats or {}
	H.dsStats[op] = (H.dsStats[op] or 0) + 1
	if H.counts.dataStoreCalls <= 300 then
		H.record("datastore", { op = op, store = storeRaw and storeRaw.storeName, key = key })
	end
	local mode = H.options.dataStore
	asyncYield()
	if mode == "fail" then
		error("503: DataStore request failed (simulated by the harness: --datastore fail)", level)
	elseif mode == "studio-off" then
		-- what Studio says when "Enable Studio Access to API Services" is off
		error("403: Cannot write to DataStore from studio if API access is not enabled.", level)
	end
end

local function storeData(kind, name, scope)
	local id = kind .. "\0" .. name .. "\0" .. (scope or "global")
	local s = stores[id]
	if not s then
		s = { entries = {}, kind = kind, name = name }
		stores[id] = s
	end
	return s
end

local function makeKeyInfo(world, e)
	local ki = I.new("DataStoreKeyInfo", nil)
	ki.props.Version = e and e.version or ""
	ki.props.CreatedTime = e and e.created or 0
	ki.props.UpdatedTime = e and e.updated or 0
	ki.userIds = e and e.userIds or {}
	ki.metadata = e and e.metadata or {}
	return wrap(world, ki)
end
I.define("DataStoreKeyInfo", {
	methods = {
		GetUserIds = function(self)
			local raw = self_(self, "GetUserIds")
			return table.clone(raw.userIds)
		end,
		GetMetadata = function(self)
			local raw = self_(self, "GetMetadata")
			return table.clone(raw.metadata)
		end,
	},
})

local versionCounter = 0
local function write(s, key, value, userIds, metadata)
	versionCounter += 1
	local now = math.floor((H.epoch() + S.clock) * 1000)
	local e = s.entries[key]
	if value == nil then
		s.entries[key] = nil
		return nil
	end
	local created = if e then e.created else now
	e = { value = deepCopy(value), version = "v" .. versionCounter, created = created, updated = now, userIds = userIds or (e and e.userIds) or {}, metadata = metadata or {} }
	s.entries[key] = e
	return e
end

local function makePages(world, pages)
	local p = I.new("DataStorePages", nil)
	p.pages = pages
	p.index = 1
	p.props.IsFinished = #pages <= 1
	return wrap(world, p)
end
I.define("Pages", {
	methods = {
		GetCurrentPage = function(self)
			local raw = self_(self, "GetCurrentPage")
			return deepCopy(raw.pages[raw.index] or {})
		end,
		AdvanceToNextPageAsync = function(self)
			local raw = self_(self, "AdvanceToNextPageAsync")
			asyncYield()
			if raw.index >= #raw.pages then
				error("No more pages", 2)
			end
			raw.index += 1
			I.setProp(raw, "IsFinished", raw.index >= #raw.pages)
		end,
	},
	get = {
		IsFinished = function(raw)
			return raw.props.IsFinished == true
		end,
	},
})

local dsMethods = {
	GetAsync = function(self, key, options)
		local raw, world = self_(self, "GetAsync")
		key = checkKey(key, 3)
		dsCall(raw, "GetAsync", key, 3)
		local e = raw.data.entries[key]
		if e == nil then
			return nil, nil
		end
		return deepCopy(e.value), makeKeyInfo(world, e)
	end,
	SetAsync = function(self, key, ...)
		local value, userIds, options = ...
		local raw, world = self_(self, "SetAsync")
		key = checkKey(key, 3)
		if select("#", ...) < 1 then
			error("Argument 2 missing or nil", 2)
		end
		checkStorable(value, key, 2)
		dsCall(raw, "SetAsync", key, 3)
		local e = write(raw.data, key, value, userIds, options and options.metadata)
		return e and e.version or ""
	end,
	UpdateAsync = function(self, key, transform)
		local raw, world = self_(self, "UpdateAsync")
		key = checkKey(key, 3)
		if type(transform) ~= "function" then
			error("Argument 2 missing or nil", 2)
		end
		dsCall(raw, "UpdateAsync", key, 3)
		local e = raw.data.entries[key]
		-- the transform function must not yield (Roblox: "Callbacks cannot yield")
		local co = coroutine.create(transform)
		local r = table.pack(coroutine.resume(co, deepCopy(e and e.value), if e then makeKeyInfo(world, e) else nil))
		if not r[1] then
			error(S.cleanMessage(r[2]), 0)
		end
		if coroutine.status(co) ~= "dead" then
			local i = S.info[co]
			if i then
				i.token = nil
				i.waiting = nil
			end
			error("UpdateAsync: Callbacks cannot yield", 2)
		end
		local newValue, userIds, metadata = r[2], r[3], r[4]
		if newValue == nil then
			return nil, nil
		end
		checkStorable(newValue, key, 2)
		local ne = write(raw.data, key, newValue, userIds, metadata)
		return deepCopy(ne.value), makeKeyInfo(world, ne)
	end,
	RemoveAsync = function(self, key)
		local raw, world = self_(self, "RemoveAsync")
		key = checkKey(key, 3)
		dsCall(raw, "RemoveAsync", key, 3)
		local e = raw.data.entries[key]
		raw.data.entries[key] = nil
		if e == nil then
			return nil, nil
		end
		return deepCopy(e.value), makeKeyInfo(world, e)
	end,
	IncrementAsync = function(self, key, delta, userIds)
		local raw, world = self_(self, "IncrementAsync")
		key = checkKey(key, 3)
		delta = delta or 1
		if type(delta) ~= "number" then
			error("IncrementAsync: delta must be a number", 2)
		end
		dsCall(raw, "IncrementAsync", key, 3)
		local e = raw.data.entries[key]
		local cur = if e then e.value else 0
		if type(cur) ~= "number" then
			error("IncrementAsync: the stored value is not a number", 2)
		end
		local ne = write(raw.data, key, math.floor(cur + delta), userIds)
		return ne.value, makeKeyInfo(world, ne)
	end,
	GetVersionAsync = function(self, key, version)
		local raw, world = self_(self, "GetVersionAsync")
		dsCall(raw, "GetVersionAsync", key, 3)
		local e = raw.data.entries[key]
		if e and e.version == version then
			return deepCopy(e.value), makeKeyInfo(world, e)
		end
		return nil, nil
	end,
	GetVersionAtTimeAsync = function(self, key)
		local raw, world = self_(self, "GetVersionAtTimeAsync")
		dsCall(raw, "GetVersionAtTimeAsync", key, 3)
		local e = raw.data.entries[key]
		return if e then deepCopy(e.value) else nil, if e then makeKeyInfo(world, e) else nil
	end,
	ListKeysAsync = function(self, prefix, pageSize)
		local raw, world = self_(self, "ListKeysAsync")
		dsCall(raw, "ListKeysAsync", prefix, 3)
		local keys = {}
		for k in raw.data.entries do
			if prefix == nil or string.sub(k, 1, #prefix) == prefix then
				table.insert(keys, k)
			end
		end
		table.sort(keys)
		local page = {}
		for _, k in keys do
			local ki = I.new("DataStoreKey", nil)
			ki.props.KeyName = k
			table.insert(page, wrap(world, ki))
		end
		return makePages(world, { page })
	end,
	ListVersionsAsync = function(self, key)
		local raw, world = self_(self, "ListVersionsAsync")
		dsCall(raw, "ListVersionsAsync", key, 3)
		return makePages(world, { {} })
	end,
	RemoveVersionAsync = function(self, key)
		local raw = self_(self, "RemoveVersionAsync")
		dsCall(raw, "RemoveVersionAsync", key, 3)
	end,
	OnUpdate = function(self, key, fn)
		local raw, world = self_(self, "OnUpdate")
		H.note("unmodeled GlobalDataStore:OnUpdate (deprecated; never fires)")
		return H.sig.proxy(world, H.sig.new("OnUpdate")):Connect(fn)
	end,
}

I.define("GlobalDataStore", { methods = dsMethods })

I.define("OrderedDataStore", {
	methods = {
		SetAsync = function(self, key, value)
			local raw = self_(self, "SetAsync")
			key = checkKey(key, 3)
			if value ~= nil and (type(value) ~= "number" or value ~= math.floor(value)) then
				error("105: Serialization error: OrderedDataStore values must be integers", 2)
			end
			dsCall(raw, "SetAsync", key, 3)
			write(raw.data, key, value)
			return ""
		end,
		GetSortedAsync = function(self, ascending, pageSize, minValue, maxValue)
			local raw, world = self_(self, "GetSortedAsync")
			if type(pageSize) ~= "number" or pageSize < 1 or pageSize > 100 then
				error("GetSortedAsync: pageSize must be between 1 and 100", 2)
			end
			dsCall(raw, "GetSortedAsync", nil, 3)
			local list = {}
			for k, e in raw.data.entries do
				local v = e.value
				if (minValue == nil or v >= minValue) and (maxValue == nil or v <= maxValue) then
					table.insert(list, { key = k, value = v })
				end
			end
			table.sort(list, function(a, b)
				if a.value ~= b.value then
					if ascending then
						return a.value < b.value
					end
					return a.value > b.value
				end
				return a.key < b.key
			end)
			local pages, cur = {}, {}
			for _, item in list do
				table.insert(cur, item)
				if #cur >= pageSize then
					table.insert(pages, cur)
					cur = {}
				end
			end
			if #cur > 0 or #pages == 0 then
				table.insert(pages, cur)
			end
			return makePages(world, pages)
		end,
	},
})

local function newStore(world, className, kind, name, scope)
	local raw = I.new(className, nil)
	raw.Name = name
	raw.storeName = name
	raw.data = storeData(kind, name, scope)
	return wrap(world, raw)
end

I.define("DataStoreService", {
	methods = {
		GetDataStore = function(self, name, scope, options)
			local _, world = self_(self, "GetDataStore")
			if type(name) ~= "string" then
				error("Argument 1 missing or nil", 2)
			end
			if world.kind ~= "server" then
				error("DataStore can't be accessed from client", 2)
			end
			if #name > 50 then
				error("DataStore name exceeds the 50 character limit.", 2)
			end
			return newStore(world, "DataStore", "ds", name, scope)
		end,
		GetGlobalDataStore = function(self)
			local _, world = self_(self, "GetGlobalDataStore")
			if world.kind ~= "server" then
				error("DataStore can't be accessed from client", 2)
			end
			return newStore(world, "DataStore", "ds", "__global", nil)
		end,
		GetOrderedDataStore = function(self, name, scope)
			local _, world = self_(self, "GetOrderedDataStore")
			if type(name) ~= "string" then
				error("Argument 1 missing or nil", 2)
			end
			if world.kind ~= "server" then
				error("DataStore can't be accessed from client", 2)
			end
			return newStore(world, "OrderedDataStore", "ods", name, scope)
		end,
		GetRequestBudgetForRequestType = function()
			return 100
		end,
		ListDataStoresAsync = function(self)
			local _, world = self_(self, "ListDataStoresAsync")
			asyncYield()
			return makePages(world, { {} })
		end,
	},
	defaults = { AutomaticRetry = true },
})

-- ── MemoryStoreService ───────────────────────────────────────────────────────
local memory = {} -- "kind\0name" -> data
local function mem(kind, name)
	local id = kind .. "\0" .. name
	memory[id] = memory[id] or { items = {}, queue = {} }
	return memory[id]
end
local function memCall(op)
	H.counts.memoryStoreCalls = (H.counts.memoryStoreCalls or 0) + 1
	asyncYield()
	if H.options.memoryStore == "fail" then
		-- an unpublished place / Studio API access off (--memorystore fail)
		error("MemoryStore request failed: the experience is not published or API access is off (simulated by the harness: --memorystore fail)", 3)
	end
end
local function alive(e)
	return e and (e.expires == nil or e.expires > S.clock)
end

I.define("MemoryStoreSortedMap", {
	methods = {
		SetAsync = function(self, key, value, expiration, sortKey)
			local raw = self_(self, "SetAsync")
			memCall("SetAsync")
			raw.data.items[key] = { value = deepCopy(value), expires = S.clock + (expiration or 3888000), sortKey = sortKey }
			return true
		end,
		GetAsync = function(self, key)
			local raw = self_(self, "GetAsync")
			memCall("GetAsync")
			local e = raw.data.items[key]
			if not alive(e) then
				return nil
			end
			return deepCopy(e.value), e.sortKey
		end,
		UpdateAsync = function(self, key, transform, expiration)
			local raw = self_(self, "UpdateAsync")
			memCall("UpdateAsync")
			local e = raw.data.items[key]
			local old = if alive(e) then deepCopy(e.value) else nil
			local new, sortKey = transform(old, e and e.sortKey)
			if new == nil then
				return nil
			end
			raw.data.items[key] = { value = deepCopy(new), expires = S.clock + (expiration or 3888000), sortKey = sortKey }
			return deepCopy(new)
		end,
		RemoveAsync = function(self, key)
			local raw = self_(self, "RemoveAsync")
			memCall("RemoveAsync")
			raw.data.items[key] = nil
		end,
		GetRangeAsync = function(self, direction, count)
			local raw = self_(self, "GetRangeAsync")
			memCall("GetRangeAsync")
			local list = {}
			for k, e in raw.data.items do
				if alive(e) then
					table.insert(list, { key = k, value = deepCopy(e.value), sortKey = e.sortKey })
				end
			end
			table.sort(list, function(a, b)
				return a.key < b.key
			end)
			if direction == Enum.SortDirection.Descending then
				local rev = {}
				for i = #list, 1, -1 do
					table.insert(rev, list[i])
				end
				list = rev
			end
			local out = {}
			for i = 1, math.min(count or 1, #list) do
				out[i] = list[i]
			end
			return out
		end,
		GetSizeAsync = function(self)
			local raw = self_(self, "GetSizeAsync")
			memCall("GetSizeAsync")
			local n = 0
			for _, e in raw.data.items do
				if alive(e) then
					n += 1
				end
			end
			return n
		end,
	},
})

I.define("MemoryStoreHashMap", {
	methods = {
		SetAsync = function(self, key, value, expiration)
			local raw = self_(self, "SetAsync")
			memCall("SetAsync")
			raw.data.items[key] = { value = deepCopy(value), expires = S.clock + (expiration or 3888000) }
			return true
		end,
		GetAsync = function(self, key)
			local raw = self_(self, "GetAsync")
			memCall("GetAsync")
			local e = raw.data.items[key]
			return if alive(e) then deepCopy(e.value) else nil
		end,
		UpdateAsync = function(self, key, transform, expiration)
			local raw = self_(self, "UpdateAsync")
			memCall("UpdateAsync")
			local e = raw.data.items[key]
			local new = transform(if alive(e) then deepCopy(e.value) else nil)
			if new == nil then
				return nil
			end
			raw.data.items[key] = { value = deepCopy(new), expires = S.clock + (expiration or 3888000) }
			return deepCopy(new)
		end,
		RemoveAsync = function(self, key)
			local raw = self_(self, "RemoveAsync")
			memCall("RemoveAsync")
			raw.data.items[key] = nil
		end,
		ListItemsAsync = function(self, count)
			local raw, world = self_(self, "ListItemsAsync")
			memCall("ListItemsAsync")
			local page = {}
			for k, e in raw.data.items do
				if alive(e) then
					table.insert(page, { key = k, value = deepCopy(e.value) })
				end
			end
			table.sort(page, function(a, b)
				return a.key < b.key
			end)
			return makePages(world, { page })
		end,
	},
})

I.define("MemoryStoreQueue", {
	methods = {
		AddAsync = function(self, value, expiration, priority)
			local raw = self_(self, "AddAsync")
			memCall("AddAsync")
			table.insert(raw.data.queue, { value = deepCopy(value), priority = priority or 0 })
		end,
		ReadAsync = function(self, count, allOrNothing, waitTimeout)
			local raw = self_(self, "ReadAsync")
			memCall("ReadAsync")
			local out = {}
			for i = 1, math.min(count or 1, #raw.data.queue) do
				table.insert(out, deepCopy(raw.data.queue[i].value))
			end
			if allOrNothing and #out < (count or 1) then
				return {}, ""
			end
			raw.readCount = (raw.readCount or 0) + 1
			raw.pending = raw.pending or {}
			local id = "read-" .. raw.readCount
			raw.pending[id] = #out
			return out, id
		end,
		RemoveAsync = function(self, id)
			local raw = self_(self, "RemoveAsync")
			memCall("RemoveAsync")
			local n = raw.pending and raw.pending[id] or 0
			for _ = 1, n do
				table.remove(raw.data.queue, 1)
			end
			if raw.pending then
				raw.pending[id] = nil
			end
		end,
		GetSizeAsync = function(self)
			local raw = self_(self, "GetSizeAsync")
			memCall("GetSizeAsync")
			return #raw.data.queue
		end,
	},
})

local function memObj(world, className, kind, name)
	local raw = I.new(className, nil)
	raw.Name = name
	raw.data = mem(kind, name)
	return wrap(world, raw)
end
I.define("MemoryStoreService", {
	methods = {
		GetSortedMap = function(self, name)
			local _, world = self_(self, "GetSortedMap")
			return memObj(world, "MemoryStoreSortedMap", "sorted", name)
		end,
		GetHashMap = function(self, name)
			local _, world = self_(self, "GetHashMap")
			return memObj(world, "MemoryStoreHashMap", "hash", name)
		end,
		GetQueue = function(self, name)
			local _, world = self_(self, "GetQueue")
			return memObj(world, "MemoryStoreQueue", "queue", name)
		end,
	},
})

-- ── MessagingService (one server: messages come back to this server) ─────────
local subscriptions = {} -- topic -> { { fn, world, connected } }
I.define("MessagingService", {
	methods = {
		PublishAsync = function(self, topic, message)
			local _, world = self_(self, "PublishAsync")
			if world.kind ~= "server" then
				error("MessagingService can only be used from the server", 2)
			end
			if type(topic) ~= "string" then
				error("Argument 1 missing or nil", 2)
			end
			H.counts.messagingCalls = (H.counts.messagingCalls or 0) + 1
			local data = H.copyArgs(world, "remote", message)[1]
			local ok, encoded = pcall(serde.encode, "json", data)
			if ok and #encoded > 1024 then
				error("PublishAsync: message exceeds the 1kB size limit", 2)
			end
			asyncYield()
			local sent = H.epoch() + S.clock
			H.afterDelay(0.1, function()
				for _, sub in table.clone(subscriptions[topic] or {}) do
					if sub.connected then
						S.spawn(sub.fn, sub.world, { Data = H.copyArgs(sub.world, "remote", data)[1], Sent = sent })
					end
				end
			end)
		end,
		SubscribeAsync = function(self, topic, fn)
			local _, world = self_(self, "SubscribeAsync")
			if world.kind ~= "server" then
				error("MessagingService can only be used from the server", 2)
			end
			if type(fn) ~= "function" then
				error("Argument 2 missing or nil", 2)
			end
			asyncYield()
			local sub = { fn = fn, world = world, connected = true }
			subscriptions[topic] = subscriptions[topic] or {}
			table.insert(subscriptions[topic], sub)
			local s = H.sig.new("Subscription:" .. tostring(topic))
			local conn = H.sig.proxy(world, s):Connect(function() end)
			-- disconnecting the returned connection ends the subscription
			local list = s.conns
			local c = list[#list]
			local mt = { __index = function(_, k)
				if k == "Disconnect" or k == "disconnect" then
					return function()
						sub.connected = false
						conn:Disconnect()
					end
				elseif k == "Connected" then
					return sub.connected
				end
				return nil
			end, __tostring = function()
				return "Connection"
			end }
			local obj = setmetatable({}, mt)
			H.typeNames[obj] = "RBXScriptConnection"
			return obj
		end,
	},
})

-- ── MarketplaceService ───────────────────────────────────────────────────────
-- Studio opens a test purchase window; the harness records the prompt. With
-- harness.autoBuy(true) (scenario) the player "clicks Buy" half a second later.
local function recordPrompt(method)
	return function(self, player, id, ...)
		local _, world = self_(self, method)
		local p = H.checkObject(player, 1, 2, "Player")
		if method ~= "PromptPremiumPurchase" and method ~= "PromptSubscriptionPurchase" then
			id = H.checkInt64(id, 2, 2)
		end
		H.record("purchasePrompt", { method = method, player = p and p.Name, id = id, world = world.id })
		if not (H.options.autoBuy and p) then
			return
		end
		H.afterDelay(0.5, function()
			local mps = I.service("MarketplaceService")
			if method == "PromptProductPurchase" then
				H.purchase(p, id)
			elseif method == "PromptGamePassPurchase" then
				H.ownedPasses = H.ownedPasses or {}
				H.ownedPasses[tostring(p.props.UserId) .. ":" .. tostring(id)] = true
				H.record("purchase", { player = p.Name, gamePassId = id, result = "game pass bought" })
				I.fire(mps, "PromptGamePassPurchaseFinished", p, id, true)
			end
		end)
	end
end

I.define("MarketplaceService", {
	set = { ProcessReceipt = H.callbackProp("ProcessReceipt", "server") },
	get = { ProcessReceipt = H.callbackGet("ProcessReceipt", "MarketplaceService") },
	methods = {
		PromptProductPurchase = recordPrompt("PromptProductPurchase"),
		PromptGamePassPurchase = recordPrompt("PromptGamePassPurchase"),
		PromptPurchase = recordPrompt("PromptPurchase"),
		PromptPremiumPurchase = recordPrompt("PromptPremiumPurchase"),
		PromptBundlePurchase = recordPrompt("PromptBundlePurchase"),
		PromptSubscriptionPurchase = recordPrompt("PromptSubscriptionPurchase"),
		UserOwnsGamePassAsync = function(self, userId, passId)
			userId = H.checkInt64(userId, 1, 2)
			passId = H.checkInt64(passId, 2, 2)
			asyncYield()
			local owned = H.ownedPasses or {}
			return owned[tostring(userId) .. ":" .. tostring(passId)] == true
		end,
		PlayerOwnsAsset = function()
			asyncYield()
			return false
		end,
		PlayerOwnsAssetAsync = function()
			asyncYield()
			return false
		end,
		PlayerOwnsBundle = function()
			asyncYield()
			return false
		end,
		IsPlayerSubscribed = function()
			asyncYield()
			return false
		end,
		GetUserSubscriptionStatusAsync = function()
			asyncYield()
			return { IsSubscribed = false, IsRenewing = false }
		end,
		GetProductInfo = function(self, id, infoType)
			asyncYield()
			return {
				Name = "Product " .. tostring(id), Description = "", PriceInRobux = 0, ProductId = id, AssetId = id,
				IsForSale = true, IsLimited = false, IsPublicDomain = false, IconImageAssetId = 0,
				Creator = { Name = "Creator", CreatorType = "User", CreatorTargetId = 0, Id = 0 },
			}
		end,
		GetProductInfoAsync = function(self, id)
			asyncYield()
			return { Name = "Product " .. tostring(id), Description = "", PriceInRobux = 0, ProductId = id, AssetId = id, IsForSale = true }
		end,
		GetDeveloperProductsAsync = function(self)
			local _, world = self_(self, "GetDeveloperProductsAsync")
			asyncYield()
			return makePages(world, { {} })
		end,
	},
})

-- Simulate a finished Robux purchase: call ProcessReceipt like Roblox does.
function H.purchase(playerRaw, productId)
	local key = "ProcessReceipt\0server"
	local mps = I.service("MarketplaceService")
	local cb = mps.callbacks and mps.callbacks[key]
	H.purchaseCount = (H.purchaseCount or 0) + 1
	local receipt = {
		PlayerId = playerRaw.props.UserId, ProductId = productId, PurchaseId = "harness-purchase-" .. H.purchaseCount,
		CurrencySpent = 0, CurrencyType = Enum.CurrencyType.Robux, PlaceIdWherePurchased = H.options.placeId or 0,
	}
	if cb == nil then
		H.record("purchase", { player = playerRaw.Name, productId = productId, result = "no ProcessReceipt callback is set" })
		return
	end
	S.spawn(function()
		local ok, result = pcall(cb.fn, receipt)
		if not ok then
			H.gameError("server", S.cleanMessage(result), nil, "ProcessReceipt")
			H.record("purchase", { player = playerRaw.Name, productId = productId, result = "ProcessReceipt errored" })
			return
		end
		H.record("purchase", { player = playerRaw.Name, productId = productId, result = tostring(result) })
		I.fire(mps, "PromptProductPurchaseFinished", playerRaw.props.UserId, productId, true)
	end, H.worlds.server)
end

-- ── TeleportService ──────────────────────────────────────────────────────────
local function teleportCall(method, yields)
	return function(self, ...)
		local _, world = self_(self, method)
		local n = select("#", ...)
		local args = {}
		for i = 1, math.min(n, 4) do
			local v = select(i, ...)
			args[i] = if v == nil then "nil" elseif type(v) == "userdata" or type(v) == "table" then H.typeof(v) else v
		end
		H.record("teleport", { method = method, args = args, world = world.id })
		if yields then
			asyncYield()
		end
		return nil
	end
end
I.define("TeleportService", {
	methods = {
		Teleport = teleportCall("Teleport"),
		TeleportAsync = teleportCall("TeleportAsync", true),
		TeleportToPlaceInstance = teleportCall("TeleportToPlaceInstance"),
		TeleportToPrivateServer = teleportCall("TeleportToPrivateServer"),
		TeleportPartyAsync = teleportCall("TeleportPartyAsync", true),
		TeleportToSpawnByName = teleportCall("TeleportToSpawnByName"),
		ReserveServer = function(self, placeId)
			asyncYield()
			H.reserveCount = (H.reserveCount or 0) + 1
			return "reserved-code-" .. H.reserveCount, "private-server-" .. H.reserveCount
		end,
		GetLocalPlayerTeleportData = function()
			return nil
		end,
		GetArrivingTeleportGui = function()
			return nil
		end,
		SetTeleportGui = function() end,
		SetTeleportSetting = function() end,
		GetTeleportSetting = function()
			return nil
		end,
		GetPlayerPlaceInstanceAsync = function()
			asyncYield()
			error("The user is not in a game", 2)
		end,
	},
})
I.define("TeleportOptions", {
	methods = {
		SetTeleportData = function(self, d)
			local raw = self_(self, "SetTeleportData")
			raw.teleportData = d
		end,
		GetTeleportData = function(self)
			local raw = self_(self, "GetTeleportData")
			return raw.teleportData
		end,
	},
})

-- ── HttpService ──────────────────────────────────────────────────────────────
local function jsonEncode(v, seen, level)
	local t = type(v)
	if t == "nil" then
		return "null"
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			return "null"
		end
		if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
			return string.format("%d", v)
		end
		return string.format("%.14g", v)
	elseif t == "string" then
		return serde.encode("json", v)
	elseif t == "table" then
		if seen[v] then
			-- raised as a marker table and re-raised once by JSONEncode at the caller's line
			error({ jsonError = "Can't convert to JSON" })
		end
		seen[v] = true
		local n = #v
		local count = 0
		for _ in v do
			count += 1
		end
		local out = {}
		if count == n then
			for i = 1, n do
				out[i] = jsonEncode(v[i], seen, level)
			end
			seen[v] = nil
			return "[" .. table.concat(out, ",") .. "]"
		end
		local keys = {}
		for k in v do
			table.insert(keys, tostring(k))
		end
		table.sort(keys)
		for _, k in keys do
			local val = v[k]
			if val == nil then
				val = v[tonumber(k)]
			end
			table.insert(out, serde.encode("json", k) .. ":" .. jsonEncode(val, seen, level))
		end
		seen[v] = nil
		return "{" .. table.concat(out, ",") .. "}"
	end
	H.note("HttpService:JSONEncode turned a " .. H.typeof(v) .. " into null")
	return "null"
end

local function httpRequest(method)
	return function(self, ...)
		local _, world = self_(self, method)
		if world.kind ~= "server" then
			error("Http requests can only be executed by game server", 2)
		end
		if not H.options.httpEnabled then
			error("Http requests are not enabled. Enable via game settings", 2)
		end
		H.record("http", { method = method })
		H.note("unmodeled HTTP: the harness has no network; requests return an empty 200 response")
		asyncYield()
		if method == "RequestAsync" then
			return { Success = true, StatusCode = 200, StatusMessage = "OK", Headers = {}, Body = "{}" }
		end
		return "{}"
	end
end

local guidState = nil
I.define("HttpService", {
	get = {
		HttpEnabled = function()
			return H.options.httpEnabled == true
		end,
	},
	methods = {
		JSONEncode = function(self, v)
			local ok, r = pcall(jsonEncode, v, {}, 3)
			if not ok then
				if type(r) == "table" and r.jsonError then
					error(r.jsonError, 2)
				end
				error(r, 0)
			end
			return r
		end,
		JSONDecode = function(self, s)
			if type(s) ~= "string" then
				error("Argument 1 missing or nil", 2)
			end
			local ok, v = pcall(serde.decode, "json", s)
			if not ok then
				error("Can't parse JSON", 2)
			end
			return v
		end,
		GenerateGUID = function(self, wrapBraces)
			guidState = guidState or D.newState((H.options.seed or 1) + 777)
			local hex = {}
			for i = 1, 32 do
				hex[i] = string.format("%X", math.floor(D.nextUnit(guidState) * 16))
			end
			local s = table.concat(hex)
			local g = string.format("%s-%s-%s-%s-%s", string.sub(s, 1, 8), string.sub(s, 9, 12), string.sub(s, 13, 16), string.sub(s, 17, 20), string.sub(s, 21, 32))
			if wrapBraces == false then
				return g
			end
			return "{" .. g .. "}"
		end,
		UrlEncode = function(self, s)
			return (string.gsub(tostring(s), "[^%w%-_%.~]", function(c)
				return string.format("%%%02X", string.byte(c))
			end))
		end,
		GetAsync = httpRequest("GetAsync"),
		PostAsync = httpRequest("PostAsync"),
		RequestAsync = httpRequest("RequestAsync"),
		GetSecret = function()
			error("Can't find secret with given key", 2)
		end,
	},
})

return {}
