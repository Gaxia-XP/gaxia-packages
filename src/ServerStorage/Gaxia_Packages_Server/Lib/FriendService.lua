--!strict
-- ─────────────────────────────────────────────────────────────
-- FriendService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/FriendService
-- Purpose : Game-internal buddies + blocks list persisted under
--           profile.Social via DataManager. Uses InviteQueue for
--           cross-server invite delivery. Online status is two-tier:
--           same-server PlayerService cache (free) then cross-server
--           Players:GetPresenceAsync cached for Social.Friend.OnlineCacheSec.
--           Block is bidirectional-ish (we drop the friendship + clear
--           outbound pending on our side; the other side still has us in
--           their list until they refresh/leave).
--
-- Access  : Gaxia.Friend  (server)
--   Friend.SendRequest(player, toUserId)
--   Friend.AcceptRequest(player, fromUserId)
--   Friend.DeclineRequest(player, fromUserId)
--   Friend.Remove(player, otherUserId)
--   Friend.Block(player, otherUserId)
--   Friend.Unblock(player, otherUserId)
--   Friend.SetFavorite(player, otherUserId, fav)
--   Friend.GetList(player) -> { { userId, name, online, favorite, since, note } }
--   Friend.GetBlocks(player) -> { { userId, name, at } }
--   Friend.IsBlocked(player, otherUserId)
--   Friend.IsBlockedByUserId(blockerUserId, otherUserId)
--   Friend.RefreshPresence(player)
--
-- Signals : OnRequest(toPlayer, fromUserId, fromName)
--           OnAccepted(player, otherUserId)
--           OnRemoved(player, otherUserId)
--           OnBlocked(player, otherUserId)
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local SharedPkg =
	require(ReplicatedStorage:WaitForChild("Gaxia_Packages"):WaitForChild("init")) :: any
local Signal = SharedPkg.Signal

local GaxiaServer: any = nil
local function server(): any
	if not GaxiaServer then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server")
			:WaitForChild("init")
		GaxiaServer = require(serverInit :: any)
	end
	return GaxiaServer
end

-- ── Effective config ──
local function fcfg(): any
	return ((server().Config or {}).Social or {}).Friend or {}
end
local function fget(key: string, fallback: any): any
	return server().EConfig.Get(`Social.Friend.{key}`, fcfg()[key] or fallback)
end

-- ── Module + signals ──
local Friend = {}
Friend.OnRequest = Signal.new() -- (toPlayer, fromUserId, fromName)
Friend.OnAccepted = Signal.new() -- (player, otherUserId)
Friend.OnRemoved = Signal.new() -- (player, otherUserId)
Friend.OnBlocked = Signal.new() -- (player, otherUserId)

-- Cross-server inbound cache (drained at PlayerAdded). Declared up-front so
-- helpers below can reference it without a "global write" lint warning.
local inboundCache: { [number]: { [number]: boolean } } = {}

-- Same-server outbound index: senderUid -> { targetUid -> true }. Lets
-- findInboundFrom look up "did sender X have a pending invite to me?" without
-- needing the sender's Player instance (which doesn't exist for offline senders
-- or for MockPlayer in tests). Mirrors social.PendingOut on the sender side.
local outboundIndex: { [number]: { [number]: boolean } } = {}

-- ── Profile shape helpers ──
local function getSocial(player: any): any
	local s = server()
	local Data = s.Data
	local social = Data.Get(player, "Social")
	if typeof(social) ~= "table" then
		social = { Friends = {}, Blocks = {}, PendingOut = {} }
		Data.Set(player, "Social", social)
	end
	social.Friends = social.Friends or {}
	social.Blocks = social.Blocks or {}
	social.PendingOut = social.PendingOut or {}
	return social
end
local function writeSocial(player: any, social: any): ()
	server().Data.Set(player, "Social", social)
end

-- ── Presence cache (cross-server) ──
local presenceCache: { [number]: { name: string?, online: boolean, at: number } } = {}
local function lookupName(userId: number): string?
	local ok, name = pcall(function()
		return game:GetService("Players"):GetNameFromUserIdAsync(userId)
	end)
	if ok then
		return name
	end
	return nil
