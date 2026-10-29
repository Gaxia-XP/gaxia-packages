--!nocheck
-- Roblox datatypes. Most come from Lune's @lune/roblox (Vector3, CFrame, Color3,
-- UDim2, ...); the ones Lune lacks are written here: TweenInfo, Random (seeded,
-- deterministic), DateTime (simulated clock), RaycastParams, OverlapParams, and a
-- permissive Enum (an Enum item Lune does not know is still returned, and noted).
local roblox = require("@lune/roblox")
local H = require("./state")

local D = {}
H.dt = D

for _, name in { "Vector3", "Vector2", "CFrame", "Color3", "UDim", "UDim2", "NumberSequence", "NumberSequenceKeypoint",
	"ColorSequence", "ColorSequenceKeypoint", "NumberRange", "Rect", "BrickColor", "Ray", "Region3", "Region3int16",
	"Vector3int16", "Vector2int16", "Font", "Faces", "Axes", "PhysicalProperties" } do
	D[name] = roblox[name]
end

-- Lune gaps in CFrame / Vector3 constructors (checked against Roblox):
--  * Lune's CFrame.lookAt returns the inverse rotation (a view matrix), so its
--    LookVector points the wrong way. Rebuilt here from fromMatrix.
--  * CFrame.new(pos, lookAt) (2 Vector3s, deprecated but still valid) is missing.
--  * Vector3.FromNormalId / Vector3.FromAxis are missing.
do
	local V3, CF = roblox.Vector3, roblox.CFrame
	local function lookAt(at, target, up)
		if typeof(at) ~= "Vector3" or typeof(target) ~= "Vector3" then
			error("invalid argument #1 to 'lookAt' (Vector3 expected)", 3)
		end
		up = if typeof(up) == "Vector3" then up else V3.yAxis
		local d = target - at
		if d.Magnitude < 1e-9 then
			return CF.new(at)
		end
		local look = d.Unit
		local right = look:Cross(up)
		if right.Magnitude < 1e-6 then
			-- looking straight along `up`: Roblox picks a right vector perpendicular to it
			right = look:Cross(V3.new(0, 0, -1))
			if right.Magnitude < 1e-6 then
				right = V3.xAxis
			end
		end
		right = right.Unit
		local up2 = right:Cross(look).Unit
		return CF.fromMatrix(at, right, up2, -look)
	end
	local cf = setmetatable({}, { __index = CF })
	for k, v in CF do
		cf[k] = v
	end
	cf.lookAt = function(at, target, up)
		return lookAt(at, target, up)
	end
	cf.new = function(...)
		local n = select("#", ...)
		local a, b = ...
		if n == 2 and typeof(a) == "Vector3" and typeof(b) == "Vector3" then
			return lookAt(a, b, nil)
		end
		return CF.new(...)
	end
	D.CFrame = cf

	local v3 = setmetatable({}, { __index = V3 })
	for k, v in V3 do
		v3[k] = v
	end
	local normals = {
		Right = V3.new(1, 0, 0),
		Top = V3.new(0, 1, 0),
		Back = V3.new(0, 0, 1),
		Left = V3.new(-1, 0, 0),
		Bottom = V3.new(0, -1, 0),
		Front = V3.new(0, 0, -1),
	}
	v3.FromNormalId = function(id)
		local v = normals[if typeof(id) == "EnumItem" then id.Name else tostring(id)]
		if v == nil then
			error("invalid argument #1 to 'FromNormalId' (NormalId expected)", 2)
		end
		return v
	end
	local axes = { X = V3.xAxis, Y = V3.yAxis, Z = V3.zAxis }
	v3.FromAxis = function(id)
		local v = axes[if typeof(id) == "EnumItem" then id.Name else tostring(id)]
		if v == nil then
			error("invalid argument #1 to 'FromAxis' (Axis expected)", 2)
		end
		return v
	end
	D.Vector3 = v3
end

local function readonlyType(typeName: string, fields, methods)
	local obj = newproxy(true)
	local mt = getmetatable(obj)
	mt.__index = function(_, k)
		local v = fields[k]
		if v ~= nil then
			return v
		end
		if methods and methods[k] then
			return methods[k]
		end
		error(string.format("%s is not a valid member of %s", tostring(k), typeName), 2)
	end
	mt.__newindex = function(_, k)
		error(string.format("%s cannot be assigned to", tostring(k)), 2)
	end
	mt.__tostring = function()
		return typeName
	end
	mt.__metatable = "The metatable is locked"
	H.typeNames[obj] = typeName
	return obj
end
D.readonlyType = readonlyType

