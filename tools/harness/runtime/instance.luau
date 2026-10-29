--!nocheck
-- The Instance model. One raw object per Instance (a plain table), shared by all
-- worlds; game code only ever sees a per-world userdata proxy of it. The proxy
-- answers like Roblox: properties (from the class database), methods, events,
-- then children by name, else "X is not a valid member of Class "Full.Name"".
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local fs = require("@lune/fs")
local H = require("./state")

local I = {}
H.inst = I

local isRaw = setmetatable({}, { __mode = "k" })
local proxyRaw = setmetatable({}, { __mode = "k" })
local proxyWorld = setmetatable({}, { __mode = "k" })
I.isRaw = isRaw

-- ── class database ───────────────────────────────────────────────────────────
local db -- className -> { super, "members" }
local ldb -- Lune's reflection database (defaults, read-only props, creatability)
local classes = {}
local ldbTypeCode
local behaviors = {} -- className -> { methods, get, set, init, defaults, events }

function I.loadClassDb(path: string)
	db = serde.decode("json", fs.readFile(path))
	ldb = roblox.getReflectionDatabase()
end

-- Register behaviour for a class (merged down the class hierarchy).
function I.define(className: string, b)
	local cur = behaviors[className]
	if not cur then
		behaviors[className] = b
		return
	end
	for _, section in { "methods", "get", "set", "defaults" } do
		if b[section] then
			cur[section] = cur[section] or {}
			for k, v in b[section] do
				cur[section][k] = v
			end
		end
	end
	if b.init then
		local old = cur.init
		cur.init = if old then function(raw)
			old(raw)
			b.init(raw)
		end else b.init
	end
	if b.events then
		cur.events = cur.events or {}
		for _, e in b.events do
			table.insert(cur.events, e)
		end
	end
end

local function ldbClass(name: string)
	local ok, c = pcall(function()
		return ldb:GetClass(name)
	end)
	return if ok then c else nil
end

local LDB_TYPES = {
	Bool = "b", String = "s", Float32 = "n", Float64 = "n", Int32 = "n", Int64 = "n", Ref = "iInstance",
	Color3uint8 = "Color3", ContentId = "s",
}
function ldbTypeCode(dt: string): string
	if LDB_TYPES[dt] then
		return LDB_TYPES[dt]
	end
	local enum = string.match(dt, "^Enum%.(%w+)$")
	if enum then
		return "E" .. enum
	end
	for _, known in { "Vector3", "Vector2", "CFrame", "Color3", "UDim2", "UDim", "Rect", "NumberRange", "NumberSequence", "ColorSequence", "BrickColor", "Font" } do
		if dt == known then
			return dt
		end
	end
	return "?"
end

