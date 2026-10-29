--!nocheck
-- Engine services the framework and game code touch. Each one does what Studio
-- Play would do as far as a script can observe it, or is a quiet stub (noted
-- once in the report) where the harness cannot simulate the real thing.
local roblox = require("@lune/roblox")
local H = require("./state")
local S = require("./sched")
local I = require("./instance")
local D = require("./datatypes")

local wrap, self_ = I.wrap, I.self
local Enum = roblox.Enum

local function serverOnly(world, what, level)
	if world.kind ~= "server" then
		error(what .. " can only be called from the server", level + 1)
	end
end

local function asyncYield()
	-- Roblox *Async calls yield; this also catches calls from where yielding is
	-- not allowed (metamethods, UpdateAsync callbacks), like Roblox does.
	S.waitFor(0)
end
H.asyncYield = asyncYield

-- ── DataModel ────────────────────────────────────────────────────────────────
local KNOWN_SERVICES = {}
for _, n in { "Workspace", "Players", "Lighting", "ReplicatedFirst", "ReplicatedStorage", "ServerScriptService", "ServerStorage",
	"StarterGui", "StarterPack", "StarterPlayer", "Teams", "SoundService", "Chat", "TextChatService", "LocalizationService",
	"TestService", "RunService", "CollectionService", "TweenService", "UserInputService", "HttpService", "DataStoreService",
	"MemoryStoreService", "MessagingService", "MarketplaceService", "TeleportService", "Debris", "ContentProvider",
	"ContextActionService", "GuiService", "HapticService", "PathfindingService", "PhysicsService", "Stats", "ScriptContext",
	"UserService", "PolicyService", "BadgeService", "GroupService", "SocialService", "AnalyticsService", "LogService",
	"TextService", "ProximityPromptService", "VRService", "InsertService", "AssetService", "MaterialService",
	"AvatarEditorService", "VoiceChatService", "ExperienceNotificationService", "GamePassService", "ScriptService",
	"ServerStorage", "CoreGui", "KeyframeSequenceProvider", "NetworkClient", "NetworkServer", "ChangeHistoryService",
	"Selection", "StudioService", "ControllerService", "PermissionsService", "FriendService", "NotificationService",
	"ReplicatedFirst", "SharedTableRegistry", "PlayerEmulatorService", "EncodingService", "CaptureService" } do
	KNOWN_SERVICES[n] = true
end

local function getService(provider, name, level)
	if type(name) ~= "string" then
		error("Argument 1 missing or nil", level + 1)
	end
	if provider == H.game then
		local cls = I.class(name)
		if cls.known and not (cls.service or KNOWN_SERVICES[name]) then
			error(string.format("'%s' is not a valid Service name", name), level + 1)
		end
		if not cls.known and not KNOWN_SERVICES[name] then
			error(string.format("'%s' is not a valid Service name (if it is a new Roblox service, regenerate tools/harness/classdb.json with tools/harness/gen-classdb.mjs)", name), level + 1)
		end
		return I.service(name)
	end
	for _, c in provider.children do
		if c.ClassName == name then
			return c
		end
	end
	local raw = I.new(name, nil)
	raw.Name = name
	I.setParent(raw, provider)
	return raw
end

I.define("ServiceProvider", {
	methods = {
		GetService = function(self, name)
			local raw, world = self_(self, "GetService")
			return wrap(world, getService(raw, name, 2))
		end,
		FindService = function(self, name)
			local raw, world = self_(self, "FindService")
			for _, c in raw.children do
				if c.ClassName == name and c.isService then
					return wrap(world, c)
				end
			end
			return nil
		end,
	},
})
I.define("DataModel", {
	methods = {
		BindToClose = function(self, fn)
			local raw, world = self_(self, "BindToClose")
			if type(fn) ~= "function" then
				error("Argument 1 missing or nil", 2)
			end
			if world.kind ~= "server" then
				H.note("game:BindToClose on the client does nothing")
				return
			end
			table.insert(H.closeCallbacks, { fn = fn, world = world })
		end,
		IsLoaded = function()
			return true
		end,
		GetJobsInfo = function()
			return {}
		end,
		HttpGet = function()
			error("HttpGet is not available to scripts", 2)
		end,
	},
	get = {
		Workspace = function(raw, world)
			return wrap(world, I.service("Workspace"))
		end,
		PlaceId = function()
			return H.options.placeId or 0
		end,
		GameId = function()
			return H.options.gameId or 0
		end,
		CreatorId = function()
			return H.options.creatorId or 0
		end,
		JobId = function()
			return ""
		end,
	},
	defaults = { PlaceVersion = 0, PrivateServerId = "", PrivateServerOwnerId = 0, CreatorType = Enum.CreatorType.User },
	events = { "Loaded" },
})

