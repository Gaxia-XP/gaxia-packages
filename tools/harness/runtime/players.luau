--!nocheck
-- Players: join (Player object, client world, PlayerScripts, character), leave,
-- kick, respawn; and TextChatService so chat commands can be simulated.
local roblox = require("@lune/roblox")
local H = require("./state")
local S = require("./sched")
local I = require("./instance")
local D = require("./datatypes")
local W = require("./world")

local wrap, self_ = I.wrap, I.self
local Enum = roblox.Enum

local P = {}
H.players = P

local function playersService()
	return I.service("Players")
end

function H.playerFromCharacter(model)
	for _, p in playersService().children do
		if p.ClassName == "Player" and p.props.Character == model then
			return p
		end
	end
	return nil
end

local function visiblePlayers(world)
	local out = {}
	for _, p in playersService().children do
		if p.ClassName == "Player" and I.visible(p, world) then
			table.insert(out, wrap(world, p))
		end
	end
	return out
end

local function pagesOf(world, pages)
	local p = I.new("FriendPages", nil)
	p.pages = pages
	p.index = 1
	p.props.IsFinished = true
	return wrap(world, p)
end

local function playerCount()
	local n = 0
	for _, p in playersService().children do
		if p.ClassName == "Player" then
			n += 1
		end
	end
	return n
end

I.define("Players", {
	get = {
		NumPlayers = playerCount,
		LocalPlayer = function(raw, world)
			if world.kind ~= "client" then
				return nil
			end
			return wrap(world, world.player)
		end,
	},
	defaults = { MaxPlayers = 8, PreferredPlayers = 8, RespawnTime = 5, CharacterAutoLoads = true, BubbleChat = false, ClassicChat = false },
	methods = {
		GetPlayers = function(self)
			local _, world = self_(self, "GetPlayers")
			return visiblePlayers(world)
		end,
		getPlayers = function(self)
			local _, world = self_(self, "getPlayers")
			return visiblePlayers(world)
		end,
		GetPlayerByUserId = function(self, id)
			local _, world = self_(self, "GetPlayerByUserId")
			if type(id) ~= "number" then
				error("Argument 1 missing or nil", 2)
			end
			for _, p in playersService().children do
				if p.ClassName == "Player" and p.props.UserId == id then
					return wrap(world, p)
				end
			end
			return nil
		end,
		GetPlayerFromCharacter = function(self, model)
			local _, world = self_(self, "GetPlayerFromCharacter")
			local m = H.checkObject(model, 1, 2, nil, true)
			if m == nil then
				return nil
			end
			return wrap(world, H.playerFromCharacter(m))
		end,
		GetUserIdFromNameAsync = function(self, name)
			H.asyncYield()
			for _, p in playersService().children do
				if p.ClassName == "Player" and p.Name == name then
					return p.props.UserId
				end
			end
			error("Failed to get UserId from name: user not found", 2)
		end,
		GetNameFromUserIdAsync = function(self, id)
			H.asyncYield()
			for _, p in playersService().children do
				if p.ClassName == "Player" and p.props.UserId == id then
					return p.Name
				end
			end
			return "Player_" .. tostring(id)
		end,
		GetUserThumbnailAsync = function(self, id, kind, size)
			H.asyncYield()
			local kinds = { HeadShot = "AvatarHeadShot", AvatarBust = "AvatarBust", AvatarThumbnail = "Avatar" }
			local k = if typeof(kind) == "EnumItem" then kinds[kind.Name] else nil
			local w, h = 150, 150
			if typeof(size) == "EnumItem" then
				local a, b = string.match(size.Name, "^Size(%d+)x(%d+)$")
				w, h = tonumber(a) or w, tonumber(b) or h
			end
			return string.format("rbxthumb://type=%s&id=%s&w=%d&h=%d", k or "AvatarHeadShot", tostring(id), w, h), true
		end,
		GetFriendsAsync = function(self)
			local _, world = self_(self, "GetFriendsAsync")
			H.asyncYield()
			return pagesOf(world, { {} })
		end,
		GetHumanoidDescriptionFromUserId = function(self)
			local _, world = self_(self, "GetHumanoidDescriptionFromUserId")
			H.asyncYield()
			return wrap(world, I.new("HumanoidDescription", nil))
		end,
		GetHumanoidDescriptionFromUserIdAsync = function(self)
			local _, world = self_(self, "GetHumanoidDescriptionFromUserIdAsync")
			H.asyncYield()
			return wrap(world, I.new("HumanoidDescription", nil))
		end,
		GetCharacterAppearanceInfoAsync = function()
			H.asyncYield()
			return { assets = {}, bodyColors = {}, scales = {}, playerAvatarType = "R15" }
		end,
		BanAsync = function(self, config)
			H.record("ban", { method = "BanAsync" })
			H.asyncYield()
		end,
		UnbanAsync = function(self, config)
			H.record("ban", { method = "UnbanAsync" })
			H.asyncYield()
		end,
		GetBanHistoryAsync = function(self)
			local _, world = self_(self, "GetBanHistoryAsync")
			H.asyncYield()
			return pagesOf(world, { {} })
		end,
		Chat = function() end,
		SetChatStyle = function() end,
	},
})

