--!strict
-- ─────────────────────────────────────────────────────────────
-- MemoryStore.lua  (Gaxia.Memory)
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/MemoryStore
-- Purpose : Cross-server ephemeral storage over MemoryStoreService — a sorted
--           map (matchmaking pools, global leaderboards, global cooldowns) and a
--           priority queue (matchmaking intake). Raw MemoryStore throws without
--           Studio API access and has a fiddly read/remove handshake. This wraps
--           it with one clean API AND a transparent in-memory FALLBACK: when the
--           real service is unreachable (Studio, no API access) every op routes
--           to a local table so code still runs and is testable — single-server,
--           but correct. Backs global CooldownService (18.4) + PartyService (24.8).
--
-- Access  : Gaxia.Memory  (server)
--   Gaxia.Memory.MapSet("ranks", tostring(uid), {name=n}, 3600, score)
--   local top = Gaxia.Memory.MapRange("ranks", 10, false)  -- highest first
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local MemoryStoreService = game:GetService("MemoryStoreService")

local Memory = {}

-- ── Availability probe (once) ──
local probed = false
local fallback = false
local function ensureProbe(): ()
	if probed then
		return
	end
	probed = true
	local ok = pcall(function()
		local m = MemoryStoreService:GetSortedMap("__gaxia_probe")
		m:SetAsync("__probe", 1, 1)
	end)
	fallback = not ok
end

function Memory.IsUsingFallback(): boolean
	ensureProbe()
	return fallback
end

-- ─────────────────────────────────────────────────────────────
-- In-memory fallback structures
-- ─────────────────────────────────────────────────────────────
type MapEntry = { value: any, sortKey: number, expireAt: number }
local localMaps: { [string]: { [string]: MapEntry } } = {}
type QueueEntry = { id: number, value: any, priority: number, expireAt: number }
local localQueues: { [string]: { QueueEntry } } = {}
local queueSeq = 0
local readBatches: { [string]: { string } } = {} -- readId → entry ids (stringified)

local function now(): number
	return os.time()
end

local function fbMap(name: string): { [string]: MapEntry }
	local m = localMaps[name]
	if not m then
		m = {}
		localMaps[name] = m
	end
	return m
end

-- ── Sorted map ──

function Memory.MapSet(mapName: string, key: string, value: any, ttl: number, sortKey: number?): boolean
	ensureProbe()
	if not fallback then
		local ok = pcall(function()
			local m = MemoryStoreService:GetSortedMap(mapName)
			m:SetAsync(key, value, ttl, sortKey)
		end)
		if ok then
			return true
		end
		fallback = true -- fall through to local on a live failure
	end
	fbMap(mapName)[key] = { value = value, sortKey = sortKey or 0, expireAt = now() + ttl }
	return true
end

function Memory.MapGet(mapName: string, key: string): any
	ensureProbe()
	if not fallback then
		local ok, v = pcall(function()
			return MemoryStoreService:GetSortedMap(mapName):GetAsync(key)
		end)
		if ok then
			return v
		end
		fallback = true
	end
	local e = fbMap(mapName)[key]
	if not e or e.expireAt < now() then
		return nil
	end
	return e.value
end

function Memory.MapRemove(mapName: string, key: string): boolean
	ensureProbe()
	if not fallback then
		local ok = pcall(function()
			MemoryStoreService:GetSortedMap(mapName):RemoveAsync(key)
		end)
		if ok then
			return true
		end
		fallback = true
	end
	fbMap(mapName)[key] = nil
	return true
end

-- Return up to `count` entries sorted by sortKey. ascending=false → highest first.
function Memory.MapRange(mapName: string, count: number, ascending: boolean?): { { key: string, value: any, sortKey: number } }
	ensureProbe()
	local asc = ascending ~= false
	if not fallback then
		local ok, result = pcall(function()
			local dir = if asc then Enum.SortDirection.Ascending else Enum.SortDirection.Descending
			return MemoryStoreService:GetSortedMap(mapName):GetRangeAsync(dir, count)
		end)
		if ok then
			return result
		end
		fallback = true
	end
	local entries: { { key: string, value: any, sortKey: number } } = {}
	for key, e in pairs(fbMap(mapName)) do
		if e.expireAt >= now() then
			table.insert(entries, { key = key, value = e.value, sortKey = e.sortKey })
		end
	end
	table.sort(entries, function(a, b)
		if asc then
			return a.sortKey < b.sortKey
		end
		return a.sortKey > b.sortKey
	end)
	local out = {}
	for i = 1, math.min(count, #entries) do
		out[i] = entries[i]
	end
	return out
end

-- ── Priority queue ──

function Memory.QueueAdd(queueName: string, value: any, ttl: number, priority: number?): boolean
	ensureProbe()
	if not fallback then
		local ok = pcall(function()
			MemoryStoreService:GetQueue(queueName):AddAsync(value, ttl, priority or 0)
		end)
		if ok then
			return true
		end
		fallback = true
	end
	local q = localQueues[queueName]
	if not q then
		q = {}
		localQueues[queueName] = q
	end
	queueSeq += 1
	table.insert(q, { id = queueSeq, value = value, priority = priority or 0, expireAt = now() + ttl })
	return true
end

-- Read up to `count` items (highest priority first). Returns (values, readId);
-- pass readId to QueueRemove to delete the read items.
function Memory.QueueRead(queueName: string, count: number): ({ any }, string?)
	ensureProbe()
	if not fallback then
		local ok, items, id = pcall(function()
			return MemoryStoreService:GetQueue(queueName):ReadAsync(count, false, 0)
		end)
		if ok then
			return items or {}, id
		end
		fallback = true
	end
	local q = localQueues[queueName] or {}
	local live: { QueueEntry } = {}
	for _, e in ipairs(q) do
		if e.expireAt >= now() then
			table.insert(live, e)
		end
	end
	table.sort(live, function(a, b)
		if a.priority ~= b.priority then
			return a.priority > b.priority
		end
		return a.id < b.id
	end)
	local values: { any } = {}
	local ids: { string } = {}
	for i = 1, math.min(count, #live) do
		table.insert(values, live[i].value)
		table.insert(ids, tostring(live[i].id))
	end
	queueSeq += 1
	local readId = `read_{queueSeq}`
	readBatches[readId] = ids
	return values, readId
end

function Memory.QueueRemove(queueName: string, readId: string): boolean
	ensureProbe()
	if not fallback then
		local ok = pcall(function()
			MemoryStoreService:GetQueue(queueName):RemoveAsync(readId)
		end)
		if ok then
			return true
		end
		fallback = true
	end
	local ids = readBatches[readId]
	if not ids then
		return false
	end
	local idSet: { [string]: boolean } = {}
	for _, id in ipairs(ids) do
		idSet[id] = true
	end
	local q = localQueues[queueName]
	if q then
		for i = #q, 1, -1 do
			if idSet[tostring(q[i].id)] then
				table.remove(q, i)
			end
		end
	end
	readBatches[readId] = nil
	return true
end

return Memory