-- ── Workspace ────────────────────────────────────────────────────────────────
local function cameraFor(world)
	if world.camera and not world.camera.destroyed then
		return world.camera
	end
	local cam = I.new("Camera", H.ownerFor(world))
	cam.Name = "Camera"
	cam.props.CFrame = D.CFrame.new(0, 20, 20) * D.CFrame.Angles(-0.5, 0, 0)
	world.camera = cam
	I.setParent(cam, I.service("Workspace"))
	return cam
end
H.cameraFor = cameraFor

I.define("Workspace", {
	get = {
		CurrentCamera = function(raw, world)
			return wrap(world, cameraFor(world))
		end,
		DistributedGameTime = function()
			return S.clock
		end,
	},
	set = {
		CurrentCamera = function(raw, world, v)
			world.camera = I.import(v)
		end,
	},
	defaults = { Gravity = 196.2, FallenPartsDestroyHeight = -500, StreamingEnabled = false, FilteringEnabled = true },
	methods = {
		Raycast = function()
			return nil
		end,
		Blockcast = function()
			return nil
		end,
		Spherecast = function()
			return nil
		end,
		Shapecast = function()
			return nil
		end,
		GetPartBoundsInBox = function()
			return {}
		end,
		GetPartBoundsInRadius = function()
			return {}
		end,
		GetPartsInPart = function()
			return {}
		end,
		FindPartOnRay = function(self, ray)
			return nil, ray and (ray.Origin + ray.Direction) or D.Vector3.zero, D.Vector3.zero, Enum.Material.Air
		end,
		FindPartOnRayWithIgnoreList = function(self, ray)
			return nil, ray and (ray.Origin + ray.Direction) or D.Vector3.zero, D.Vector3.zero, Enum.Material.Air
		end,
		FindPartOnRayWithWhitelist = function(self, ray)
			return nil, ray and (ray.Origin + ray.Direction) or D.Vector3.zero, D.Vector3.zero, Enum.Material.Air
		end,
		FindPartsInRegion3 = function()
			return {}
		end,
		ArePartsTouchingOthers = function()
			return false
		end,
		GetServerTimeNow = function()
			return H.epoch() + S.clock
		end,
		GetRealPhysicsFPS = function()
			return 60
		end,
		GetNumAwakeParts = function()
			return 0
		end,
		BulkMoveTo = function(self, parts, cframes)
			for i, p in parts do
				local r = I.rawOf(p)
				if r and cframes[i] then
					H.setPartCFrame(r, cframes[i])
				end
			end
		end,
		JoinToOutsiders = function() end,
		UnjoinFromOutsiders = function() end,
	},
})

-- ── RunService ───────────────────────────────────────────────────────────────
I.define("RunService", {
	methods = {
		IsServer = function(self)
			local _, world = self_(self, "IsServer")
			return world.kind == "server"
		end,
		IsClient = function(self)
			local _, world = self_(self, "IsClient")
			return world.kind == "client"
		end,
		IsStudio = function()
			return H.options.studio ~= false
		end,
		IsRunning = function()
			return true
		end,
		IsRunMode = function()
			return false
		end,
		IsEdit = function()
			return false
		end,
		BindToRenderStep = function(self, name, priority, fn)
			local raw, world = self_(self, "BindToRenderStep")
			if world.kind ~= "client" then
				H.note("RunService:BindToRenderStep on the server never runs")
				return
			end
			if type(fn) ~= "function" then
				error("Argument 3 missing or nil", 2)
			end
			world.renderBinds = world.renderBinds or {}
			world.renderBinds[name] = { fn = fn, priority = priority or 0, name = name }
		end,
		UnbindFromRenderStep = function(self, name)
			local raw, world = self_(self, "UnbindFromRenderStep")
			if world.renderBinds then
				world.renderBinds[name] = nil
			end
		end,
		Pause = function() end,
		Run = function() end,
		Stop = function() end,
	},
})

local function runServiceSignal(name)
	local rs = I.service("RunService")
	return rs.sigs and rs.sigs[name]
end

local function fireAll(name, ...)
	local s = runServiceSignal(name)
	if s and #s.conns > 0 then
		H.sig.fire(s, ...)
	end
end

local function fireClients(name, ...)
	local s = runServiceSignal(name)
	if s and #s.conns > 0 then
		for _, w in H.worldList do
			if w.kind == "client" and not w.dead then
				H.sig.fireWorld(s, w, ...)
			end
		end
	end
end

table.insert(S.frameHooks, {
	phase = "render",
	fn = function(dt)
		for _, w in H.worldList do
			if w.kind == "client" and not w.dead and w.renderBinds then
				local list = {}
				for _, b in w.renderBinds do
					table.insert(list, b)
				end
				table.sort(list, function(a, b)
					return a.priority < b.priority or (a.priority == b.priority and a.name < b.name)
				end)
				for _, b in list do
					S.spawn(b.fn, w, dt)
				end
			end
		end
		fireClients("PreRender", dt)
		fireClients("RenderStepped", dt)
		fireAll("PreAnimation", dt)
	end,
})
table.insert(S.frameHooks, {
	phase = "stepped",
	fn = function(dt)
		fireAll("Stepped", S.clock, dt)
		fireAll("PreSimulation", dt)
	end,
})
table.insert(S.frameHooks, {
	phase = "heartbeat",
	fn = function(dt)
		fireAll("PostSimulation", dt)
		fireAll("Heartbeat", dt)
	end,
})