I.define("Player", {
	defaults = {
		UserId = 0, AccountAge = 30, MembershipType = Enum.MembershipType.None, LocaleId = "en-us", FollowUserId = 0,
		Neutral = true, AutoJumpEnabled = true, CanLoadCharacterAppearance = true, HasVerifiedBadge = false,
		CameraMaxZoomDistance = 128, CameraMinZoomDistance = 0.5,
	},
	get = {
		DisplayName = function(raw)
			return raw.props.DisplayName or raw.Name
		end,
	},
	methods = {
		Kick = function(self, message)
			local raw, world = self_(self, "Kick")
			if world.kind == "client" and world.player ~= raw then
				error("Cannot kick a non-local Player from a LocalScript", 2)
			end
			if raw.kicked or raw.left then
				return
			end
			raw.kicked = true
			H.counts.kicks += 1
			H.record("kick", { player = raw.Name, message = if message == nil then "" else tostring(message), by = world.id,
				trace = S.formatTrace(debug.traceback()) })
			H.afterDelay(0, function()
				P.leave(raw, "kicked")
			end)
		end,
		GetRankInGroup = function(self, groupId)
			H.checkInt64(groupId, 1, 2)
			return 0
		end,
		GetRoleInGroup = function(self, groupId)
			H.checkInt64(groupId, 1, 2)
			return "Guest"
		end,
		IsInGroup = function(self, groupId)
			H.checkInt64(groupId, 1, 2)
			return false
		end,
		GetRankInGroupAsync = function(self, groupId)
			H.checkInt64(groupId, 1, 2)
			H.asyncYield()
			return 0
		end,
		GetRoleInGroupAsync = function(self, groupId)
			H.checkInt64(groupId, 1, 2)
			H.asyncYield()
			return "Guest"
		end,
		IsInGroupAsync = function(self, groupId)
			H.checkInt64(groupId, 1, 2)
			H.asyncYield()
			return false
		end,
		IsFriendsWith = function()
			return false
		end,
		IsFriendsWithAsync = function()
			H.asyncYield()
			return false
		end,
		GetFriendStatus = function()
			return Enum.FriendStatus.NotFriend
		end,
		GetFriendsOnline = function()
			H.asyncYield()
			return {}
		end,
		GetFriendsOnlineAsync = function()
			H.asyncYield()
			return {}
		end,
		GetMouse = function(self)
			local raw, world = self_(self, "GetMouse")
			if world.kind ~= "client" then
				return nil
			end
			if not world.mouse then
				world.mouse = I.new("PlayerMouse", world.id)
				world.mouse.Name = "Instance"
			end
			return wrap(world, world.mouse)
		end,
		LoadCharacter = function(self)
			local raw, world = self_(self, "LoadCharacter")
			if world.kind ~= "server" then
				error("LoadCharacter can only be called by the backend server", 2)
			end
			P.loadCharacter(raw)
		end,
		LoadCharacterAsync = function(self)
			local raw, world = self_(self, "LoadCharacterAsync")
			if world.kind ~= "server" then
				error("LoadCharacter can only be called by the backend server", 2)
			end
			P.loadCharacter(raw)
		end,
		LoadCharacterWithHumanoidDescription = function(self)
			local raw = self_(self, "LoadCharacterWithHumanoidDescription")
			P.loadCharacter(raw)
		end,
		RemoveCharacter = function(self)
			local raw = self_(self, "RemoveCharacter")
			local c = raw.props.Character
			if c then
				I.setProp(raw, "Character", nil)
				I.destroy(c)
			end
		end,
		ClearCharacterAppearance = function() end,
		GetNetworkPing = function()
			return 0
		end,
		HasAppearanceLoaded = function()
			return true
		end,
		GetJoinData = function()
			return { LaunchData = "", SourcePlaceId = 0, SourceGameId = 0, Members = {} }
		end,
		RequestStreamAroundAsync = function() end,
		DistanceFromCharacter = function(self, pos)
			local raw = self_(self, "DistanceFromCharacter")
			local c = raw.props.Character
			local root = c and I.findChild(c, "HumanoidRootPart", nil)
			if not root then
				return 0
			end
			return ((root.props.CFrame or D.CFrame.new()).Position - pos).Magnitude
		end,
		GetUnder13 = function()
			return false
		end,
		IsVerified = function()
			return false
		end,
		Move = function() end,
		SetSuperSafeChat = function() end,
		AddReplicationFocus = function() end,
		RemoveReplicationFocus = function() end,
	},
})

