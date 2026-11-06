--!strict
-- ─────────────────────────────────────────────────────────────
-- PartyService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/PartyService
-- Purpose : Grouping + matchmaking that unlocks co-op / lobby flows. Players form
--           a party (leader + members, capped size, leader auto-promotes on
--           leave); QueueForMatch drops the party into a cross-server pool
--           (Gaxia.Memory sorted map, FIFO by enqueue time); PollMatch pulls the
--           oldest parties until a match is full, removes them from the pool, and
--           reserves a server (Gaxia.Teleport); StartMatch teleports every member
--           to a reserved server with party data. Built on the verified Memory +
--           Teleport layers, so it degrades gracefully in Studio.
--           A player who leaves the game leaves their party (PlayerRemoving →
--           Leave): the leader passes on, an empty party is removed.
--
-- Access  : Gaxia.Party  (server)
--   local pid = Gaxia.Party.Create(leader) ; Gaxia.Party.Join(p2, pid)
--   Gaxia.Party.QueueForMatch(pid, "Duel", placeId)
--   local match = Gaxia.Party.PollMatch("Duel", 2)   -- {parties, accessCode, placeId}
-- ─────────────────────────────────────────────────────────────
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Signal          = require(ReplicatedStorage.Gaxia_Packages.Shared.Signal)
local Net             = require(ReplicatedStorage.Gaxia_Packages.Shared.NetService)
local Lifecycle       = require(script.Parent.ServiceLifecycle)
local Config          = require(script.Parent.Parent.Config)
local EConfig         = require(script.Parent.EffectiveConfig)
local MemoryStore     = require(script.Parent.MemoryStore)
local TeleportService = require(script.Parent.TeleportService)
local InviteQueue     = require(script.Parent.InviteQueue)
local FriendService   = require(script.Parent.FriendService)

local POOL_TTL: number = 120

-- ── Types ──
-- Party members / leaders are stored as `any`: tests pass MockPlayers (StartMatch
-- only teleports the members that are real Player Instances). The getters return
-- them as Player, which is what a game has.
type Party = { id: string, leader: any, members: { any } }

-- One queued party in the matchmaking pool (Memory sorted map value).
export type PoolEntry = { partyId: string, memberIds: { number }, size: number, placeId: number }
-- PollMatch result: the parties that formed the match and the reserved server.
export type MatchResult = { parties: { PoolEntry }, accessCode: string?, placeId: number? }

local PartyService = {}

-- (partyId)
PartyService.OnPartyChanged = Signal.new() :: Signal.Signal<string>
-- (matchType, parties, accessCode)
PartyService.OnMatchFound = Signal.new() :: Signal.Signal<string, { PoolEntry }, string?>

local parties: { [string]: Party } = {}
local playerParty: { [number]: string } = {}
local seq = 0
local maxSizeOverride: number? = nil -- set via SetMaxSize; else Config.Party.MaxSize

-- Effective tunable: runtime Flag override <- Config.Party default <- fallback.
local function partyGet(key: string, configured: number?, fallback: number): number
	return EConfig.Get(`Party.{key}`, configured or fallback)
end
local function getMaxSize(): number
	return maxSizeOverride or partyGet("MaxSize", Config.Party.MaxSize, 4)
end

-- ── Argument checks (game code and the Party remote share them) ──
-- A userId: a whole number (NaN, ±inf, fractions and non-numbers are not).
local function isUserId(v: any): boolean
	return typeof(v) == "number" and v == v and v % 1 == 0 and math.abs(v) < 2 ^ 53
end
local function isPlayerLike(player: any): boolean
	return (typeof(player) == "Instance" or typeof(player) == "table") and isUserId(player.UserId)
end
local MAX_PARTY_ID_LEN = 64
local function isPartyId(v: any): boolean
	return typeof(v) == "string" and #v > 0 and #v <= MAX_PARTY_ID_LEN
end

-- ── Lifecycle ──

-- Runtime override of party size; nil/unset falls back to Config.Party.MaxSize.
function PartyService.SetMaxSize(n: number): ()
	maxSizeOverride = math.max(1, n)
end