end
local function presenceFor(userId: number): { name: string?, online: boolean, at: number }
	local now = os.time()
	local cache = presenceCache[userId]
	local ttl = fget("OnlineCacheSec", 60)
	if cache and (now - cache.at) < ttl then
		return cache
	end
	-- Same-server first (free).
	local Players = game:GetService("Players")
	local same = Players:GetPlayerByUserId(userId)
	if same then
		cache = { name = same.Name, online = true, at = now }
		presenceCache[userId] = cache
		return cache
	end
	-- Cross-server (rate-limited, wrapped in pcall).
	local ok, info = pcall(function()
		return (Players :: any):GetPresenceAsync({ userId })[1]
	end)
	local online = false
	if ok and typeof(info) == "table" then
		-- UserPresenceType: 1=Online, 2=InGame, 3=InStudio, 4=Offline (best-effort)
		local kind = info.UserPresenceType
		online = (kind == 1 or kind == 2 or kind == 3)
	end
	cache = { name = lookupName(userId), online = online, at = now }
	presenceCache[userId] = cache
	return cache
end

-- ── Public: IsBlocked / IsBlockedByUserId ──
function Friend.IsBlocked(player: any, otherUserId: number): boolean
	local social = getSocial(player)
	return social.Blocks[otherUserId] ~= nil
end
-- Used by PartyService.Invite without needing the blocker to be in-server. If the
-- blocker is in this server, check; otherwise return false (best-effort across servers).
function Friend.IsBlockedByUserId(blockerUserId: number, otherUserId: number): boolean
	local Players = game:GetService("Players")
	local blocker = Players:GetPlayerByUserId(blockerUserId)
	if not blocker then
		return false
	end
	return Friend.IsBlocked(blocker, otherUserId)
end

-- ── Public: SendRequest ──
function Friend.SendRequest(from: any, toUserId: number): (boolean, string?)
	if not from or typeof(from.UserId) ~= "number" then
		return false, "invalid sender"
	end
	if from.UserId == toUserId then
		return false, "cannot friend self"
	end
	local social = getSocial(from)
	if social.Blocks[toUserId] then
		return false, "you have blocked this user — unblock first"
	end
	if social.Friends[toUserId] then
		return false, "already friends"
	end
	if social.PendingOut[toUserId] then
		return false, "request already pending"
	end
	local maxFriends = fget("MaxFriends", 200)
	local count = 0
	for _ in pairs(social.Friends) do
		count += 1
	end
	if count >= maxFriends then
		return false, `max friends ({maxFriends}) reached`
	end

	-- Cooldown FIRST (before any target-side check or web call). This prevents
	-- an attacker from spamming SendRequest(uid) to enumerate which userIds
	-- exist + which userIds block them by observing different error strings,
	-- and from burning a GetNameFromUserIdAsync web call per attempt. The
	-- legitimate "I unblocked you, let me re-request" path is handled by
	-- Friend.Unblock calling Cooldown.Clear on this same key.
	local s = server()
	local Cooldown = s.Cooldown
	local cdKey = string.format("FriendReq:%d->%d", from.UserId, toUserId)
	local cd = fget("RequestCooldownSec", 10)
	if Cooldown then
		local cdReady = Cooldown.Consume(cdKey, cd)
		if not cdReady then
			return false, "wait a moment before resending"
		end
	end

	-- Block check on TARGET's side (only if target is in this server OR has a
	-- loaded profile via a UserId shim — that covers offline players who
	-- previously logged in this server, plus MockPlayer in tests).
	local Players = game:GetService("Players")
	local targetPlayer = Players:GetPlayerByUserId(toUserId)
	local targetBlocksMe = false
	if targetPlayer then
		targetBlocksMe = Friend.IsBlocked(targetPlayer, from.UserId)
	else
		local targetSocialRaw = s.Data.Get({ UserId = toUserId } :: any, "Social")
		if typeof(targetSocialRaw) == "table" and typeof(targetSocialRaw.Blocks) == "table" then
			targetBlocksMe = targetSocialRaw.Blocks[from.UserId] ~= nil
		end
	end
	if targetBlocksMe then
		return false, "could not send request"
	end

	-- Verify target is a real account (best-effort).
	local targetName = (targetPlayer and targetPlayer.Name) or lookupName(toUserId)
	if not targetName then
		return false, "unknown user"
	end

	-- Record outgoing pending.
	social.PendingOut[toUserId] = { name = targetName, at = os.time() }
	writeSocial(from, social)
	outboundIndex[from.UserId] = outboundIndex[from.UserId] or {}
	outboundIndex[from.UserId][toUserId] = true

	-- Durable cross-server delivery: ALWAYS enqueue so a server restart doesn't
	-- strand same-server invites that the target hasn't accepted yet. Same-server
	-- ALSO gets a direct OnRequest fire so the UI sees it instantly. The
	-- PlayerAdded drain dedupes via inboundCache/outboundIndex, and clients are
	-- expected to dedupe replayed OnRequest by invite identity (sender userId).
	local InviteQueue = s.InviteQueue
	if InviteQueue then
		local ttl = (fget("InviteQueueTTLDays", 7)) * 86400
		InviteQueue.Push("friend", toUserId, {
			fromUserId = from.UserId,
			fromName = from.Name,
			at = os.time(),
		}, ttl)
	end
	if targetPlayer then
		Friend.OnRequest:Fire(targetPlayer, from.UserId, from.Name)
	end
	return true, nil
