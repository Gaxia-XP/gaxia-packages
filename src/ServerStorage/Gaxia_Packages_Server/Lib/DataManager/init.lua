--!strict
--[[
	Module : DataManager
	Location: ServerStorage.Gaxia_Packages_Server.Lib.DataManager
	Purpose : ProfileStore wrapper exposing simple Get / Set / Save API per player.
	          Loads on PlayerAdded, ends sessions on PlayerRemoving, and fires lifecycle/change Signals.
	          Phase 17.2: resilient safeWrite helper (pcall + exponential backoff + request-budget wait)
	          for any external DataStore write — degrades gracefully when no real DataStore exists (Studio stub).
	          Phase 17.3: game:BindToClose() flushes every loaded profile (Save + EndSession) within the
	          shutdown deadline, as defense-in-depth on top of ProfileStore's own internal BindToClose,
	          and (optionally) writes a disaster-recovery backup — OFF by default.
	          Phase 17.4: DataMigration.Migrate runs on load (after Reconcile) to upgrade old schemas.
]]

-- Server-only guard: returning an empty table on the client keeps require() safe.

-- ── Services ──
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local DataStoreService   = game:GetService("DataStoreService")

-- ── Shared utilities ──
local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal = SharedPkg.Signal
local Util   = SharedPkg.Util

-- ── Config (server-side, see ServerStorage/Gaxia_Packages_Server/Config) ──
-- FindFirstChild (not WaitForChild) + Config's body has no yields, so requiring it
-- here is safe under the loader's no-yield metamethod. Config is the single place
-- DataStore names + resilience tunables are set — nothing below is hardcoded.
local Config = require(script.Parent.Parent:FindFirstChild("Config") :: ModuleScript) :: any

-- ── ProfileStore (lazily resolved — see getProfileStore below) ──
-- WHY lazy: ProfileStore is a server-only Wally dependency under ServerPackages.
-- It is present in the built place after `wally install`, but DataManager
-- is first required THROUGH the server loader's no-yield __index metamethod, and
-- require()-ing ProfileStore yields (its module body spins up DataStore / auto-
-- save state). Yielding across that metamethod boundary throws "attempt to yield
-- across metamethod/C-call boundary", so we resolve on first player load instead
-- (a normal coroutine, where yielding is fine).

-- ── DataMigration (sibling Lib module, lazily resolved) ──
-- WHY lazy + FindFirstChild (NOT a top-level WaitForChild require):
-- DataManager is first required THROUGH the server loader's __index metamethod,
-- and Luau forbids yielding across that boundary. Requiring DataMigration at
-- module top — or even WaitForChild-ing it — yields under the metamethod and
-- throws "attempt to yield across metamethod/C-call boundary". We resolve it on
-- first player load instead (onPlayerAdded runs in a normal coroutine where
-- yielding is fine). Sibling-direct also avoids the circular require that going
-- through Gaxia_Packages_Server.init.Migration would cause.
local dataMigration: any = nil
local function getMigration(): any
	if not dataMigration then
		local mod = script.Parent:FindFirstChild("DataMigration")
		if mod then
			dataMigration = require(mod)
		end
	end
	return dataMigration
end

-- ── Constants (from Config.Data) ──
local PROFILE_STORE_NAME: string = Config.Data.StoreName
local PROFILE_KEY_PREFIX: string = Config.Data.KeyPrefix
local WAIT_FOR_DEFAULT_TIMEOUT: number = Config.Data.WaitForDefaultTimeout

-- ── Phase 17.2 / 17.3 — resilience + shutdown (from Config.Data) ──
local SHUTDOWN_FLUSH_DEADLINE: number = Config.Data.ShutdownFlushDeadline
local WRITE_MAX_ATTEMPTS: number     = Config.Data.Write.MaxAttempts
local WRITE_BASE_BACKOFF: number     = Config.Data.Write.BaseBackoff
local WRITE_BUDGET_WAIT_STEP: number = Config.Data.Write.BudgetWaitStep
local WRITE_BUDGET_MAX_WAIT: number  = Config.Data.Write.BudgetMaxWait
local BACKUP_ENABLED: boolean        = Config.Data.Backup.Enabled
local BACKUP_STORE_NAME: string      = Config.Data.Backup.StoreName