-- ── characters ───────────────────────────────────────────────────────────────
local function part(name, size, offset, model)
	local p = I.new("Part", nil)
	p.Name = name
	p.props.Size = size
	p.props.CFrame = D.CFrame.new(offset)
	p.props.Anchored = false
	p.props.CanCollide = name == "HumanoidRootPart" or name == "UpperTorso" or name == "LowerTorso" or name == "Head"
	if name == "HumanoidRootPart" then
		p.props.Transparency = 1
	end
	p.Parent = model
	table.insert(model.children, p)
	return p
end

local function defaultCharacter()
	local model = I.new("Model", nil)
	local root = part("HumanoidRootPart", D.Vector3.new(2, 2, 1), D.Vector3.new(0, 0, 0), model)
	part("Head", D.Vector3.new(1.2, 1.2, 1.2), D.Vector3.new(0, 1.6, 0), model)
	part("UpperTorso", D.Vector3.new(2, 1.6, 1), D.Vector3.new(0, 0.2, 0), model)
	part("LowerTorso", D.Vector3.new(2, 0.4, 1), D.Vector3.new(0, -0.8, 0), model)
	part("LeftUpperArm", D.Vector3.new(1, 1.2, 1), D.Vector3.new(-1.5, 0.4, 0), model)
	part("RightUpperArm", D.Vector3.new(1, 1.2, 1), D.Vector3.new(1.5, 0.4, 0), model)
	part("LeftHand", D.Vector3.new(1, 0.3, 1), D.Vector3.new(-1.5, -0.6, 0), model)
	part("RightHand", D.Vector3.new(1, 0.3, 1), D.Vector3.new(1.5, -0.6, 0), model)
	part("LeftUpperLeg", D.Vector3.new(1, 1.2, 1), D.Vector3.new(-0.5, -1.6, 0), model)
	part("RightUpperLeg", D.Vector3.new(1, 1.2, 1), D.Vector3.new(0.5, -1.6, 0), model)
	part("LeftFoot", D.Vector3.new(1, 0.3, 1), D.Vector3.new(-0.5, -2.6, 0), model)
	part("RightFoot", D.Vector3.new(1, 0.3, 1), D.Vector3.new(0.5, -2.6, 0), model)
	local hum = I.new("Humanoid", nil)
	hum.props.RigType = Enum.HumanoidRigType.R15
	hum.Parent = model
	table.insert(model.children, hum)
	local animator = I.new("Animator", nil)
	animator.Parent = hum
	table.insert(hum.children, animator)
	model.props.PrimaryPart = root
	return model