-- ── CollectionService ────────────────────────────────────────────────────────
local tagSignals = {} -- tag -> { added, removed }
local function tagSig(tag, which)
	local t = tagSignals[tag]
	if not t then
		t = { added = H.sig.new("InstanceAdded:" .. tag), removed = H.sig.new("InstanceRemoved:" .. tag) }
		tagSignals[tag] = t
	end
	return t[which]
end

function H.addTag(raw, tag)
	if type(tag) ~= "string" then
		error("Argument 2 missing or nil", 3)
	end
	if raw.tags[tag] then
		return
	end
	raw.tags[tag] = true
	if I.inGame(raw) then
		H.sig.fireVisible(tagSig(tag, "added"), raw, raw)
		local cs = I.service("CollectionService")
		I.fire(cs, "TagAdded", tag)
	end
end
function H.removeTag(raw, tag)
	if not raw.tags[tag] then
		return
	end
	raw.tags[tag] = nil
	if I.inGame(raw) then
		H.sig.fireVisible(tagSig(tag, "removed"), raw, raw)
	end
end
H.tagEnter = function(raw, tag, entering)
	H.sig.fireVisible(tagSig(tag, if entering then "added" else "removed"), raw, raw)
end

I.define("CollectionService", {
	methods = {
		AddTag = function(self, inst, tag)
			self_(self, "AddTag")
			local r = I.rawOf(inst)
			if not r then
				error("Argument 1 missing or nil", 2)
			end
			H.addTag(r, tag)
		end,
		RemoveTag = function(self, inst, tag)
			self_(self, "RemoveTag")
			local r = I.rawOf(inst)
			if r then
				H.removeTag(r, tag)
			end
		end,
		HasTag = function(self, inst, tag)
			self_(self, "HasTag")
			local r = I.rawOf(inst)
			return r ~= nil and r.tags[tag] == true
		end,
		GetTags = function(self, inst)
			self_(self, "GetTags")
			local r = I.rawOf(inst)
			local out = {}
			for t in (r and r.tags or {}) do
				table.insert(out, t)
			end
			table.sort(out)
			return out
		end,
		GetTagged = function(self, tag)
			local _, world = self_(self, "GetTagged")
			local out = {}
			for _, d in I.visibleDescendants(H.game, world, {}) do
				if d.tags[tag] then
					table.insert(out, wrap(world, d))
				end
			end
			return out
		end,
		GetAllTags = function(self)
			local out, seen = {}, {}
			for _, d in I.descendants(H.game) do
				for t in d.tags do
					if not seen[t] then
						seen[t] = true
						table.insert(out, t)
					end
				end
			end
			table.sort(out)
			return out
		end,
		GetInstanceAddedSignal = function(self, tag)
			local _, world = self_(self, "GetInstanceAddedSignal")
			if type(tag) ~= "string" then
				error("Argument 1 missing or nil", 2)
			end
			return H.sig.proxy(world, tagSig(tag, "added"))
		end,
		GetInstanceRemovedSignal = function(self, tag)
			local _, world = self_(self, "GetInstanceRemovedSignal")
			if type(tag) ~= "string" then
				error("Argument 1 missing or nil", 2)
			end
			return H.sig.proxy(world, tagSig(tag, "removed"))
		end,
	},
})

-- ── TweenService ─────────────────────────────────────────────────────────────
local TWEENABLE = { number = true, Vector3 = true, Vector2 = true, CFrame = true, Color3 = true, UDim2 = true, UDim = true, Rect = true,
	NumberRange = true }

local function ease(alpha, style, direction)
	local name = if style then style.Name else "Quad"
	local function easeIn(t)
		if name == "Linear" then
			return t
		elseif name == "Sine" then
			return 1 - math.cos(t * math.pi / 2)
		elseif name == "Quad" then
			return t * t
		elseif name == "Cubic" then
			return t ^ 3
		elseif name == "Quart" then
			return t ^ 4
		elseif name == "Quint" then
			return t ^ 5
		elseif name == "Exponential" then
			return if t == 0 then 0 else 2 ^ (10 * t - 10)
		elseif name == "Circular" then
			return 1 - math.sqrt(1 - t * t)
		elseif name == "Back" then
			return 2.70158 * t ^ 3 - 1.70158 * t * t
		end
		return t
	end
	local dir = if direction then direction.Name else "Out"
	if dir == "In" then
		return easeIn(alpha)
	elseif dir == "Out" then
		return 1 - easeIn(1 - alpha)
	end
	if alpha < 0.5 then
		return easeIn(alpha * 2) / 2
	end
	return 1 - easeIn((1 - alpha) * 2) / 2