-- ── Types ──
export type PlayerData = {
	Coins: number,
	Gems: number,
	Level: number,
	Experience: number,
	Inventory: { [string]: number },
	Settings: { Music: boolean, SFX: boolean },
	PlayTime: number,
	LastLogin: number,
	-- Schema version read/written by DataMigration.Migrate (key: __version).
	-- Baseline = 1: the current DEFAULT_PROFILE shape IS schema v1. Existing
	-- unlabeled saves are normalised to v1 by Reconcile (their shape already
	-- matches); future schema changes bump to v2+ and register N→N+1 migrations.
	__version: number,
}

-- ── Module ──
local DataManager = {}

-- Default profile schema: anything missing in saved data is filled via Reconcile.
DataManager.DEFAULT_PROFILE = {
	Coins      = 0,
	Gems       = 0,
	Level      = 1,
	Experience = 0,
	Inventory  = {} :: { [string]: number },
	Settings   = { Music = true, SFX = true },
	PlayTime   = 0,
	LastLogin  = 0,
	-- Schema baseline (see PlayerData.__version). currentVersion in DataMigration
	-- also defaults to 1, so Migrate is a clean no-op until a game bumps it.
	__version  = 1,
} :: PlayerData

-- ── Signals ──
DataManager.OnLoaded      = Signal.new()
DataManager.OnReleased    = Signal.new()
DataManager.OnDataChanged = Signal.new()

-- ── Internal state ──
-- profileStore is resolved lazily (see the ProfileStore WHY above): the require
-- yields, which is illegal under the loader's metamethod, so we defer it to first
-- player load. ProfileStore.New is a module constructor called with a dot.
local profileStore: any = nil
local function getProfileStore(): any
	if profileStore then
		return profileStore
	end
	local serverPackages = script.Parent.Parent:WaitForChild("ServerPackages")
	local ProfileStore = require(serverPackages:WaitForChild("ProfileStore")) :: any
	profileStore = ProfileStore.New(PROFILE_STORE_NAME, DataManager.DEFAULT_PROFILE)
	return profileStore
end
local loadedProfiles: { [number]: any } = {}
-- Phase 17.3: set true once BindToClose begins so a late PlayerAdded does not load a doomed profile.
local isClosing: boolean = false
-- Phase 17.2: lazily-fetched backup store handle (nil until first successful GetDataStore, or if disabled).
local backupStore: any = nil

-- ── Phase 17.2 — DataStore resilience ──
-- WHY: DataManager itself never wrote to a raw DataStore before; the ONLY raw write is the
-- optional backup below. safeWrite wraps it in pcall + bounded exponential backoff and waits on
-- the request budget, so an absent DataStore (Studio stub) or a throttled live server degrades to
-- a single warn instead of erroring inside BindToClose.
local function waitForWriteBudget(): ()
	-- Best-effort: if the API is missing (stub) or errors, just proceed — the pcall around
	-- the write itself is the real guard.
	local deadline = os.clock() + WRITE_BUDGET_MAX_WAIT
	while os.clock() < deadline do
		local ok, budget = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(
				Enum.DataStoreRequestType.SetIncrementAsync
			)
		end)
		if not ok then
			return -- no budget API (stub) → let the write attempt + pcall decide
		end
		if typeof(budget) == "number" and budget > 0 then
			return
		end
		task.wait(WRITE_BUDGET_WAIT_STEP)
	end
end

-- Returns true on a confirmed write, false after exhausting retries (caller just warns).
local function safeWrite(store: any, key: string, value: any): boolean
	if store == nil then
		return false
	end
	for attempt = 1, WRITE_MAX_ATTEMPTS do
		waitForWriteBudget()
		local ok, err = pcall(function()
			store:SetAsync(key, value)
		end)
		if ok then
			return true
		end
		warn(`[DataManager] safeWrite attempt {attempt}/{WRITE_MAX_ATTEMPTS} failed for {key}: {err}`)
		if attempt < WRITE_MAX_ATTEMPTS then
			task.wait(WRITE_BASE_BACKOFF * (2 ^ (attempt - 1)))
		end
	end
	return false
end

