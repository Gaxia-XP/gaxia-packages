--!strict
-- ─────────────────────────────────────────────────────────────
-- BanService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/BanService
-- Purpose : Persistent bans and the join gate used by moderation. Automatic
--           AntiCheat policy lives only in AntiCheatEnforcement; this module
--           persists explicit Ban/Unban calls and provides the shared staff
--           exemption check used by that one enforcement owner.
--
-- Access  : Gaxia.Ban  (server)
--   Gaxia.Ban.Ban(userId, "Exploiting", 3600)   -- 1h temp ban (nil = permanent)
--   local banned, reason = Gaxia.Ban.IsBanned(userId)
-- ─────────────────────────────────────────────────────────────
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal = SharedPkg.Signal

local Config = require(script.Parent.Parent:FindFirstChild("Config") :: ModuleScript) :: any

-- Store name comes from Config so operators can namespace bans per-game
-- (Config.Admin.Stores.Bans, "override to namespace bans/roles per game").
-- Read once at load: the store name is fixed for the server lifetime and is a
-- server-private secret, never a runtime Flag. Falls back to the historic default.
local BAN_STORE: string = ((Config.Admin or {}).Stores or {}).Bans or "GaxiaBans"

export type Ban = {
	reason: string,
	expiresAt: number?, -- os.time(); nil = permanent
	time: number,
}

local BanService = {}

BanService.OnBan = Signal.new() -- (userId, ban)
BanService.OnUnban = Signal.new() -- (userId)

-- Session cache: Ban record, or false = explicitly not banned (so we don't re-hit
-- the DataStore every check). Lets Studio (no real DataStore) work in-memory.
local cache: { [number]: any } = {}

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
		cache[userId] = data
		return data
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
function BanService.ListBans(maxCount: number?): { { [string]: any } }
	local cap = maxCount or 50
	local seen: { [number]: boolean } = {}
	local out: { { [string]: any } } = {}
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
	-- automatic action is exempt) — a record here is stale (e.g. an old auto-ban issued
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
Players.PlayerAdded:Connect(gate)
for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(gate, p)
end

-- ── Automatic-action exemption helper ────────────────────────

-- Lazy AdminCommands ref (sibling Lib module) for the role lookup in the
-- escalation exemption. Resolved at call time via pcall: a load-time require
-- would drag AdminCommands' DataStore setup onto this module's load path, and
-- BanService must still work when AdminCommands is absent (exemption then
-- covers only the place creator).
local _adminRef: any = nil
local function getAdmin(): any
	if _adminRef ~= nil then
		return _adminRef
	end
	local mod = script.Parent:FindFirstChild("AdminCommands")
	if mod and mod:IsA("ModuleScript") then
		local ok, m = pcall(require, mod)
		if ok then
			_adminRef = m
		end
	end
	return _adminRef
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
	local policy = (Config.AntiCheat or {}).BanPolicy or {}
	if policy.ExemptRole == false then
		return false
	end
	local admin = getAdmin()
	if admin and admin.IsUserIdAtLeast then
		return admin.IsUserIdAtLeast(userId, tostring(policy.ExemptRole or "admin"))
	end
	return false
end

-- Public: the sole AntiCheatEnforcement owner calls this before automatic
-- action. Manual Ban() deliberately remains a low-level administrator API.
function BanService.IsEscalationExempt(userId: number): boolean
	return isEscalationExempt(userId)
end

Players.PlayerRemoving:Connect(function(p)
	-- Evict the ban cache so a rejoin re-reads the store: bans/unbans issued on
	-- ANOTHER server while this one held a warm entry must take effect here too.
	-- Only when a real store exists — without one (Studio, no API access) the
	-- cache IS the ban state and must survive rejoin within the session.
	if store() then
		cache[p.UserId] = nil
	end
end)

return BanService