end

local activeTweens = setmetatable({}, { __mode = "k" }) -- instance raw -> { prop -> tween raw }

local function finishTween(t, state)
	if t.timer then
		pcall(coroutine.close, t.timer)
		t.timer = nil
	end
	I.setProp(t, "PlaybackState", state)
	I.fire(t, "Completed", state)
end

I.define("TweenService", {
	methods = {
		Create = function(self, inst, info, props)
			local _, world = self_(self, "Create")
			local target = I.rawOf(inst)
			if target == nil then
				error("Unable to cast value to Object", 2)
			end
			if H.typeof(info) ~= "TweenInfo" then
				error("Unable to cast value to TweenInfo", 2)
			end
			if type(props) ~= "table" then
				error("Unable to cast value to Dictionary", 2)
			end
			local goals = {}
			for k, v in props do
				local kind = target.class.members[k]
				local isProp = (kind and string.sub(kind, 1, 1) == ":") or target.class.getters[k] ~= nil
				if target.class.known and not isProp then
					error(string.format("TweenService:Create no property named '%s' for object '%s'", tostring(k), target.Name), 2)
				end
				local t = H.typeof(v)
				if not TWEENABLE[t] then
					error(string.format("TweenService:Create property named '%s' on object '%s' is not a data type that can be tweened", tostring(k), target.Name), 2)
				end
				local cur = I.export(world, inst[k])
				if cur ~= nil and H.typeof(cur) ~= t then
					error(string.format("TweenService:Create property named '%s' cannot be tweened due to type mismatch (property is a '%s', but given type is '%s')", tostring(k), H.typeof(cur), t), 2)
				end
				goals[k] = v
			end
			local tw = I.new("Tween", H.ownerFor(world))
			tw.Name = "Tween"
			tw.props.Instance = target
			tw.props.TweenInfo = info
			tw.props.PlaybackState = Enum.PlaybackState.Begin
			tw.goals = goals
			tw.world = world
			return wrap(world, tw)
		end,
		GetValue = function(self, alpha, style, direction)
			return ease(math.clamp(alpha, 0, 1), style, direction)
		end,
		SmoothDamp = function(self, current, target)
			H.note("unmodeled method TweenService:SmoothDamp() (returns target)")
			return target
		end,
	},
})

I.define("Tween", {
	methods = {
		Play = function(self)
			local t = self_(self, "Play")
			local state = I.getProp(t, "PlaybackState")
			if state == Enum.PlaybackState.Playing then
				return
			end
			local target = t.props.Instance
			-- a newer tween on the same property cancels the older one
			activeTweens[target] = activeTweens[target] or {}
			for prop in t.goals do
				local other = activeTweens[target][prop]
				if other and other ~= t and I.getProp(other, "PlaybackState") == Enum.PlaybackState.Playing then
					finishTween(other, Enum.PlaybackState.Cancelled)
				end
				activeTweens[target][prop] = t
			end
			local info = t.props.TweenInfo
			if t.startValues == nil then
				t.startValues = {}
				for prop in t.goals do
					t.startValues[prop] = I.getProp(target, prop) or (target.class.getters[prop] and target.class.getters[prop](target, t.world))
				end
			end
			I.setProp(t, "PlaybackState", Enum.PlaybackState.Playing)
			local repeats = info.RepeatCount
			local duration = (info.DelayTime + info.Time * (if info.Reverses then 2 else 1)) * (if repeats < 0 then 1 else repeats + 1)
			duration = t.remaining or duration
			t.started = S.clock
			t.duration = duration
			t.timer = H.afterDelay(duration, function()
				t.timer = nil
				for prop, v in t.goals do
					local final = if info.Reverses then t.startValues[prop] else v
					local setter = target.class.setters[prop]
					if setter then
						pcall(setter, target, t.world, final)
					else
						I.setPropFrom(target, t.world, prop, final)
					end
				end
				if repeats < 0 then
					return -- loops forever: stays Playing
				end
				finishTween(t, Enum.PlaybackState.Completed)
			end)
		end,
		Pause = function(self)
			local t = self_(self, "Pause")
			if I.getProp(t, "PlaybackState") == Enum.PlaybackState.Playing then
				if t.timer then
					pcall(coroutine.close, t.timer)
					t.timer = nil
				end
				t.remaining = math.max(0, t.duration - (S.clock - t.started))
				I.setProp(t, "PlaybackState", Enum.PlaybackState.Paused)
			end
		end,
		Cancel = function(self)
			local t = self_(self, "Cancel")
			local st = I.getProp(t, "PlaybackState")
			if st == Enum.PlaybackState.Playing or st == Enum.PlaybackState.Paused then
				t.remaining = nil
				finishTween(t, Enum.PlaybackState.Cancelled)
			end
		end,
	},
	get = {
		PlaybackState = function(raw)
			return raw.props.PlaybackState or Enum.PlaybackState.Begin
		end,
		Instance = function(raw, world)
			return wrap(world, raw.props.Instance)
		end,
		TweenInfo = function(raw)
			return raw.props.TweenInfo
		end,
	},
	events = { "Completed" },
})