-- Makes a party led by `leader` and returns its id; nil when `leader` is already
-- in a party (or is not a player).
function PartyService.Create(leader: any): string?
	if not isPlayerLike(leader) or playerParty[leader.UserId] then
		return nil
	end
	seq += 1
	local id = `party_{seq}`
	parties[id] = { id = id, leader = leader, members = { leader } }
	playerParty[leader.UserId] = id
	PartyService.OnPartyChanged:Fire(id)
	return id
end

function PartyService.GetParty(player: any): string?
	if not isPlayerLike(player) then
		return nil
	end
	return playerParty[player.UserId]
end

-- The party's members, leader included, in join order. A new list each call
-- (changing it does not change the party); empty when the party does not exist.
function PartyService.GetMembers(partyId: string): { Player }
	local out: { Player } = {}
	local p = parties[partyId]
	if p then
		for i, m in ipairs(p.members) do
			out[i] = m
		end
	end
	return out
end

function PartyService.GetLeader(partyId: string): Player?
	local p = parties[partyId]
	return p and p.leader
end

function PartyService.IsLeader(player: any): boolean
	if not isPlayerLike(player) then
		return false
	end
	local id = playerParty[player.UserId]
	local p = id and parties[id]
	return p ~= nil and p.leader.UserId == player.UserId
end

function PartyService.Join(player: any, partyId: string): (boolean, string)
	if not isPlayerLike(player) then
		return false, "invalid player"
	end
	if not isPartyId(partyId) then
		return false, "no such party"
	end
	if playerParty[player.UserId] then
		return false, "already in a party"
	end
	local p = parties[partyId]
	if not p then
		return false, "no such party"
	end
	if #p.members >= getMaxSize() then
		return false, "party full"
	end
	table.insert(p.members, player)
	playerParty[player.UserId] = partyId
	PartyService.OnPartyChanged:Fire(partyId)
	return true, "ok"
end

-- Removes `player` from their party. The next member becomes leader when the
-- leader leaves; the party is removed when it is empty. Called automatically
-- when a player leaves the game.
function PartyService.Leave(player: any): ()
	if not isPlayerLike(player) then
		return
	end
	local id = playerParty[player.UserId]
	local p = id and parties[id]
	if not p then
		return
	end
	playerParty[player.UserId] = nil
	for i, m in ipairs(p.members) do
		if m.UserId == player.UserId then
			table.remove(p.members, i)
			break
		end
	end
	if #p.members == 0 then
		parties[id] = nil
		PartyService.OnPartyChanged:Fire(id)
		return
	end
	-- promote a new leader if the leader left
	if p.leader.UserId == player.UserId then
		p.leader = p.members[1]
	end
	PartyService.OnPartyChanged:Fire(id)
end

function PartyService.Disband(leader: any): boolean
	if not isPlayerLike(leader) then
		return false
	end
	local id = playerParty[leader.UserId]
	local p = id and parties[id]
	if not p or p.leader.UserId ~= leader.UserId then
		return false
	end
	for _, m in ipairs(p.members) do
		playerParty[m.UserId] = nil
	end
	parties[id] = nil
	PartyService.OnPartyChanged:Fire(id)
	return true
end

-- ── Matchmaking (cross-server pool via Gaxia.Memory) ──

local function poolName(matchType: string): string
	return `mm_{matchType}`
end