end

-- ── Inbound pending lookup (helper) ──
-- For accept/decline, locate any record that sender→me is pending. We check
-- THREE sources because each covers a different delivery path:
--   1. sender's profile PendingOut[me] — same-server real Player.
--   2. outboundIndex[sender][me] — same-server fallback when the sender's
--      Player instance isn't reachable (offline since send, or MockPlayer
--      in a test). Mirrors PendingOut at module scope.
--   3. inboundCache[me][sender] — cross-server queue drained at our PlayerAdded.
local function findInboundFrom(me: any, senderUserId: number): boolean
	local Players = game:GetService("Players")
	local sender = Players:GetPlayerByUserId(senderUserId)
	if sender then
		local senderSocial = getSocial(sender)
		if senderSocial.PendingOut[me.UserId] ~= nil then
			return true
		end
	end
	local outbox = outboundIndex[senderUserId]
	if outbox and outbox[me.UserId] then
		return true
	end
	local inbox = inboundCache[me.UserId]
	return inbox ~= nil and inbox[senderUserId] ~= nil
end

function Friend.AcceptRequest(player: any, fromUserId: number): (boolean, string?)
	if not findInboundFrom(player, fromUserId) then
		return false, "no such request"
	end
	local social = getSocial(player)
	local maxFriends = fget("MaxFriends", 200)
	local count = 0
	for _ in pairs(social.Friends) do
		count += 1
	end
	if count >= maxFriends then
		return false, "max friends reached"
	end

	local Players = game:GetService("Players")
	local sender = Players:GetPlayerByUserId(fromUserId)
	local senderName = (sender and sender.Name) or lookupName(fromUserId) or "?"

	-- Add to my list.
	social.Friends[fromUserId] =
		{ name = senderName, since = os.time(), favorite = false, note = "" }
	writeSocial(player, social)

	-- Add to sender's list + clear their PendingOut[me]. Take the sender's
	-- profile via getSocial when we have a Player instance (fires Signals); fall
	-- back to a UserId shim when sender is offline-in-this-server or a MockPlayer
	-- (no Player instance) — same shape Data.Get/Set needs.
	if sender then
		local senderSocial = getSocial(sender)
		senderSocial.Friends[player.UserId] =
			{ name = player.Name, since = os.time(), favorite = false, note = "" }
		senderSocial.PendingOut[player.UserId] = nil
		writeSocial(sender, senderSocial)
		Friend.OnAccepted:Fire(sender, player.UserId)
	else
		local Data = server().Data
		local shim: any = { UserId = fromUserId }
		local senderSocialRaw = Data.Get(shim, "Social")
		if typeof(senderSocialRaw) == "table" then
			senderSocialRaw.Friends = senderSocialRaw.Friends or {}
			senderSocialRaw.PendingOut = senderSocialRaw.PendingOut or {}
			senderSocialRaw.Friends[player.UserId] = {
				name = player.Name,
				since = os.time(),
				favorite = false,
				note = "",
			}
			senderSocialRaw.PendingOut[player.UserId] = nil
			Data.Set(shim, "Social", senderSocialRaw)
		end
	end
	-- Clear both same-server outbound mirror and cross-server inbound cache.
	if outboundIndex[fromUserId] then
		outboundIndex[fromUserId][player.UserId] = nil
	end
	if inboundCache[player.UserId] then
		inboundCache[player.UserId][fromUserId] = nil
	end
	Friend.OnAccepted:Fire(player, fromUserId)
	return true, nil
end

function Friend.DeclineRequest(player: any, fromUserId: number): (boolean, string?)
	if not findInboundFrom(player, fromUserId) then
		return false, "no such request"
	end
	local Players = game:GetService("Players")
	local sender = Players:GetPlayerByUserId(fromUserId)
	if sender then
		local senderSocial = getSocial(sender)
		senderSocial.PendingOut[player.UserId] = nil
		writeSocial(sender, senderSocial)
	end
	if outboundIndex[fromUserId] then
		outboundIndex[fromUserId][player.UserId] = nil
	end
	if inboundCache[player.UserId] then
		inboundCache[player.UserId][fromUserId] = nil
	end
	return true, nil