-- ── input / GUI services ─────────────────────────────────────────────────────
I.define("UserInputService", {
	defaults = {
		KeyboardEnabled = true, MouseEnabled = true, TouchEnabled = false, GamepadEnabled = false, AccelerometerEnabled = false,
		GyroscopeEnabled = false, VREnabled = false, MouseIconEnabled = true,
	},
	methods = {
		GetLastInputType = function()
			return Enum.UserInputType.Keyboard
		end,
		IsKeyDown = function()
			return false
		end,
		IsMouseButtonPressed = function()
			return false
		end,
		GetMouseLocation = function()
			return D.Vector2.new(H.viewport.X / 2, H.viewport.Y / 2)
		end,
		GetMouseDelta = function()
			return D.Vector2.zero
		end,
		GetKeysPressed = function()
			return {}
		end,
		GetMouseButtonsPressed = function()
			return {}
		end,
		GetConnectedGamepads = function()
			return {}
		end,
		GetNavigationGamepads = function()
			return {}
		end,
		GetGamepadConnected = function()
			return false
		end,
		GetGamepadState = function()
			return {}
		end,
		GetSupportedGamepadKeyCodes = function()
			return {}
		end,
		IsGamepadButtonDown = function()
			return false
		end,
		IsNavigationGamepad = function()
			return false
		end,
		GamepadSupports = function()
			return false
		end,
		GetFocusedTextBox = function()
			return nil
		end,
		GetPlatform = function()
			return Enum.Platform.Windows
		end,
		GetStringForKeyCode = function(self, kc)
			return if kc then kc.Name else ""
		end,
		GetImageForKeyCode = function()
			return ""
		end,
		GetDeviceAcceleration = function()
			return nil
		end,
		GetDeviceGravity = function()
			return nil
		end,
		GetDeviceRotation = function()
			return nil
		end,
		RecenterUserHeadCFrame = function() end,
		GetUserCFrame = function()
			return D.CFrame.new()
		end,
	},
})

I.define("ContextActionService", {
	methods = {
		BindAction = function(self, name, fn, createButton, ...)
			local raw, world = self_(self, "BindAction")
			world.actions = world.actions or {}
			world.actions[name] = { fn = fn, inputs = { ... } }
		end,
		BindActionAtPriority = function(self, name, fn, createButton, priority, ...)
			local raw, world = self_(self, "BindActionAtPriority")
			world.actions = world.actions or {}
			world.actions[name] = { fn = fn, inputs = { ... } }
		end,
		UnbindAction = function(self, name)
			local raw, world = self_(self, "UnbindAction")
			if world.actions then
				world.actions[name] = nil
			end
		end,
		UnbindAllActions = function(self)
			local raw, world = self_(self, "UnbindAllActions")
			world.actions = {}
		end,
		GetButton = function()
			return nil
		end,
		GetAllBoundActionInfo = function()
			return {}
		end,
		GetBoundActionInfo = function()
			return {}
		end,
		SetTitle = function() end,
		SetImage = function() end,
		SetDescription = function() end,
		SetPosition = function() end,
		BindCoreAction = function() end,
		UnbindCoreAction = function() end,
	},
})

I.define("GuiService", {
	methods = {
		GetGuiInset = function()
			return D.Vector2.new(0, 58), D.Vector2.zero
		end,
		IsTenFootInterface = function()
			return false
		end,
		InspectPlayerFromUserId = function() end,
		InspectPlayerFromHumanoidDescription = function() end,
		CloseInspectMenu = function() end,
		AddSelectionParent = function() end,
		RemoveSelectionGroup = function() end,
		Select = function() end,
		GetEmotesMenuOpen = function()
			return false
		end,
		SetEmotesMenuOpen = function() end,
		GetInspectMenuEnabled = function()
			return false
		end,
		SetInspectMenuEnabled = function() end,
	},
	defaults = { MenuIsOpen = false, AutoSelectGuiEnabled = true },
})

I.define("StarterGui", {
	methods = {
		SetCore = function(self, name, value)
			local _, world = self_(self, "SetCore")
			if world.kind ~= "client" then
				error("SetCore can only be called from a LocalScript", 2)
			end
		end,
		GetCore = function(self, name)
			return nil
		end,
		SetCoreGuiEnabled = function(self, coreType, enabled)
			local raw, world = self_(self, "SetCoreGuiEnabled")
			world.coreGui = world.coreGui or {}
			world.coreGui[tostring(coreType)] = enabled
		end,
		GetCoreGuiEnabled = function(self, coreType)
			local raw, world = self_(self, "GetCoreGuiEnabled")
			local v = world.coreGui and world.coreGui[tostring(coreType)]
			return v ~= false
		end,
		RegisterSetCore = function() end,
		RegisterGetCore = function() end,
	},
	defaults = { ShowDevelopmentGui = true, ResetPlayerGuiOnSpawn = true },
})