local function mutableType(typeName: string, fields, methods)
	local obj = newproxy(true)
	local mt = getmetatable(obj)
	mt.__index = function(_, k)
		if fields[k] ~= nil then
			return fields[k]
		end
		if methods and methods[k] then
			return methods[k]
		end
		error(string.format("%s is not a valid member of %s", tostring(k), typeName), 2)
	end
	mt.__newindex = function(_, k, v)
		if fields[k] == nil then
			error(string.format("%s is not a valid member of %s", tostring(k), typeName), 2)
		end
		fields[k] = v
	end
	mt.__tostring = function()
		return typeName
	end
	mt.__metatable = "The metatable is locked"
	H.typeNames[obj] = typeName
	return obj
end

-- ── Enum ─────────────────────────────────────────────────────────────────────
local LEnum = roblox.Enum
local enumData = setmetatable({}, { __mode = "k" })
local enumCache = {}
local fakeValue = 10000

local function fakeItem(enum, enumName: string, itemName: string)
	fakeValue += 1
	local value = fakeValue
	local item = newproxy(true)
	local mt = getmetatable(item)
	mt.__index = function(self, k)
		if k == "Name" then
			return itemName
		elseif k == "Value" then
			return value
		elseif k == "EnumType" then
			return enum
		elseif k == "IsA" then
			return function(_, n)
				return n == enumName
			end
		end
		error(string.format("%s is not a valid member of EnumItem", tostring(k)), 2)
	end
	mt.__tostring = function()
		return "Enum." .. enumName .. "." .. itemName
	end
	mt.__metatable = "The metatable is locked"
	H.typeNames[item] = "EnumItem"
	return item
end

local EnumMT = {}
EnumMT.__index = function(self, key)
	local d = enumData[self]
	if key == "GetEnumItems" then
		return function()
			if d.real then
				return d.real:GetEnumItems()
			end
			local out = {}
			for _, item in d.items do
				table.insert(out, item)
			end
			return out
		end
	elseif key == "FromName" then
		return function(_, name)
			local ok, v = pcall(function()
				return d.real[name]
			end)
			return if ok then v else nil
		end
	elseif key == "FromValue" then
		return function(_, value)
			if d.real then
				for _, item in d.real:GetEnumItems() do
					if item.Value == value then
						return item
					end
				end
			end
			return nil
		end
	end
	if d.real then
		local ok, item = pcall(function()
			return d.real[key]
		end)
		if ok and item ~= nil then
			return item
		end
	end
	local item = d.items[key]
	if item == nil and d.real then
		-- the Enum type is known and complete: an unknown item is a typo, as in Roblox
		error(string.format("%s is not a valid member of \"Enum.%s\"", tostring(key), d.name), 2)
	end
	if item == nil then
		H.note(string.format("unmodeled Enum.%s.%s (not in the harness's Roblox database; given a placeholder item)", d.name, tostring(key)))
		item = fakeItem(self, d.name, tostring(key))
		d.items[key] = item
	end
	return item
end
EnumMT.__tostring = function(self)
	return enumData[self].name
end
EnumMT.__metatable = "The metatable is locked"

function D.getEnum(name: string)
	local e = enumCache[name]
	if e then
		return e
	end
	local ok, real = pcall(function()
		return LEnum[name]
	end)
	e = setmetatable({}, EnumMT)
	enumData[e] = { name = name, real = if ok then real else nil, items = {} }
	H.typeNames[e] = "Enum"
	if not ok then
		H.note("unmodeled Enum." .. name .. " (not in the harness's Roblox database)")
	end
	enumCache[name] = e
	return e
end

D.Enum = setmetatable({}, {
	__index = function(_, key)
		if key == "GetEnums" then
			return function()
				return {}
			end
		end
		return D.getEnum(key)
	end,
	__tostring = function()
		return "Enums"
	end,
	__metatable = "The metatable is locked",
})
H.typeNames[D.Enum] = "Enums"

-- The default item of an enum-typed property (value 0, else the first item).
function D.enumDefault(name: string)
	local ok, real = pcall(function()
		return LEnum[name]
	end)
	if not ok or real == nil then
		return nil
	end
	local items = real:GetEnumItems()
	for _, item in items do
		if item.Value == 0 then
			return item
		end
	end
	return items[1]
end

-- ── TweenInfo ────────────────────────────────────────────────────────────────
D.TweenInfo = {
	new = function(time, style, direction, repeatCount, reverses, delayTime)
		if time ~= nil and type(time) ~= "number" then
			error("invalid argument #1 to 'new' (number expected, got " .. typeof(time) .. ")", 2)
		end
		return readonlyType("TweenInfo", {
			Time = time or 1,
			EasingStyle = style or LEnum.EasingStyle.Quad,
			EasingDirection = direction or LEnum.EasingDirection.Out,
			RepeatCount = repeatCount or 0,
			Reverses = reverses or false,
			DelayTime = delayTime or 0,
		})
	end,
}