end

function Friend.Remove(player: any, otherUserId: number): (boolean, string?)
	local social = getSocial(player)
	if not social.Friends[otherUserId] then
		return false, "not friends"
	end
	social.Friends[otherUserId] = nil
	writeSocial(player, social)
	local Players = game:GetService("Players")
	local other = Players:GetPlayerByUserId(otherUserId)
	if other then
		local s = getSocial(other)
		s.Friends[player.UserId] = nil
		writeSocial(other, s)
		Friend.OnRemoved:Fire(other, player.UserId)
	end
	Friend.OnRemoved:Fire(player, otherUserId)
	return true, nil
end

function Friend.Block(player: any, otherUserId: number): (boolean, string?)
	if player.UserId == otherUserId then
		return false, "cannot block self"
	end
	local social = getSocial(player)
	local maxBlocks = fget("MaxBlocks", 100)
	local count = 0
	for _ in pairs(social.Blocks) do
		count += 1
	end
	if count >= maxBlocks then
		return false, "max blocks reached"
	end
	social.Blocks[otherUserId] = { name = lookupName(otherUserId), at = os.time() }
	-- Block implies remove friendship + drop pending both ways.
	social.Friends[otherUserId] = nil
	social.PendingOut[otherUserId] = nil
	writeSocial(player, social)
	-- Mirror PendingOut clear into the module-level outbound index, and drop any
	-- inbound from the blocked user so a stale request can't be accepted later.
	if outboundIndex[player.UserId] then
		outboundIndex[player.UserId][otherUserId] = nil
	end
	if outboundIndex[otherUserId] then
		outboundIndex[otherUserId][player.UserId] = nil
	end
	if inboundCache[player.UserId] then
		inboundCache[player.UserId][otherUserId] = nil
	end
	-- Best-effort bidirectional cleanup: if the blocked user has a loaded
	-- profile in this server (real Player OR test-seeded MockPlayer), wipe
	-- their friendship-to-us + any PendingOut-to-us so they can't keep us in
	-- their list or replay a stale request. We use DataManager directly with a
	-- UserId-only shim because real Players AND MockPlayers both expose
	-- `.UserId` and that's all Data.Get / Data.Set ever reads. Cross-server
	-- peers (no loaded profile) fall through harmlessly.
	local Data = server().Data
	local otherShim: any = { UserId = otherUserId }
	local otherSocialRaw = Data.Get(otherShim, "Social")
	if typeof(otherSocialRaw) == "table" then
		if typeof(otherSocialRaw.Friends) == "table" then
			otherSocialRaw.Friends[player.UserId] = nil
		end
		if typeof(otherSocialRaw.PendingOut) == "table" then
			otherSocialRaw.PendingOut[player.UserId] = nil
		end
		Data.Set(otherShim, "Social", otherSocialRaw)
	end
	Friend.OnBlocked:Fire(player, otherUserId)
	return true, nil
end

function Friend.Unblock(player: any, otherUserId: number): (boolean, string?)
	local social = getSocial(player)
	if not social.Blocks[otherUserId] then
		return false, "not blocked"
	end
	social.Blocks[otherUserId] = nil
	writeSocial(player, social)
	-- Unblocking releases any outstanding "wait before retrying" cooldown so the
	-- legitimate re-request flow isn't blocked by the rate limiter. Clear BOTH
	-- directions: the other party's earlier attempt (which got rejected with
	-- "could not send request" while we were blocking them) also charged a
	-- cooldown slot under their key, and unblock signals "I'm open to either of
	-- us reaching out again".
	local s = server()
	if s.Cooldown and s.Cooldown.Clear then
		s.Cooldown.Clear(string.format("FriendReq:%d->%d", player.UserId, otherUserId))
		s.Cooldown.Clear(string.format("FriendReq:%d->%d", otherUserId, player.UserId))
	end
	return true, nil
end

function Friend.SetFavorite(player: any, otherUserId: number, fav: boolean): ()
	local social = getSocial(player)
	local rec = social.Friends[otherUserId]
	if rec then
		rec.favorite = fav and true or false
		writeSocial(player, social)
	end
end