I.define("HapticService", {
	methods = {
		IsVibrationSupported = function()
			return false
		end,
		IsMotorSupported = function()
			return false
		end,
		SetMotor = function() end,
		GetMotor = function()
			return 0
		end,
	},
})

-- ── misc services ────────────────────────────────────────────────────────────
I.define("Debris", {
	methods = {
		AddItem = function(self, inst, lifetime)
			self_(self, "AddItem")
			local r = I.rawOf(inst)
			if r == nil then
				error("Unable to cast value to Object", 2)
			end
			H.afterDelay(tonumber(lifetime) or 10, function()
				if not r.destroyed then
					I.destroy(r)
				end
			end)
		end,
		addItem = function(self, inst, lifetime)
			return self:AddItem(inst, lifetime)
		end,
	},
})

I.define("ContentProvider", {
	methods = {
		PreloadAsync = function(self, list, callback)
			local _, world = self_(self, "PreloadAsync")
			if type(list) ~= "table" then
				error("Unable to cast value to std::vector<Instance>", 2)
			end
			asyncYield()
			if type(callback) == "function" then
				for _, item in list do
					local id = if type(item) == "string" then item else ""
					callback(id, Enum.AssetFetchStatus.Success)
				end
			end
		end,
		Preload = function() end,
		GetAssetFetchStatus = function()
			return Enum.AssetFetchStatus.Success
		end,
	},
	defaults = { RequestQueueSize = 0 },
})

I.define("PathfindingService", {
	methods = {
		CreatePath = function(self, params)
			local _, world = self_(self, "CreatePath")
			local p = I.new("Path", H.ownerFor(world))
			p.props.Status = Enum.PathStatus.NoPath
			return wrap(world, p)
		end,
		FindPathAsync = function(self)
			local _, world = self_(self, "FindPathAsync")
			asyncYield()
			local p = I.new("Path", H.ownerFor(world))
			p.props.Status = Enum.PathStatus.NoPath
			return wrap(world, p)
		end,
	},
})
I.define("Path", {
	methods = {
		ComputeAsync = function(self)
			asyncYield()
			H.note("unmodeled pathfinding (Path:ComputeAsync always gives Status NoPath)")
		end,
		GetWaypoints = function()
			return {}
		end,
		CheckOcclusionAsync = function()
			return -1
		end,
	},
})

local collisionGroups = { Default = true }
I.define("PhysicsService", {
	methods = {
		RegisterCollisionGroup = function(self, name)
			if name == nil then
				error("Argument 1 missing or nil", 2)
			end
			name = tostring(name)
			collisionGroups[name] = true
		end,
		CreateCollisionGroup = function(self, name)
			if name == nil then
				error("Argument 1 missing or nil", 2)
			end
			name = tostring(name)
			collisionGroups[name] = true
			return 1
		end,
		UnregisterCollisionGroup = function(self, name)
			if name == nil then
				error("Argument 1 missing or nil", 2)
			end
			name = tostring(name)
			collisionGroups[name] = nil
		end,
		IsCollisionGroupRegistered = function(self, name)
			return collisionGroups[name] == true
		end,
		CollisionGroupSetCollidable = function(self, a, b)
			if not collisionGroups[a] or not collisionGroups[b] then
				error("Collision group does not exist", 2)
			end
		end,
		CollisionGroupsAreCollidable = function()
			return true
		end,
		GetRegisteredCollisionGroups = function()
			local out = {}
			for n in collisionGroups do
				table.insert(out, { name = n, mask = 0 })
			end
			table.sort(out, function(a, b)
				return a.name < b.name
			end)
			return out
		end,
		SetPartCollisionGroup = function() end,
		GetMaxCollisionGroups = function()
			return 32
		end,
		RenameCollisionGroup = function() end,
	},
})

I.define("Stats", {
	methods = {
		GetTotalMemoryUsageMb = function()
			return 200
		end,
		GetMemoryUsageMbForTag = function()
			return 0
		end,
		GetMemoryUsageMbAllCategories = function()
			return {}
		end,
	},
	get = {
		HeartbeatTimeMs = function()
			return 1
		end,
		PhysicsStepTimeMs = function()
			return 1
		end,
		DataReceiveKbps = function()
			return 0
		end,
		DataSendKbps = function()
			return 0
		end,
	},
})

I.define("ScriptContext", { events = { "Error" } })
H.onGameError = function(worldId, message, trace)
	local world = H.worlds[worldId]
	local sc = H.game and I.findChild(H.game, "ScriptContext", nil)
	if world and sc and sc.sigs and sc.sigs.Error then
		H.sig.fireWorld(sc.sigs.Error, world, message, trace or "", nil)
	end
	local ls = H.game and I.findChild(H.game, "LogService", nil)
	if world and ls and ls.sigs and ls.sigs.MessageOut then
		H.sig.fireWorld(ls.sigs.MessageOut, world, message, Enum.MessageType.MessageError)
	end