end

local function spawnCFrame()
	for _, d in I.descendants(I.service("Workspace")) do
		if d.ClassName == "SpawnLocation" and d.props.Enabled ~= false then
			return (d.props.CFrame or D.CFrame.new()) + D.Vector3.new(0, 4, 0)
		end
	end
	return D.CFrame.new(0, 5, 0)
end

local function cloneInto(srcParent, dstParent, owner, mark)
	if srcParent == nil then
		return
	end
	for _, c in srcParent.children do
		local cc = I.clone(c, owner)
		if cc then
			if mark then
				cc.fromStarterGui = true
			end
			I.setParent(cc, dstParent)
		end
	end
end

function P.loadCharacter(plr)
	if plr.Parent == nil or plr.left then
		return
	end
	local old = plr.props.Character
	if old then
		I.fireAbout(plr, "CharacterRemoving", old, old)
		plr.props.Character = nil
		I.destroy(old)
	end
	-- PlayerGui: StarterGui contents (ResetOnSpawn ones again on every spawn)
	local pg = I.findChild(plr, "PlayerGui", nil)
	local sg = I.service("StarterGui")
	if pg then
		for _, c in table.clone(pg.children) do
			if c.fromStarterGui and c.props.ResetOnSpawn ~= false then
				I.destroy(c)
			end
		end
		for _, c in sg.children do
			local keep = false
			for _, existing in pg.children do
				if existing.fromStarterGui and existing.Name == c.Name and existing.props.ResetOnSpawn == false then
					keep = true
				end
			end
			if not keep then
				local cc = I.clone(c, nil)
				if cc then
					cc.fromStarterGui = true
					I.setParent(cc, pg)
				end
			end
		end
	end
	-- Backpack: StarterPack + StarterGear
	local bp = I.findChild(plr, "Backpack", nil)
	if bp then
		for _, c in table.clone(bp.children) do
			I.destroy(c)
		end
		cloneInto(I.service("StarterPack"), bp, nil)
		cloneInto(I.findChild(plr, "StarterGear", nil), bp, nil)
	end
	local sp = I.service("StarterPlayer")
	local custom = I.findChild(sp, "StarterCharacter", nil)
	local model = if custom then I.clone(custom, nil) else defaultCharacter()
	model.Name = plr.Name
	H.pivotTo(model, spawnCFrame())
	local scs = I.findChild(sp, "StarterCharacterScripts", nil)
	if scs then
		for _, c in scs.children do
			local cc = I.clone(c, nil)
			if cc then
				cc.Parent = model
				table.insert(model.children, cc)
			end
		end
	end
	plr.props.Character = model
	I.changed(plr, "Character")
	I.fireAbout(plr, "CharacterAdded", model, model)
	I.setParent(model, I.service("Workspace"))
	H.afterDelay(0, function()
		if plr.props.Character == model then
			I.fireAbout(plr, "CharacterAppearanceLoaded", model, model)
		end
	end)
end

H.onHumanoidDied = function(hum)
	local model = hum.Parent
	local plr = model and H.playerFromCharacter(model)
	if not plr then
		return
	end
	local ps = playersService()
	local delay = I.getProp(ps, "RespawnTime") or 5
	H.afterDelay(delay, function()
		if I.getProp(ps, "CharacterAutoLoads") ~= false and plr.props.Character == model and not plr.left then
			P.loadCharacter(plr)
		end
	end)
