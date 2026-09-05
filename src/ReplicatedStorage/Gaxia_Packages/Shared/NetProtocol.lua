--!strict
--[[
	Module : NetProtocol
	Location: ReplicatedStorage.Gaxia_Packages.Shared.NetProtocol
	Purpose : Pure, bounded helpers for inbound network requests. This module
	          deliberately has no Remote connections or gameplay knowledge;
	          NetService owns transport and calls these helpers before a handler.

	The checks here are a server boundary, not client authentication. A client
	can always create another valid request, but malformed, oversized, non-finite
	or replayed envelopes must not reach a domain handler.
]]

local NetProtocol = {}

NetProtocol.Code = {
	MALFORMED = "MALFORMED",
	REPLAY = "REPLAY",
	BUDGET = "BUDGET",
	UNSUPPORTED_TYPE = "UNSUPPORTED_TYPE",
	INVALID_NUMBER = "INVALID_NUMBER",
	INVALID_REQUEST_ID = "INVALID_REQUEST_ID",
	RATE_LIMITED = "RATE_LIMITED",
	BUSY = "BUSY",
	SCHEMA = "SCHEMA",
	FORBIDDEN = "FORBIDDEN",
	INTERNAL = "INTERNAL",
}

export type Budget = {
	maxDepth: number,
	maxNodes: number,
	maxEntries: number,
	maxStringBytes: number,
	maxTotalStringBytes: number,
	maxBufferBytes: number,
}

type ReplayWindow = {
	capacity: number,
	seen: { [number]: boolean },
	order: { number },
	head: number,
	count: number,
}

type CacheEntry = {
	value: any,
	expiresAt: number,
	version: number,
}

type CacheOrderEntry = {
	requestId: string,
	version: number,
}

type RequestCache = {
	capacity: number,
	ttlSeconds: number,
	entries: { [string]: CacheEntry },
	order: { CacheOrderEntry },
	head: number,
	count: number,
	nextVersion: number,
}

local BUDGETS: { [string]: Budget } = {
	tiny = {
		maxDepth = 4,
		maxNodes = 32,
		maxEntries = 24,
		maxStringBytes = 128,
		maxTotalStringBytes = 512,
		maxBufferBytes = 0,
	},
	small = {
		maxDepth = 8,
		maxNodes = 128,
		maxEntries = 96,
		maxStringBytes = 512,
		maxTotalStringBytes = 2048,
		maxBufferBytes = 1024,
	},
	medium = {
		maxDepth = 12,
		maxNodes = 512,
		maxEntries = 384,
		maxStringBytes = 2048,
		maxTotalStringBytes = 8192,
		maxBufferBytes = 4096,
	},
}

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function nextRingIndex(index: number, capacity: number): number
	return index % capacity + 1
end

local function copyBudget(budget: Budget): Budget
	return {
		maxDepth = budget.maxDepth,
		maxNodes = budget.maxNodes,
		maxEntries = budget.maxEntries,
		maxStringBytes = budget.maxStringBytes,
		maxTotalStringBytes = budget.maxTotalStringBytes,
		maxBufferBytes = budget.maxBufferBytes,
	}
end

function NetProtocol.GetBudget(name: string?): Budget
	return copyBudget(BUDGETS[name or "small"] or BUDGETS.small)
end

function NetProtocol.IsBudgetName(value: any): boolean
	return typeof(value) == "string" and BUDGETS[value] ~= nil
end

function NetProtocol.IsValidNonce(value: any): boolean
	return typeof(value) == "number"
		and isFinite(value)
		and value % 1 == 0
		and value >= 1
		and value <= 0x7FFFFFFF
end

function NetProtocol.NewReplayWindow(capacity: number?): ReplayWindow
	local resolved = math.floor(tonumber(capacity) or 256)
	assert(resolved > 0 and resolved <= 4096, "replay window capacity must be 1..4096")
	return {
		capacity = resolved,
		seen = {},
		order = {},
		head = 1,
		count = 0,
	}
end

-- Returns false when the nonce was already accepted within this bounded window.
function NetProtocol.RememberNonce(window: ReplayWindow, nonce: number): boolean
	if window.seen[nonce] then
		return false
	end

	if window.count == window.capacity then
		local retired = window.order[window.head]
		window.seen[retired] = nil
		window.order[window.head] = nonce
		window.head = nextRingIndex(window.head, window.capacity)
	else
		local index = (window.head + window.count - 1) % window.capacity + 1
		window.order[index] = nonce
		window.count += 1
	end
	window.seen[nonce] = true

	return true
end

function NetProtocol.IsValidRequestId(value: any): boolean
	return typeof(value) == "string"
		and #value > 0
		and #value <= 64
		and string.match(value, "^[%w_%-]+$") ~= nil
