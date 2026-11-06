--!strict
-- ─────────────────────────────────────────────────────────────
-- GuildService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/GuildService
-- Purpose : Persistent guilds (per-guild DataStore key "guild:<guildId>")
--           with three roles (Owner / Officer / Member). Every mutation
--           serialises across servers through the GuildLock MemoryStore
--           mutex; read paths hit DataStore directly. Membership is
--           denormalised onto profile.Social.GuildId via DataManager so a
--           player's current guild is one cheap profile lookup.
--           Every change refuses with "data not loaded" until the acting
--           player's profile has loaded (GaxiaServer.Data.IsLoaded).
--           GuildData.Members is keyed by number userId in memory and saved
--           with string keys (DataStores reject sparse number keys).
--
-- Access  : Gaxia.Guild  (server)
--   Guild.Create(leader, name, tag) -> (ok, guildIdOrErr)
--   Guild.Disband(player)
--   Guild.Leave(player)
--   Guild.Invite(officer, targetUserId)
--   Guild.AcceptInvite(player, guildId)
--   Guild.DeclineInvite(player, guildId)
--   Guild.GetPendingInvites(player) -> { { guildId, name, fromName } }
--   Guild.Kick(actor, targetUserId)
--   Guild.Promote(owner, userId)
--   Guild.Demote(owner, userId)
--   Guild.Transfer(owner, newOwnerUserId)
--   Guild.SetDescription(actor, text)
--   Guild.GetGuild(player) / Guild.GetById(guildId) / Guild.GetMembers(guildId)
--   Guild.IsMember(player, guildId?) / Guild.RoleOf(player)
--   -- Vault (Task 6 fills these in; currently stubbed):
--   Guild.VaultGetContents / VaultGetCapacity / VaultGetUsed
--   Guild.VaultDeposit / VaultWithdraw
--
-- Signals : OnCreate(guildId, ownerUserId)
--           OnDisband(guildId, byUserId)
--           OnMemberJoin(guildId, userId)
--           OnMemberLeave(guildId, userId, reason)
--           OnRoleChange(guildId, userId, newRole)
--           OnVaultChange(guildId, itemId, delta)
--           OnInvite(toPlayer, guildId, guildName, fromName)
-- ─────────────────────────────────────────────────────────────
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Signal               = require(ReplicatedStorage.Gaxia_Packages.Shared.Signal)
local Net                  = require(ReplicatedStorage.Gaxia_Packages.Shared.NetService)
local Lifecycle            = require(script.Parent.ServiceLifecycle)
local Config               = require(script.Parent.Parent.Config)
local EConfig              = require(script.Parent.EffectiveConfig)
local DataManager          = require(script.Parent.DataManager)
local GuildLock            = require(script.Parent.GuildLock)
local InviteQueue          = require(script.Parent.InviteQueue)
local FriendService        = require(script.Parent.FriendService)
local CrossServerMessaging = require(script.Parent.CrossServerMessaging)

-- ── Types ──
-- Player / actor parameters stay `any`: tests pass MockPlayers (see Invite and
-- Disband) — only .UserId and .Name are ever read.
export type GuildRole = "Owner" | "Officer" | "Member"
-- Why a member left (OnMemberLeave).
export type MemberLeaveReason = "kicked" | "left"
-- GuildData.Members[userId]
export type GuildMember = { name: string, role: GuildRole, joined: number }
-- The guild record (DataStore key "guild:<guildId>"; GetGuild / GetById).
export type GuildData = {
	Id: string,
	Name: string,
	Tag: string,
	CreatedAt: number,
	OwnerUserId: number,
	Members: { [number]: GuildMember },
	Description: string,
}
-- One row of GetMembers
export type GuildMemberEntry = { userId: number, name: string, role: GuildRole, joined: number }
-- A pending invite (in RAM, and the InviteQueue "guild" item).
export type GuildInvite = {
	kind: "guild",
	guildId: string,
	name: string,
	tag: string,
	fromUserId: number,
	fromName: string,
	at: number,
}
-- One row of GetPendingInvites
export type GuildPendingInvite = { guildId: string, name: string, fromName: string, expiresAt: number }

-- ── Config helpers (runtime Flag override <- Config.Social.Guild <- fallback) ──
local function gget(key: string, configured: number?, fallback: number): number
	return EConfig.Get(`Social.Guild.{key}`, configured or fallback)
end

local GUILD_STORE = "GaxiaGuilds"

-- Argument limits for ids that come from game code or the Guild remote.
local MAX_ID_LEN = 64     -- guildId (a GUID is 36)
local MAX_ITEM_ID_LEN = 100

local guildStore: any = nil
local function getGuildStore(): any
	if not guildStore then
		guildStore = DataStoreService:GetDataStore(Config.Admin.Stores.Guilds or GUILD_STORE)
	end
	return guildStore
end

-- GetAsync options that bypass the DataStore cache, for reads that authorize a
-- mutation (see loadGuildFresh). Made on first use.
local freshReadOptions: DataStoreGetOptions? = nil
local function getFreshReadOptions(): DataStoreGetOptions
	if freshReadOptions == nil then
		local options = Instance.new("DataStoreGetOptions")
		options.UseCache = false
		freshReadOptions = options
		return options
	end
	return freshReadOptions :: DataStoreGetOptions
end

-- Per-process cache of currently-loaded guilds for this server (read-mostly).
-- Invalidated implicitly through guildCache[gid] = nil on disband, and via
-- CrossServerMessaging "guild:vault" subscription in the vault block (Task 6).
local guildCache: { [string]: GuildData } = {}

-- Forward-declared here so Disband (above the vault block) can clear it
-- alongside guildCache. Populated/read by the vault helpers further down.
-- Invalidated on local write (saveVault refreshes), on save failure, on
-- disband, and via the CrossServerMessaging "guild:vault" subscription for
-- remote writes. Slight staleness is acceptable per spec.
local vaultCache: { [string]: { [string]: number } } = {}

-- ── Module + signals ──
local Guild = {}
-- (guildId, ownerUserId)
Guild.OnCreate = Signal.new() :: Signal.Signal<string, number>
-- (guildId, byUserId) — fired inside the guild lock, before Disband returns
Guild.OnDisband = Signal.new() :: Signal.Signal<string, number>
-- (guildId, userId)
Guild.OnMemberJoin = Signal.new() :: Signal.Signal<string, number>
-- (guildId, userId, reason)
Guild.OnMemberLeave = Signal.new() :: Signal.Signal<string, number, MemberLeaveReason>
-- (guildId, userId, newRole)
Guild.OnRoleChange = Signal.new() :: Signal.Signal<string, number, GuildRole>
-- (guildId, itemId, delta) — delta is negative on withdraw
Guild.OnVaultChange = Signal.new() :: Signal.Signal<string, string, number>
-- (toPlayer, guildId, guildName, fromName)
Guild.OnInvite = Signal.new() :: Signal.Signal<Player, string, string, string>

-- In-RAM pending guild invites per target UserId. Same shape as PartyService's
-- pendingByUser; cross-server entries land here when InviteQueue is drained at
-- PlayerAdded.
local guildInvites: { [number]: { [string]: GuildInvite } } = {}

