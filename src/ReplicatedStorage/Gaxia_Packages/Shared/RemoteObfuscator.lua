--!strict
--[[
	Lightweight, reversible transport obfuscation for NetService.

	This is deliberately not presented as cryptographic security: the key and
	decoder must exist on the client, so a determined exploiter can recover both.
	Its purpose is to make ordinary RemoteSpy payloads inconvenient to read and
	edit while server-side validation remains the actual security boundary.
]]

local VERSION = 1
local MAX_DEPTH = 32
local MAX_NODES = 4096
local MAX_ENTRIES = 4096

local TAG_NIL = 0
local TAG_BOOLEAN = 1
local TAG_NUMBER = 2
local TAG_STRING = 3
local TAG_TABLE = 4
local TAG_PASSTHROUGH = 5

local rng = Random.new()

type Stream = {
	value: number,
}

type EncodeBudget = {
	nodes: number,
}

export type DecodeLimits = {
	maxDepth: number?,
	maxNodes: number?,
	maxEntries: number?,
	maxStringBytes: number?,
	maxTotalStringBytes: number?,
	maxBufferBytes: number?,
}

type DecodeBudget = {
	nodes: number,
	entries: number,
	stringBytes: number,
	maxDepth: number,
	maxNodes: number,
	maxEntries: number,
	maxStringBytes: number,
	maxTotalStringBytes: number,
	maxBufferBytes: number,
}

local RemoteObfuscator = {}

local function newStream(key: number, nonce: number): Stream
	local value = bit32.bxor(bit32.bxor(key, nonce), 0x6D2B79F5)
	if value == 0 then
		value = 0xA341316C
	end
	return { value = value }
end

local function nextByte(stream: Stream): number
	local value = stream.value
	value = bit32.bxor(value, bit32.lshift(value, 13))
	value = bit32.bxor(value, bit32.rshift(value, 17))
	value = bit32.bxor(value, bit32.lshift(value, 5))
	stream.value = value
	return bit32.band(value, 0xFF)
end

