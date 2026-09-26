--!strict
-- ─────────────────────────────────────────────────────────────
-- BanService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/BanService
-- Purpose : Persistent bans + an auto-escalation policy. AntiCheat only Kicked
--           (in-memory, cleared on leave) so cheaters rejoined instantly. This
--           persists bans (DataStore, pcall-guarded + session cache so Studio
--           works without API), gates them on PlayerAdded, and escalates repeat
--           hard AntiCheat actions: warn/kick → temp-ban → perm-ban (thresholds
--           in Config.AntiCheat.BanPolicy). Exempt from ALL auto-action: the
--           place creator + roles >= BanPolicy.ExemptRole (escalation only
--           warns; stale creator bans self-heal at the join gate). The role
--           lookup is installed by AdminCommands (SetRoleResolver); without it
--           only the place creator is exempt.
--
-- Access  : Gaxia.Ban  (server)
--   Gaxia.Ban.Ban(userId, "Exploiting", 3600)   -- 1h temp ban (nil = permanent)
--   local banned, reason = Gaxia.Ban.IsBanned(userId)
--
-- Lifecycle: Init connects the PlayerAdded ban gate (before players are
--            admitted) + the leave cleanup; Start subscribes to AntiCheat.OnAction.
-- ─────────────────────────────────────────────────────────────
local Players           = game:GetService("Players")
local DataStoreService  = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Shared    = ReplicatedStorage.Gaxia_Packages.Shared
local Signal    = require(Shared.Signal)
local Lifecycle = require(script.Parent.ServiceLifecycle)
local Config    = require(script.Parent.Parent.Config)
local Types     = require(script.Parent.Parent.Types)
-- The orchestrator (not a Need: Start only subscribes to its OnAction signal,
-- which never starts AntiCheat).
local AntiCheat = require(script.Parent.Parent.AntiCheat)

-- Store name comes from Config so operators can namespace bans per-game
-- (Config.Admin.Stores.Bans, "override to namespace bans/roles per game").
-- Read once, in Init: the store name is fixed for the server lifetime and is a
-- server-private secret, never a runtime Flag. Falls back to the historic default.
local BAN_STORE : string = "GaxiaBans"

export type Ban = {
	reason: string,
	expiresAt: number?,  -- os.time(); nil = permanent
	time: number,
}