-- ── Random (deterministic) ───────────────────────────────────────────────────
local function hashSeed(seed: number): number
	seed = math.floor(seed) % 4294967296
	local x = bit32.bxor(seed, 0x9E3779B9)
	if x == 0 then
		x = 0x6D2B79F5
	end
	return x
end

local function newState(seed: number)
	return { a = hashSeed(seed), b = hashSeed(seed * 7 + 13) }
end

local function next32(st): number
	local x = st.a
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	x = bit32.bxor(x, bit32.lshift(x, 5))
	st.a = x
	local y = st.b
	y = bit32.bxor(y, bit32.lshift(y, 11))
	y = bit32.bxor(y, bit32.rshift(y, 19))
	y = bit32.bxor(y, bit32.lshift(y, 7))
	st.b = y
	return bit32.bxor(x, y)
end

local function nextUnit(st): number
	local a, b = next32(st), next32(st)
	return (a * 2097152 + bit32.rshift(b, 11)) / 9007199254740992
end
D.nextUnit = nextUnit
D.newState = newState

local randomCounter = 0
local RandomMethods = {}
local randomState = setmetatable({}, { __mode = "k" })
local function makeRandom(st)
	local obj = readonlyType("Random", {}, RandomMethods)
	randomState[obj] = st
	return obj
end
function RandomMethods.NextNumber(self, min, max)
	local u = nextUnit(randomState[self])
	if min == nil then
		return u
	end
	max = max or 1
	return min + (max - min) * u
end
function RandomMethods.NextInteger(self, min, max)
	if type(min) ~= "number" or type(max) ~= "number" then
		error("invalid argument #1 to 'NextInteger' (number expected)", 2)
	end
	min, max = math.floor(min), math.floor(max)
	if max < min then
		error("invalid argument #2 to 'NextInteger' (max must be greater than or equal to min)", 2)
	end
	return min + math.floor(nextUnit(randomState[self]) * (max - min + 1))
end
function RandomMethods.NextUnitVector(self)
	local st = randomState[self]
	local z = nextUnit(st) * 2 - 1
	local t = nextUnit(st) * 2 * math.pi
	local r = math.sqrt(1 - z * z)
	return roblox.Vector3.new(r * math.cos(t), r * math.sin(t), z)
end
function RandomMethods.Shuffle(self, t)
	local st = randomState[self]
	for i = #t, 2, -1 do
		local j = 1 + math.floor(nextUnit(st) * i)
		t[i], t[j] = t[j], t[i]
	end
end
function RandomMethods.Clone(self)
	local st = randomState[self]
	return makeRandom({ a = st.a, b = st.b })
end

D.Random = {
	new = function(seed)
		if seed == nil then
			randomCounter += 1
			seed = (H.options.seed or 1) * 1000 + randomCounter
		end
		return makeRandom(newState(seed))
	end,
}

-- math.random / math.randomseed replacement (one generator per world)
function D.makeMath(seedOffset: number)
	local st = newState((H.options.seed or 1) + seedOffset)
	local m = table.clone(math)
	m.random = function(a, b)
		local u = nextUnit(st)
		if a == nil then
			return u
		end
		if b == nil then
			a, b = 1, a
		end
		a, b = math.floor(a), math.floor(b)
		if b < a then
			error("invalid argument #2 to 'random' (interval is empty)", 2)
		end
		return a + math.floor(u * (b - a + 1))
	end
	m.randomseed = function(seed)
		local s = newState(seed or 0)
		st.a, st.b = s.a, s.b
	end
	return m
end