function I.class(name: string)
	local c = classes[name]
	if c then
		return c
	end
	local entry = db[name]
	c = {
		name = name, known = entry ~= nil, members = {}, methods = {}, getters = {}, setters = {}, isA = { [name] = true },
		defaults = {}, inits = {}, readonly = {},
	}
	classes[name] = c
	local superName = if entry then entry[1] else (if name ~= "Instance" then "Instance" else "")
	if superName ~= "" then
		local s = I.class(superName)
		c.super = s
		for k, v in s.members do c.members[k] = v end
		for k, v in s.methods do c.methods[k] = v end
		for k, v in s.getters do c.getters[k] = v end
		for k, v in s.setters do c.setters[k] = v end
		for k, v in s.defaults do c.defaults[k] = v end
		for k, v in s.isA do c.isA[k] = v end
		for k, v in s.readonly do c.readonly[k] = v end
		for _, f in s.inits do table.insert(c.inits, f) end
	end
	if entry then
		for item in string.gmatch(entry[2], "[^,]+") do
			local first = string.sub(item, 1, 1)
			if first == "!" then
				c.members[string.sub(item, 2)] = "!"
			elseif first == "^" then
				c.members[string.sub(item, 2)] = "^"
			else
				local n, t = string.match(item, "^(.-):(.*)$")
				c.members[n] = ":" .. t
			end
		end
	end
	local lc = ldbClass(name)
	c.ldb = lc
	if lc then
		for pname, prop in lc.Properties do
			if prop.Scriptability == "Read" then
				c.readonly[pname] = true
			end
			-- deprecated properties (Velocity, FilteringEnabled, NumPlayers, ...) are
			-- missing from the luau-lsp definitions but still work in Roblox
			local upper = string.upper(string.sub(pname, 1, 1)) .. string.sub(pname, 2)
			local isAlias = upper ~= pname and (c.members[upper] ~= nil or lc.Properties[upper] ~= nil)
			if c.members[pname] == nil and prop.Scriptability ~= "None" and not isAlias then
				c.members[pname] = ":" .. ldbTypeCode(prop.Datatype)
			end
		end
		local tags = lc.Tags or {}
		c.notCreatable = table.find(tags, "NotCreatable") ~= nil
		c.service = table.find(tags, "Service") ~= nil
	end
	local b = behaviors[name]
	if b then
		for k, v in b.methods or {} do c.methods[k] = v end
		for k, v in b.get or {} do c.getters[k] = v; c.readonly[k] = nil end
		for k, v in b.set or {} do c.setters[k] = v; c.readonly[k] = nil end
		for k, v in b.defaults or {} do c.defaults[k] = v end
		for _, e in b.events or {} do c.members[e] = "^" end
		if b.init then table.insert(c.inits, b.init) end
		if b.props then
			for k, t in b.props do
				c.members[k] = ":" .. t
			end
		end
	end
	return c
end

-- ── raw instances ────────────────────────────────────────────────────────────
local nextId = 0

function I.new(className: string, owner: string?)
	local cls = I.class(className)
	nextId += 1
	local raw = {
		ClassName = className, Name = className, class = cls, children = {}, props = {}, attrs = {}, tags = {},
		owner = owner, id = nextId,
	}
	isRaw[raw] = true
	for _, f in cls.inits do
		f(raw)
	end
	return raw
end

-- ── proxies ──────────────────────────────────────────────────────────────────
local index, newindex, lowerAlias

local function proxyToString(p)
	return proxyRaw[p].Name
end

function I.wrap(world, raw)
	if raw == nil then
		return nil
	end
	local cache = world.proxies
	local p = cache[raw]
	if p then
		return p
	end
	p = newproxy(true)
	local mt = getmetatable(p)
	mt.__index = index
	mt.__newindex = newindex
	mt.__tostring = proxyToString
	mt.__metatable = "The metatable is locked"
	proxyRaw[p] = raw
	proxyWorld[p] = world
	cache[raw] = p
	return p
end

function I.rawOf(v)
	if type(v) == "userdata" then
		return proxyRaw[v]
	end
	return nil
end

function I.worldOfProxy(v)
	return proxyWorld[v]
end

function I.isInstance(v): boolean
	return type(v) == "userdata" and proxyRaw[v] ~= nil
end

-- method `self` check, like Roblox's "Expected ':' not '.'"
function I.self(self, method: string)
	local raw = if type(self) == "userdata" then proxyRaw[self] else nil
	if raw == nil then
		error(string.format("Expected ':' not '.' calling member function %s", method), 3)
	end
	return raw, proxyWorld[self]
end

