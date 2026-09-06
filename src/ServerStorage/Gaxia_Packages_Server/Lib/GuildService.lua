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
local CollectionService = game:GetService("CollectionService")

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal = SharedPkg.Signal
local Net = SharedPkg.Net

-- ── Lazy server (Config + EConfig + sibling services) ──
local GaxiaServer: any = nil
local function server(): any
	if not GaxiaServer then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server")

		GaxiaServer = require(serverInit :: any)
	end
	return GaxiaServer
end

-- ── Config helpers ──
local function gcfg(): any
	return ((server().Config or {}).Social or {}).Guild or {}
end
local function gget(key: string, fallback: any): any
	return server().EConfig.Get(`Social.Guild.{key}`, gcfg()[key] or fallback)
end
local function storeName(key: string, fallback: string): string
	local admin = (server().Config or {}).Admin
	local stores = admin and admin.Stores
	if typeof(stores) == "table" and stores[key] then
		return stores[key]
	end
	return fallback
end

local GUILD_STORE = "GaxiaGuilds"

local guildStore: any = nil
local freshGuildReadOptions = Instance.new("DataStoreGetOptions") :: DataStoreGetOptions
freshGuildReadOptions.UseCache = false

local function getGuildStore(): any
	if not guildStore then
		guildStore = DataStoreService:GetDataStore(storeName("Guilds", GUILD_STORE))
	end
	return guildStore
end

-- Per-process cache of currently-loaded guilds for this server (read-mostly).
-- Invalidated implicitly through guildCache[gid] = nil on disband, and via
-- CrossServerMessaging "guild:vault" subscription in the vault block (Task 6).
local guildCache: { [string]: any } = {}

-- Forward-declared here so Disband (above the vault block) can clear it
-- alongside guildCache. Populated/read by the vault helpers further down.
-- Invalidated on local write (saveVault refreshes), on save failure, on
-- disband, and via the CrossServerMessaging "guild:vault" subscription for
-- remote writes. Slight staleness is acceptable per spec.
local vaultCache: { [string]: { [string]: number } } = {}

-- ── Module + signals ──
local Guild = {}
Guild.OnCreate = Signal.new() -- (guildId, ownerUserId)
Guild.OnDisband = Signal.new() -- (guildId, byUserId)
Guild.OnMemberJoin = Signal.new() -- (guildId, userId)
Guild.OnMemberLeave = Signal.new() -- (guildId, userId, reason)
Guild.OnRoleChange = Signal.new() -- (guildId, userId, newRole)
Guild.OnVaultChange = Signal.new() -- (guildId, itemId, delta)
Guild.OnInvite = Signal.new() -- (toPlayer, guildId, guildName, fromName)

-- In-RAM pending guild invites per target UserId. Same shape as PartyService's
-- pendingByUser; cross-server entries land here when InviteQueue is drained at
-- PlayerAdded.
local guildInvites: { [number]: { [string]: any } } = {}
local membershipMutations: { [number]: boolean } = {}

-- Serialize same-player membership mutations in this server. GuildLock still
-- serializes the guild record across servers; this closes the local Create vs
-- AcceptInvite race where both operations could pass the profile check while
-- the other was yielding.
local function withMembershipMutation(player: any, fn: () -> any): (boolean, any)
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
local function withGuildLock(guildId: string, fn: () -> any): (boolean, any)
	local GuildLock = server().GuildLock
	if not GuildLock then
		return false, "GuildLock not available"
	end
	return GuildLock.WithLock(guildId, fn, gget("VaultLockTTLSec", 5))
end

-- ── DataStore helpers ──
local function loadGuild(guildId: string): any?
	local cached = guildCache[guildId]
	if cached then
		return cached
	end
	local ok, data = pcall(function()
		return getGuildStore():GetAsync("guild:" .. guildId)
	end)
	if not ok or typeof(data) ~= "table" then
		return nil
	end
	guildCache[guildId] = data
	return data
end

-- Mutations must never authorize from guildCache: a different server can have
-- changed roles or membership while this server was waiting for GuildLock.
-- Refresh after the lock is owned, then replace the local cache with that
-- exact snapshot before changing it.
local function loadGuildFresh(guildId: string): any?
	local ok, data = pcall(function()
		return getGuildStore():GetAsync("guild:" .. guildId, freshGuildReadOptions)
	end)
	if not ok or typeof(data) ~= "table" then
		return nil
	end
	guildCache[guildId] = data
	return data