function Friend.GetList(player: any): { any }
	local social = getSocial(player)
	local list = {}
	for uid, rec in pairs(social.Friends) do
		local pres = presenceFor(uid)
		table.insert(list, {
			userId = uid,
			name = rec.name or pres.name or "?",
			online = pres.online,
			favorite = rec.favorite == true,
			since = rec.since,
			note = rec.note or "",
		})
	end
	table.sort(list, function(a, b)
		if a.online ~= b.online then
			return a.online
		end
		if a.favorite ~= b.favorite then
			return a.favorite
		end
		return (a.name or "") < (b.name or "")
	end)
	return list
end

function Friend.GetBlocks(player: any): { any }
	local social = getSocial(player)
	local list = {}
	for uid, rec in pairs(social.Blocks) do
		table.insert(list, { userId = uid, name = rec.name, at = rec.at })
	end
	return list
end

function Friend.RefreshPresence(player: any): ()
	local social = getSocial(player)
	for uid in pairs(social.Friends) do
		presenceCache[uid] = nil -- force recompute on next GetList
	end
end

-- ── Cross-server inbound drain at PlayerAdded ──
local function drainOnJoin(player: Player): ()
	local s = server()
	local InviteQueue = s and s.InviteQueue
	if not InviteQueue then
		return
	end
	local items = InviteQueue.DrainFor("friend", player.UserId)
	inboundCache[player.UserId] = inboundCache[player.UserId] or {}
	for _, item in ipairs(items) do
		if typeof(item) == "table" and typeof(item.fromUserId) == "number" then
			inboundCache[player.UserId][item.fromUserId] = true
			Friend.OnRequest:Fire(player, item.fromUserId, item.fromName or "?")
		end
	end
end

do
	local Players = game:GetService("Players")
	Players.PlayerAdded:Connect(function(p)
		task.spawn(drainOnJoin, p)
	end)
	Players.PlayerRemoving:Connect(function(p)
		inboundCache[p.UserId] = nil
		outboundIndex[p.UserId] = nil
		presenceCache[p.UserId] = nil
	end)
	for _, p in ipairs(Players:GetPlayers()) do
		task.spawn(drainOnJoin, p)
	end
end

-- ── RemoteFunction surface ──
do
	local Events = ReplicatedStorage:FindFirstChild("Events") or Instance.new("Folder")
	Events.Name = "Events"
	Events.Parent = ReplicatedStorage
	local FriendFolder = Events:FindFirstChild("Friend") or Instance.new("Folder")
	FriendFolder.Name = "Friend"
	FriendFolder.Parent = Events
	local Action = FriendFolder:FindFirstChild("Action") or Instance.new("RemoteFunction")
	Action.Name = "Action"
	Action.Parent = FriendFolder
	local Inbound = FriendFolder:FindFirstChild("Inbound") or Instance.new("RemoteEvent")
	Inbound.Name = "Inbound"
	Inbound.Parent = FriendFolder

	Action.OnServerInvoke = function(player: Player, envelope: any): (boolean, any)
		if typeof(envelope) ~= "table" or typeof(envelope.type) ~= "string" then
			return false, "bad envelope"
		end
		local t = envelope.type
		if t == "send" then
			return Friend.SendRequest(player, envelope.to)
		end
		if t == "accept" then
			return Friend.AcceptRequest(player, envelope.from)
		end
		if t == "decline" then
			return Friend.DeclineRequest(player, envelope.from)
		end
		if t == "remove" then
			return Friend.Remove(player, envelope.other)
		end
		if t == "block" then
			return Friend.Block(player, envelope.other)
		end
		if t == "unblock" then
			return Friend.Unblock(player, envelope.other)
		end
		if t == "favorite" then
			Friend.SetFavorite(player, envelope.other, envelope.fav == true)
			return true
		end
		if t == "list" then
			return true, Friend.GetList(player)
		end
		if t == "blocks" then
			return true, Friend.GetBlocks(player)
		end
		return false, "unknown action"
	end

	-- Push inbound events to the affected player.
	Friend.OnRequest:Connect(function(toPlayer, fromUserId, fromName)
		Inbound:FireClient(toPlayer, { type = "request", from = fromUserId, fromName = fromName })
	end)
	Friend.OnAccepted:Connect(function(player, otherUserId)
		Inbound:FireClient(player, { type = "accepted", other = otherUserId })
	end)
	Friend.OnRemoved:Connect(function(player, otherUserId)
		Inbound:FireClient(player, { type = "removed", other = otherUserId })
	end)
end

return Friend