-- engine value -> value for `world` (raw Instance -> that world's proxy)
function I.export(world, v)
	if type(v) == "table" and isRaw[v] then
		return I.wrap(world, v)
	elseif type(v) == "userdata" then
		local r = proxyRaw[v]
		if r and proxyWorld[v] ~= world then
			return I.wrap(world, r)
		end
	end
	return v
end

function I.exportArgs(world, args)
	local out = { n = args.n }
	for i = 1, args.n do
		out[i] = I.export(world, args[i])
	end
	return out
end

-- game value -> engine value (proxy -> raw)
function I.import(v)
	if type(v) == "userdata" then
		local r = proxyRaw[v]
		if r then
			return r
		end
	end
	return v
end

-- ── tree helpers ─────────────────────────────────────────────────────────────
function I.fullName(raw): string
	local parts = {}
	local r = raw
	while r and r.ClassName ~= "DataModel" do
		table.insert(parts, 1, r.Name)
		r = r.Parent
	end
	return table.concat(parts, ".")
end

function I.isDescendantOf(raw, anc): boolean
	local p = raw.Parent
	while p do
		if p == anc then
			return true
		end
		p = p.Parent
	end
	return false
end

function I.inGame(raw): boolean
	local r = raw
	while r do
		if r == H.game then
			return true
		end
		r = r.Parent
	end
	return false
end

-- Can `world` see this instance? The server sees everything not created by a
-- client; a client sees replicated instances plus its own, never the contents
-- of ServerStorage / ServerScriptService.
function I.visible(raw, world): boolean
	if world == nil or raw == nil then
		return true
	end
	if world.kind == "server" then
		return raw.owner == nil
	end
	if raw.owner ~= nil and raw.owner ~= world.id then
		return false
	end
	local p = raw.Parent
	while p do
		if p.hideChildren then
			return false
		end
		p = p.Parent
	end
	return true
end

function I.findChild(raw, name, world)
	for _, c in raw.children do
		if c.Name == name and I.visible(c, world) then
			return c
		end
	end
	return nil
end

function I.descendants(raw, out)
	out = out or {}
	for _, c in raw.children do
		table.insert(out, c)
		I.descendants(c, out)
	end
	return out
end

function I.isA(raw, className: string): boolean
	return raw.class.isA[className] == true
end

-- ── signals ──────────────────────────────────────────────────────────────────
function I.signal(raw, name: string)
	raw.sigs = raw.sigs or {}
	local s = raw.sigs[name]
	if not s then
		s = H.sig.new(name, raw)
		raw.sigs[name] = s
	end
	return s
end

function I.fire(raw, name: string, ...)
	local s = raw.sigs and raw.sigs[name]
	if s and #s.conns > 0 then
		H.sig.fireVisible(s, raw, ...)
	end
end

-- fire about `subject` (only worlds that can see subject get it)
function I.fireAbout(raw, name: string, subject, ...)
	local s = raw.sigs and raw.sigs[name]
	if s and #s.conns > 0 then
		local args = table.pack(...)
		for _, c in table.clone(s.conns) do
			if I.visible(subject, c.world) and I.visible(raw, c.world) then
				H.sig.deliver(c, args)
			end
		end
	end
end

function I.propSignal(raw, prop: string)
	raw.propSigs = raw.propSigs or {}
	local s = raw.propSigs[prop]
	if not s then
		s = H.sig.new(prop .. "Changed", raw)
		raw.propSigs[prop] = s
	end
	return s
end

function I.changed(raw, key: string)
	if raw.propSigs and raw.propSigs[key] then
		H.sig.fireVisible(raw.propSigs[key], raw)
	end
	if raw.sigs and raw.sigs.Changed then
		if raw.class.isA.ValueBase then
			if key == "Value" then
				H.sig.fireVisible(raw.sigs.Changed, raw, raw.props.Value)
			end
		else
			H.sig.fireVisible(raw.sigs.Changed, raw, key)
		end
	end
end

-- ── properties ───────────────────────────────────────────────────────────────
local D = nil
local function typeDefault(code: string)
	D = D or H.dt
	if code == "n" then
		return 0
	elseif code == "s" then
		return ""
	elseif code == "b" then
		return false
	elseif code == "Vector3" then
		return D.Vector3.zero
	elseif code == "Vector2" then
		return D.Vector2.zero
	elseif code == "CFrame" then
		return D.CFrame.new()
	elseif code == "Color3" then
		return D.Color3.new()
	elseif code == "UDim2" then
		return D.UDim2.new()
	elseif code == "UDim" then
		return D.UDim.new()
	elseif code == "Rect" then
		return D.Rect.new(0, 0, 0, 0)
	elseif code == "NumberRange" then
		return D.NumberRange.new(0)
	elseif code == "NumberSequence" then
		return D.NumberSequence.new(0)
	elseif code == "ColorSequence" then
		return D.ColorSequence.new(D.Color3.new())
	elseif code == "BrickColor" then
		return D.BrickColor.new("Medium stone grey")
	elseif code == "Font" then
		return D.Font.fromEnum(roblox.Enum.Font.SourceSans)
	elseif code == "Content" then
		return ""
	elseif code == "Faces" then
		return D.Faces.new()
	elseif code == "Axes" then
		return D.Axes.new()
	elseif string.sub(code, 1, 1) == "E" then
		return D.enumDefault(string.sub(code, 2))
	end
	return nil
end

local function matchesCode(v, code: string): boolean
	if code == "n" then
		return type(v) == "number"
	elseif code == "s" then
		return type(v) == "string"
	elseif code == "b" then
		return type(v) == "boolean"
	elseif code == "?" then
		local t = typeof(v)
		return t == "number" or t == "string" or t == "boolean" or t == "EnumItem" or t == "Vector3" or t == "Color3"
	elseif string.sub(code, 1, 1) == "E" then
		return typeof(v) == "EnumItem"
	end
	return typeof(v) == code
end

function I.default(raw, key: string, kind: string)
	local cls = raw.class
	local d = cls.defaults[key]
	if d ~= nil then
		if type(d) == "function" then
			return d(raw)
		end
		return d
	end
	local code = string.sub(kind, 2)
	local cache = cls.defaultCache
	if not cache then
		cache = {}
		cls.defaultCache = cache
	end
	local v = cache[key]
	if v ~= nil then
		return v
	end
	if cls.ldb then
		local ok, dv = pcall(function()
			return cls.ldb.DefaultProperties[key]
		end)
		if ok and dv ~= nil and matchesCode(dv, code) then
			v = dv
		end
	end
	if v == nil then
		v = typeDefault(code)
	end
	if v ~= nil then
		cache[key] = v
	end
	return v
end

function I.getProp(raw, key: string)
	local v = raw.props[key]
	if v ~= nil then
		return v
	end
	local kind = raw.class.members[key]
	if kind and string.sub(kind, 1, 1) == ":" then
		return I.default(raw, key, kind)
	end
	return nil
end

function I.setProp(raw, key: string, v)
	local old = raw.props[key]
	if old == nil then
		old = I.getProp(raw, key)
	end
	raw.props[key] = v
	if old ~= v then
		I.changed(raw, key)
	end
end

-- ── client-local writes ──────────────────────────────────────────────────────
-- In Roblox a client that changes a property or attribute of an instance the
-- server owns changes only its own copy: the server (and other clients) never
-- see it, until the server writes that property again. Exception: the physics
-- of the player's own character replicate (the client owns them).
local NIL = newproxy(false)
local PHYSICS = { CFrame = true, Position = true, Orientation = true, Rotation = true, AssemblyLinearVelocity = true,
	AssemblyAngularVelocity = true, Velocity = true, RotVelocity = true }

local function isLocalWrite(raw, world, key): boolean
	if world == nil or world.kind ~= "client" or raw.owner == world.id then
		return false
	end
	if key and PHYSICS[key] and raw.class.isA.BasePart and world.player then
		local char = world.player.props.Character
		if char and I.isDescendantOf(raw, char) then
			return false
		end
	end
	return true
end
I.isLocalWrite = isLocalWrite

local function localState(raw, world)
	raw.locals = raw.locals or {}
	local l = raw.locals[world]
	if not l then
		l = { props = {}, attrs = {} }
		raw.locals[world] = l
	end
	return l
end

-- the property as `world` sees it (engine form); second result: overridden
function I.readProp(raw, world, key: string)
	local l = world and raw.locals and raw.locals[world]
	if l then
		local v = l.props[key]
		if v == NIL then
			return nil, true
		elseif v ~= nil then
			return v, true
		end
	end
	local v = raw.props[key]
	if v == nil then
		v = I.getProp(raw, key)
	end
	return v, false
end

local function changedFor(raw, key: string, world)
	if raw.propSigs and raw.propSigs[key] then
		H.sig.fireWorld(raw.propSigs[key], world)
	end
	if raw.sigs and raw.sigs.Changed then
		if raw.class.isA.ValueBase then
			if key == "Value" then
				H.sig.fireWorld(raw.sigs.Changed, world, (I.readProp(raw, world, "Value")))
			end
		else
			H.sig.fireWorld(raw.sigs.Changed, world, key)
		end
	end
end

-- a game write: local to the client when Roblox would not replicate it
function I.setPropFrom(raw, world, key: string, v)
	if isLocalWrite(raw, world, key) then
		local old = I.readProp(raw, world, key)
		localState(raw, world).props[key] = if v == nil then NIL else v
		if old ~= v then
			changedFor(raw, key, world)
		end
		return
	end
	if raw.locals then
		for _, l in raw.locals do
			l.props[key] = nil -- the owner's write replicates over local copies
		end
	end
	I.setProp(raw, key, v)
end

function I.getAttributeFor(raw, world, name)
	local l = world and raw.locals and raw.locals[world]
	if l then
		local v = l.attrs[name]
		if v == NIL then
			return nil
		elseif v ~= nil then
			return v
		end
	end
	return raw.attrs[name]
end

function I.getAttributesFor(raw, world)
	local out = table.clone(raw.attrs)
	local l = world and raw.locals and raw.locals[world]
	if l then
		for k, v in l.attrs do
			out[k] = if v == NIL then nil else v
		end
	end
	return out
end

local function coerce(raw, key: string, code: string, v, level: number)
	local t = H.typeof(v)
	if code == "s" then
		if t == "string" then
			return v
		elseif t == "number" then
			return tostring(v)
		end
		error(string.format("Unable to assign property %s. string expected, got %s", key, t), level)
	elseif code == "n" then
		if t == "number" then
			return v
		elseif t == "string" and tonumber(v) then
			return tonumber(v)
		end
		error(string.format("Unable to assign property %s. number expected, got %s", key, t), level)
	elseif code == "b" then
		if t == "boolean" then
			return v
		end
		error(string.format("Unable to assign property %s. bool expected, got %s", key, t), level)
	elseif code == "Content" then
		if t == "string" or t == "Content" then
			return v
		end
		error(string.format("Unable to assign property %s. Content expected, got %s", key, t), level)
	elseif string.sub(code, 1, 1) == "E" then
		if t == "EnumItem" then
			return v
		elseif t == "number" or t == "string" then
			-- Roblox accepts an item's Value or Name
			local enum = H.dt.getEnum(string.sub(code, 2))
			for _, item in enum:GetEnumItems() do
				if item.Value == v or item.Name == v then
					return item
				end
			end
			error(string.format("Unable to assign property %s. EnumItem, number or string expected, got %s", key, t), level)
		end
		error(string.format("Unable to assign property %s. EnumItem expected, got %s", key, t), level)
	elseif code == "?" then
		return v
	elseif string.sub(code, 1, 1) == "i" then
		-- an Instance property: nil or an Instance of the declared class
		if v == nil then
			return nil
		end
		local r = if type(v) == "userdata" then proxyRaw[v] else nil
		if r == nil then
			error(string.format("Unable to assign property %s. Object expected, got %s", key, t), level)
		end
		local want = string.sub(code, 2)
		if r.class.known and not r.class.isA[want] then
			error(string.format("Unable to assign property %s. %s expected, got %s", key, want, r.ClassName), level)
		end
		return v
	elseif code == "Font" or code == "PhysicalProperties" or code == "Ray" or code == "Region3" then
		return v
	end
	if t ~= code then
		error(string.format("Unable to assign property %s. %s expected, got %s", key, code, t), level)
	end
	return v
end
I.coerce = coerce

local unmodeledMethods = {}
local function unmodeledMethod(className: string, key: string)
	local id = className .. ":" .. key
	local f = unmodeledMethods[id]
	if not f then
		f = function(self, ...)
			H.note(string.format("unmodeled method %s() (returned nil)", id))
			return nil
		end
		unmodeledMethods[id] = f
	end
	return f
end

local function notMember(raw, key)
	return string.format("%s is not a valid member of %s \"%s\"", tostring(key), raw.ClassName, I.fullName(raw))
end
I.notMember = notMember

function lowerAlias(cls, key)
	if type(key) ~= "string" or not string.match(key, "^%l") then
		return nil
	end
	local alt = string.upper(string.sub(key, 1, 1)) .. string.sub(key, 2)
	local kind = cls.members[alt]
	if (kind and string.sub(kind, 1, 1) == ":") or cls.getters[alt] or cls.methods[alt] or kind == "!" or kind == "^" then
		return alt
	end
	return nil
end

index = function(p, key)
	local raw = proxyRaw[p]
	local world = proxyWorld[p]
	local cls = raw.class
	local m = cls.methods[key]
	if m then
		return m
	end
	local g = cls.getters[key]
	if g then
		return g(raw, world)
	end
	local kind = cls.members[key]
	if kind then
		local c1 = string.sub(kind, 1, 1)
		if c1 == ":" then
			local v, overridden = I.readProp(raw, world, key)
			if v == nil and not overridden then
				v = I.default(raw, key, kind)
			end
			return I.export(world, v)
		elseif c1 == "^" then
			return H.sig.proxy(world, I.signal(raw, key))
		end
	end
	if type(key) == "string" then
		local child = I.findChild(raw, key, world)
		if child then
			return I.wrap(world, child)
		end
	end
	if kind == "!" then
		return unmodeledMethod(cls.name, key)
	end
	if not cls.known then
		return I.export(world, (I.readProp(raw, world, key)))
	end
	-- Roblox keeps deprecated lowercase aliases (player.userId, sound.isPlaying)
	local alias = lowerAlias(cls, key)
	if alias then
		return index(p, alias)
	end
	error(notMember(raw, key), 2)
end

newindex = function(p, key, value)
	local raw = proxyRaw[p]
	local world = proxyWorld[p]
	local cls = raw.class
	local s = cls.setters[key]
	if s then
		s(raw, world, value)
		return
	end
	local kind = cls.members[key]
	if kind and string.sub(kind, 1, 1) == ":" then
		if cls.readonly[key] then
			error(string.format("Unable to assign property %s. Property is read only", key), 2)
		end
		if raw.destroyed and key ~= "Parent" then
			-- allowed in Roblox; nothing listens anymore
		end
		value = coerce(raw, key, string.sub(kind, 2), value, 3)
		I.setPropFrom(raw, world, key, I.import(value))
		return
	end
	if not cls.known then
		I.setPropFrom(raw, world, key, I.import(value))
		return
	end
	if kind == "!" or kind == "^" then
		error(string.format("%s cannot be assigned to", tostring(key)), 2)
	end
	local alias = lowerAlias(cls, key)
	if alias then
		newindex(p, alias, value)
		return
	end
	error(notMember(raw, key), 2)
end

-- ── parenting ────────────────────────────────────────────────────────────────
local function anyConnections(raw, name)
	local s = raw.sigs and raw.sigs[name]
	return s ~= nil and #s.conns > 0
end

local function fireTagsFor(raw, entering: boolean)
	local list = { raw }
	I.descendants(raw, list)
	for _, r in list do
		for tag in r.tags do
			if H.tagEnter then
				H.tagEnter(r, tag, entering)
			end
		end
	end
end

function I.setParent(raw, newParent, level: number?)
	level = (level or 2) + 1
	if raw.parentLocked then
		error(string.format("The Parent property of %s is locked, current parent: %s, new parent %s", raw.Name,
			if raw.Parent then raw.Parent.Name else "NULL", if newParent then newParent.Name else "NULL"), level)
	end
	local old = raw.Parent
	if newParent == old then
		return
	end
	if newParent and (newParent == raw or I.isDescendantOf(newParent, raw)) then
		error(string.format("Attempt to set parent of %s to %s would result in circular reference", I.fullName(raw), I.fullName(newParent)), level)
	end
	local wasInGame = I.inGame(raw)
	if old then
		-- DescendantRemoving on the old ancestors, before the removal
		local a = old
		local subtree
		while a do
			if anyConnections(a, "DescendantRemoving") then
				subtree = subtree or I.descendants(raw, { raw })
				for _, d in subtree do
					I.fireAbout(a, "DescendantRemoving", d, d)
				end
			end
			a = a.Parent
		end
		local list = old.children
		for i, c in list do
			if c == raw then
				table.remove(list, i)
				break
			end
		end
		raw.Parent = nil
		I.fireAbout(old, "ChildRemoved", raw, raw)
	end
	raw.Parent = newParent
	if newParent then
		table.insert(newParent.children, raw)
		I.fireAbout(newParent, "ChildAdded", raw, raw)
		local a = newParent
		local subtree
		while a do
			if anyConnections(a, "DescendantAdded") then
				subtree = subtree or I.descendants(raw, { raw })
				for _, d in subtree do
					I.fireAbout(a, "DescendantAdded", d, d)
				end
			end
			a = a.Parent
		end
		I.wakeChildWaiters(newParent, raw)
	end
	-- AncestryChanged on the instance and every descendant
	if anyConnections(raw, "AncestryChanged") then
		I.fire(raw, "AncestryChanged", raw, newParent)
	end
	for _, d in I.descendants(raw) do
		if anyConnections(d, "AncestryChanged") then
			I.fire(d, "AncestryChanged", raw, newParent)
		end
	end
	I.changed(raw, "Parent")
	local nowInGame = I.inGame(raw)
	if wasInGame ~= nowInGame then
		fireTagsFor(raw, nowInGame)
	end
	if H.onParented then
		H.onParented(raw, old)
	end
end

function I.wakeChildWaiters(parent, child)
	local waiters = parent.childWaiters
	if not waiters then
		return
	end
	local keep = {}
	for _, wt in waiters do
		if not H.sched.valid(wt.w) then
			continue
		end
		if wt.name == child.Name and I.visible(child, wt.world) then
			H.sched.wakeDeferred(wt.w, child)
		else
			table.insert(keep, wt)
		end
	end
	parent.childWaiters = keep
end

function I.destroy(raw)
	if raw.destroyed then
		return
	end
	if raw.serviceLocked then
		error(string.format("The Parent property of %s is locked", raw.Name), 3)
	end
	if anyConnections(raw, "Destroying") then
		local s = raw.sigs.Destroying
		local args = table.pack(nil)
		for _, c in table.clone(s.conns) do
			if c.once then H.sig.disconnect(c) end
			H.sched.spawn(c.fn, c.world)
		end
	end
	if raw.onDestroy then
		raw.onDestroy(raw)
	end
	if raw.Parent then
		I.setParent(raw, nil)
	end
	raw.parentLocked = true
	raw.destroyed = true
	for _, c in table.clone(raw.children) do
		I.destroy(c)
	end
	for _, s in raw.sigs or {} do
		H.sig.disconnectAll(s)
	end
	for _, s in raw.propSigs or {} do
		H.sig.disconnectAll(s)
	end
	for _, s in raw.attrSigs or {} do
		H.sig.disconnectAll(s)
	end
end

function I.clone(raw, owner)
	if raw.props.Archivable == false then
		return nil
	end
	local map = {}
	local function cp(r)
		if r.props.Archivable == false then
			return nil
		end
		nextId += 1
		local c = {
			ClassName = r.ClassName, Name = r.Name, class = r.class, children = {}, props = table.clone(r.props),
			attrs = table.clone(r.attrs), tags = table.clone(r.tags), owner = owner, id = nextId, source = r.source,
			scriptKind = r.scriptKind,
		}
		isRaw[c] = true
		if r.cloneState then
			r.cloneState(r, c)
		end
		map[r] = c
		for _, ch in r.children do
			local cc = cp(ch)
			if cc then
				cc.Parent = c
				table.insert(c.children, cc)
			end
		end
		return c
	end
	local root = cp(raw)
	for _, c in map do
		for k, v in c.props do
			if type(v) == "table" and isRaw[v] and map[v] then
				c.props[k] = map[v]
			end
		end
	end
	return root
end

-- ── attributes ───────────────────────────────────────────────────────────────
local ATTR_TYPES = {
	string = true, boolean = true, number = true, UDim = true, UDim2 = true, BrickColor = true, Color3 = true,
	Vector2 = true, Vector3 = true, CFrame = true, NumberSequence = true, ColorSequence = true, NumberRange = true,
	Rect = true, Font = true, EnumItem = true,
}

function I.setAttribute(raw, name, value, level, world)
	if type(name) ~= "string" then
		error("Argument 1 missing or nil", level)
	end
	if #name > 100 or not string.match(name, "^[%w_]+$") or string.sub(name, 1, 3) == "RBX" then
		error(string.format("Attribute name '%s' is invalid (letters, digits and _ only, at most 100, not starting with RBX)", name), level)
	end
	if value ~= nil and not ATTR_TYPES[H.typeof(value)] then
		error(string.format("SetAttribute failed: %s is not a supported attribute type", H.typeof(value)), level)
	end
	if isLocalWrite(raw, world, nil) then
		local old = I.getAttributeFor(raw, world, name)
		localState(raw, world).attrs[name] = if value == nil then NIL else value
		if old ~= value then
			if raw.attrSigs and raw.attrSigs[name] then
				H.sig.fireWorld(raw.attrSigs[name], world)
			end
			if raw.sigs and raw.sigs.AttributeChanged then
				H.sig.fireWorld(raw.sigs.AttributeChanged, world, name)
			end
		end
		return
	end
	if raw.locals then
		for _, l in raw.locals do
			l.attrs[name] = nil
		end
	end
	local old = raw.attrs[name]
	raw.attrs[name] = value
	if old ~= value then
		if raw.attrSigs and raw.attrSigs[name] then
			H.sig.fireVisible(raw.attrSigs[name], raw)
		end
		I.fire(raw, "AttributeChanged", name)
	end
end

function I.attrSignal(raw, name)
	raw.attrSigs = raw.attrSigs or {}
	local s = raw.attrSigs[name]
	if not s then
		s = H.sig.new(name .. "AttributeChanged", raw)
		raw.attrSigs[name] = s
	end
	return s
end

-- ── services ─────────────────────────────────────────────────────────────────
function I.service(name: string)
	local game = H.game
	for _, c in game.children do
		if c.ClassName == name and c.isService then
			return c
		end
	end
	local raw = I.new(name, nil)
	raw.isService = true
	raw.Name = if name == "Workspace" then "Workspace" else name
	I.setParent(raw, game)
	raw.parentLocked = true
	raw.serviceLocked = true
	if not raw.class.known then
		H.note("unmodeled service " .. name .. " (generic instance)")
	end
	return raw
end

function H.typeof(v): string
	if type(v) == "userdata" and proxyRaw[v] then
		return "Instance"
	end
	if v ~= nil then
		local n = H.typeNames[v]
		if n then
			return n
		end
	end
	return typeof(v)
end

return I