-- Per-player token bucket of the Guild remote (see "Remote guard" below);
-- declared here so the PlayerRemoving hook can clear it.
type RemoteBucket = { tokens: number, last: number }
local remoteBuckets: { [number]: RemoteBucket } = {}

local membershipMutations: { [number]: boolean } = {}

-- Serialize same-player membership mutations in this server. GuildLock still
-- serializes the guild record across servers; this closes the local Create vs
-- AcceptInvite race where both operations could pass the profile check while
-- the other was yielding.
local function withMembershipMutation(player: any, fn: () -> (any, any)): (boolean, any)
	local userId = player and player.UserId
	if typeof(userId) ~= "number" then
		return false, "invalid player"
	end
	if membershipMutations[userId] then
		return false, "membership mutation in progress"
	end
	membershipMutations[userId] = true
	local ok, a, b = pcall(fn)
	membershipMutations[userId] = nil
	if not ok then
		return false, a
	end
	return a, b
end

-- ── Lock helper (every mutation goes through this) ──
-- Code inside `fn` fails with error(reason, 0): level 0 keeps the script position
-- out of the reason the caller returns ("guild full", not "GuildService:510: ...").
local function withGuildLock(guildId: string, fn: () -> any): (boolean, any)
	return GuildLock.WithLock(guildId, fn, gget("VaultLockTTLSec", Config.Social.Guild.VaultLockTTLSec, 5))
end

-- ── DataStore helpers ──
-- DataStores reject tables with sparse number keys (real UserIds), so Members
-- is saved with string keys and turned back into number keys on load. Number
-- keys in old data are accepted too.
local function decodeGuild(raw: any): GuildData?
	if typeof(raw) ~= "table" then
		return nil
	end
	local members: { [number]: GuildMember } = {}
	if typeof(raw.Members) == "table" then
		for k, rec in pairs(raw.Members) do
			local uid = tonumber(k)
			if uid and typeof(rec) == "table" then
				members[uid] = rec :: any
			end
		end
	end
	raw.Members = members
	return raw :: GuildData
end

local function encodeGuild(data: GuildData): { [string]: any }
	local members: { [string]: GuildMember } = {}
	for uid, rec in pairs(data.Members) do
		members[tostring(uid)] = rec
	end
	return {
		Id = data.Id,
		Name = data.Name,
		Tag = data.Tag,
		CreatedAt = data.CreatedAt,
		OwnerUserId = data.OwnerUserId,
		Members = members,
		Description = data.Description,
	}
end

local function loadGuild(guildId: string): GuildData?
	local cached = guildCache[guildId]
	if cached then
		return cached
	end
	local ok, raw = pcall(function()
		return getGuildStore():GetAsync("guild:" .. guildId)
	end)
	local data = if ok then decodeGuild(raw) else nil
	if not data then
		return nil
	end
	guildCache[guildId] = data
	return data
end

-- Mutations must never authorize from guildCache: a different server can have
-- changed roles or membership while this server was waiting for GuildLock.
-- Refresh after the lock is owned, then replace the local cache with that
-- exact snapshot before changing it.
local function loadGuildFresh(guildId: string): GuildData?
	local ok, raw = pcall(function()
		return getGuildStore():GetAsync("guild:" .. guildId, getFreshReadOptions())
	end)
	local data = if ok then decodeGuild(raw) else nil
	if not data then
		return nil
	end
	guildCache[guildId] = data
	return data
end

local function saveGuild(guildId: string, data: GuildData): boolean
	local stored = encodeGuild(data)
	local ok, err = pcall(function()
		getGuildStore():UpdateAsync("guild:" .. guildId, function(_existing)
			-- We hold the GuildLock; under normal conditions _existing matches the
			-- snapshot mutator was based on. Returning `data` unconditionally
			-- preserves the lock-as-primary-guard model; UpdateAsync vs SetAsync
			-- gives defense-in-depth: if the lock TTL expired and a different
			-- server's UpdateAsync interleaves, both writes go through the same
			-- atomic UpdateAsync path with last-writer-wins semantics on the
			-- per-key sequence number rather than blind clobber.
			return stored
		end, { data.OwnerUserId }) -- userIds for GDPR compliance
	end)
	if not ok then
		warn(`[Guild] save failed for {guildId}: {tostring(err)}`)
		-- Save failed; the in-memory mutation may have already touched the cached
		-- table by reference. Invalidate so the next read re-fetches truth from
		-- DataStore rather than serving the half-applied local mutation.
		guildCache[guildId] = nil
		return false
	end
	guildCache[guildId] = data
	return true
end

local function trimString(s: string, max: number): string
	s = tostring(s or "")
	s = (s:gsub("[\r\n%z]", ""))
	if #s > max then
		s = s:sub(1, max)
	end
	return s
end