-- ── DateTime ─────────────────────────────────────────────────────────────────
local function daysFromCivil(y: number, m: number, d: number): number
	y = if m <= 2 then y - 1 else y
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = math.floor((153 * mp + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

local function pad(n: number, w: number): string
	return string.format("%0" .. w .. "d", n)
end

local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" }
local DateTimeMethods = {}
local dtMillis = setmetatable({}, { __mode = "k" })
local function makeDateTime(ms: number)
	ms = math.floor(ms)
	local obj = readonlyType("DateTime", {
		UnixTimestamp = math.floor(ms / 1000),
		UnixTimestampMillis = ms,
	}, DateTimeMethods)
	dtMillis[obj] = ms
	return obj
end
local function parts(self)
	local ms = dtMillis[self]
	local t = os.date("!*t", math.floor(ms / 1000))
	return { Year = t.year, Month = t.month, Day = t.day, Hour = t.hour, Minute = t.min, Second = t.sec, Millisecond = ms % 1000 }
end
DateTimeMethods.ToUniversalTime = parts
DateTimeMethods.ToLocalTime = parts -- the harness runs in UTC
function DateTimeMethods.ToIsoDate(self)
	local p = parts(self)
	return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ", p.Year, p.Month, p.Day, p.Hour, p.Minute, p.Second)
end
local function format(self, fmt: string)
	local p = parts(self)
	local tokens = {
		YYYY = pad(p.Year, 4), YY = pad(p.Year % 100, 2), MMMM = MONTHS[p.Month], MMM = string.sub(MONTHS[p.Month], 1, 3),
		MM = pad(p.Month, 2), M = tostring(p.Month), DD = pad(p.Day, 2), D = tostring(p.Day),
		HH = pad(p.Hour, 2), H = tostring(p.Hour), hh = pad((p.Hour - 1) % 12 + 1, 2), h = tostring((p.Hour - 1) % 12 + 1),
		mm = pad(p.Minute, 2), m = tostring(p.Minute), ss = pad(p.Second, 2), s = tostring(p.Second),
		A = if p.Hour < 12 then "AM" else "PM", a = if p.Hour < 12 then "am" else "pm",
		LT = string.format("%d:%02d %s", (p.Hour - 1) % 12 + 1, p.Minute, if p.Hour < 12 then "AM" else "PM"),
		LL = string.format("%s %d, %d", MONTHS[p.Month], p.Day, p.Year),
		L = string.format("%02d/%02d/%04d", p.Month, p.Day, p.Year),
	}
	local out = {}
	local i = 1
	local order = { "YYYY", "MMMM", "MMM", "YY", "MM", "DD", "HH", "hh", "mm", "ss", "LT", "LL", "M", "D", "H", "h", "m", "s", "A", "a", "L" }
	while i <= #fmt do
		local matched = false
		for _, tok in order do
			if string.sub(fmt, i, i + #tok - 1) == tok then
				table.insert(out, tokens[tok])
				i += #tok
				matched = true
				break
			end
		end
		if not matched then
			table.insert(out, string.sub(fmt, i, i))
			i += 1
		end
	end
	return table.concat(out)
end
DateTimeMethods.FormatUniversalTime = format
DateTimeMethods.FormatLocalTime = format

local function fromParts(t)
	local days = daysFromCivil(t.Year or t.year or 1970, t.Month or t.month or 1, t.Day or t.day or 1)
	local secs = days * 86400 + (t.Hour or t.hour or 0) * 3600 + (t.Minute or t.min or 0) * 60 + (t.Second or t.sec or 0)
	return secs * 1000 + (t.Millisecond or 0)
end
D.fromParts = fromParts

D.DateTime = {
	now = function()
		return makeDateTime((H.epoch() + H.sched.clock) * 1000)
	end,
	fromUnixTimestamp = function(s)
		return makeDateTime(s * 1000)
	end,
	fromUnixTimestampMillis = function(ms)
		return makeDateTime(ms)
	end,
	fromUniversalTime = function(y, mo, d, h, mi, s, ms)
		return makeDateTime(fromParts({ Year = y, Month = mo, Day = d, Hour = h, Minute = mi, Second = s, Millisecond = ms }))
	end,
	fromLocalTime = function(y, mo, d, h, mi, s, ms)
		return makeDateTime(fromParts({ Year = y, Month = mo, Day = d, Hour = h, Minute = mi, Second = s, Millisecond = ms }))
	end,
	fromIsoDate = function(iso)
		local y, mo, d, h, mi, s = string.match(iso or "", "^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
		if not y then
			return nil
		end
		return makeDateTime(fromParts({ Year = tonumber(y), Month = tonumber(mo), Day = tonumber(d), Hour = tonumber(h), Minute = tonumber(mi), Second = tonumber(s) }))
	end,
}

-- ── RaycastParams / OverlapParams ────────────────────────────────────────────
local function filterMethods()
	return {
		AddToFilter = function(self, v)
			local list = self.FilterDescendantsInstances
			if type(v) == "table" then
				for _, x in v do
					table.insert(list, x)
				end
			else
				table.insert(list, v)
			end
			self.FilterDescendantsInstances = list
		end,
	}
end
D.RaycastParams = {
	new = function()
		return mutableType("RaycastParams", {
			FilterDescendantsInstances = {}, FilterType = LEnum.RaycastFilterType.Exclude, IgnoreWater = false,
			CollisionGroup = "Default", RespectCanCollide = false, BruteForceAllSlow = false,
		}, filterMethods())
	end,
}
D.OverlapParams = {
	new = function()
		return mutableType("OverlapParams", {
			FilterDescendantsInstances = {}, FilterType = LEnum.RaycastFilterType.Exclude, MaxParts = 0,
			CollisionGroup = "Default", RespectCanCollide = false, BruteForceAllSlow = false,
		}, filterMethods())
	end,
}

-- tostring() like Roblox: "1, 2, 3" instead of Lune's "<Vector3(1, 2, 3)>"
function D.tostring(v): string
	local s = tostring(v)
	if type(v) == "userdata" then
		local inner = string.match(s, "^<%w+%((.*)%)>$")
		if inner then
			return inner
		end
	end
	return s
end

return D