local function cryptString(stream: Stream, value: string): string
	local output = table.create(#value)
	for index = 1, #value do
		output[index] = string.char(bit32.bxor(string.byte(value, index), nextByte(stream)))
	end
	return table.concat(output)
end

local function takeEncodeNode(budget: EncodeBudget, depth: number)
	if depth > MAX_DEPTH then
		error("payload exceeds maximum nesting depth")
	end
	budget.nodes += 1
	if budget.nodes > MAX_NODES then
		error("payload exceeds maximum node count")
	end
end

local function encodeValue(
	value: any,
	stream: Stream,
	budget: EncodeBudget,
	depth: number,
	seen: { [table]: boolean }
): any
	takeEncodeNode(budget, depth)

	local valueType = typeof(value)
	if valueType == "nil" then
		return { TAG_NIL }
	elseif valueType == "boolean" then
		return { TAG_BOOLEAN, bit32.bxor(if value then 1 else 0, bit32.band(nextByte(stream), 1)) }
	elseif valueType == "number" then
		local encodedText = if value ~= value
			then "nan"
			elseif value == math.huge then "inf"
			elseif value == -math.huge then "-inf"
			else string.format("%.17g", value)
		return { TAG_NUMBER, cryptString(stream, encodedText) }
	elseif valueType == "string" then
		return { TAG_STRING, cryptString(stream, value) }
	elseif valueType == "table" then
		if seen[value] then
			error("cyclic tables cannot be sent through NetService")
		end
		seen[value] = true
		local entries = {}
		for key, child in pairs(value) do
			table.insert(entries, {
				encodeValue(key, stream, budget, depth + 1, seen),
				encodeValue(child, stream, budget, depth + 1, seen),
			})
		end
		seen[value] = nil
		return { TAG_TABLE, entries }
	end

	-- Roblox-native values retain their native type so callers do not lose
	-- Instance, Vector3, CFrame, EnumItem, buffer, and similar arguments.
	-- Functions and threads can NEVER cross a Roblox remote: if they fell
	-- through to TAG_PASSTHROUGH the engine would throw while serializing the
	-- already-returned envelope, outside every protected call. Fail HERE so
	-- the transport's xpcall converts this into a clean INTERNAL rejection.
	if valueType == "function" or valueType == "thread" then
		error(`values of type '{valueType}' cannot be sent through NetService`, 0)
	end

	return { TAG_PASSTHROUGH, value }
end

-- The encoded format is deliberately a set of exact, dense arrays. Checking
-- the wire shape before decoding keeps attacker-added sparse entries and junk
-- fields from escaping the inbound structural budget.
local function hasExactArrayShape(value: any, length: number): boolean
	if typeof(value) ~= "table" then
		return false
	end
	local count = 0
	for key in pairs(value) do
		if typeof(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > length then
			return false
		end
		count += 1
		if count > length then
			return false
		end
	end
	return count == length
end

local function isDenseArray(value: any, maxLength: number): (boolean, number)
	if typeof(value) ~= "table" then
		return false, 0
	end
	local count = 0
	for key in pairs(value) do
		if typeof(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > maxLength then
			return false, 0
		end
		count += 1
		if count > maxLength then
			return false, 0
		end
	end
	for index = 1, count do
		if value[index] == nil then
			return false, 0
		end
	end
	return true, count
end

local function consumeEncodedString(budget: DecodeBudget, value: string, label: string): ()
	if #value > budget.maxStringBytes then
		error(`encoded {label} exceeds maximum string size`)
	end
	budget.stringBytes += #value
	if budget.stringBytes > budget.maxTotalStringBytes then
		error("encoded payload exceeds total string budget")
	end
end

local function decodeValue(node: any, stream: Stream, budget: DecodeBudget, depth: number): any
	if depth > budget.maxDepth then
		error("encoded payload exceeds maximum nesting depth")
	end
	budget.nodes += 1
	if budget.nodes > budget.maxNodes then
		error("encoded payload exceeds maximum node count")
	end
	if typeof(node) ~= "table" then
		error("invalid encoded node")
	end

	local tag = node[1]
	if tag == TAG_NIL then
		if not hasExactArrayShape(node, 1) then
			error("invalid encoded nil")
		end
		return nil
	elseif tag == TAG_BOOLEAN then
		if not hasExactArrayShape(node, 2) then
			error("invalid encoded boolean")
		end
		if node[2] ~= 0 and node[2] ~= 1 then
			error("invalid encoded boolean")
		end
		return bit32.bxor(node[2], bit32.band(nextByte(stream), 1)) == 1
	elseif tag == TAG_NUMBER then
		if not hasExactArrayShape(node, 2) then
			error("invalid encoded number")
		end
		if typeof(node[2]) ~= "string" then
			error("invalid encoded number")
		end
		consumeEncodedString(budget, node[2], "number")
		local decodedText = cryptString(stream, node[2])
		local decoded = if decodedText == "inf"
			then math.huge
			elseif decodedText == "-inf" then -math.huge
			elseif decodedText == "nan" then 0 / 0
			else tonumber(decodedText)
		if decoded == nil then
			error("invalid encoded number")
		end
		return decoded
	elseif tag == TAG_STRING then
		if not hasExactArrayShape(node, 2) then
			error("invalid encoded string")
		end
		if typeof(node[2]) ~= "string" then
			error("invalid encoded string")
		end
		consumeEncodedString(budget, node[2], "string")
		return cryptString(stream, node[2])
	elseif tag == TAG_TABLE then
		if not hasExactArrayShape(node, 2) then
			error("invalid encoded table")
		end
		if typeof(node[2]) ~= "table" then
			error("invalid encoded table")
		end
		local denseEntries, entryCount = isDenseArray(node[2], budget.maxEntries)
		if not denseEntries then
			error("invalid encoded table entries")
		end
		local result = {}
		for index = 1, entryCount do
			local entry = node[2][index]
			budget.entries += 1
			if budget.entries > budget.maxEntries then
				error("encoded payload exceeds maximum table entries")
			end
			if not hasExactArrayShape(entry, 2) then
				error("invalid encoded table entry")
			end
			local key = decodeValue(entry[1], stream, budget, depth + 1)
			if key == nil then
				error("encoded table key cannot be nil")
			end
			result[key] = decodeValue(entry[2], stream, budget, depth + 1)
		end
		return result
	elseif tag == TAG_PASSTHROUGH then
		if not hasExactArrayShape(node, 2) then
			error("invalid passthrough value")
		end
		local valueType = typeof(node[2])
		if
			valueType == "nil"
			or valueType == "boolean"
			or valueType == "number"
			or valueType == "string"
			or valueType == "table"
		then
			error("invalid passthrough value")
		end
		if valueType == "buffer" and buffer.len(node[2]) > budget.maxBufferBytes then
			error("encoded buffer exceeds maximum size")
		end
		return node[2]
	end

	error("unknown encoded node tag")
end

local function positiveInteger(value: any, fallback: number): number
	if
		typeof(value) ~= "number"
		or value ~= value
		or value == math.huge
		or value == -math.huge
		or value < 1
	then
		return fallback
	end
	return math.floor(value)
end

local function nonNegativeInteger(value: any, fallback: number): number
	if
		typeof(value) ~= "number"
		or value ~= value
		or value == math.huge
		or value == -math.huge
		or value < 0
	then
		return fallback
	end
	return math.floor(value)
end

local function newDecodeBudget(limits: DecodeLimits?): DecodeBudget
	return {
		nodes = 0,
		entries = 0,
		stringBytes = 0,
		maxDepth = positiveInteger(limits and limits.maxDepth, MAX_DEPTH),
		maxNodes = positiveInteger(limits and limits.maxNodes, MAX_NODES),
		maxEntries = positiveInteger(limits and limits.maxEntries, MAX_ENTRIES),
		maxStringBytes = positiveInteger(limits and limits.maxStringBytes, math.huge),
		maxTotalStringBytes = positiveInteger(limits and limits.maxTotalStringBytes, math.huge),
		maxBufferBytes = nonNegativeInteger(limits and limits.maxBufferBytes, math.huge),
	}
end

function RemoteObfuscator.Encode(key: number, value: any, nonce: number?): { any }
	assert(typeof(key) == "number", "RemoteObfuscator.Encode requires a numeric key")
	local messageNonce = nonce or rng:NextInteger(1, 0x7FFFFFFF)
	local stream = newStream(key, messageNonce)
	local encoded = encodeValue(value, stream, { nodes = 0 }, 0, {})
	return { VERSION, messageNonce, encoded }
end

-- `limits` protects server inbound decoding before a decoded value reaches
-- NetProtocol. Omit it for legacy outbound/client decoding compatibility.
function RemoteObfuscator.Decode(key: number, envelope: any, limits: DecodeLimits?): any
	assert(typeof(key) == "number", "RemoteObfuscator.Decode requires a numeric key")
	if not hasExactArrayShape(envelope, 3) or envelope[1] ~= VERSION then
		error("invalid obfuscation envelope")
	end
	local nonce = envelope[2]
	if typeof(nonce) ~= "number" or nonce % 1 ~= 0 or nonce < 1 or nonce > 0x7FFFFFFF then
		error("invalid obfuscation nonce")
	end
	return decodeValue(envelope[3], newStream(key, nonce), newDecodeBudget(limits), 0)
end

return RemoteObfuscator