end

-- ── join / leave ─────────────────────────────────────────────────────────────
local nextUserId = 0
P.list = {}

function P.join(name: string, userId: number?)
	nextUserId += 1
	local plr = I.new("Player", nil)
	plr.Name = name
	plr.props.UserId = userId or (H.options.firstUserId or 1) + nextUserId - 1
	plr.props.DisplayName = name
	local world = W.new("client:" .. name, "client", plr)
	plr.clientWorld = world
	for _, cls in { "Backpack", "PlayerGui", "StarterGear" } do
		local c = I.new(cls, nil)
		I.setParent(c, plr)
	end
	local ps = I.new("PlayerScripts", world.id)
	I.setParent(ps, plr)
	table.insert(P.list, plr)
	H.record("join", { player = name, userId = plr.props.UserId })
	local players = playersService()
	I.setParent(plr, players)
	I.fireAbout(players, "PlayerAdded", plr, plr)
	-- the client starts: ReplicatedFirst, then StarterPlayerScripts copies
	for _, d in I.descendants(I.service("ReplicatedFirst")) do
		if d.ClassName == "LocalScript" and d.props.Enabled ~= false and d.props.Disabled ~= true then
			W.runScript(d, world)
		end
	end
	local sps = I.findChild(I.service("StarterPlayer"), "StarterPlayerScripts", nil)
	cloneInto(sps, ps, world.id)
	if I.getProp(players, "CharacterAutoLoads") ~= false then
		H.afterDelay(0.1, function()
			P.loadCharacter(plr)
		end)
	end
	return plr
end

function P.leave(plr, reason)
	if plr.left then
		return
	end
	plr.left = true
	local world = plr.clientWorld
	if world then
		-- the client stops here: what it was still waiting for never comes
		if H.reportHangs then
			H.reportHangs(world)
		end
		world.dead = true
	end
	H.record("leave", { player = plr.Name, reason = reason or "left" })
	local players = playersService()
	I.fireAbout(players, "PlayerRemoving", plr, plr)
	H.afterDelay(S.FRAME, function()
		local char = plr.props.Character
		if char then
			I.fireAbout(plr, "CharacterRemoving", char, char)
			I.destroy(char)
		end
		I.setParent(plr, nil)
	end)
end

-- ── chat ─────────────────────────────────────────────────────────────────────
function P.setupChat()
	local tcs = I.service("TextChatService")
	if not I.findChild(tcs, "TextChannels", nil) then
		local channels = I.new("Folder", nil)
		channels.Name = "TextChannels"
		I.setParent(channels, tcs)
		for _, n in { "RBXGeneral", "RBXSystem" } do
			local ch = I.new("TextChannel", nil)
			ch.Name = n
			I.setParent(ch, channels)
		end
	end
	if not I.findChild(tcs, "TextChatCommands", nil) then
		local cmds = I.new("Folder", nil)
		cmds.Name = "TextChatCommands"
		I.setParent(cmds, tcs)
	end
end

I.define("TextChatService", {
	defaults = { ChatVersion = Enum.ChatVersion.TextChatService, CreateDefaultCommands = true, CreateDefaultTextChannels = true },
	methods = {
		CanUserChatAsync = function()
			H.asyncYield()
			return true
		end,
		CanUsersChatAsync = function()
			H.asyncYield()
			return true
		end,
		CanUsersDirectChatAsync = function()
			H.asyncYield()
			return {}
		end,
		DisplayBubble = function() end,
	},
})

local function textSource(channel, plr)
	local ts = I.new("TextSource", nil)
	ts.Name = plr.Name
	ts.props.UserId = plr.props.UserId
	ts.props.CanSend = true
	I.setParent(ts, channel)
	return ts
end