-- Lazily resolve the backup store; returns nil (and never errors) when disabled or unavailable.
local function getBackupStore(): any
	if not BACKUP_ENABLED then
		return nil
	end
	if backupStore ~= nil then
		return backupStore
	end
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(BACKUP_STORE_NAME)
	end)
	if ok then
		backupStore = store
		return store
	end
	warn(`[DataManager] backup store unavailable (no DataStore API?): {store}`)
	return nil
end

-- Best-effort disaster-recovery snapshot. No-op when BACKUP_ENABLED is false (default / Studio).
local function writeBackup(userId: number, data: { [string]: any }): ()
	local store = getBackupStore()
	if store == nil then
		return
	end
	local key = `{PROFILE_KEY_PREFIX}{userId}`
	if not safeWrite(store, key, data) then
		warn(`[DataManager] backup write gave up for {key}`)
	end
end

-- ── Public API ──

-- Returns Profile.Data[key] when key is given, or the whole data table otherwise.
function DataManager.Get(player: Player, key: string?): any
	local profile = loadedProfiles[player.UserId]
	if not profile then return nil end
	if key == nil then
		return profile.Data
	end
	return profile.Data[key]
end

-- Writes a key to Profile.Data and fires OnDataChanged. Returns false if profile is not loaded.
function DataManager.Set(player: Player, key: string, value: any): boolean
	local profile = loadedProfiles[player.UserId]
	if not profile then return false end
	profile.Data[key] = value
	DataManager.OnDataChanged:Fire(player, key, value)
	return true
end

-- Yields until profile loaded; returns the Data table or nil on timeout / leave.
function DataManager.WaitFor(player: Player, timeout: number?): any
	local deadline = os.clock() + (timeout or WAIT_FOR_DEFAULT_TIMEOUT)
	while os.clock() < deadline do
		local profile = loadedProfiles[player.UserId]
		if profile then return profile.Data end
		if player.Parent == nil then return nil end
		task.wait(0.1)
	end
	return nil
end

function DataManager.IsLoaded(player: Player): boolean
	return loadedProfiles[player.UserId] ~= nil
end

-- Force-save (ProfileStore persists periodically, this just nudges it).
function DataManager.Save(player: Player): ()
	local profile = loadedProfiles[player.UserId]
	if profile and typeof(profile.Save) == "function" then
		profile:Save()
	end
end

-- ── Lifecycle ──
local function onPlayerAdded(player: Player)
	if isClosing then
		-- Server is shutting down; do not start a load we cannot guarantee to flush.
		return
	end
	local key = `{PROFILE_KEY_PREFIX}{player.UserId}`
	local profile = getProfileStore():StartSessionAsync(key, {
		Cancel = function()
			return player.Parent == nil or isClosing
		end,
	})
	if not profile then
		if player.Parent then
			player:Kick("[DataManager] Could not start profile session.")
		end
		return
	end

	profile:AddUserId(player.UserId)
	profile:Reconcile()

	-- ── Schema migration (Phase 17.4) ──
	-- WHY here: run AFTER Reconcile (so every template field exists) and BEFORE
	-- loadedProfiles is populated (so no consumer can Get() un-migrated data).
	-- Migrate reads/writes profile.Data.__version and walks single-step
	-- migrations up to DataMigration's currentVersion; no-op when already current.
	-- getMigration() is resolved here (not at module top) to stay clear of the
	-- loader's no-yield metamethod boundary.
	local migration = getMigration()
	if migration then
		migration.Migrate(profile.Data)
	end

	profile.OnSessionEnd:Connect(function()
		local wasLoaded = loadedProfiles[player.UserId] == profile
		if wasLoaded then
			loadedProfiles[player.UserId] = nil
		end
		-- An unexpected external session end invalidates the local cache.
		if wasLoaded and player.Parent then
			player:Kick("[DataManager] Profile released.")
		end
	end)

	if player.Parent == nil then
		-- Player left before we finished loading.
		profile:EndSession()
		return
	end

	profile.Data.LastLogin = os.time()
	loadedProfiles[player.UserId] = profile
	DataManager.OnLoaded:Fire(player, profile.Data)
end