end

function NetProtocol.NewRequestCache(capacity: number?, ttlSeconds: number?): RequestCache
	local resolvedCapacity = math.floor(tonumber(capacity) or 64)
	local resolvedTtl = tonumber(ttlSeconds) or 30
	assert(
		resolvedCapacity > 0 and resolvedCapacity <= 1024,
		"request cache capacity must be 1..1024"
	)
	assert(
		isFinite(resolvedTtl) and resolvedTtl > 0 and resolvedTtl <= 300,
		"request cache TTL must be 0..300"
	)
	return {
		capacity = resolvedCapacity,
		ttlSeconds = resolvedTtl,
		entries = {},
		order = {},
		head = 1,
		count = 0,
		nextVersion = 0,
	}
end

function NetProtocol.GetCached(cache: RequestCache, requestId: string, now: number?): any
	local entry = cache.entries[requestId]
	if not entry then
		return nil
	end
	if entry.expiresAt <= (now or os.clock()) then
		cache.entries[requestId] = nil
		return nil
	end
	return entry.value
end

function NetProtocol.PutCached(cache: RequestCache, requestId: string, value: any, now: number?): ()
	local clock = now or os.clock()
	local expiresAt = clock + cache.ttlSeconds
	cache.nextVersion += 1
	local version = cache.nextVersion
	cache.entries[requestId] = {
		value = value,
		expiresAt = expiresAt,
		version = version,
	}

	if cache.count == cache.capacity then
		local retired = cache.order[cache.head]
		local entry = cache.entries[retired.requestId]
		if entry and entry.version == retired.version then
			cache.entries[retired.requestId] = nil
		end
		cache.order[cache.head] = { requestId = requestId, version = version }
		cache.head = nextRingIndex(cache.head, cache.capacity)
	else
		local index = (cache.head + cache.count - 1) % cache.capacity + 1
		cache.order[index] = { requestId = requestId, version = version }
		cache.count += 1
	end
end

-- Validates the decoded payload before endpoint-specific schema validators.
-- Tables are expected to come from RemoteObfuscator.Decode, which reconstructs
-- plain tables; native values are rejected by default so an endpoint must not
-- accidentally accept a client-controlled Instance or object reference.
function NetProtocol.ValidatePayload(value: any, budgetName: string?): (boolean, string?)
	local budget = NetProtocol.GetBudget(budgetName)
	local nodes = 0
	local entries = 0
	local stringBytes = 0
	local activeTables: { [any]: boolean } = {}

	local function addString(valueToCount: string): boolean
		local bytes = #valueToCount
		if bytes > budget.maxStringBytes then
			return false
		end
		stringBytes += bytes
		return stringBytes <= budget.maxTotalStringBytes
	end

	local function walk(node: any, depth: number): (boolean, string?)
		if depth > budget.maxDepth then
			return false, NetProtocol.Code.BUDGET
		end

		nodes += 1
		if nodes > budget.maxNodes then
			return false, NetProtocol.Code.BUDGET
		end

		local nodeType = typeof(node)
		if nodeType == "nil" or nodeType == "boolean" then
			return true, nil
		end
		if nodeType == "number" then
			if isFinite(node) then
				return true, nil
			end
			return false, NetProtocol.Code.INVALID_NUMBER
		end
		if nodeType == "string" then
			if addString(node) then
				return true, nil
			end
			return false, NetProtocol.Code.BUDGET
		end
		if nodeType == "buffer" then
			local bytes = buffer.len(node)
			if bytes <= budget.maxBufferBytes then
				return true, nil
			end
			return false, NetProtocol.Code.BUDGET
		end
		if nodeType ~= "table" then
			return false, NetProtocol.Code.UNSUPPORTED_TYPE
		end

		if activeTables[node] then
			return false, NetProtocol.Code.MALFORMED
		end
		activeTables[node] = true
		for key, child in pairs(node) do
			entries += 1
			if entries > budget.maxEntries then
				activeTables[node] = nil
				return false, NetProtocol.Code.BUDGET
			end

			local keyType = typeof(key)
			if keyType == "string" then
				if not addString(key) then
					activeTables[node] = nil
					return false, NetProtocol.Code.BUDGET
				end
			elseif keyType == "number" then
				if not isFinite(key) then
					activeTables[node] = nil
					return false, NetProtocol.Code.INVALID_NUMBER
				end
			else
				activeTables[node] = nil
				return false, NetProtocol.Code.UNSUPPORTED_TYPE
			end

			local ok, code = walk(child, depth + 1)
			if not ok then
				activeTables[node] = nil
				return false, code
			end
		end
		activeTables[node] = nil
		return true, nil
	end

	return walk(value, 0)
end

return NetProtocol