I.define("TextChannel", {
	methods = {
		SendAsync = function(self, text)
			local raw, world = self_(self, "SendAsync")
			H.record("chat", { channel = raw.Name, text = tostring(text), world = world.id })
			H.asyncYield()
			return nil
		end,
		DisplaySystemMessage = function(self, text)
			local raw, world = self_(self, "DisplaySystemMessage")
			H.record("chat", { channel = raw.Name, text = tostring(text), system = true, world = world.id })
			return nil
		end,
		AddUserAsync = function(self, userId)
			local raw, world = self_(self, "AddUserAsync")
			H.asyncYield()
			for _, p in playersService().children do
				if p.ClassName == "Player" and p.props.UserId == userId then
					return wrap(world, textSource(raw, p)), true
				end
			end
			return nil, false
		end,
		SetDirectChatRequester = function() end,
	},
})

I.define("TextChannel", {
	set = { ShouldDeliverCallback = H.callbackProp("ShouldDeliverCallback", "server") },
	get = { ShouldDeliverCallback = H.callbackGet("ShouldDeliverCallback", "TextChannel") },
})

-- Simulate a player typing `text` in chat, the way Roblox delivers it:
--  * a TextChatCommand whose alias matches the first word fires Triggered (and
--    the text is not sent as a message);
--  * otherwise the message goes to the RBXGeneral channel: the server's
--    ShouldDeliverCallback decides per recipient, then MessageReceived fires on
--    the clients that get it;
--  * with ChatVersion = LegacyChatService, Player.Chatted fires on the server.
local messageCount = 0
function P.chat(plr, text)
	H.record("chat", { player = plr.Name, text = text })
	local tcs = I.service("TextChatService")
	if I.getProp(tcs, "ChatVersion") == Enum.ChatVersion.LegacyChatService then
		I.fireAbout(plr, "Chatted", plr, text, nil)
		return
	end
	local channels = I.findChild(tcs, "TextChannels", nil)
	local general = channels and I.findChild(channels, "RBXGeneral", nil)
	local first = string.lower(string.match(text, "^(%S+)") or "")
	for _, d in I.descendants(tcs) do
		if d.ClassName == "TextChatCommand" and d.props.Enabled ~= false then
			local a1 = string.lower(d.props.PrimaryAlias or "")
			local a2 = string.lower(d.props.SecondaryAlias or "")
			if first ~= "" and (first == a1 or first == a2) then
				I.fire(d, "Triggered", textSource(general or tcs, plr), text)
				return
			end
		end
	end
	if general == nil then
		H.note("chat: TextChatService has no RBXGeneral channel; the message went nowhere")
		return
	end
	messageCount += 1
	local msg = I.new("TextChatMessage", nil)
	msg.props.Text = text
	msg.props.TextSource = textSource(general, plr)
	msg.props.TextChannel = general
	msg.props.MessageId = "harness-message-" .. messageCount
	msg.props.Timestamp = H.dt.DateTime.now()
	msg.props.Status = Enum.TextChatMessageStatus.Success
	local cb = general.callbacks and general.callbacks["ShouldDeliverCallback\0server"]
	for _, target in playersService().children do
		if target.ClassName ~= "Player" or target.left then
			continue
		end
		local deliver = true
		if cb then
			-- runs on a server thread (errors are reported like any game error)
			local result, done = nil, false
			local m, t = I.wrap(cb.world, msg), I.wrap(cb.world, textSource(general, target))
			S.spawn(function()
				result = cb.fn(m, t)
				done = true
			end, cb.world)
			deliver = not done or result ~= false
		end
		local cw = target.clientWorld
		if deliver and cw and not cw.dead then
			if general.sigs and general.sigs.MessageReceived then
				H.sig.fireWorld(general.sigs.MessageReceived, cw, msg)
			end
			if tcs.sigs and tcs.sigs.MessageReceived then
				H.sig.fireWorld(tcs.sigs.MessageReceived, cw, msg)
			end
		end
	end
end

return P