end
H.onOutput = function(world, text, kind)
	local ls = H.game and I.findChild(H.game, "LogService", nil)
	if ls and ls.sigs and ls.sigs.MessageOut then
		H.sig.fireWorld(ls.sigs.MessageOut, world, text, Enum.MessageType[kind])
	end
end
I.define("LogService", {
	methods = {
		GetLogHistory = function()
			return {}
		end,
		ClearOutput = function() end,
	},
})

local function playerName(userId)
	for _, p in I.service("Players").children do
		if p.ClassName == "Player" and p.props.UserId == userId then
			return p.Name, p.props.DisplayName or p.Name
		end
	end
	return "Player_" .. tostring(userId), "Player_" .. tostring(userId)
end

I.define("UserService", {
	methods = {
		GetUserInfosByUserIdsAsync = function(self, ids)
			asyncYield()
			local out = {}
			for _, id in ids or {} do
				local name, display = playerName(id)
				table.insert(out, { Id = id, Username = name, DisplayName = display, HasVerifiedBadge = false })
			end
			return out
		end,
	},
})

I.define("LocalizationService", {
	defaults = { RobloxLocaleId = "en-us", SystemLocaleId = "en-us" },
	methods = {
		GetCountryRegionForPlayerAsync = function()
			asyncYield()
			return "US"
		end,
		GetTranslatorForPlayerAsync = function(self)
			local _, world = self_(self, "GetTranslatorForPlayerAsync")
			asyncYield()
			return wrap(world, I.new("Translator", nil))
		end,
		GetTranslatorForPlayer = function(self)
			local _, world = self_(self, "GetTranslatorForPlayer")
			return wrap(world, I.new("Translator", nil))
		end,
		GetTranslatorForLocaleAsync = function(self)
			local _, world = self_(self, "GetTranslatorForLocaleAsync")
			asyncYield()
			return wrap(world, I.new("Translator", nil))
		end,
	},
})
I.define("Translator", {
	defaults = { LocaleId = "en-us" },
	methods = {
		Translate = function(self, context, text)
			return text
		end,
		FormatByKey = function(self, key)
			error("Translator:FormatByKey: key not found: " .. tostring(key), 2)
		end,
	},
})

I.define("PolicyService", {
	methods = {
		GetPolicyInfoForPlayerAsync = function()
			asyncYield()
			return {
				AreAdsAllowed = true, ArePaidRandomItemsRestricted = false, AllowedExternalLinkReferences = {},
				IsPaidItemTradingAllowed = true, IsSubjectToChinaPolicies = false, IsContentSharingAllowed = true,
			}
		end,
	},
})

I.define("BadgeService", {
	methods = {
		AwardBadge = function(self, userId, badgeId)
			userId = H.checkInt64(userId, 1, 2)
			badgeId = H.checkInt64(badgeId, 2, 2)
			H.record("call", { service = "BadgeService", method = "AwardBadge", args = { userId, badgeId } })
			asyncYield()
			return true
		end,
		UserHasBadgeAsync = function(self, userId, badgeId)
			H.checkInt64(userId, 1, 2)
			H.checkInt64(badgeId, 2, 2)
			asyncYield()
			return false
		end,
		UserHasBadge = function()
			return false
		end,
		GetBadgeInfoAsync = function(self, id)
			asyncYield()
			return { Name = "Badge " .. tostring(id), Description = "", IconImageId = 0, IsEnabled = true }
		end,
		CheckUserBadgesAsync = function()
			asyncYield()
			return {}
		end,
	},
})

I.define("GroupService", {
	methods = {
		GetGroupInfoAsync = function(self, id)
			asyncYield()
			return { Name = "Group " .. tostring(id), Id = id, Owner = { Name = "Owner", Id = 0 }, EmblemUrl = "", Description = "", Roles = {} }
		end,
		GetGroupsAsync = function()
			asyncYield()
			return {}
		end,
		GetAlliesAsync = function()
			asyncYield()
			return nil
		end,
		GetEnemiesAsync = function()
			asyncYield()
			return nil
		end,
	},
})

I.define("Chat", {
	methods = {
		Chat = function() end,
		FilterStringAsync = function(self, s)
			asyncYield()
			return s
		end,
		FilterStringForBroadcast = function(self, s)
			return s
		end,
		CanUserChatAsync = function()
			asyncYield()
			return true
		end,
		CanUsersChatAsync = function()
			asyncYield()
			return true
		end,
		RegisterChatCallback = function() end,
		InvokeChatCallback = function() end,
	},
	defaults = { LoadDefaultChat = true, BubbleChatEnabled = false },
})

