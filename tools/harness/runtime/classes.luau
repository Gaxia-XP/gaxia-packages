--!nocheck
-- Behaviour of Instance and common classes (methods, computed properties).
-- Anything not here falls back to the class database: properties read their
-- Roblox default, unknown methods return nil and are noted as "unmodeled".
local H = require("./state")
local I = require("./instance")
local S = require("./sched")
local D = require("./datatypes")
local roblox = require("@lune/roblox")

local wrap, self_ = I.wrap, I.self
local Enum = roblox.Enum

local function ownerFor(world)
	return if world and world.kind == "client" then world.id else nil
end
H.ownerFor = ownerFor

local function nameArg(name, level)
	if type(name) == "number" then
		return tostring(name)
	end
	if type(name) ~= "string" then
		error("Argument 1 missing or nil", level + 1)
	end
	return name
end

local function wrapList(world, list)
	local out = table.create(#list)
	for _, r in list do
		table.insert(out, wrap(world, r))
	end
	return out
end

local function visibleDescendants(raw, world, out)
	for _, c in raw.children do
		if I.visible(c, world) then
			table.insert(out, c)
			visibleDescendants(c, world, out)
		end
	end
	return out
end
I.visibleDescendants = visibleDescendants

local function classArg(v, level)
	if type(v) ~= "string" then
		error("Argument 1 missing or nil", level + 1)
	end
	return v
end

-- engine-side delay (not a game thread): errors here are harness bugs
function H.afterDelay(seconds: number, fn)
	local co = S.create(function()
		local ok, err = pcall(fn)
		if not ok then
			H.harnessError("engine timer failed: " .. tostring(err))
		end
	end, nil)
	S.delayThread(co, seconds, nil)
	return co
end

-- the stack of a suspended game thread, for warnings and hang reports
function H.traceOf(co): string?
	return S.formatTrace(debug.traceback(co))
end

local m = {}

function m.FindFirstChild(self, name, recursive)
	local raw, world = self_(self, "FindFirstChild")
	name = nameArg(name, 2)
	if recursive then
		for _, d in visibleDescendants(raw, world, {}) do
			if d.Name == name then
				return wrap(world, d)
			end
		end
		return nil
	end
	return wrap(world, I.findChild(raw, name, world))
end
function m.FindFirstChildOfClass(self, cls)
	local raw, world = self_(self, "FindFirstChildOfClass")
	cls = classArg(cls, 2)
	for _, c in raw.children do
		if c.ClassName == cls and I.visible(c, world) then
			return wrap(world, c)
		end
	end
	return nil
end
function m.FindFirstChildWhichIsA(self, cls, recursive)
	local raw, world = self_(self, "FindFirstChildWhichIsA")
	cls = classArg(cls, 2)
	local list = if recursive then visibleDescendants(raw, world, {}) else raw.children
	for _, c in list do
		if c.class.isA[cls] and I.visible(c, world) then
			return wrap(world, c)
		end
	end
	return nil
end
function m.FindFirstDescendant(self, name)
	local raw, world = self_(self, "FindFirstDescendant")
	name = nameArg(name, 2)
	for _, d in visibleDescendants(raw, world, {}) do
		if d.Name == name then
			return wrap(world, d)
		end
	end
	return nil
end
function m.FindFirstAncestor(self, name)
	local raw, world = self_(self, "FindFirstAncestor")
	local p = raw.Parent
	while p do
		if p.Name == name then
			return wrap(world, p)
		end
		p = p.Parent
	end
	return nil
end
function m.FindFirstAncestorOfClass(self, cls)
	local raw, world = self_(self, "FindFirstAncestorOfClass")
	local p = raw.Parent
	while p do
		if p.ClassName == cls then
			return wrap(world, p)
		end
		p = p.Parent
	end
	return nil
end
function m.FindFirstAncestorWhichIsA(self, cls)
	local raw, world = self_(self, "FindFirstAncestorWhichIsA")
	local p = raw.Parent
	while p do
		if p.class.isA[cls] then
			return wrap(world, p)
		end
		p = p.Parent
	end
	return nil
end
function m.GetChildren(self)
	local raw, world = self_(self, "GetChildren")
	local out = {}
	for _, c in raw.children do
		if I.visible(c, world) then
			table.insert(out, wrap(world, c))
		end
	end
	return out
end
function m.GetDescendants(self)
	local raw, world = self_(self, "GetDescendants")
	return wrapList(world, visibleDescendants(raw, world, {}))
end
function m.IsA(self, cls)
	local raw = self_(self, "IsA")
	return raw.class.isA[cls] == true
end
function m.IsDescendantOf(self, other)
	local raw = self_(self, "IsDescendantOf")
	local o = I.import(other)
	if o == nil then
		return false
	end
	return I.isDescendantOf(raw, o)
end
function m.IsAncestorOf(self, other)
	local raw = self_(self, "IsAncestorOf")
	local o = I.import(other)
	if o == nil then
		return false
	end
	return I.isDescendantOf(o, raw)
end
function m.GetFullName(self)
	local raw = self_(self, "GetFullName")
	return I.fullName(raw)
end
function m.WaitForChild(self, name, timeout)
	local raw, world = self_(self, "WaitForChild")
	name = nameArg(name, 2)
	local c = I.findChild(raw, name, world)
	if c then
		return wrap(world, c)
	end
	if timeout ~= nil and type(timeout) ~= "number" then
		error("invalid argument #2 to 'WaitForChild' (number expected, got " .. H.typeof(timeout) .. ")", 2)
	end
	local text = string.format("%s:WaitForChild(\"%s\")", I.fullName(raw), name)
	local w = S.suspend({ kind = "WaitForChild", text = text, since = S.clock, timeout = timeout })
	raw.childWaiters = raw.childWaiters or {}
	table.insert(raw.childWaiters, { name = name, w = w, world = world })
	if timeout then
		S.sleep(w, timeout, table.pack(nil))
	else
		H.afterDelay(5, function()
			if S.valid(w) then
				H.warn(world.id, string.format("Infinite yield possible on '%s'", text), nil, H.traceOf(w.co))
			end
		end)
	end
	local result = coroutine.yield()
	if result == nil then
		return nil
	end
	return wrap(world, result)
end
function m.Clone(self)
	local raw, world = self_(self, "Clone")
	return wrap(world, I.clone(raw, ownerFor(world)))
end
function m.Destroy(self)
	local raw = self_(self, "Destroy")
	I.destroy(raw)
end
function m.Remove(self)
	local raw = self_(self, "Remove")
	I.setParent(raw, nil)
end
function m.ClearAllChildren(self)
	local raw, world = self_(self, "ClearAllChildren")
	for _, c in table.clone(raw.children) do
		if I.visible(c, world) then
			I.destroy(c)
		end
	end
end
function m.GetAttribute(self, name)
	local raw, world = self_(self, "GetAttribute")
	if type(name) ~= "string" then
		error("Argument 1 missing or nil", 2)
	end
	return I.getAttributeFor(raw, world, name)
end
function m.SetAttribute(self, name, value)
	local raw, world = self_(self, "SetAttribute")
	I.setAttribute(raw, name, value, 3, world)
end
function m.GetAttributes(self)
	local raw, world = self_(self, "GetAttributes")
	return I.getAttributesFor(raw, world)
end
function m.GetAttributeChangedSignal(self, name)
	local raw, world = self_(self, "GetAttributeChangedSignal")
	return H.sig.proxy(world, I.attrSignal(raw, name))
end
function m.GetPropertyChangedSignal(self, prop)
	local raw, world = self_(self, "GetPropertyChangedSignal")
	local kind = raw.class.members[prop]
	if raw.class.known and not (kind and string.sub(kind, 1, 1) == ":") and not raw.class.getters[prop] then
		error(string.format("%s is not a valid property name.", tostring(prop)), 2)
	end
	return H.sig.proxy(world, I.propSignal(raw, prop))
end
function m.AddTag(self, tag)
	local raw = self_(self, "AddTag")
	H.addTag(raw, tag)
end
function m.RemoveTag(self, tag)
	local raw = self_(self, "RemoveTag")
	H.removeTag(raw, tag)
end
function m.HasTag(self, tag)
	local raw = self_(self, "HasTag")
	return raw.tags[tag] == true
end
function m.GetTags(self)
	local raw = self_(self, "GetTags")
	local out = {}
	for t in raw.tags do
		table.insert(out, t)
	end
	table.sort(out)
	return out
end
function m.GetActor()
	return nil
end
function m.GetDebugId(self)
	local raw = self_(self, "GetDebugId")
	return tostring(raw.id)
end
function m.IsPropertyModified(self, prop)
	local raw = self_(self, "IsPropertyModified")
	return raw.props[prop] ~= nil
end
function m.ResetPropertyToDefault(self, prop)
	local raw = self_(self, "ResetPropertyToDefault")
	raw.props[prop] = nil
	I.changed(raw, prop)
end
function m.GetStyled(self, prop)
	return self[prop]
end
m.findFirstChild = m.FindFirstChild
m.getChildren = m.GetChildren
m.children = m.GetChildren
m.clone = m.Clone
m.destroy = m.Destroy
m.remove = m.Remove
m.isA = m.IsA
m.isDescendantOf = m.IsDescendantOf

I.define("Instance", {
	methods = m,
	get = {
		Name = function(raw)
			return raw.Name
		end,
		ClassName = function(raw)
			return raw.ClassName
		end,
		Parent = function(raw, world)
			local p = raw.Parent
			if p == nil or not I.visible(p, world) then
				return nil
			end
			return wrap(world, p)
		end,
	},
	set = {
		Name = function(raw, world, v)
			v = I.coerce(raw, "Name", "s", v, 4)
			if raw.Name == v then
				return
			end
			raw.Name = v
			I.changed(raw, "Name")
			if raw.Parent then
				I.wakeChildWaiters(raw.Parent, raw)
			end
		end,
		Parent = function(raw, world, v)
			if v ~= nil and not I.isInstance(v) then
				error("Unable to assign property Parent. Instance expected, got " .. H.typeof(v), 3)
			end
			I.setParent(raw, I.import(v), 3)
		end,
		ClassName = function()
			error("Unable to assign property ClassName. Property is read only", 3)
		end,
	},
	defaults = { Archivable = true },
})

-- ── scripts ──────────────────────────────────────────────────────────────────
local function scriptEnabledSetter(prop: string)
	return function(raw, world, v)
		v = I.coerce(raw, prop, "b", v, 4)
		local enabled = if prop == "Enabled" then v else not v
		raw.props.Enabled = enabled
		raw.props.Disabled = not enabled
		I.changed(raw, prop)
		if enabled and H.onScriptEnabled then
			H.onScriptEnabled(raw)
		end
	end
end
I.define("BaseScript", {
	defaults = { Enabled = true, Disabled = false },
	set = { Enabled = scriptEnabledSetter("Enabled"), Disabled = scriptEnabledSetter("Disabled") },
	props = { Disabled = "b" },
})
I.define("LuaSourceContainer", {
	get = {
		Source = function(raw)
			error("The current thread cannot read 'Source' (lacking capability PluginOrOpenCloud)", 3)
		end,
	},
})

-- ── parts / models ───────────────────────────────────────────────────────────
local function cf(raw, world)
	if world then
		return (I.readProp(raw, world, "CFrame")) or D.CFrame.new()
	end
	return raw.props.CFrame or D.CFrame.new()
end
local function setCF(raw, v, world)
	if world and I.isLocalWrite(raw, world, "CFrame") then
		I.setPropFrom(raw, world, "CFrame", v)
		return
	end
	I.setPropFrom(raw, world, "CFrame", v)
	I.changed(raw, "Position")
	I.changed(raw, "Orientation")
end
H.setPartCFrame = setCF

local function orientationOf(c)
	local rx, ry, rz = c:ToOrientation()
	return D.Vector3.new(math.deg(rx), math.deg(ry), math.deg(rz))
end
local function fromOrientation(pos, o)
	return D.CFrame.new(pos) * D.CFrame.fromOrientation(math.rad(o.X), math.rad(o.Y), math.rad(o.Z))
end

I.define("BasePart", {
	get = {
		Position = function(raw, world)
			return cf(raw, world).Position
		end,
		Orientation = function(raw, world)
			return orientationOf(cf(raw, world))
		end,
		Rotation = function(raw, world)
			return orientationOf(cf(raw, world))
		end,
	},
	set = {
		CFrame = function(raw, world, v)
			setCF(raw, I.coerce(raw, "CFrame", "CFrame", v, 4), world)
		end,
		Position = function(raw, world, v)
			v = I.coerce(raw, "Position", "Vector3", v, 4)
			local c = cf(raw, world)
			setCF(raw, D.CFrame.new(v) * c.Rotation, world)
		end,
		Orientation = function(raw, world, v)
			v = I.coerce(raw, "Orientation", "Vector3", v, 4)
			setCF(raw, fromOrientation(cf(raw, world).Position, v), world)
		end,
		Rotation = function(raw, world, v)
			v = I.coerce(raw, "Rotation", "Vector3", v, 4)
			setCF(raw, fromOrientation(cf(raw, world).Position, v), world)
		end,
	},
	methods = {
		GetTouchingParts = function()
			return {}
		end,
		GetConnectedParts = function()
			return {}
		end,
		GetJoints = function()
			return {}
		end,
		GetNoCollisionConstraints = function()
			return {}
		end,
		GetMass = function(self)
			local raw = self_(self, "GetMass")
			local s = raw.props.Size or I.getProp(raw, "Size") or D.Vector3.one
			return s.X * s.Y * s.Z * 0.7
		end,
		GetRootPart = function(self)
			return self
		end,
		ApplyImpulse = function() end,
		ApplyImpulseAtPosition = function() end,
		ApplyAngularImpulse = function() end,
		BreakJoints = function() end,
		GetVelocityAtPosition = function()
			return D.Vector3.zero
		end,
		CanSetNetworkOwnership = function(self)
			local raw = self_(self, "CanSetNetworkOwnership")
			if I.getProp(raw, "Anchored") then
				return false, "Cannot change network ownership of an anchored part"
			end
			return true
		end,
		SetNetworkOwner = function(self, player)
			local raw, world = self_(self, "SetNetworkOwner")
			if world.kind ~= "server" then
				error("Network Ownership API can only be called from the server", 2)
			end
			if not I.isDescendantOf(raw, I.service("Workspace")) then
				error("Can only call Network Ownership API on a part that is descendent of Workspace", 2)
			end
			if I.getProp(raw, "Anchored") then
				error("Network Ownership API cannot be called on Anchored parts or parts welded to Anchored parts.", 2)
			end
			raw.networkOwner = I.import(player)
		end,
		SetNetworkOwnershipAuto = function() end,
		GetNetworkOwner = function(self)
			local raw, world = self_(self, "GetNetworkOwner")
			return wrap(world, raw.networkOwner)
		end,
		GetNetworkOwnershipAuto = function()
			return true
		end,
		Resize = function()
			return true
		end,
	},
})

local function modelParts(raw)
	local out = {}
	for _, d in I.descendants(raw) do
		if d.class.isA.BasePart then
			table.insert(out, d)
		end
	end
	return out
end

local function pivotOf(raw)
	if raw.class.isA.BasePart then
		return cf(raw) * (raw.props.PivotOffset or D.CFrame.new())
	end
	local primary = raw.props.PrimaryPart
	if primary and I.isDescendantOf(primary, raw) then
		return cf(primary)
	end
	if raw.props.WorldPivot then
		return raw.props.WorldPivot
	end
	local parts = modelParts(raw)
	if #parts > 0 then
		return D.CFrame.new(cf(parts[1]).Position)
	end
	return D.CFrame.new()
end

local function pivotTo(raw, target, world)
	if raw.class.isA.BasePart then
		setCF(raw, target * (raw.props.PivotOffset or D.CFrame.new()):Inverse(), world)
		return
	end
	local current = pivotOf(raw)
	local delta = target * current:Inverse()
	for _, p in modelParts(raw) do
		setCF(p, delta * cf(p, world), world)
	end
	if raw.props.WorldPivot then
		raw.props.WorldPivot = target
	end
end
H.pivotTo = pivotTo

I.define("PVInstance", {
	methods = {
		GetPivot = function(self)
			local raw = self_(self, "GetPivot")
			return pivotOf(raw)
		end,
		PivotTo = function(self, target)
			local raw, world = self_(self, "PivotTo")
			if H.typeof(target) ~= "CFrame" then
				error("Unable to cast value to CFrame", 2)
			end
			pivotTo(raw, target, world)
		end,
	},
})

I.define("Model", {
	methods = {
		GetPrimaryPartCFrame = function(self)
			local raw = self_(self, "GetPrimaryPartCFrame")
			local p = raw.props.PrimaryPart
			return if p then cf(p) else pivotOf(raw)
		end,
		SetPrimaryPartCFrame = function(self, target)
			local raw, world = self_(self, "SetPrimaryPartCFrame")
			if not raw.props.PrimaryPart then
				error("Model:SetPrimaryPartCFrame() failed because no PrimaryPart has been set, or the PrimaryPart no longer exists. Please set Model.PrimaryPart before using this.", 2)
			end
			pivotTo(raw, target, world)
		end,
		MoveTo = function(self, pos)
			local raw, world = self_(self, "MoveTo")
			pivotTo(raw, D.CFrame.new(pos) * pivotOf(raw).Rotation, world)
		end,
		TranslateBy = function(self, delta)
			local raw, world = self_(self, "TranslateBy")
			pivotTo(raw, pivotOf(raw) + delta, world)
		end,
		GetBoundingBox = function(self)
			local raw = self_(self, "GetBoundingBox")
			return pivotOf(raw), D.Vector3.new(4, 5, 2)
		end,
		GetExtentsSize = function()
			return D.Vector3.new(4, 5, 2)
		end,
		GetScale = function(self)
			local raw = self_(self, "GetScale")
			return raw.scale or 1
		end,
		ScaleTo = function(self, s)
			local raw = self_(self, "ScaleTo")
			raw.scale = s
		end,
		BreakJoints = function() end,
		MakeJoints = function() end,
	},
})

I.define("Attachment", {
	get = {
		WorldPosition = function(raw)
			local p = raw.Parent
			local base = if p and p.class.isA.BasePart then cf(p) else D.CFrame.new()
			return (base * (raw.props.CFrame or D.CFrame.new())).Position
		end,
		WorldCFrame = function(raw)
			local p = raw.Parent
			local base = if p and p.class.isA.BasePart then cf(p) else D.CFrame.new()
			return base * (raw.props.CFrame or D.CFrame.new())
		end,
		Position = function(raw)
			return (raw.props.CFrame or D.CFrame.new()).Position
		end,
	},
	set = {
		Position = function(raw, world, v)
			v = I.coerce(raw, "Position", "Vector3", v, 4)
			I.setProp(raw, "CFrame", D.CFrame.new(v) * (raw.props.CFrame or D.CFrame.new()).Rotation)
			I.changed(raw, "Position")
		end,
	},
})

-- ── humanoid / animation ─────────────────────────────────────────────────────
local function humanoidState(raw)
	return raw.state or Enum.HumanoidStateType.Running
end

local function newTrack(world, animRaw, ownerRaw)
	local t = I.new("AnimationTrack", ownerFor(world))
	t.props.Animation = animRaw
	t.props.Length = 1
	t.Name = if animRaw then animRaw.Name else "AnimationTrack"
	return wrap(world, t)
end

local animMethods = {
	LoadAnimation = function(self, anim)
		local raw, world = self_(self, "LoadAnimation")
		local a = I.import(anim)
		if a == nil or not (type(a) == "table" and I.isRaw[a] and a.class.isA.Animation) then
			error("Unable to cast value to Object", 2)
		end
		return newTrack(world, a, raw)
	end,
	GetPlayingAnimationTracks = function()
		return {}
	end,
}

I.define("Humanoid", {
	defaults = { Health = 100, MaxHealth = 100, WalkSpeed = 16, JumpPower = 50, JumpHeight = 7.2, HipHeight = 2 },
	set = {
		Health = function(raw, world, v)
			v = I.coerce(raw, "Health", "n", v, 4)
			local max = I.getProp(raw, "MaxHealth")
			v = math.clamp(v, 0, max)
			local old = I.getProp(raw, "Health")
			I.setProp(raw, "Health", v)
			if old ~= v then
				I.fire(raw, "HealthChanged", v)
			end
			if old > 0 and v <= 0 and not raw.dead then
				raw.dead = true
				local prev = humanoidState(raw)
				raw.state = Enum.HumanoidStateType.Dead
				I.fire(raw, "StateChanged", prev, raw.state)
				I.fire(raw, "Died")
				if H.onHumanoidDied then
					H.onHumanoidDied(raw)
				end
			end
		end,
	},
	get = {
		RootPart = function(raw, world)
			local model = raw.Parent
			if model then
				return wrap(world, I.findChild(model, "HumanoidRootPart", world))
			end
			return nil
		end,
	},
	methods = {
		TakeDamage = function(self, amount)
			local raw = self_(self, "TakeDamage")
			if amount == nil then
				error("Argument 1 missing or nil", 2)
			end
			if type(amount) ~= "number" then
				amount = tonumber(amount)
				if amount == nil then
					error("Unable to cast string to float", 2)
				end
			end
			-- Roblox skips the damage while the character has a ForceField:
			-- any child of class ForceField, whatever its name.
			local model = raw.Parent
			if model then
				for _, c in model.children do
					if c.class.isA.ForceField then
						return
					end
				end
			end
			self.Health = I.getProp(raw, "Health") - amount
		end,
		GetState = function(self)
			local raw = self_(self, "GetState")
			return humanoidState(raw)
		end,
		ChangeState = function(self, state)
			local raw = self_(self, "ChangeState")
			local prev = humanoidState(raw)
			raw.state = state
			I.fire(raw, "StateChanged", prev, state)
			if state == Enum.HumanoidStateType.Dead and I.getProp(raw, "Health") > 0 then
				self.Health = 0
			end
		end,
		SetStateEnabled = function(self, state, enabled)
			local raw = self_(self, "SetStateEnabled")
			raw.stateEnabled = raw.stateEnabled or {}
			raw.stateEnabled[state] = enabled
		end,
		GetStateEnabled = function(self, state)
			local raw = self_(self, "GetStateEnabled")
			return not (raw.stateEnabled and raw.stateEnabled[state] == false)
		end,
		Move = function() end,
		MoveTo = function(self, pos)
			local raw = self_(self, "MoveTo")
			H.afterDelay(1, function()
				I.fire(raw, "MoveToFinished", true)
			end)
		end,
		EquipTool = function(self, tool)
			local raw = self_(self, "EquipTool")
			local t = I.import(tool)
			if t and raw.Parent then
				I.setParent(t, raw.Parent)
			end
		end,
		UnequipTools = function(self)
			local raw = self_(self, "UnequipTools")
			local model = raw.Parent
			local player = model and H.playerFromCharacter and H.playerFromCharacter(model)
			if not player then
				return
			end
			local backpack = I.findChild(player, "Backpack", nil)
			for _, c in table.clone(model.children) do
				if c.class.isA.Tool and backpack then
					I.setParent(c, backpack)
				end
			end
		end,
		GetAppliedDescription = function(self)
			local raw, world = self_(self, "GetAppliedDescription")
			return wrap(world, I.new("HumanoidDescription", ownerFor(world)))
		end,
		ApplyDescription = function() end,
		ApplyDescriptionAsync = function() end,
		ApplyDescriptionReset = function() end,
		BuildRigFromAttachments = function() end,
		GetLimb = function()
			return Enum.Limb.Unknown
		end,
		GetMoveVelocity = function()
			return D.Vector3.zero
		end,
		LoadAnimation = animMethods.LoadAnimation,
		GetPlayingAnimationTracks = animMethods.GetPlayingAnimationTracks,
		AddAccessory = function(self, acc)
			local raw = self_(self, "AddAccessory")
			if raw.Parent then
				I.setParent(I.import(acc), raw.Parent)
			end
		end,
		GetAccessories = function(self)
			local raw, world = self_(self, "GetAccessories")
			local out = {}
			for _, c in (raw.Parent and raw.Parent.children or {}) do
				if c.class.isA.Accoutrement then
					table.insert(out, wrap(world, c))
				end
			end
			return out
		end,
		RemoveAccessories = function() end,
	},
})
-- deprecated members the luau-lsp definitions leave out but Roblox still has
I.define("Humanoid", { events = { "AnimationPlayed" } })

-- Tool:Activate() / Tool:Deactivate() "simulate a click": Activated /
-- Deactivated fire in the world that called it, and only while the tool is
-- equipped (parented to a model with a Humanoid), like Roblox.
local function toolEquipped(raw): boolean
	local model = raw.Parent
	if model == nil then
		return false
	end
	for _, c in model.children do
		if c.class.isA.Humanoid then
			return true
		end
	end
	return false
end
H.toolEquipped = toolEquipped
I.define("Tool", {
	methods = {
		Activate = function(self)
			local raw, world = self_(self, "Activate")
			if toolEquipped(raw) then
				H.sig.fireWorld(raw.sigs and raw.sigs.Activated, world)
			end
		end,
		Deactivate = function(self)
			local raw, world = self_(self, "Deactivate")
			if toolEquipped(raw) then
				H.sig.fireWorld(raw.sigs and raw.sigs.Deactivated, world)
			end
		end,
	},
})
I.define("Animator", { methods = animMethods })
I.define("AnimationController", { methods = animMethods })

I.define("AnimationTrack", {
	methods = {
		Play = function(self, fade, weight, speed)
			local raw = self_(self, "Play")
			I.setProp(raw, "IsPlaying", true)
			if speed then
				I.setProp(raw, "Speed", speed)
			end
		end,
		Stop = function(self)
			local raw = self_(self, "Stop")
			if I.getProp(raw, "IsPlaying") then
				I.setProp(raw, "IsPlaying", false)
				I.fire(raw, "Stopped")
				I.fire(raw, "Ended")
			end
		end,
		AdjustSpeed = function(self, speed)
			local raw = self_(self, "AdjustSpeed")
			I.setProp(raw, "Speed", speed or 1)
		end,
		AdjustWeight = function() end,
		GetMarkerReachedSignal = function(self, name)
			local raw, world = self_(self, "GetMarkerReachedSignal")
			return H.sig.proxy(world, I.signal(raw, "Marker:" .. tostring(name)))
		end,
		GetTimeOfKeyframe = function()
			return 0
		end,
	},
	defaults = { Speed = 1, Looped = false },
})

-- ── sounds / effects ─────────────────────────────────────────────────────────
I.define("Sound", {
	methods = {
		Play = function(self)
			local raw = self_(self, "Play")
			I.setProp(raw, "IsPlaying", true)
			I.setProp(raw, "Playing", true)
			I.fire(raw, "Played", raw.props.SoundId or "")
		end,
		Stop = function(self)
			local raw = self_(self, "Stop")
			I.setProp(raw, "IsPlaying", false)
			I.setProp(raw, "Playing", false)
			I.fire(raw, "Stopped", raw.props.SoundId or "")
		end,
		Pause = function(self)
			local raw = self_(self, "Pause")
			I.setProp(raw, "IsPlaying", false)
			I.setProp(raw, "Playing", false)
			I.fire(raw, "Paused", raw.props.SoundId or "")
		end,
		Resume = function(self)
			local raw = self_(self, "Resume")
			I.setProp(raw, "IsPlaying", true)
			I.setProp(raw, "Playing", true)
			I.fire(raw, "Resumed", raw.props.SoundId or "")
		end,
	},
	defaults = { IsLoaded = true, Volume = 0.5, PlaybackSpeed = 1 },
})
I.define("ParticleEmitter", { methods = { Emit = function() end, Clear = function() end } })

-- ── GUI ──────────────────────────────────────────────────────────────────────
local VIEWPORT = D.Vector2.new(1920, 1080)
H.viewport = VIEWPORT

local function absSize(raw)
	if raw == nil then
		return VIEWPORT
	end
	if raw.class.isA.LayerCollector or not raw.class.isA.GuiObject then
		if raw.class.isA.GuiObject then
			return VIEWPORT
		end
		return VIEWPORT
	end
	local size = raw.props.Size or I.getProp(raw, "Size") or D.UDim2.new()
	local parent = absSize(raw.Parent)
	return D.Vector2.new(parent.X * size.X.Scale + size.X.Offset, parent.Y * size.Y.Scale + size.Y.Offset)
end

local function absPos(raw)
	if raw == nil or not raw.class.isA.GuiObject then
		return D.Vector2.zero
	end
	local pos = raw.props.Position or D.UDim2.new()
	local parentSize = absSize(raw.Parent)
	local parentPos = absPos(raw.Parent)
	local size = absSize(raw)
	local anchor = raw.props.AnchorPoint or D.Vector2.zero
	return D.Vector2.new(
		parentPos.X + parentSize.X * pos.X.Scale + pos.X.Offset - size.X * anchor.X,
		parentPos.Y + parentSize.Y * pos.Y.Scale + pos.Y.Offset - size.Y * anchor.Y
	)
end

local function guiTween(props)
	return function(self, ...)
		local raw, world = self_(self, "TweenSizeAndPosition")
		local args = table.pack(...)
		local values = {}
		local i = 1
		for _, p in props do
			values[p] = args[i]
			i += 1
		end
		local time = args[i + 2] or 1
		local override = args[i + 3]
		local callback = args[i + 4]
		if raw.guiTweening and not override then
			return false
		end
		raw.guiTweening = true
		H.afterDelay(time, function()
			raw.guiTweening = false
			for p, v in values do
				if v ~= nil then
					I.setPropFrom(raw, world, p, v)
				end
			end
			if type(callback) == "function" then
				S.spawn(callback, world, Enum.TweenStatus.Completed)
			end
		end)
		return true
	end
end

I.define("GuiBase2d", {
	get = {
		AbsoluteSize = function(raw)
			return absSize(raw)
		end,
		AbsolutePosition = function(raw)
			return absPos(raw)
		end,
		AbsoluteRotation = function(raw)
			return raw.props.Rotation or 0
		end,
	},
})
I.define("GuiObject", {
	methods = {
		TweenSize = guiTween({ "Size" }),
		TweenPosition = guiTween({ "Position" }),
		TweenSizeAndPosition = guiTween({ "Size", "Position" }),
	},
})
I.define("TextLabel", {
	get = {
		TextBounds = function(raw)
			local size = raw.props.TextSize or I.getProp(raw, "TextSize") or 14
			local text = raw.props.Text or I.getProp(raw, "Text") or ""
			return D.Vector2.new(#text * size * 0.5, size)
		end,
		TextFits = function()
			return true
		end,
		ContentText = function(raw)
			return raw.props.Text or I.getProp(raw, "Text") or ""
		end,
	},
})
I.define("TextButton", {
	get = {
		TextBounds = function(raw)
			local size = raw.props.TextSize or I.getProp(raw, "TextSize") or 14
			local text = raw.props.Text or I.getProp(raw, "Text") or ""
			return D.Vector2.new(#text * size * 0.5, size)
		end,
		ContentText = function(raw)
			return raw.props.Text or I.getProp(raw, "Text") or ""
		end,
	},
})
I.define("TextBox", {
	methods = {
		CaptureFocus = function(self)
			local raw = self_(self, "CaptureFocus")
			raw.focused = true
			I.fire(raw, "Focused")
		end,
		ReleaseFocus = function(self, submitted)
			local raw = self_(self, "ReleaseFocus")
			if raw.focused then
				raw.focused = false
				I.fire(raw, "FocusLost", submitted == true, nil)
			end
		end,
		IsFocused = function(self)
			local raw = self_(self, "IsFocused")
			return raw.focused == true
		end,
	},
	get = {
		ContentText = function(raw)
			return raw.props.Text or ""
		end,
		TextBounds = function(raw)
			local size = raw.props.TextSize or 14
			return D.Vector2.new(#(raw.props.Text or "") * size * 0.5, size)
		end,
	},
})
I.define("UIGridStyleLayout", {
	get = {
		AbsoluteContentSize = function(raw)
			return D.Vector2.zero
		end,
	},
	methods = { ApplyLayout = function() end },
})
I.define("ScrollingFrame", {
	get = {
		AbsoluteCanvasSize = function(raw)
			return absSize(raw)
		end,
		AbsoluteWindowSize = function(raw)
			return absSize(raw)
		end,
	},
})

-- ── camera / mouse ───────────────────────────────────────────────────────────
I.define("Camera", {
	defaults = { ViewportSize = VIEWPORT, FieldOfView = 70 },
	methods = {
		WorldToViewportPoint = function(self, p)
			return D.Vector3.new(VIEWPORT.X / 2, VIEWPORT.Y / 2, 10), true
		end,
		WorldToScreenPoint = function(self, p)
			return D.Vector3.new(VIEWPORT.X / 2, VIEWPORT.Y / 2, 10), true
		end,
		ScreenPointToRay = function(self, x, y, depth)
			local raw = self_(self, "ScreenPointToRay")
			local c = raw.props.CFrame or D.CFrame.new()
			return D.Ray.new(c.Position, c.LookVector)
		end,
		ViewportPointToRay = function(self, x, y, depth)
			local raw = self_(self, "ViewportPointToRay")
			local c = raw.props.CFrame or D.CFrame.new()
			return D.Ray.new(c.Position, c.LookVector)
		end,
		GetPartsObscuringTarget = function()
			return {}
		end,
		Interpolate = function() end,
		ZoomToExtents = function() end,
		GetRenderCFrame = function(self)
			local raw = self_(self, "GetRenderCFrame")
			return raw.props.CFrame or D.CFrame.new()
		end,
	},
})
I.define("Mouse", {
	get = {
		Hit = function()
			return D.CFrame.new()
		end,
		Origin = function()
			return D.CFrame.new()
		end,
		Target = function()
			return nil
		end,
		UnitRay = function()
			return D.Ray.new(D.Vector3.zero, D.Vector3.new(0, 0, -1))
		end,
		X = function()
			return VIEWPORT.X / 2
		end,
		Y = function()
			return VIEWPORT.Y / 2
		end,
		ViewSizeX = function()
			return VIEWPORT.X
		end,
		ViewSizeY = function()
			return VIEWPORT.Y
		end,
	},
})

I.define("Team", {
	methods = {
		GetPlayers = function(self)
			local raw, world = self_(self, "GetPlayers")
			local out = {}
			for _, p in I.service("Players").children do
				if p.ClassName == "Player" and p.props.Team == raw then
					table.insert(out, wrap(world, p))
				end
			end
			return out
		end,
	},
})

-- DataStoreOptions / DataStoreSetOptions: option bags; the in-memory DataStore ignores them.
I.define("DataStoreOptions", {
	methods = {
		SetExperimentalFeatures = function(self, _features)
			self_(self, "SetExperimentalFeatures")
			return nil
		end,
	},
})

I.define("DataStoreSetOptions", {
	methods = {
		GetMetadata = function(self)
			self_(self, "GetMetadata")
			return {}
		end,
		SetMetadata = function(self, _metadata)
			self_(self, "SetMetadata")
			return nil
		end,
	},
})

return {}