function PartyService.QueueForMatch(
	partyId: string,
	matchType: string,
	placeId: number
): (boolean, string)
	local p = parties[partyId]
	if not p then
		return false, "no such party"
	end
	local memberIds: { number } = {}
	for _, m in ipairs(p.members) do
		table.insert(memberIds, m.UserId)
	end
	local entry: PoolEntry = { partyId = partyId, memberIds = memberIds, size = #p.members, placeId = placeId }
	MemoryStore.MapSet(poolName(matchType), partyId, entry, partyGet("PoolTTL", Config.Party.PoolTTL, POOL_TTL), os.time())
	return true, "ok"
end

function PartyService.Unqueue(partyId: string, matchType: string): ()
	MemoryStore.MapRemove(poolName(matchType), partyId)
end

-- Pull oldest queued parties until `neededPlayers` is reached; if a full match
-- forms, remove those parties from the pool, reserve a server, and return it.
function PartyService.PollMatch(matchType: string, neededPlayers: number): MatchResult?
	local pool = MemoryStore.MapRange(poolName(matchType), partyGet("PoolScanLimit", Config.Party.PoolScanLimit, 50), true) -- oldest first
	local chosen: { PoolEntry } = {}
	local total = 0
	local placeId: number? = nil
	for _, row in ipairs(pool) do
		local entry = row.value
		table.insert(chosen, entry)
		total += entry.size
		placeId = entry.placeId
		if total >= neededPlayers then
			break
		end
	end
	if total < neededPlayers then
		return nil
	end
	for _, entry in ipairs(chosen) do
		MemoryStore.MapRemove(poolName(matchType), entry.partyId)
	end
	local accessCode = TeleportService.ReserveServer(placeId or 0)
	PartyService.OnMatchFound:Fire(matchType, chosen, accessCode)
	return { parties = chosen, accessCode = accessCode, placeId = placeId }
end

-- ── Start a match: reserve a server + teleport every member ──
function PartyService.StartMatch(partyId: string, placeId: number): (boolean, any)
	local p = parties[partyId]
	if not p then
		return false, "no such party"
	end
	local code, _, rerr = TeleportService.ReserveServer(placeId)
	if not code then
		return false, rerr or "reserve failed"
	end
	-- Only real Player members can be teleported.
	local toSend: { Player } = {}
	for _, m in ipairs(p.members) do
		if typeof(m) == "Instance" then
			table.insert(toSend, m)
		end
	end
	local ok, err = TeleportService.ToPrivate(toSend, placeId, code, { Data = { partyId = partyId } })
	return ok, err
end

-- ── Invites (Phase 26 · Social) ─────────────────────────────────
-- Pending invites are RAM-only and ephemeral. Same-server: direct fire of
-- OnInvite. Cross-server: InviteQueue.Push("party", ...) drained at
-- PlayerAdded for the joining player.

-- (toPlayer, partyId, fromName)
PartyService.OnInvite = Signal.new() :: Signal.Signal<Player, string, string>
-- (leader, targetUserId, accepted)
PartyService.OnInviteResponded = Signal.new() :: Signal.Signal<Player, number, boolean>

-- A pending party invite (GetPendingInvites; also the InviteQueue "party" item).
export type PendingInvite = {
	partyId: string,
	fromUserId: number,
	fromName: string,
	expiresAt: number,
}

-- Pending invites indexed by target UserId, then by partyId so a target may have
-- multiple invites from different parties without overwriting.
local pendingByUser: { [number]: { [string]: PendingInvite } } = {}

-- Per-player token bucket of the Party remote (see "Remote guard" below).
type RemoteBucket = { tokens: number, last: number }
local remoteBuckets: { [number]: RemoteBucket } = {}

local function inviteCfg(key: string, configured: number?, fallback: number): number
	return EConfig.Get(`Social.Party.{key}`, configured or fallback)
end

local function getPendingMap(userId: number): { [string]: PendingInvite }
	pendingByUser[userId] = pendingByUser[userId] or {}
	return pendingByUser[userId]
end

-- Read-only — does NOT auto-create the per-user map.
local function peekPendingMap(userId: number): { [string]: PendingInvite }?
	return pendingByUser[userId]
end

local function pendingCount(userId: number): number
	local pmap = peekPendingMap(userId)
	if not pmap then
		return 0
	end
	local n = 0
	for _ in pairs(pmap) do
		n += 1
	end
	return n
end

local function cleanExpired(userId: number): ()
	local pmap = peekPendingMap(userId)
	if not pmap then
		return
	end
	local now = os.time()
	for pid, inv in pairs(pmap) do
		if inv.expiresAt <= now then
			pmap[pid] = nil
		end
	end
end

-- The leader invites `targetUserId` (same server: OnInvite; else the InviteQueue).
-- (false, why) on "invalid leader", "invalid target", "cannot invite self", ...
function PartyService.Invite(leader: any, targetUserId: number): (boolean, string?)
	if not isPlayerLike(leader) then
		return false, "invalid leader"
	end
	if not isUserId(targetUserId) then
		return false, "invalid target"
	end
	if leader.UserId == targetUserId then
		return false, "cannot invite self"
	end
	if not PartyService.IsLeader(leader) then
		return false, "only the party leader can invite"
	end
	local partyId = PartyService.GetParty(leader)
	if not partyId then
		return false, "leader is not in a party"
	end
	local party = parties[partyId]
	if not party then
		return false, "party not found"
	end

	cleanExpired(targetUserId)
	local pending = getPendingMap(targetUserId)
	if pending[partyId] then
		return false, "already invited"
	end
	local maxSize = getMaxSize()
	-- Count distinct targets with a pending invite to THIS party (which equals
	-- outstanding invites issued by this party, because the dup-check above
	-- prevents the same (party, target) pair being invited twice).
	local outstanding = 0
	for _, perUser in pairs(pendingByUser) do
		if perUser[partyId] then
			outstanding += 1
		end
	end
	if (#party.members + outstanding) >= maxSize then
		return false, "party + pending invites would exceed max size"
	end
	if pendingCount(targetUserId) >= inviteCfg("MaxPending", Config.Social.Party.MaxPending, 10) then
		return false, "target has too many pending invites"
	end

	-- Friend block check (best-effort: only a blocker in this server is known).
	if FriendService.IsBlockedByUserId(targetUserId, leader.UserId) then
		return false, "could not invite"
	end

	local ttl = inviteCfg("InviteTTL", Config.Social.Party.InviteTTL, 60)
	local invite: PendingInvite = {
		partyId = partyId,
		fromUserId = leader.UserId,
		fromName = leader.Name,
		expiresAt = os.time() + ttl,
	}
	pending[partyId] = invite

	local Players = game:GetService("Players")
	local targetPlayer = Players:GetPlayerByUserId(targetUserId)
	if targetPlayer then
		PartyService.OnInvite:Fire(targetPlayer, partyId, leader.Name)
	else
		-- Cross-server: push to MemoryStore queue for drain at PlayerAdded.
		InviteQueue.Push("party", targetUserId, invite, ttl)
	end
	return true, nil
end

function PartyService.GetPendingInvites(player: any): { PendingInvite }
	if not isPlayerLike(player) then
		return {}
	end
	cleanExpired(player.UserId)
	local pmap = peekPendingMap(player.UserId)
	if not pmap then
		return {}
	end
	local list: { PendingInvite } = {}
	for _, inv in pairs(pmap) do
		table.insert(list, inv)
	end
	table.sort(list, function(a, b)
		return a.expiresAt < b.expiresAt
	end)
	return list
end

function PartyService.CancelInvite(leader: any, targetUserId: number): ()
	if not isUserId(targetUserId) or not PartyService.IsLeader(leader) then
		return
	end
	local pid = PartyService.GetParty(leader)
	if not pid then
		return
	end
	local pmap = peekPendingMap(targetUserId)
	if pmap then
		pmap[pid] = nil
	end
end

function PartyService.DeclineInvite(player: any, partyId: string): (boolean, string?)
	if not isPlayerLike(player) then
		return false, "invalid player"
	end
	if not isPartyId(partyId) then
		return false, "no such invite"
	end
	cleanExpired(player.UserId)
	local pmap = peekPendingMap(player.UserId)
	local inv = pmap and pmap[partyId]
	if not pmap or not inv then
		return false, "no such invite"
	end
	pmap[partyId] = nil
	local Players = game:GetService("Players")
	local leaderPlayer = Players:GetPlayerByUserId(inv.fromUserId)
	if leaderPlayer then
		PartyService.OnInviteResponded:Fire(leaderPlayer, player.UserId, false)
	end
	return true, nil
end

function PartyService.AcceptInvite(player: any, partyId: string): (boolean, string?)
	if not isPlayerLike(player) then
		return false, "invalid player"
	end
	if not isPartyId(partyId) then
		return false, "no such invite"
	end
	cleanExpired(player.UserId)
	local pmap = peekPendingMap(player.UserId)
	local inv = pmap and pmap[partyId]
	if not pmap or not inv then
		return false, "no such invite or it expired"
	end
	if not parties[partyId] then
		pmap[partyId] = nil
		return false, "party no longer exists"
	end
	local joinOk, joinErr = PartyService.Join(player, partyId)
	if not joinOk then
		return false, joinErr or "join failed"
	end
	pmap[partyId] = nil
	local Players = game:GetService("Players")
	local leaderPlayer = Players:GetPlayerByUserId(inv.fromUserId)
	if leaderPlayer then
		PartyService.OnInviteResponded:Fire(leaderPlayer, player.UserId, true)
	end
	return true, nil
end

-- Drain cross-server invite queue at PlayerAdded for this player.
local function drainOnJoin(player: Player): ()
	local items = InviteQueue.DrainFor("party", player.UserId)
	local pmap = getPendingMap(player.UserId)
	local now = os.time()
	for _, item in ipairs(items) do
		if typeof(item) == "table" and typeof(item.partyId) == "string" then
			if (item.expiresAt or 0) > now then
				pmap[item.partyId] = item
				PartyService.OnInvite:Fire(player, item.partyId, item.fromName or "?")
			end
		end
	end
end

-- Runs in Init. The drain yields on MemoryStore, so each runs on its own thread.
local function hookPlayers(): ()
	local Players = game:GetService("Players")
	Players.PlayerAdded:Connect(function(player)
		task.spawn(drainOnJoin, player)
	end)
	-- Free per-player pending invite map when the target disconnects so long-
	-- running servers don't accumulate dead userIds (matches the cleanup pattern
	-- used by every other Lib service).
	Players.PlayerRemoving:Connect(function(player)
		pendingByUser[player.UserId] = nil
		remoteBuckets[player.UserId] = nil
		-- A player who left the game leaves their party (the leader passes on).
		PartyService.Leave(player)
	end)
	for _, p in ipairs(Players:GetPlayers()) do
		task.spawn(drainOnJoin, p)
	end
end

-- ── Network surface ──
-- Party mutations and reads use separate logical Net RPCs (Gaxia.Net.Client.Invoke).
-- The legacy Events/Party/InviteAction RemoteFunction deliberately has no
-- replacement handler; Events/Party/InviteInbound remains the outbound channel.
--
-- Two gates run before any party code: Net's own per-RPC rate / schema /
-- concurrency gates, then the per-player token bucket shared by every Party RPC
-- (Social.Party.RemoteRate per second, up to RemoteBurst at once). A refused
-- request is rejected by Net's `validate` step.
local function remoteAllowed(player: Player): boolean
	local rate = inviteCfg("RemoteRate", Config.Social.Party.RemoteRate, 4)
	local burst = inviteCfg("RemoteBurst", Config.Social.Party.RemoteBurst, 10)
	local now = os.clock()
	local b = remoteBuckets[player.UserId]
	if not b then
		b = { tokens = burst, last = now }
		remoteBuckets[player.UserId] = b
	end
	b.tokens = math.min(burst, b.tokens + (now - b.last) * rate)
	b.last = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end

local MAX_USER_ID = 9007199254740991 -- largest integer exactly representable by Luau numbers

type FieldValidators = { [string]: (any) -> boolean }

local function isFiniteInteger(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value % 1 == 0
end

-- Client payload checks: stricter than isUserId / isPartyId above (which game
-- code and Studio's negative test-player ids also go through).
local function isPayloadUserId(value: any): boolean
	return isFiniteInteger(value) and value > 0 and value <= MAX_USER_ID
end

local function isPayloadPartyId(value: any): boolean
	return isPartyId(value) and string.match(value, "^party_%d+$") ~= nil
end

local function exactSchema(fields: FieldValidators): (any) -> boolean
	return function(payload: any): boolean
		if typeof(payload) ~= "table" then
			return false
		end
		for key, value in pairs(payload) do
			if typeof(key) ~= "string" then
				return false
			end
			local validate = fields[key]
			if not validate or not validate(value) then
				return false
			end
		end
		for key in pairs(fields) do
			if payload[key] == nil then
				return false
			end
		end
		return true
	end
end

-- Same as exactSchema({}) (a table with no keys), written out so nothing runs at require time (R4).
local function EMPTY_SCHEMA(payload: any): boolean
	return typeof(payload) == "table" and next(payload) == nil
end

local function isCurrentPlayer(context: any, _payload: any): boolean
	local player = context.player
	return typeof(player) == "Instance"
		and player:IsA("Player")
		and player.Parent == game:GetService("Players")
end

local function readAllowed(context: any, _payload: any): boolean
	return remoteAllowed(context.player)
end

local function mutationAllowed(context: any, payload: any): boolean
	return isCurrentPlayer(context, payload) and remoteAllowed(context.player)
end

local function operationResult(ok: boolean, reason: string?): { ok: boolean, reason: string? }
	return { ok = ok, reason = reason }
end

local function registerRead(name: string, schema: (any) -> boolean, handler: (any, any) -> any): ()
	Net.Server.RegisterFunction(name, {
		schema = schema,
		handler = handler,
		validate = readAllowed,
		rate = 2,
		burst = 4,
		budget = "tiny",
		concurrency = 1,
	})
end

local function registerMutation(
	name: string,
	schema: (any) -> boolean,
	handler: (any, any) -> any,
	rate: number?,
	burst: number?
): ()
	Net.Server.RegisterFunction(name, {
		schema = schema,
		handler = handler,
		validate = mutationAllowed,
		mutation = true,
		rate = rate or 3,
		burst = burst or 4,
		budget = "tiny",
		concurrency = 1,
	})
end

-- ── Net RPCs + Events/Party/InviteInbound (created in Init) ──
local function createRemotes(): ()
	local Events = ReplicatedStorage:FindFirstChild("Events") or Instance.new("Folder")
	Events.Name = "Events"
	Events.Parent = ReplicatedStorage
	local PartyFolder = Events:FindFirstChild("Party") or Instance.new("Folder")
	PartyFolder.Name = "Party"
	PartyFolder.Parent = Events
	local Inbound = PartyFolder:FindFirstChild("InviteInbound") or Instance.new("RemoteEvent")
	Inbound.Name = "InviteInbound"
	Inbound.Parent = PartyFolder

	registerMutation(
		"Party.Invite",
		exactSchema({ targetUserId = isPayloadUserId }),
		function(context, payload)
			local ok, reason = PartyService.Invite(context.player, payload.targetUserId)
			return operationResult(ok, reason)
		end,
		0.5,
		2
	)
	registerMutation(
		"Party.AcceptInvite",
		exactSchema({ partyId = isPayloadPartyId }),
		function(context, payload)
			local ok, reason = PartyService.AcceptInvite(context.player, payload.partyId)
			return operationResult(ok, reason)
		end,
		nil,
		nil
	)
	registerMutation(
		"Party.DeclineInvite",
		exactSchema({ partyId = isPayloadPartyId }),
		function(context, payload)
			local ok, reason = PartyService.DeclineInvite(context.player, payload.partyId)
			return operationResult(ok, reason)
		end,
		nil,
		nil
	)
	registerMutation(
		"Party.CancelInvite",
		exactSchema({ targetUserId = isPayloadUserId }),
		function(context, payload)
			PartyService.CancelInvite(context.player, payload.targetUserId)
			return operationResult(true, nil)
		end,
		nil,
		nil
	)
	registerRead("Party.GetPendingInvites", EMPTY_SCHEMA, function(context, _payload)
		return PartyService.GetPendingInvites(context.player)
	end)

	PartyService.OnInvite:Connect(function(toPlayer, partyId, fromName)
		Inbound:FireClient(toPlayer, { type = "invite", partyId = partyId, fromName = fromName })
	end)
end

Lifecycle.Define(PartyService, {
	Name = "Party",
	-- Init's existing-player drain calls InviteQueue.DrainFor.
	Needs = { InviteQueue },
	Init = function()
		-- Same order as the old module body: player hooks + existing-player drain
		-- (each drain on its own thread — it yields on MemoryStore), then the
		-- Events/Party remotes and the OnInvite client forwarder.
		hookPlayers()
		createRemotes()
	end,
})

return PartyService