end

local function saveGuild(guildId: string, data: any): boolean
	local ok, err = pcall(function()
		getGuildStore():UpdateAsync("guild:" .. guildId, function(_existing)
			-- We hold the GuildLock; under normal conditions _existing matches the
			-- snapshot mutator was based on. Returning `data` unconditionally
			-- preserves the lock-as-primary-guard model; UpdateAsync vs SetAsync
			-- gives defense-in-depth: if the lock TTL expired and a different
			-- server's UpdateAsync interleaves, both writes go through the same
			-- atomic UpdateAsync path with last-writer-wins semantics on the
			-- per-key sequence number rather than blind clobber.
			return data
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
	local Data = server().Data
	local social = Data.Get(player, "Social")
	if typeof(social) ~= "table" then
		social = {}
	end
	social.GuildId = guildId
	Data.Set(player, "Social", social)
end

local function playerGuildId(player: any): string?
	local Data = server().Data
	local social = Data.Get(player, "Social")
	return (typeof(social) == "table") and social.GuildId or nil
end

-- ── Role rank table ──
local ROLE_RANK: { [string]: number } = { Member = 1, Officer = 2, Owner = 3 }
local function rankOf(role: string?): number
	return (role and ROLE_RANK[role]) or 0
end

local function memberRecord(guild: any, userId: number): any?
	if typeof(guild) ~= "table" or typeof(guild.Members) ~= "table" then
		return nil
	end
	local member = guild.Members[userId]
	if typeof(member) ~= "table" or rankOf(member.role) == 0 then
		return nil
	end
	return member
end

-- ── Public: Create ──
function Guild.Create(leader: any, name: string, tag: string): (boolean, string)
	if not leader or typeof(leader.UserId) ~= "number" then
		return false, "invalid leader"
	end
	if playerGuildId(leader) then
		return false, "already in a guild"
	end
	name = trimString(name, gget("MaxNameLen", 24))
	tag = trimString(tag, gget("MaxTagLen", 4))
	if #name < 2 then
		return false, "name too short"
	end
	if #tag < 2 then
		return false, "tag too short"
	end

	local guildId = HttpService:GenerateGUID(false)
	local data = {
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
				error("save failed")
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
function Guild.GetGuild(player: any): any?
	local gid = playerGuildId(player)
	if not gid then
		return nil
	end
	return loadGuild(gid)
end

function Guild.GetById(guildId: string): any?
	return loadGuild(guildId)
end

function Guild.GetMembers(guildId: string): { any }
	local g = loadGuild(guildId)
	if not g then
		return {}
	end
	local out = {}
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

function Guild.RoleOf(player: any): string?
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
function Guild.Invite(officer: any, targetUserId: number): (boolean, string?)
	if not officer or typeof(officer.UserId) ~= "number" then
		return false, "invalid actor"
	end
	if officer.UserId == targetUserId then
		return false, "cannot invite self"
	end
	local gid = playerGuildId(officer)
	if not gid then
		return false, "not in a guild"
	end

	-- Block check (best-effort; if Friend not loaded, skip).
	local s = server()
	if
		s.Friend
		and s.Friend.IsBlockedByUserId
		and s.Friend.IsBlockedByUserId(targetUserId, officer.UserId)
	then
		return false, "could not invite"
	end

	-- An invite changes pending-invite state. Re-check the actor's role and the
	-- target's membership from a DataStore snapshot obtained *after* the guild
	-- lock, rather than trusting an earlier cached read.
	local item: any = nil
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
		if memberCount >= gget("MaxMembers", 50) then
			error("guild full", 0)
		end
		item = {
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
	if not ok then
		return false, tostring(err)
	end

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
		local InviteQueue = s.InviteQueue
		if InviteQueue then
			InviteQueue.Push("guild", targetUserId, item, gget("InviteQueueTTLDays", 7) * 86400)
		end
	end
	return true, nil
end

function Guild.GetPendingInvites(player: any): { any }
	if not player or typeof(player.UserId) ~= "number" then
		return {}
	end
	local out = {}
	local ttl = gget("InviteQueueTTLDays", 7) * 86400
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

function Guild.AcceptInvite(player: any, guildId: string): (boolean, string?)
	if not player or typeof(player.UserId) ~= "number" then
		return false, "invalid player"
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
			if count >= gget("MaxMembers", 50) then
				error("guild full")
			end
			g.Members[player.UserId] = { name = player.Name, role = "Member", joined = os.time() }
			if not saveGuild(guildId, g) then
				error("save failed")
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
	if not player or typeof(player.UserId) ~= "number" then
		return false, "invalid player"
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
	mutator: (g: any, post: (PostCommit) -> ()) -> (boolean, string?)
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
	if not actor or typeof(actor.UserId) ~= "number" then
		return false, "invalid actor"
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
		if officerCount >= gget("OfficerCap", 5) then
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
			error(tostring(errR))
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
	if rankOf(Guild.RoleOf(actor)) < ROLE_RANK.Officer then
		return false, "officer required"
	end
	local trimmed = trimString(text, gget("MaxDescLen", 280))
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
			`[Guild] reconcileOnJoin DataStore probe failed for {gid}; leaving GuildId in place: {tostring(
				data
			)}`
		)
		return
	end
	if data == nil then
		setPlayerGuildId(player, nil)
	else
		-- Hydrate cache as a side benefit.
		guildCache[gid] = data
	end
end

-- ── Drain cross-server invite queue at PlayerAdded ──
local function drainInvitesOnJoin(player: Player): ()
	local s = server()
	local InviteQueue = s and s.InviteQueue
	if not InviteQueue then
		return
	end
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

do
	local Players = game:GetService("Players")
	Players.PlayerAdded:Connect(function(p)
		task.spawn(reconcileOnJoin, p)
		task.spawn(drainInvitesOnJoin, p)
	end)
	Players.PlayerRemoving:Connect(function(p)
		guildInvites[p.UserId] = nil
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
		vaultStore = DataStoreService:GetDataStore(storeName("GuildVaults", VAULT_STORE))
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

local function loadVaultFresh(guildId: string): { [string]: number }?
	local ok, data = pcall(function()
		return getVaultStore():GetAsync("vault:" .. guildId, freshGuildReadOptions)
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
	return gget("VaultCapacity", 500)
end

function Guild.VaultDeposit(player: any, itemId: string, count: number?): (boolean, string?)
	if not player or typeof(player.UserId) ~= "number" then
		return false, "invalid player"
	end
	local gid = playerGuildId(player)
	if not gid then
		return false, "not in a guild"
	end
	-- All members (Owner/Officer/Member) may deposit. Just verify role exists.
	if not Guild.RoleOf(player) then
		return false, "not a member"
	end
	local n: number = count or 1
	if typeof(n) ~= "number" or n < 1 then
		return false, "bad count"
	end
	if typeof(itemId) ~= "string" or #itemId == 0 then
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
		local cap = gget("VaultCapacity", 500)
		if vaultUsed(v) + n > cap then
			error("vault full")
		end
		v[itemId] = (v[itemId] or 0) + n
		if not saveVault(gid, v) then
			error("save failed")
		end
		return true
	end)
	if not ok then
		return false, tostring(err)
	end
	Guild.OnVaultChange:Fire(gid, itemId, n)
	-- Best-effort cross-server broadcast (no-op if CrossServerMessaging absent
	-- or not yet wired into the loader). pcall-guarded so test envs without
	-- MessagingService never break a successful vault write.
	local s = server()
	if s.Messages and s.Messages.Publish then
		pcall(function()
			s.Messages.Publish("guild:vault", { guildId = gid, itemId = itemId, delta = n })
		end)
	end
	return true, nil
end

function Guild.VaultWithdraw(player: any, itemId: string, count: number?): (boolean, string?)
	if not player or typeof(player.UserId) ~= "number" then
		return false, "invalid player"
	end
	local gid = playerGuildId(player)
	if not gid then
		return false, "not in a guild"
	end
	-- Per spec §5.2: only Officer or higher may withdraw.
	if rankOf(Guild.RoleOf(player)) < ROLE_RANK.Officer then
		return false, "officer required to withdraw"
	end
	local n: number = count or 1
	if typeof(n) ~= "number" or n < 1 then
		return false, "bad count"
	end
	if typeof(itemId) ~= "string" or #itemId == 0 then
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
			error("not enough")
		end
		v[itemId] = have - n
		if (v[itemId] or 0) <= 0 then
			v[itemId] = nil
		end
		if not saveVault(gid, v) then
			error("save failed")
		end
		return true
	end)
	if not ok then
		return false, tostring(err)
	end
	Guild.OnVaultChange:Fire(gid, itemId, -n)
	local s = server()
	if s.Messages and s.Messages.Publish then
		pcall(function()
			s.Messages.Publish("guild:vault", { guildId = gid, itemId = itemId, delta = -n })
		end)
	end
	return true, nil
end

-- Subscribe to cross-server vault changes → invalidate cache so the next local
-- read re-fetches from DataStore. Deferred via task.spawn because this module
-- is itself being required THROUGH the loader's __index metamethod — calling
-- server() (which re-requires the loader) synchronously here would yield across
-- the metamethod/C-call boundary. task.spawn defers to a fresh coroutine that
-- runs AFTER the loader's metamethod returns, so the re-require is safe.
task.spawn(function()
	local s = server()
	if s.Messages and s.Messages.Subscribe then
		pcall(function()
			s.Messages.Subscribe("guild:vault", function(msg)
				if typeof(msg) == "table" and typeof(msg.guildId) == "string" then
					vaultCache[msg.guildId] = nil
				end
			end)
		end)
	end
end)

-- ── Net gateway + outbound notification surface ──
-- Each client operation gets its own logical RPC rather than a broad action
-- envelope. The gateway owns the RemoteFunction, transport, size budget,
-- rate/concurrency gates, and replay handling; this module owns only domain
-- schema and state/role validation. Inbound data is never coerced with
-- tostring: a malformed request stops before a Guild API can observe it.
type RpcReply = { ok: boolean, data: any }

local MAX_USER_ID = 9_007_199_254_740_991
local MAX_GUILD_ID_LENGTH = 64
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

local function configuredPositiveInteger(key: string, fallback: number, ceiling: number): number
	local value = gget(key, fallback)
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

local function isUserId(value: any): boolean
	return isPositiveFiniteInteger(value) and value <= MAX_USER_ID
end

local function guildIdSchema(payload: any): boolean
	return hasOnlyKeys(payload, { guildId = true })
		and isSafeText(payload.guildId, 1, MAX_GUILD_ID_LENGTH)
end

local function targetSchema(payload: any): boolean
	return hasOnlyKeys(payload, { target = true }) and isUserId(payload.target)
end

local function isLivePlayer(player: Player): boolean
	return player.Parent == game:GetService("Players")
end

local function freshMembership(player: Player): (any?, boolean)
	if not isLivePlayer(player) then
		return nil, true
	end
	local gid = playerGuildId(player)
	if not gid then
		return nil, true
	end
	local ok, guild = pcall(function()
		return getGuildStore():GetAsync("guild:" .. gid, freshGuildReadOptions)
	end)
	if not ok then
		return nil, false
	end
	-- The DataStore read yielded. A membership mutation may have completed
	-- while it was in flight; never reconcile against a stale GuildId.
	if not isLivePlayer(player) or playerGuildId(player) ~= gid then
		return nil, false
	end
	if typeof(guild) ~= "table" or typeof(guild.Members) ~= "table" then
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

local function currentGuild(player: Player): any?
	local guild = freshMembership(player)
	return guild
end

local function roleInCurrentGuild(player: Player, minimum: number): any?
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

local function registerRead(
	name: string,
	schema: (payload: any) -> boolean,
	handler: (player: Player, payload: any) -> (boolean, any),
	validate: ((context: any, payload: any) -> boolean)?
): ()
	Net.Server.RegisterFunction(name, {
		schema = schema,
		validate = validate or function(context: any, _payload: any): boolean
			return isLivePlayer(context.player)
		end,
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
	validate: (context: any, payload: any) -> boolean,
	handler: (player: Player, payload: any) -> (boolean, any)
): ()
	Net.Server.RegisterFunction(name, {
		schema = schema,
		validate = validate,
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

local function validateCurrentGuild(context: any, _payload: any): boolean
	return isLivePlayer(context.player) and currentGuild(context.player) ~= nil
end

registerRead("Guild.Get", isEmptyPayload, function(player: Player, _payload: any): (boolean, any)
	local guild = currentGuild(player)
	return true, guild
end, validateCurrentGuild)

registerRead(
	"Guild.Members",
	isEmptyPayload,
	function(player: Player, _payload: any): (boolean, any)
		local guild = currentGuild(player)
		return true, if guild then Guild.GetMembers(guild.Id) else {}
	end,
	validateCurrentGuild
)

registerRead(
	"Guild.PendingInvites",
	isEmptyPayload,
	function(player: Player, _payload: any): (boolean, any)
		return true, Guild.GetPendingInvites(player)
	end
)

registerRead(
	"Guild.VaultContents",
	isEmptyPayload,
	function(player: Player, _payload: any): (boolean, any)
		return true, Guild.VaultGetContents(player)
	end,
	validateCurrentGuild
)

registerMutation(
	"Guild.Create",
	function(payload: any): boolean
		return hasOnlyKeys(payload, { name = true, tag = true })
			and isSafeText(
				payload.name,
				2,
				configuredPositiveInteger("MaxNameLen", 24, MAX_CONFIGURED_TEXT_LENGTH)
			)
			and isSafeText(
				payload.tag,
				2,
				configuredPositiveInteger("MaxTagLen", 4, MAX_CONFIGURED_TEXT_LENGTH)
			)
	end,
	validateCreate,
	function(player: Player, payload: any): (boolean, any)
		return Guild.Create(player, payload.name, payload.tag)
	end
)

registerMutation(
	"Guild.Disband",
	isEmptyPayload,
	validateOwner,
	function(player: Player, _payload: any): (boolean, any)
		return Guild.Disband(player)
	end
)

registerMutation(
	"Guild.Leave",
	isEmptyPayload,
	validateLeave,
	function(player: Player, _payload: any): (boolean, any)
		return Guild.Leave(player)
	end
)

registerMutation(
	"Guild.Invite",
	targetSchema,
	validateInvite,
	function(player: Player, payload: any): (boolean, any)
		return Guild.Invite(player, payload.target)
	end
)

registerMutation(
	"Guild.AcceptInvite",
	guildIdSchema,
	validatePendingInvite,
	function(player: Player, payload: any): (boolean, any)
		return Guild.AcceptInvite(player, payload.guildId)
	end
)

registerMutation("Guild.DeclineInvite", guildIdSchema, function(context: any, payload: any): boolean
	return isLivePlayer(context.player)
		and (guildInvites[context.player.UserId] or {})[payload.guildId] ~= nil
end, function(player: Player, payload: any): (boolean, any)
	return Guild.DeclineInvite(player, payload.guildId)
end)

registerMutation(
	"Guild.Kick",
	targetSchema,
	validateKick,
	function(player: Player, payload: any): (boolean, any)
		return Guild.Kick(player, payload.target)
	end
)

registerMutation(
	"Guild.Promote",
	targetSchema,
	validatePromote,
	function(player: Player, payload: any): (boolean, any)
		return Guild.Promote(player, payload.target)
	end
)

registerMutation(
	"Guild.Demote",
	targetSchema,
	validateDemote,
	function(player: Player, payload: any): (boolean, any)
		return Guild.Demote(player, payload.target)
	end
)

registerMutation(
	"Guild.Transfer",
	targetSchema,
	validateTransfer,
	function(player: Player, payload: any): (boolean, any)
		return Guild.Transfer(player, payload.target)
	end
)

registerMutation(
	"Guild.SetDescription",
	function(payload: any): boolean
		return hasOnlyKeys(payload, { text = true })
			and isSafeText(
				payload.text,
				0,
				configuredPositiveInteger("MaxDescLen", 280, MAX_CONFIGURED_TEXT_LENGTH)
			)
	end,
	validateOfficer,
	function(player: Player, payload: any): (boolean, any)
		return Guild.SetDescription(player, payload.text)
	end
)

-- VaultDeposit/VaultWithdraw intentionally have no client RPC registration yet.
-- The package has no authoritative inventory transfer adapter, so exposing these
-- ledger-only mutations would let a client mint or remove vault contents without
-- changing player inventory. Keep the server API available for a future
-- inventory-backed transaction, but fail closed at the transport boundary.

do
	-- Keep legacy Inbound only for server-to-client invite/membership notices.
	-- No raw Guild Action RemoteFunction is created or handled here.
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

return Guild