-- ── Profile-side helpers (denormalise the player's current GuildId) ──
local function setPlayerGuildId(player: any, guildId: string?): ()
	local social = DataManager.Get(player, "Social")
	if typeof(social) ~= "table" then
		social = {}
	end
	social.GuildId = guildId
	DataManager.Set(player, "Social", social)
end

local function playerGuildId(player: any): string?
	local social = DataManager.Get(player, "Social")
	return (typeof(social) == "table") and social.GuildId or nil
end

-- ── Role rank table ──
local ROLE_RANK: { [string]: number } = { Member = 1, Officer = 2, Owner = 3 }
local function rankOf(role: string?): number
	return (role and ROLE_RANK[role]) or 0
end

-- The member record of `userId` in `guild`, or nil when there is none (or its
-- role is unknown).
local function memberRecord(guild: any, userId: number): GuildMember?
	if typeof(guild) ~= "table" or typeof(guild.Members) ~= "table" then
		return nil
	end
	local member = guild.Members[userId]
	if typeof(member) ~= "table" or rankOf(member.role) == 0 then
		return nil
	end
	return member
end

-- ── Argument checks (game code and the Guild remote share them) ──
-- A whole number (NaN, ±inf and fractions are not). UserIds and vault counts.
local function isWholeNumber(v: any): boolean
	return typeof(v) == "number" and v == v and v % 1 == 0 and math.abs(v) < 2 ^ 53
end
local isUserId = isWholeNumber

local function isId(v: any, maxLen: number): boolean
	return typeof(v) == "string" and #v > 0 and #v <= maxLen
end

-- nil when `player` may change guild state; else why not. Every change reads or
-- writes the profile's GuildId, so it waits for the player's data to load.
local function actorProblem(player: any, invalid: string): string?
	local kind = typeof(player)
	if kind ~= "table" and kind ~= "Instance" then
		return invalid
	end
	if not isUserId(player.UserId) then
		return invalid
	end
	if not DataManager.IsLoaded(player) then
		return "data not loaded"
	end
	return nil
end

-- ── Public: Create ──
-- Creates a guild with `leader` as Owner. Returns (true, guildId) or (false, why):
-- "invalid leader", "data not loaded", "already in a guild", "bad name",
-- "name too short", "tag too short", "lock busy", "save failed".
function Guild.Create(leader: any, name: string, tag: string): (boolean, string)
	local problem = actorProblem(leader, "invalid leader")
	if problem then
		return false, problem
	end
	if typeof(name) ~= "string" or typeof(tag) ~= "string" then
		return false, "bad name"
	end
	if playerGuildId(leader) then
		return false, "already in a guild"
	end
	name = trimString(name, gget("MaxNameLen", Config.Social.Guild.MaxNameLen, 24))
	tag = trimString(tag, gget("MaxTagLen", Config.Social.Guild.MaxTagLen, 4))
	if #name < 2 then
		return false, "name too short"
	end
	if #tag < 2 then
		return false, "tag too short"
	end

	local guildId = HttpService:GenerateGUID(false)
	local data: GuildData = {
		Id = guildId,
		Name = name,
		Tag = tag,
		CreatedAt = os.time(),
		OwnerUserId = leader.UserId,
		Members = {
			[leader.UserId] = { name = leader.Name, role = "Owner", joined = os.time() },
		},
		Description = "",
	}
	local ok, err = withMembershipMutation(leader, function()
		return withGuildLock(guildId, function()
			-- The profile may have changed while waiting for the lock. Creating a
			-- second guild for the same actor would break the GuildId invariant.
			if playerGuildId(leader) then
				error("already in a guild", 0)
			end
			if not saveGuild(guildId, data) then
				error("save failed", 0)
			end
			return true
		end)
	end)
	if not ok then
		return false, tostring(err)
	end
	setPlayerGuildId(leader, guildId)
	Guild.OnCreate:Fire(guildId, leader.UserId)
	return true, guildId
end

-- ── Public: lookups ──
function Guild.GetGuild(player: any): GuildData?
	local gid = playerGuildId(player)
	if not gid then
		return nil
	end
	return loadGuild(gid)
end

function Guild.GetById(guildId: string): GuildData?
	return loadGuild(guildId)
end

function Guild.GetMembers(guildId: string): { GuildMemberEntry }
	local g = loadGuild(guildId)
	if not g then
		return {}
	end
	local out: { GuildMemberEntry } = {}
	for uid, rec in pairs(g.Members) do
		table.insert(out, { userId = uid, name = rec.name, role = rec.role, joined = rec.joined })
	end
	return out
end

function Guild.IsMember(player: any, guildId: string?): boolean
	local gid = playerGuildId(player)
	if not gid then
		return false
	end
	if guildId and gid ~= guildId then
		return false
	end
	local g = loadGuild(gid)
	return (g and g.Members[player.UserId] ~= nil) or false
end

function Guild.RoleOf(player: any): GuildRole?
	local gid = playerGuildId(player)
	if not gid then
		return nil
	end
	local g = loadGuild(gid)
	if not g then
		return nil
	end
	local rec = g.Members[player.UserId]
	return rec and rec.role or nil
end

-- ── Public: Invite / Accept / Decline ──
-- Officer or Owner invites `targetUserId`. (false, why) on "invalid actor",
-- "data not loaded", "invalid target", "officer required", "guild full", ...
function Guild.Invite(officer: any, targetUserId: number): (boolean, string?)
	local problem = actorProblem(officer, "invalid actor")
	if problem then
		return false, problem
	end
	if not isUserId(targetUserId) then
		return false, "invalid target"
	end
	if officer.UserId == targetUserId then
		return false, "cannot invite self"
	end
	local gid = playerGuildId(officer)
	if not gid then
		return false, "not in a guild"
	end

	-- Block check (best-effort: only a blocker in this server is known).
	if FriendService.IsBlockedByUserId(targetUserId, officer.UserId) then
		return false, "could not invite"
	end

	-- An invite changes pending-invite state. Check the actor's role and the
	-- target's membership against a DataStore snapshot read *after* the guild
	-- lock is owned, rather than trusting an earlier cached read.
	local fresh: GuildInvite? = nil
	local ok, err = withGuildLock(gid, function()
		if playerGuildId(officer) ~= gid then
			error("not in a guild", 0)
		end
		local g = loadGuildFresh(gid)
		if not g then
			error("guild not loaded", 0)
		end
		local actor = memberRecord(g, officer.UserId)
		if not actor or rankOf(actor.role) < ROLE_RANK.Officer then
			error("officer required", 0)
		end
		if memberRecord(g, targetUserId) then
			error("already a member", 0)
		end
		local memberCount = 0
		for _ in pairs(g.Members) do
			memberCount += 1
		end
		if memberCount >= gget("MaxMembers", Config.Social.Guild.MaxMembers, 50) then
			error("guild full", 0)
		end
		fresh = {
			kind = "guild",
			guildId = gid,
			name = g.Name,
			tag = g.Tag,
			fromUserId = officer.UserId,
			fromName = officer.Name,
			at = os.time(),
		}
		return true
	end)
	if not ok or not fresh then
		return false, tostring(err)
	end
	local item: GuildInvite = fresh

	-- Deliver invite. Same-server: direct on the in-RAM pending set + OnInvite
	-- signal. Cross-server: durable InviteQueue entry, drained at PlayerAdded.
	local Players = game:GetService("Players")
	local target = Players:GetPlayerByUserId(targetUserId)
	if target then
		guildInvites[target.UserId] = guildInvites[target.UserId] or {}
		guildInvites[target.UserId][gid] = item
		Guild.OnInvite:Fire(target, gid, item.name, officer.Name)
	else
		-- For MockPlayer / cross-server: ALSO write into the in-RAM map so the
		-- same-server test flow (AcceptInvite immediately after Invite) works
		-- without a Player instance. Real cross-server flow still relies on the
		-- InviteQueue drain at PlayerAdded.
		guildInvites[targetUserId] = guildInvites[targetUserId] or {}
		guildInvites[targetUserId][gid] = item
		InviteQueue.Push(
			"guild",
			targetUserId,
			item,
			gget("InviteQueueTTLDays", Config.Social.Guild.InviteQueueTTLDays, 7) * 86400
		)
	end
	return true, nil
end

function Guild.GetPendingInvites(player: any): { GuildPendingInvite }
	if not player or typeof(player.UserId) ~= "number" then
		return {}
	end
	local out: { GuildPendingInvite } = {}
	local ttl = gget("InviteQueueTTLDays", Config.Social.Guild.InviteQueueTTLDays, 7) * 86400
	for _, inv in pairs(guildInvites[player.UserId] or {}) do
		table.insert(out, {
			guildId = inv.guildId,
			name = inv.name,
			fromName = inv.fromName,
			expiresAt = (inv.at or os.time()) + ttl,
		})
	end
	return out
end

-- Joins `guildId` from a pending invite. (false, why) on "invalid player",
-- "data not loaded", "no such invite", "already in a guild", "guild full", ...
function Guild.AcceptInvite(player: any, guildId: string): (boolean, string?)
	local problem = actorProblem(player, "invalid player")
	if problem then
		return false, problem
	end
	if not isId(guildId, MAX_ID_LEN) then
		return false, "no such invite"
	end
	local invs = guildInvites[player.UserId] or {}
	if not invs[guildId] then
		return false, "no such invite"
	end
	if playerGuildId(player) then
		return false, "already in a guild"
	end
	local ok, err = withMembershipMutation(player, function()
		return withGuildLock(guildId, function()
			-- Both the invite and the player's membership can have changed while
			-- Acquire waited. Check them again before adding a member.
			if not (guildInvites[player.UserId] or {})[guildId] then
				error("no such invite", 0)
			end
			if playerGuildId(player) then
				error("already in a guild", 0)
			end
			local g = loadGuildFresh(guildId)
			if not g then
				error("guild gone", 0)
			end
			if memberRecord(g, player.UserId) then
				error("already in a guild", 0)
			end
			local count = 0
			for _ in pairs(g.Members) do
				count += 1
			end
			if count >= gget("MaxMembers", Config.Social.Guild.MaxMembers, 50) then
				error("guild full", 0)
			end
			g.Members[player.UserId] = { name = player.Name, role = "Member", joined = os.time() }
			if not saveGuild(guildId, g) then
				error("save failed", 0)
			end
			return true
		end)
	end)
	if not ok then
		return false, tostring(err)
	end
	invs[guildId] = nil
	setPlayerGuildId(player, guildId)
	Guild.OnMemberJoin:Fire(guildId, player.UserId)
	return true, nil
end

function Guild.DeclineInvite(player: any, guildId: string): (boolean, string?)
	if not player or not isUserId(player.UserId) then
		return false, "invalid player"
	end
	if not isId(guildId, MAX_ID_LEN) then
		return false, "no such invite"
	end
	local invs = guildInvites[player.UserId] or {}
	if not invs[guildId] then
		return false, "no such invite"
	end
	-- This only removes the caller's in-memory invite and does not yield or
	-- change shared guild state, so there is no post-lock authorization window.
	invs[guildId] = nil
	return true, nil
end

-- ── mutateGuild: shared wrapper for every role/membership write ──
-- Acquires the lock, refreshes the guild directly from DataStore, runs the
-- mutator, saves, then releases. The mutator returns (true) or
-- (false, errString) — false aborts the save AND propagates the error string
-- out as the second return value.
--
-- Side-effects (signals, setPlayerGuildId) MUST be deferred via the `post`
-- callback so they only fire if the save actually succeeds; otherwise observers
-- see state that the DataStore disagrees with.
type PostCommit = () -> ()
local function mutateGuild(
	actor: any,
	mutator: (g: GuildData, post: (PostCommit) -> ()) -> (boolean, string?)
): (boolean, string?)
	local gid = playerGuildId(actor)
	if not gid then
		return false, "not in a guild"
	end
	local postCommits: { PostCommit } = {}
	local function schedule(cb: PostCommit)
		table.insert(postCommits, cb)
	end

	local ok, err = withGuildLock(gid, function()
		if playerGuildId(actor) ~= gid then
			error("not in a guild", 0)
		end
		local g = loadGuildFresh(gid)
		if not g then
			error("guild gone", 0)
		end
		local mOk, mErr = mutator(g, schedule)
		if not mOk then
			error(mErr or "mutate failed", 0)
		end
		if not saveGuild(gid, g) then
			error("save failed", 0)
		end
		return true
	end)
	if not ok then
		return false, tostring(err)
	end
	-- Save succeeded; fire post-commit side-effects.
	for _, cb in ipairs(postCommits) do
		local cbOk, cbErr = pcall(cb)
		if not cbOk then
			warn(`[Guild] post-commit callback failed: {tostring(cbErr)}`)
		end
	end
	return true, nil
end

-- ── Public: Kick / Promote / Demote / Transfer / Leave / Disband ──
function Guild.Kick(actor: any, targetUserId: number): (boolean, string?)
	local problem = actorProblem(actor, "invalid actor")
	if problem then
		return false, problem
	end
	if not isUserId(targetUserId) then
		return false, "invalid target"
	end
	local actorRole = Guild.RoleOf(actor)
	if rankOf(actorRole) < ROLE_RANK.Officer then
		return false, "officer required"
	end
	if actor.UserId == targetUserId then
		return false, "use Leave to remove yourself"
	end
	return mutateGuild(actor, function(g, post)
		local freshActor = memberRecord(g, actor.UserId)
		if not freshActor or rankOf(freshActor.role) < ROLE_RANK.Officer then
			return false, "officer required"
		end
		local victim = memberRecord(g, targetUserId)
		if not victim then
			return false, "not a member"
		end
		if rankOf(victim.role) >= rankOf(freshActor.role) then
			return false, "cannot kick equal or higher rank"
		end
		g.Members[targetUserId] = nil
		post(function()
			Guild.OnMemberLeave:Fire(g.Id, targetUserId, "kicked")
			local Players = game:GetService("Players")
			local p = Players:GetPlayerByUserId(targetUserId)
			if p then
				setPlayerGuildId(p, nil)
			end
		end)
		return true
	end)
end

function Guild.Promote(owner: any, userId: number): (boolean, string?)
	local problem = actorProblem(owner, "invalid actor")
	if problem then
		return false, problem
	end
	if not isUserId(userId) then
		return false, "invalid target"
	end
	if Guild.RoleOf(owner) ~= "Owner" then
		return false, "owner only"
	end
	return mutateGuild(owner, function(g, post)
		local freshOwner = memberRecord(g, owner.UserId)
		if not freshOwner or freshOwner.role ~= "Owner" then
			return false, "owner only"
		end
		local rec = memberRecord(g, userId)
		if not rec then
			return false, "not a member"
		end
		if rec.role ~= "Member" then
			return false, "must promote a Member"
		end
		local officerCount = 0
		for _, m in pairs(g.Members) do
			if m.role == "Officer" then
				officerCount += 1
			end
		end
		if officerCount >= gget("OfficerCap", Config.Social.Guild.OfficerCap, 5) then
			return false, "officer cap reached"
		end
		rec.role = "Officer"
		post(function()
			Guild.OnRoleChange:Fire(g.Id, userId, "Officer")
		end)
		return true
	end)
end

function Guild.Demote(owner: any, userId: number): (boolean, string?)
	local problem = actorProblem(owner, "invalid actor")
	if problem then
		return false, problem
	end
	if not isUserId(userId) then
		return false, "invalid target"
	end
	if Guild.RoleOf(owner) ~= "Owner" then
		return false, "owner only"
	end
	return mutateGuild(owner, function(g, post)
		local freshOwner = memberRecord(g, owner.UserId)
		if not freshOwner or freshOwner.role ~= "Owner" then
			return false, "owner only"
		end
		local rec = memberRecord(g, userId)
		if not rec then
			return false, "not a member"
		end
		if rec.role ~= "Officer" then
			return false, "must demote an Officer"
		end
		rec.role = "Member"
		post(function()
			Guild.OnRoleChange:Fire(g.Id, userId, "Member")
		end)
		return true
	end)
end

function Guild.Transfer(owner: any, newOwnerUserId: number): (boolean, string?)
	local problem = actorProblem(owner, "invalid actor")
	if problem then
		return false, problem
	end
	if not isUserId(newOwnerUserId) then
		return false, "invalid target"
	end
	if Guild.RoleOf(owner) ~= "Owner" then
		return false, "owner only"
	end
	return mutateGuild(owner, function(g, post)
		local freshOwner = memberRecord(g, owner.UserId)
		if not freshOwner or freshOwner.role ~= "Owner" then
			return false, "owner only"
		end
		if not memberRecord(g, newOwnerUserId) then
			return false, "target not a member"
		end
		g.Members[owner.UserId].role = "Officer"
		g.Members[newOwnerUserId].role = "Owner"
		g.OwnerUserId = newOwnerUserId
		post(function()
			Guild.OnRoleChange:Fire(g.Id, owner.UserId, "Officer")
			Guild.OnRoleChange:Fire(g.Id, newOwnerUserId, "Owner")
		end)
		return true
	end)
end

function Guild.Leave(player: any): (boolean, string?)
	local problem = actorProblem(player, "invalid player")
	if problem then
		return false, problem
	end
	local role = Guild.RoleOf(player)
	if not role then
		return false, "not in a guild"
	end
	if role == "Owner" then
		return false, "owner must transfer or disband first"
	end
	return mutateGuild(player, function(g, post)
		local freshMember = memberRecord(g, player.UserId)
		if not freshMember then
			return false, "not in a guild"
		end
		if freshMember.role == "Owner" then
			return false, "owner must transfer or disband first"
		end
		g.Members[player.UserId] = nil
		post(function()
			Guild.OnMemberLeave:Fire(g.Id, player.UserId, "left")
			setPlayerGuildId(player, nil)
		end)
		return true
	end)
end

function Guild.Disband(player: any): (boolean, string?)
	local problem = actorProblem(player, "invalid player")
	if problem then
		return false, problem
	end
	if Guild.RoleOf(player) ~= "Owner" then
		return false, "owner only"
	end
	local gid = playerGuildId(player)
	if not gid then
		return false, "not in a guild"
	end
	local ok, err = withGuildLock(gid, function()
		if playerGuildId(player) ~= gid then
			error("not in a guild", 0)
		end
		local g = loadGuildFresh(gid)
		if not g then
			error("guild gone", 0)
		end
		local freshOwner = memberRecord(g, player.UserId)
		if not freshOwner or freshOwner.role ~= "Owner" then
			error("owner only", 0)
		end
		local memberIds = {}
		for uid in pairs(g.Members) do
			table.insert(memberIds, uid)
		end
		-- Clear all online members' GuildId; offline get cleaned by reconcileOnJoin.
		local Players = game:GetService("Players")
		for _, uid in ipairs(memberIds) do
			local p = Players:GetPlayerByUserId(uid)
			if p then
				setPlayerGuildId(p, nil)
			end
		end
		-- The actor themselves may be a MockPlayer / not in Players service —
		-- explicitly clear them so the post-Disband IsMember check sees no guild.
		setPlayerGuildId(player, nil)
		-- Remove from DataStore.
		local okR, errR = pcall(function()
			getGuildStore():RemoveAsync("guild:" .. gid)
		end)
		if not okR then
			error(tostring(errR), 0)
		end
		guildCache[gid] = nil
		vaultCache[gid] = nil
		Guild.OnDisband:Fire(gid, player.UserId)
		return true
	end)
	if ok then
		return true, nil
	end
	return false, tostring(err)
end

function Guild.SetDescription(actor: any, text: string): (boolean, string?)
	local problem = actorProblem(actor, "invalid actor")
	if problem then
		return false, problem
	end
	if typeof(text) ~= "string" then
		return false, "bad text"
	end
	if rankOf(Guild.RoleOf(actor)) < ROLE_RANK.Officer then
		return false, "officer required"
	end
	local trimmed = trimString(text, gget("MaxDescLen", Config.Social.Guild.MaxDescLen, 280))
	return mutateGuild(actor, function(g, _post)
		local freshActor = memberRecord(g, actor.UserId)
		if not freshActor or rankOf(freshActor.role) < ROLE_RANK.Officer then
			return false, "officer required"
		end
		g.Description = trimmed
		return true
	end)
end

-- ── Reconcile orphan GuildId at PlayerAdded ──
-- If a player's profile says they're in a guild but the guild no longer exists,
-- clear it. Avoids zombie membership after a disband on another server.
local function reconcileOnJoin(player: Player): ()
	-- Runs from PlayerAdded, before the profile has loaded: wait for it, or the
	-- GuildId reads as nil and an orphan is never cleared.
	if DataManager.WaitFor(player, 60) == nil then
		return
	end
	local gid = playerGuildId(player)
	if not gid then
		return
	end
	-- Only clear the orphan GuildId on CONFIRMED absence — never on a transient
	-- DataStore hiccup. Doing the pcall here (instead of relying on loadGuild
	-- which collapses both states to nil) lets us distinguish.
	local ok, data = pcall(function()
		return getGuildStore():GetAsync("guild:" .. gid)
	end)
	if not ok then
		warn(
			`[Guild] reconcileOnJoin DataStore probe failed for {gid}; leaving GuildId in place: {tostring(data)}`
		)
		return
	end
	if data == nil then
		-- Only clear the GuildId this check was about (the player may have
		-- left meanwhile, or the field may have changed during the yield).
		if player.Parent ~= nil and playerGuildId(player) == gid then
			setPlayerGuildId(player, nil)
		end
	else
		-- Hydrate cache as a side benefit.
		local decoded = decodeGuild(data)
		if decoded then
			guildCache[gid] = decoded
		end
	end
end

-- ── Drain cross-server invite queue at PlayerAdded ──
local function drainInvitesOnJoin(player: Player): ()
	local items = InviteQueue.DrainFor("guild", player.UserId)
	local pmap = guildInvites[player.UserId] or {}
	guildInvites[player.UserId] = pmap
	for _, item in ipairs(items) do
		if typeof(item) == "table" and typeof(item.guildId) == "string" then
			pmap[item.guildId] = item
			Guild.OnInvite:Fire(player, item.guildId, item.name or "?", item.fromName or "?")
		end
	end
end

-- Runs in Init. Reconcile and drain yield (DataStore / MemoryStore), so each
-- runs on its own thread.
local function hookPlayers(): ()
	local Players = game:GetService("Players")
	Players.PlayerAdded:Connect(function(p)
		task.spawn(reconcileOnJoin, p)
		task.spawn(drainInvitesOnJoin, p)
	end)
	Players.PlayerRemoving:Connect(function(p)
		guildInvites[p.UserId] = nil
		remoteBuckets[p.UserId] = nil
	end)
	for _, p in ipairs(Players:GetPlayers()) do
		task.spawn(reconcileOnJoin, p)
		task.spawn(drainInvitesOnJoin, p)
	end
end

-- ── Vault ──
-- Per spec §5.4: getters do NOT acquire the lock (cache or DataStore read).
-- Only Deposit / Withdraw acquire withGuildLock. saveVault uses UpdateAsync
-- (not SetAsync) for the same defense-in-depth reason as saveGuild (see commit
-- 7cb2c48): GuildLock is the primary guard, UpdateAsync is the fallback if the
-- lock TTL ever expires mid-write.
local VAULT_STORE = "GaxiaGuildVaults"
local vaultStore: any = nil
local function getVaultStore(): any
	if not vaultStore then
		vaultStore = DataStoreService:GetDataStore(Config.Admin.Stores.GuildVaults or VAULT_STORE)
	end
	return vaultStore
end

-- vaultCache is forward-declared above (next to guildCache) so Disband can
-- clear it without a forward reference; see comment there.

local function loadVault(guildId: string): { [string]: number }
	if vaultCache[guildId] then
		return vaultCache[guildId]
	end
	local ok, data = pcall(function()
		return getVaultStore():GetAsync("vault:" .. guildId)
	end)
	local v: { [string]: number } = (ok and typeof(data) == "table") and data or {}
	vaultCache[guildId] = v
	return v
end

-- Like loadVault, but read past the DataStore cache (for writes under the lock).
-- nil when the read failed; an empty vault when there is none yet.
local function loadVaultFresh(guildId: string): { [string]: number }?
	local ok, data = pcall(function()
		return getVaultStore():GetAsync("vault:" .. guildId, getFreshReadOptions())
	end)
	if not ok then
		return nil
	end
	if data == nil then
		local empty: { [string]: number } = {}
		vaultCache[guildId] = empty
		return empty
	end
	if typeof(data) ~= "table" then
		return nil
	end
	local v = data :: { [string]: number }
	vaultCache[guildId] = v
	return v
end

local function saveVault(guildId: string, vault: { [string]: number }): boolean
	local ok, err = pcall(function()
		getVaultStore():UpdateAsync("vault:" .. guildId, function(_old)
			return vault
		end, { 0 })
	end)
	if not ok then
		warn(`[Guild] vault save failed for {guildId}: {tostring(err)}`)
		-- Save failed; the in-memory mutation may have already touched the cached
		-- table by reference. Invalidate so the next read re-fetches truth from
		-- DataStore rather than serving the half-applied local mutation.
		vaultCache[guildId] = nil
		return false
	end
	vaultCache[guildId] = vault
	return true
end

local function vaultUsed(vault: { [string]: number }): number
	local n = 0
	for _, c in pairs(vault) do
		n += c
	end
	return n
end

function Guild.VaultGetContents(player: any): { [string]: number }
	local gid = playerGuildId(player)
	if not gid then
		return {}
	end
	local v = loadVault(gid)
	local out: { [string]: number } = {}
	for k, c in pairs(v) do
		out[k] = c
	end
	return out
end

function Guild.VaultGetUsed(player: any): number
	local gid = playerGuildId(player)
	if not gid then
		return 0
	end
	return vaultUsed(loadVault(gid))
end

function Guild.VaultGetCapacity(_player: any): number
	return gget("VaultCapacity", Config.Social.Guild.VaultCapacity, 500)
end

function Guild.VaultDeposit(player: any, itemId: string, count: number?): (boolean, string?)
	local problem = actorProblem(player, "invalid player")
	if problem then
		return false, problem
	end
	local gid = playerGuildId(player)
	if not gid then
		return false, "not in a guild"
	end
	-- All members (Owner/Officer/Member) may deposit. Just verify role exists.
	if not Guild.RoleOf(player) then
		return false, "not a member"
	end
	local n: number = if count == nil then 1 else count
	-- A whole number, 1 or more: NaN, ±inf and fractions are refused.
	if not isWholeNumber(n) or n < 1 then
		return false, "bad count"
	end
	if not isId(itemId, MAX_ITEM_ID_LEN) then
		return false, "bad itemId"
	end

	local ok, err = withGuildLock(gid, function()
		if playerGuildId(player) ~= gid then
			error("not in a guild", 0)
		end
		local g = loadGuildFresh(gid)
		if not g then
			error("guild gone", 0)
		end
		if not memberRecord(g, player.UserId) then
			error("not a member", 0)
		end
		local v = loadVaultFresh(gid)
		if not v then
			error("vault unavailable", 0)
		end
		local cap = gget("VaultCapacity", Config.Social.Guild.VaultCapacity, 500)
		if vaultUsed(v) + n > cap then
			error("vault full", 0)
		end
		v[itemId] = (v[itemId] or 0) + n
		if not saveVault(gid, v) then
			error("save failed", 0)
		end
		return true
	end)
	if not ok then
		return false, tostring(err)
	end
	Guild.OnVaultChange:Fire(gid, itemId, n)
	-- Best-effort cross-server broadcast. pcall-guarded so test envs without
	-- MessagingService never break a successful vault write.
	pcall(function()
		CrossServerMessaging.Publish("guild:vault", { guildId = gid, itemId = itemId, delta = n })
	end)
	return true, nil
end

function Guild.VaultWithdraw(player: any, itemId: string, count: number?): (boolean, string?)
	local problem = actorProblem(player, "invalid player")
	if problem then
		return false, problem
	end
	local gid = playerGuildId(player)
	if not gid then
		return false, "not in a guild"
	end
	-- Per spec §5.2: only Officer or higher may withdraw.
	if rankOf(Guild.RoleOf(player)) < ROLE_RANK.Officer then
		return false, "officer required to withdraw"
	end
	local n: number = if count == nil then 1 else count
	-- A whole number, 1 or more: NaN, ±inf and fractions are refused.
	if not isWholeNumber(n) or n < 1 then
		return false, "bad count"
	end
	if not isId(itemId, MAX_ITEM_ID_LEN) then
		return false, "bad itemId"
	end

	local ok, err = withGuildLock(gid, function()
		if playerGuildId(player) ~= gid then
			error("not in a guild", 0)
		end
		local g = loadGuildFresh(gid)
		if not g then
			error("guild gone", 0)
		end
		local member = memberRecord(g, player.UserId)
		if not member or rankOf(member.role) < ROLE_RANK.Officer then
			error("officer required to withdraw", 0)
		end
		local v = loadVaultFresh(gid)
		if not v then
			error("vault unavailable", 0)
		end
		local have = v[itemId] or 0
		if have < n then
			error("not enough", 0)
		end
		v[itemId] = have - n
		if (v[itemId] or 0) <= 0 then
			v[itemId] = nil
		end
		if not saveVault(gid, v) then
			error("save failed", 0)
		end
		return true
	end)
	if not ok then
		return false, tostring(err)
	end
	Guild.OnVaultChange:Fire(gid, itemId, -n)
	pcall(function()
		CrossServerMessaging.Publish("guild:vault", { guildId = gid, itemId = itemId, delta = -n })
	end)
	return true, nil
end

-- Subscribe to cross-server vault changes → invalidate cache so the next local
-- read re-fetches from DataStore. Runs in Start (SubscribeAsync yields).
local function subscribeVault(): ()
	pcall(function()
		CrossServerMessaging.Subscribe("guild:vault", function(msg)
			if typeof(msg) == "table" and typeof(msg.guildId) == "string" then
				vaultCache[msg.guildId] = nil
			end
		end)
	end)
end

-- ── Net gateway + outbound notification surface ──
-- Each client operation gets its own logical RPC (Gaxia.Net.Client.Invoke)
-- rather than a broad action envelope; the legacy Events/Guild/Action
-- RemoteFunction is not created or handled. The gateway owns the RemoteFunction,
-- transport, size budget, rate/concurrency gates, and replay handling; this
-- module owns only domain schema and state/role validation. Inbound data is
-- never coerced with tostring: a malformed request stops before a Guild API can
-- observe it.
--
-- On top of Net's per-RPC gates, every Guild RPC first spends a token from the
-- per-player bucket shared by all of them (Social.Guild.RemoteRate per second,
-- up to RemoteBurst at once); a refused request is rejected by Net's `validate`
-- step before any DataStore read.
local function remoteAllowed(player: Player): boolean
	local rate = gget("RemoteRate", Config.Social.Guild.RemoteRate, 4)
	local burst = gget("RemoteBurst", Config.Social.Guild.RemoteBurst, 10)
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

type RpcReply = { ok: boolean, data: any }
type RpcValidate = (context: any, payload: any) -> boolean

local MAX_USER_ID = 9_007_199_254_740_991
local MAX_CONFIGURED_TEXT_LENGTH = 2_048

local function reply(ok: boolean, data: any): RpcReply
	return { ok = ok, data = data }
end

local function isPositiveFiniteInteger(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value % 1 == 0
		and value > 0
end

local function configuredPositiveInteger(key: string, configured: number?, fallback: number, ceiling: number): number
	local value = gget(key, configured, fallback)
	if not isPositiveFiniteInteger(value) then
		return fallback
	end
	return math.min(value, ceiling)
end

local function hasOnlyKeys(payload: any, allowed: { [string]: boolean }): boolean
	if typeof(payload) ~= "table" then
		return false
	end
	for key in pairs(payload) do
		if typeof(key) ~= "string" or allowed[key] ~= true then
			return false
		end
	end
	return true
end

local function isEmptyPayload(payload: any): boolean
	return hasOnlyKeys(payload, {})
end

local function isSafeText(value: any, minimum: number, maximum: number): boolean
	return typeof(value) == "string"
		and #value >= minimum
		and #value <= maximum
		and string.find(value, "[\r\n%z]") == nil
end

-- A userId sent by a client: a positive whole number (stricter than isUserId,
-- which game code and Studio's negative test-player ids also go through).
local function isPayloadUserId(value: any): boolean
	return isPositiveFiniteInteger(value) and value <= MAX_USER_ID
end

local function guildIdSchema(payload: any): boolean
	return hasOnlyKeys(payload, { guildId = true })
		and isSafeText(payload.guildId, 1, MAX_ID_LEN)
end

local function targetSchema(payload: any): boolean
	return hasOnlyKeys(payload, { target = true }) and isPayloadUserId(payload.target)
end

local function isLivePlayer(player: Player): boolean
	return player.Parent == game:GetService("Players")
end

local function freshMembership(player: Player): (GuildData?, boolean)
	if not isLivePlayer(player) then
		return nil, true
	end
	local gid = playerGuildId(player)
	if not gid then
		return nil, true
	end
	local ok, raw = pcall(function()
		return getGuildStore():GetAsync("guild:" .. gid, getFreshReadOptions())
	end)
	if not ok then
		return nil, false
	end
	-- The DataStore read yielded. A membership mutation may have completed
	-- while it was in flight; never reconcile against a stale GuildId.
	if not isLivePlayer(player) or playerGuildId(player) ~= gid then
		return nil, false
	end
	local guild = decodeGuild(raw)
	if not guild then
		setPlayerGuildId(player, nil)
		return nil, true
	end
	guildCache[gid] = guild
	if memberRecord(guild, player.UserId) == nil then
		-- A cross-server kick/revocation is authoritative. Reconcile only after
		-- a successful fresh read; never clear on DataStore failure.
		setPlayerGuildId(player, nil)
		return nil, true
	end
	return guild, true
end

local function currentGuild(player: Player): GuildData?
	local guild = freshMembership(player)
	return guild
end

local function roleInCurrentGuild(player: Player, minimum: number): GuildData?
	local guild = currentGuild(player)
	if not guild then
		return nil
	end
	local member = guild.Members[player.UserId]
	if typeof(member) ~= "table" or rankOf(member.role) < minimum then
		return nil
	end
	return guild
end

local function validateCreate(context: any, _payload: any): boolean
	return isLivePlayer(context.player) and Guild.GetGuild(context.player) == nil
end

local function validateOfficer(context: any, _payload: any): boolean
	return roleInCurrentGuild(context.player, ROLE_RANK.Officer) ~= nil
end

local function validateOwner(context: any, _payload: any): boolean
	return roleInCurrentGuild(context.player, ROLE_RANK.Owner) ~= nil
end

local function validateLeave(context: any, _payload: any): boolean
	local guild = currentGuild(context.player)
	return guild ~= nil and guild.Members[context.player.UserId].role ~= "Owner"
end

local function validateInvite(context: any, payload: any): boolean
	local guild = roleInCurrentGuild(context.player, ROLE_RANK.Officer)
	return guild ~= nil
		and payload.target ~= context.player.UserId
		and guild.Members[payload.target] == nil
end

local function validatePendingInvite(context: any, payload: any): boolean
	return isLivePlayer(context.player)
		and Guild.GetGuild(context.player) == nil
		and (guildInvites[context.player.UserId] or {})[payload.guildId] ~= nil
end

local function validateDecline(context: any, payload: any): boolean
	return isLivePlayer(context.player)
		and (guildInvites[context.player.UserId] or {})[payload.guildId] ~= nil
end

local function validateKick(context: any, payload: any): boolean
	local guild = roleInCurrentGuild(context.player, ROLE_RANK.Officer)
	if not guild or payload.target == context.player.UserId then
		return false
	end
	local actor = guild.Members[context.player.UserId]
	local target = guild.Members[payload.target]
	return typeof(target) == "table" and rankOf(target.role) < rankOf(actor.role)
end

local function validatePromote(context: any, payload: any): boolean
	local guild = roleInCurrentGuild(context.player, ROLE_RANK.Owner)
	local target = guild and guild.Members[payload.target]
	return typeof(target) == "table" and target.role == "Member"
end

local function validateDemote(context: any, payload: any): boolean
	local guild = roleInCurrentGuild(context.player, ROLE_RANK.Owner)
	local target = guild and guild.Members[payload.target]
	return typeof(target) == "table" and target.role == "Officer"
end

local function validateTransfer(context: any, payload: any): boolean
	local guild = roleInCurrentGuild(context.player, ROLE_RANK.Owner)
	return guild ~= nil and guild.Members[payload.target] ~= nil
end

local function validateCurrentGuild(context: any, _payload: any): boolean
	return isLivePlayer(context.player) and currentGuild(context.player) ~= nil
end

-- The shared per-player bucket first (cheap, no yield), then the RPC's own check.
local function budgeted(validate: RpcValidate): RpcValidate
	return function(context: any, payload: any): boolean
		return remoteAllowed(context.player) and validate(context, payload)
	end
end

local function registerRead(
	name: string,
	schema: (payload: any) -> boolean,
	handler: (player: Player, payload: any) -> (boolean, any),
	validate: RpcValidate?
): ()
	Net.Server.RegisterFunction(name, {
		schema = schema,
		validate = budgeted(validate or function(context: any, _payload: any): boolean
			return isLivePlayer(context.player)
		end),
		handler = function(context: any, payload: any): RpcReply
			local ok, data = handler(context.player, payload)
			return reply(ok, data)
		end,
		rate = 4,
		burst = 8,
		budget = "tiny",
		concurrency = 2,
	})
end

local function registerMutation(
	name: string,
	schema: (payload: any) -> boolean,
	validate: RpcValidate,
	handler: (player: Player, payload: any) -> (boolean, any)
): ()
	Net.Server.RegisterFunction(name, {
		schema = schema,
		validate = budgeted(validate),
		mutation = true,
		handler = function(context: any, payload: any): RpcReply
			local ok, data = handler(context.player, payload)
			return reply(ok, data)
		end,
		rate = 2,
		burst = 4,
		budget = "small",
		concurrency = 1,
	})
end

-- Runs in Init (createRemotes).
local function registerRpcs(): ()
	registerRead("Guild.Get", isEmptyPayload, function(player: Player, _payload: any): (boolean, any)
		local guild = currentGuild(player)
		return true, guild
	end, validateCurrentGuild)

	registerRead("Guild.Members", isEmptyPayload, function(player: Player, _payload: any): (boolean, any)
		local guild = currentGuild(player)
		return true, if guild then Guild.GetMembers(guild.Id) else {}
	end, validateCurrentGuild)

	registerRead("Guild.PendingInvites", isEmptyPayload, function(player: Player, _payload: any): (boolean, any)
		return true, Guild.GetPendingInvites(player)
	end)

	registerRead("Guild.VaultContents", isEmptyPayload, function(player: Player, _payload: any): (boolean, any)
		return true, Guild.VaultGetContents(player)
	end, validateCurrentGuild)

	registerMutation("Guild.Create", function(payload: any): boolean
		return hasOnlyKeys(payload, { name = true, tag = true })
			and isSafeText(
				payload.name,
				2,
				configuredPositiveInteger("MaxNameLen", Config.Social.Guild.MaxNameLen, 24, MAX_CONFIGURED_TEXT_LENGTH)
			)
			and isSafeText(
				payload.tag,
				2,
				configuredPositiveInteger("MaxTagLen", Config.Social.Guild.MaxTagLen, 4, MAX_CONFIGURED_TEXT_LENGTH)
			)
	end, validateCreate, function(player: Player, payload: any): (boolean, any)
		return Guild.Create(player, payload.name, payload.tag)
	end)

	registerMutation("Guild.Disband", isEmptyPayload, validateOwner, function(player: Player, _payload: any): (boolean, any)
		return Guild.Disband(player)
	end)

	registerMutation("Guild.Leave", isEmptyPayload, validateLeave, function(player: Player, _payload: any): (boolean, any)
		return Guild.Leave(player)
	end)

	registerMutation("Guild.Invite", targetSchema, validateInvite, function(player: Player, payload: any): (boolean, any)
		return Guild.Invite(player, payload.target)
	end)

	registerMutation("Guild.AcceptInvite", guildIdSchema, validatePendingInvite, function(player: Player, payload: any): (boolean, any)
		return Guild.AcceptInvite(player, payload.guildId)
	end)

	registerMutation("Guild.DeclineInvite", guildIdSchema, validateDecline, function(player: Player, payload: any): (boolean, any)
		return Guild.DeclineInvite(player, payload.guildId)
	end)

	registerMutation("Guild.Kick", targetSchema, validateKick, function(player: Player, payload: any): (boolean, any)
		return Guild.Kick(player, payload.target)
	end)

	registerMutation("Guild.Promote", targetSchema, validatePromote, function(player: Player, payload: any): (boolean, any)
		return Guild.Promote(player, payload.target)
	end)

	registerMutation("Guild.Demote", targetSchema, validateDemote, function(player: Player, payload: any): (boolean, any)
		return Guild.Demote(player, payload.target)
	end)

	registerMutation("Guild.Transfer", targetSchema, validateTransfer, function(player: Player, payload: any): (boolean, any)
		return Guild.Transfer(player, payload.target)
	end)

	registerMutation("Guild.SetDescription", function(payload: any): boolean
		return hasOnlyKeys(payload, { text = true })
			and isSafeText(
				payload.text,
				0,
				configuredPositiveInteger("MaxDescLen", Config.Social.Guild.MaxDescLen, 280, MAX_CONFIGURED_TEXT_LENGTH)
			)
	end, validateOfficer, function(player: Player, payload: any): (boolean, any)
		return Guild.SetDescription(player, payload.text)
	end)

	-- VaultDeposit/VaultWithdraw intentionally have no client RPC registration yet.
	-- The package has no authoritative inventory transfer adapter, so exposing these
	-- ledger-only mutations would let a client mint or remove vault contents without
	-- changing player inventory. Keep the server API available for a future
	-- inventory-backed transaction, but fail closed at the transport boundary.
end

-- ── Net RPCs + Events/Guild/Inbound (created in Init) ──
-- Events/Guild/Inbound stays only for server-to-client invite/membership notices.
local function createRemotes(): ()
	registerRpcs()

	local Events = ReplicatedStorage:FindFirstChild("Events") or Instance.new("Folder")
	Events.Name = "Events"
	Events.Parent = ReplicatedStorage
	local GuildFolder = Events:FindFirstChild("Guild") or Instance.new("Folder")
	GuildFolder.Name = "Guild"
	GuildFolder.Parent = Events
	local Inbound = GuildFolder:FindFirstChild("Inbound") or Instance.new("RemoteEvent")
	Inbound.Name = "Inbound"
	Inbound.Parent = GuildFolder

	Guild.OnInvite:Connect(function(toPlayer, guildId, name, fromName)
		Inbound:FireClient(
			toPlayer,
			{ type = "invite", guildId = guildId, name = name, fromName = fromName }
		)
	end)
	Guild.OnMemberJoin:Connect(function(guildId, userId)
		-- Notify everyone in the guild who is on this server.
		local Players = game:GetService("Players")
		local g = loadGuild(guildId)
		if not g then
			return
		end
		for memberId in pairs(g.Members) do
			local p = Players:GetPlayerByUserId(memberId)
			if p then
				Inbound:FireClient(p, { type = "member_join", userId = userId })
			end
		end
	end)
	Guild.OnMemberLeave:Connect(function(guildId, userId, reason)
		local Players = game:GetService("Players")
		local g = loadGuild(guildId)
		if not g then
			return
		end
		for memberId in pairs(g.Members) do
			local p = Players:GetPlayerByUserId(memberId)
			if p then
				Inbound:FireClient(p, { type = "member_leave", userId = userId, reason = reason })
			end
		end
	end)
end

Lifecycle.Define(Guild, {
	Name = "Guild",
	-- DataManager: Init's existing-player reconcile reads the profile GuildId.
	-- InviteQueue: Init's existing-player drain calls DrainFor.
	-- CrossServerMessaging: Start subscribes "guild:vault" into it.
	Needs = { DataManager, InviteQueue, CrossServerMessaging },
	Init = function()
		-- Same order as the old module body: player hooks + existing-player
		-- reconcile/drain, then the Events/Guild remotes and client forwarders.
		hookPlayers()
		createRemotes()
	end,
	Start = subscribeVault,
})

return Guild