I.define("TextService", {
	methods = {
		GetTextSize = function(self, text, size)
			return D.Vector2.new(#(text or "") * (size or 14) * 0.5, size or 14)
		end,
		GetTextBoundsAsync = function(self, params)
			asyncYield()
			return D.Vector2.new(100, 14)
		end,
		FilterStringAsync = function(self, text, fromUserId)
			local _, world = self_(self, "FilterStringAsync")
			asyncYield()
			local r = I.new("TextFilterResult", nil)
			r.text = text
			return wrap(world, r)
		end,
		GetFamilyInfoAsync = function()
			asyncYield()
			return { Name = "Source Sans Pro", Faces = {} }
		end,
	},
})
I.define("TextFilterResult", {
	methods = {
		GetNonChatStringForBroadcastAsync = function(self)
			local raw = self_(self, "GetNonChatStringForBroadcastAsync")
			asyncYield()
			return raw.text
		end,
		GetNonChatStringForUserAsync = function(self)
			local raw = self_(self, "GetNonChatStringForUserAsync")
			asyncYield()
			return raw.text
		end,
		GetChatForUserAsync = function(self)
			local raw = self_(self, "GetChatForUserAsync")
			asyncYield()
			return raw.text
		end,
	},
})

I.define("SocialService", {
	methods = {
		CanSendGameInviteAsync = function()
			asyncYield()
			return false
		end,
		PromptGameInvite = function(self, player)
			H.record("call", { service = "SocialService", method = "PromptGameInvite" })
		end,
		CanSendCallInviteAsync = function()
			asyncYield()
			return false
		end,
	},
})

local function recordCall(service, method)
	return function(self, ...)
		local n = select("#", ...)
		local args = {}
		for i = 1, math.min(n, 6) do
			local v = select(i, ...)
			args[i] = if type(v) == "table" or type(v) == "userdata" then H.typeof(v) else v
		end
		H.record("call", { service = service, method = method, args = args })
	end
end
local analytics = {}
for _, m in { "LogEconomyEvent", "LogCustomEvent", "LogProgressionEvent", "LogProgressionStartEvent", "LogProgressionCompleteEvent",
	"LogProgressionFailEvent", "LogFunnelStepEvent", "LogOnboardingFunnelStepEvent", "FireCustomEvent", "FireInGameEconomyEvent",
	"FireLogEvent", "FirePlayerProgressionEvent" } do
	analytics[m] = recordCall("AnalyticsService", m)
end
I.define("AnalyticsService", { methods = analytics })

I.define("TestService", {
	methods = {
		Message = function(self, text)
			local _, world = self_(self, "Message")
			H.print(world.id, "TestService: " .. tostring(text))
		end,
		Warn = function(self, cond, text)
			local _, world = self_(self, "Warn")
			if not cond then
				H.warn(world.id, "TestService: " .. tostring(text))
			end
		end,
		Check = function(self, cond, text)
			local _, world = self_(self, "Check")
			if not cond then
				H.gameError(world.id, "TestService.Check failed: " .. tostring(text))
			end
		end,
		Error = function(self, text)
			local _, world = self_(self, "Error")
			H.gameError(world.id, "TestService: " .. tostring(text))
		end,
		Checkpoint = function() end,
		Done = function() end,
		Fail = function(self, text)
			local _, world = self_(self, "Fail")
			H.gameError(world.id, "TestService.Fail: " .. tostring(text))
		end,
		Require = function(self, cond, text)
			if not cond then
				error("TestService.Require failed: " .. tostring(text), 2)
			end
		end,
	},
})

I.define("Lighting", {
	methods = {
		GetMinutesAfterMidnight = function(self)
			local raw = self_(self, "GetMinutesAfterMidnight")
			return (I.getProp(raw, "ClockTime") or 14) * 60
		end,
		SetMinutesAfterMidnight = function(self, minutes)
			local raw = self_(self, "SetMinutesAfterMidnight")
			I.setProp(raw, "ClockTime", (minutes / 60) % 24)
		end,
		GetSunDirection = function()
			return D.Vector3.new(0, 1, 0)
		end,
		GetMoonDirection = function()
			return D.Vector3.new(0, -1, 0)
		end,
	},
	defaults = { ClockTime = 14, TimeOfDay = "14:00:00" },
})

I.define("SoundService", {
	methods = {
		PlayLocalSound = function() end,
		GetListener = function()
			return Enum.ListenerType.Camera, nil
		end,
		SetListener = function() end,
	},
})

I.define("InsertService", {
	methods = {
		LoadAsset = function(self, id)
			asyncYield()
			H.note("unmodeled InsertService:LoadAsset (the harness cannot download assets)")
			error("HTTP 403 (Forbidden): the harness cannot load assets", 2)
		end,
	},
})

I.define("ProximityPromptService", { defaults = { Enabled = true, MaxPromptsVisible = 16 } })
I.define("VRService", { defaults = { VREnabled = false } })

return {}