-- One row of ListBans (the Admin Panel's /unban list).
export type BanListEntry = {
	userId: number,
	reason: string,
	expiresAt: number?,  -- os.time(); nil = permanent
	time: number,
}

local BanService = {}

-- (userId, ban) after a ban is applied (persisted or session-only)
BanService.OnBan = Signal.new() :: Signal.Signal<number, Ban>
-- (userId) after a ban record is cleared (manual unban, expiry, creator self-heal)
BanService.OnUnban = Signal.new() :: Signal.Signal<number>

-- Session cache: Ban record, or false = explicitly not banned (so we don't re-hit
-- the DataStore every check). Lets Studio (no real DataStore) work in-memory.
local cache: { [number]: Ban | false } = {}

local _store: any = nil
local function store(): any
	if _store == nil then
		local ok, s = pcall(function()
			return DataStoreService:GetDataStore(BAN_STORE)
		end)
		_store = (ok and s) or false
	end
	return _store or nil
end

local function isExpired(ban: Ban): boolean
	return ban.expiresAt ~= nil and os.time() >= ban.expiresAt
end

local function loadBan(userId: number): Ban?
	local c = cache[userId]
	if c ~= nil then
		return if c == false then nil else c :: Ban
	end
	local s = store()
	if not s then
		cache[userId] = false
		return nil
	end
	local ok, data = pcall(function()
		return s:GetAsync(tostring(userId))
	end)
	if ok and typeof(data) == "table" then
		cache[userId] = data :: Ban
		return data :: Ban
	end
	if ok then
		-- Successful read with no record: genuinely not banned.
		cache[userId] = false
		return nil
	end
	-- GetAsync ERROR: do NOT negative-cache — a transient outage during a banned
	-- player's join would otherwise disable enforcement for them on this server
	-- for its whole lifetime. Fail open this once and re-read on the next check.
	warn(`[BanService] GetAsync failed for {userId} — ban state unknown this check`)
	return nil
end

-- ── Public API ──

function BanService.IsBanned(userId: number): (boolean, string?, number?)
	local ban = loadBan(userId)
	if not ban then
		return false
	end
	if isExpired(ban) then
		BanService.Unban(userId)
		return false
	end
	return true, ban.reason, ban.expiresAt
end

-- Returns whether the ban was PERSISTED. The session ban (cache + kick) always
-- happens; a false return means the DataStore write failed (or no store — e.g.
-- Studio without API access) and the ban will not survive this server. Callers
-- presenting "persistent ban" feedback to a human must surface that.
function BanService.Ban(userId: number, reason: string, durationSec: number?): boolean
	local ban: Ban = {
		reason = reason or "Banned",
		expiresAt = if durationSec then os.time() + durationSec else nil,
		time = os.time(),
	}
	cache[userId] = ban
	local persisted = false
	local s = store()
	if s then
		local ok, err = pcall(function()
			s:SetAsync(tostring(userId), ban)
		end)
		persisted = ok
		if not ok then
			warn(`[BanService] failed to persist ban for {userId}: {tostring(err)}`)
		end
	end
	BanService.OnBan:Fire(userId, ban)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		player:Kick(`[Banned] {ban.reason}`)
	end
	return persisted
end

-- Returns whether the persisted record was removed. A false return means the
-- on-disk ban survives (re-applied at the next cold read) despite the local
-- cache being cleared.
function BanService.Unban(userId: number): boolean
	cache[userId] = false
	local persisted = false
	local s = store()
	if s then
		local ok, err = pcall(function()
			s:RemoveAsync(tostring(userId))
		end)
		persisted = ok
		if not ok then
			warn(`[BanService] failed to remove persisted ban for {userId}: {tostring(err)}`)
		end
	end
	BanService.OnUnban:Fire(userId)
	return persisted
end

-- Active (non-expired) ban records, newest first, capped at maxCount.
-- Combines the session cache (Studio in-memory bans, warm entries) with
-- persisted keys via ListKeysAsync — pcall-guarded, so without DataStore API
-- access this degrades to the session cache. Feeds the Admin Panel's /unban
-- list. Each entry: { userId, reason, expiresAt?, time }.
function BanService.ListBans(maxCount: number?): { BanListEntry }
	local cap = maxCount or 50
	local seen: { [number]: boolean } = {}
	local out: { BanListEntry } = {}
	local function add(userId: number, ban: Ban)
		if seen[userId] or isExpired(ban) then
			return
		end
		seen[userId] = true
		table.insert(out, {
			userId = userId,
			reason = ban.reason,
			expiresAt = ban.expiresAt,
			time = ban.time,
		})
	end
	for userId, c in pairs(cache) do
		if typeof(c) == "table" then
			add(userId, c :: Ban)
		end
	end
	local s = store()
	if s then
		pcall(function()
			local pages = s:ListKeysAsync()
			while #out < cap do
				for _, key in ipairs(pages:GetCurrentPage()) do
					if #out >= cap then
						break
					end
					local userId = tonumber(key.KeyName)
					if userId and not seen[userId] then
						local ban = loadBan(userId)
						if ban then
							add(userId, ban)
						end
					end
				end
				if pages.IsFinished then
					break
				end
				pages:AdvanceToNextPageAsync()
			end
		end)
	end
	table.sort(out, function(a, b)
		return (a.time or 0) > (b.time or 0)
	end)
	return out
end

-- ── PlayerAdded gate ──
local function gate(player: Player): ()
	local banned, reason = BanService.IsBanned(player.UserId)
	if not banned then
		return
	end
	-- The place creator can never be legitimately banned (manual /ban refuses,
	-- escalation is exempt) — a record here is stale (e.g. an auto-ban issued
	-- before the exemption existed) and would lock the owner out of their own
	-- game. Self-heal: drop the record instead of kicking. Creator ONLY: role
	-- rows load async (racy at join) and lower staff CAN be legitimately banned.
	if game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
		warn(`[BanService] dropped stale ban on place creator {player.Name} (was: {reason})`)
		BanService.Unban(player.UserId)
		return
	end
	player:Kick(`[Banned] {reason}`)
end

-- ── Auto-escalation policy (repeat hard AntiCheat actions) ──

-- Role lookup for the escalation exemption, installed by AdminCommands' Init
-- (BanService never requires AdminCommands: AdminCommands depends on this module).
-- BanService still works without it — the exemption then covers only the place
-- creator.
local roleResolver: Types.UserRoleResolver? = nil

-- Install the (userId, role) -> boolean lookup the escalation exemption uses.
-- AdminCommands does this in its Init; game code does not need to call it.
function BanService.SetRoleResolver(fn: Types.UserRoleResolver): ()
	roleResolver = fn
end

-- The machine must never ban high roles. Detectors legitimately fire on admin
-- work (teleports, speed grants, dev tooling) and an auto-ban here locks the
-- very people who can fix it out of the game — the place creator got temp-
-- banned by "Auto: Teleport x2" exactly this way. The creator is exempt
-- unconditionally (sync check — role rows may not have loaded yet at flag
-- time); roles at Config.AntiCheat.BanPolicy.ExemptRole and above are exempt
-- via the role registry. Default "admin", NOT "moderator": the lowest, least-
-- vetted staff tier keeps the automated cheating deterrent. Best-effort during
-- join: DataStore-granted roles load async, so a hard-flag burst in the first
-- seconds can still strike a non-Bootstrap admin (creator/Bootstrap roles are
-- sync and never race). Manual /ban is NOT affected: protectTarget in
-- AdminCommands still allows deliberately banning a lower-ranked staff member.
local function isEscalationExempt(userId: number): boolean
	if game.CreatorType == Enum.CreatorType.User and userId == game.CreatorId then
		return true
	end
	-- ExemptRole = false turns the role exemption off (creator only).
	local exemptRole = Config.AntiCheat.BanPolicy.ExemptRole
	if exemptRole == false then
		return false
	end
	local resolve = roleResolver
	if resolve then
		return resolve(userId, tostring(exemptRole or "admin"))
	end
	return false
end

-- Public: AntiCheat.OnAction has TWO enforcing consumers — escalate() here and
-- the bootstrap's default hard-action kick. Both must answer "is this user
-- machine-punishable?" identically, or the exemption only stops the ban while
-- the other consumer still kicks the creator out of their own game.
function BanService.IsEscalationExempt(userId: number): boolean
	return isEscalationExempt(userId)
end

local strikes: { [number]: number } = {}
-- Players already kicked/banned by escalate() whose disconnect is still pending.
-- Kick is asynchronous, so several hard actions arriving in the same frame used to
-- add several strikes (KickAt=1 → TempBanAt=2 → PermBanAt=3 inside one frame):
-- three simultaneous flags meant a permanent ban. One punishment per session.
-- Strikes reset on leave, so with the default KickAt = 1 the temp/perm thresholds
-- are only reached when KickAt is raised above 1.
local punished: { [number]: boolean } = {}
local function escalate(player: Player, reason: string): ()
	local uid = player.UserId
	if punished[uid] then return end
	if isEscalationExempt(uid) then
		warn(`[BanService] escalation exempt for {player.Name} ({uid}) — would have acted on: {reason}`)
		return
	end
	strikes[uid] = (strikes[uid] or 0) + 1
	local n = strikes[uid]
	local policy = Config.AntiCheat.BanPolicy
	local kickAt    : number = policy.KickAt or 1
	local tempBanAt : number = policy.TempBanAt or 2
	local permBanAt : number = policy.PermBanAt or 3
	local tempSecs  : number = policy.TempBanSeconds or 3600
	if n >= permBanAt then
		punished[uid] = true
		BanService.Ban(uid, `Auto: {reason} x{n}`)
	elseif n >= tempBanAt then
		punished[uid] = true
		BanService.Ban(uid, `Auto: {reason} x{n}`, tempSecs)
	elseif n >= kickAt then
		punished[uid] = true
		player:Kick(`[AntiCheat] {reason}`)
	end
end

local function onPlayerRemoving(p: Player): ()
	strikes[p.UserId] = nil
	punished[p.UserId] = nil
	-- Evict the ban cache so a rejoin re-reads the store: bans/unbans issued on
	-- ANOTHER server while this one held a warm entry must take effect here too.
	-- Only when a real store exists — without one (Studio, no API access) the
	-- cache IS the ban state and must survive rejoin within the session.
	if store() then
		cache[p.UserId] = nil
	end
end

Lifecycle.Define(BanService, {
	Name = "Ban",
	Needs = {},
	Init = function()
		BAN_STORE = Config.Admin.Stores.Bans or "GaxiaBans"
		-- Join gate: connected before players are admitted; players already in
		-- game (late start) are checked too. The ban read yields, so each runs
		-- on its own thread.
		Players.PlayerAdded:Connect(gate)
		for _, p in ipairs(Players:GetPlayers()) do
			task.spawn(gate, p)
		end
		Players.PlayerRemoving:Connect(onPlayerRemoving)
	end,
	Start = function()
		-- Escalate repeat hard AntiCheat actions ("observe" = not enforced: ignored).
		AntiCheat.OnAction:Connect(function(player: Player, reason: string, kind: string)
			if kind == "hard" then
				escalate(player, reason)
			end
		end)
	end,
})

return BanService