local function onPlayerRemoving(player: Player)
	local profile = loadedProfiles[player.UserId]
	if profile then
		loadedProfiles[player.UserId] = nil
		profile:EndSession()
		-- Fire INSIDE the guard so the claim (nil-ing the map) also gates the signal:
		-- prevents a double OnReleased when BindToClose races PlayerRemoving on shutdown.
		DataManager.OnReleased:Fire(player)
	end
end

-- Hook current + future players (a player may already exist if module loads after PlayerAdded fires).
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- ── Phase 17.3 — shutdown flush (defense-in-depth) ──
-- WHY: ProfileStore registers its OWN game:BindToClose that saves and ends
-- every active session, so the core save guarantee already exists in production. This block is
-- belt-and-suspenders: it (1) makes the Studio in-memory stub flush deterministically, (2) fires
-- our DataManager.OnReleased Signal for every player (loleris does not), and (3) flushes profiles
-- CONCURRENTLY inside the deadline. Double-ending is prevented by nil-ing loadedProfiles[uid]
-- BEFORE ending, so any concurrent onPlayerRemoving / OnSessionEnd becomes a no-op.
local function flushProfileOnClose(userId: number, profile: any): ()
	-- Claim the profile: clearing the map first makes a racing session end a no-op.
	loadedProfiles[userId] = nil

	-- Optional disaster-recovery snapshot BEFORE ending the session (data is still in hand).
	if typeof(profile.Data) == "table" then
		writeBackup(userId, profile.Data)
	end

	-- Force a final persist, then hand the session back. Both are pcall-guarded: a stub that
	-- lacks Save must not abort the shutdown loop for the other players. (In production this
	-- doubles with ProfileStore's own final save — acceptable for a shutdown-only path; it makes
	-- the Studio stub flush deterministically.)
	if typeof(profile.Save) == "function" then
		pcall(function()
			profile:Save()
		end)
	end
	if typeof(profile.EndSession) == "function" then
		pcall(function()
			profile:EndSession()
		end)
	end

	local player = Players:GetPlayerByUserId(userId)
	if player then
		DataManager.OnReleased:Fire(player)
	end
end

game:BindToClose(function()
	isClosing = true

	-- Snapshot the keys first: flushProfileOnClose mutates loadedProfiles as it runs.
	local pending: { number } = {}
	for userId in pairs(loadedProfiles) do
		table.insert(pending, userId)
	end
	if #pending == 0 then
		return
	end

	-- Flush every profile concurrently so N async session ends overlap inside the deadline.
	local remaining = #pending
	for _, userId in ipairs(pending) do
		local profile = loadedProfiles[userId]
		if profile then
			task.spawn(function()
				local ok, err = pcall(flushProfileOnClose, userId, profile)
				if not ok then
					warn(`[DataManager] flush on close failed for {userId}: {err}`)
				end
				remaining -= 1
			end)
		else
			remaining -= 1
		end
	end

	-- Block shutdown until all flushes finish OR the self-imposed deadline elapses
	-- (Roblox hard-kills the server at ~30s; we stop at SHUTDOWN_FLUSH_DEADLINE to leave margin).
	local deadline = os.clock() + SHUTDOWN_FLUSH_DEADLINE
	while remaining > 0 and os.clock() < deadline do
		task.wait(0.05)
	end
	if remaining > 0 then
		warn(`[DataManager] BindToClose deadline hit with {remaining} profile(s) unflushed`)
	end
end)

-- Test-only seed: install a synthetic profile so MockPlayer calls don't throw
-- "profile not loaded". Real Player profiles still go through ProfileStore.
-- Use ONLY from run_script_in_play_mode tests / repl — never from production code.
function DataManager._SeedForTest(player: any, data: { [string]: any }?): ()
	if loadedProfiles[player.UserId] then
		return -- don't clobber a real profile
	end
	-- Synthesise the minimum profile shape: `.Data` table + a no-op `.Save`.
	-- Reconcile against DEFAULT_PROFILE so existing accessors that read fields
	-- like Coins/XP don't see nil where they expect numbers.
	local synthetic = {
		Data = (Util :: any).Table.Reconcile(data or {}, DataManager.DEFAULT_PROFILE),
		Save = function(_self) end,
	}
	loadedProfiles[player.UserId] = synthetic
end

return DataManager
