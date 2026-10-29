--!strict
--[[
	Module : DataManager
	Location: ServerStorage.Gaxia_Packages_Server.Lib.DataManager
	Purpose : ProfileService wrapper exposing simple Get / Set / Save API per player.
	          Loads on PlayerAdded, releases on PlayerRemoving, fires Signals on lifecycle and changes.
	          Phase 17.2: resilient safeWrite helper (pcall + exponential backoff + request-budget wait)
	          for any external DataStore write — degrades gracefully when no real DataStore exists (Studio stub).
	          Phase 17.3: game:BindToClose() flushes every loaded profile (Save + Release) within the
	          shutdown deadline, as defense-in-depth on top of ProfileService's own internal BindToClose,
	          and (optionally) writes a disaster-recovery backup — OFF by default.
	          Phase 17.4: DataMigration.Migrate runs on load (after Reconcile) to upgrade old schemas.
	          SetDefaults: game code adds default values for its own saved fields; they are
	          reconciled into every profile on load, right after DEFAULT_PROFILE.
]]

-- ── Services ──
local Players          = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")

-- ── Dependencies ──
local Shared        = ReplicatedStorage.Gaxia_Packages.Shared
local Signal        = require(Shared.Signal)
local Table         = require(Shared.Util.Table)
local Lifecycle     = require(script.Parent.ServiceLifecycle)
local Config        = require(script.Parent.Parent.Config)
local DataMigration = require(script.Parent.DataMigration)
-- ProfileService (bundled child, loleris STANDALONE) stays lazily required on the
-- first profile load: its module body probes the DataStore API, connects Heartbeat
-- and registers its own BindToClose, which must not happen just because something
-- required DataManager.

-- ── Settings (from Config.Data, read in Init) ──
-- Read in Init rather than at module load: a place whose Config.Data lacks a
-- section then fails only DataManager's Init (warned; GaxiaServer.Data returns
-- nil) instead of making every module that requires DataManager fail to load.
local PROFILE_STORE_NAME: string = ""
local PROFILE_KEY_PREFIX: string = ""
local WAIT_FOR_DEFAULT_TIMEOUT: number = 120
local SHUTDOWN_FLUSH_DEADLINE: number = 25
local WRITE_MAX_ATTEMPTS: number = 1
local WRITE_BASE_BACKOFF: number = 1
local WRITE_BUDGET_WAIT_STEP: number = 0.5
local WRITE_BUDGET_MAX_WAIT: number = 0
local BACKUP_ENABLED: boolean = false
local BACKUP_STORE_NAME: string = ""

local function readConfig(): ()
	local cfg = Config.Data
	PROFILE_STORE_NAME       = cfg.StoreName
	PROFILE_KEY_PREFIX       = cfg.KeyPrefix
	WAIT_FOR_DEFAULT_TIMEOUT = cfg.WaitForDefaultTimeout
	SHUTDOWN_FLUSH_DEADLINE  = cfg.ShutdownFlushDeadline
	WRITE_MAX_ATTEMPTS       = cfg.Write.MaxAttempts
	WRITE_BASE_BACKOFF       = cfg.Write.BaseBackoff
	WRITE_BUDGET_WAIT_STEP   = cfg.Write.BudgetWaitStep
	WRITE_BUDGET_MAX_WAIT    = cfg.Write.BudgetMaxWait
	BACKUP_ENABLED           = cfg.Backup.Enabled
	BACKUP_STORE_NAME        = cfg.Backup.StoreName
end

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

-- Kick messages the player sees. Neutral on purpose: no internal names; details go to the server log.
local KICK_LOAD_FAILED = "Could not load your data. Please rejoin."
local KICK_SESSION_TAKEN = "Your data was opened on another server. Please rejoin."

-- ── Signals ──
-- (player, data) once the player's profile is loaded, reconciled and migrated
DataManager.OnLoaded      = Signal.new() :: Signal.Signal<Player, PlayerData>
-- (player) after the player's profile is released (leave or shutdown)
DataManager.OnReleased    = Signal.new() :: Signal.Signal<Player>
-- (player, key, value) after DataManager.Set
DataManager.OnDataChanged = Signal.new() :: Signal.Signal<Player, string, any>

-- ── Internal state ──
-- profileStore is resolved lazily (see the ProfileService note above) on the first
-- player load. GetProfileStore is called with a DOT (not colon): it is declared as
-- a plain function; calling with `:` would pass the module as the first arg and
-- trigger "Missing or invalid Name parameter".
local profileStore: any = nil
local function getProfileStore(): any
	if profileStore then
		return profileStore
	end
	local ProfileService = require(script.ProfileService)
	profileStore = ProfileService.GetProfileStore(PROFILE_STORE_NAME, DataManager.DEFAULT_PROFILE)
	return profileStore
end
local loadedProfiles: { [number]: any } = {}
-- Defaults game code added with DataManager.SetDefaults (deep-merged; reconciled on every load).
local gameDefaults: { [string]: any } = {}
-- Set once the first profile has been reconciled: SetDefaults after that is late (warned).
local anyProfileLoaded: boolean = false
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

-- Yields until the player's data is loaded and returns the data table.
-- Returns nil when the player leaves or `timeout` seconds pass first
-- (default 120 seconds: Config.Data.WaitForDefaultTimeout).
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

-- Force-save (ProfileService persists periodically, this just nudges it).
function DataManager.Save(player: Player): ()
	local profile = loadedProfiles[player.UserId]
	if profile and typeof(profile.Save) == "function" then
		profile:Save()
	end
end

-- ── Game defaults (SetDefaults) ──

-- Checks that `value` can be saved in a DataStore (numbers, strings, booleans and
-- tables of them: string keys only, or a list 1..n). Returns an error text, or nil when fine.
local function checkSaveable(value: any, path: string, depth: number): string?
	local kind = typeof(value)
	if kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return `{path} is not a finite number`
		end
		return nil
	elseif kind == "string" or kind == "boolean" then
		return nil
	elseif kind ~= "table" then
		return `{path} is a {kind}: save numbers, strings, booleans or tables of them`
	end
	if depth > 16 then
		return `{path} is nested too deep`
	end
	local count = 0
	local hasStringKey = false
	local hasNumberKey = false
	local listKeysOk = true
	for k, v in pairs(value) do
		count += 1
		if type(k) == "string" then
			hasStringKey = true
		elseif type(k) == "number" then
			hasNumberKey = true
			if k ~= math.floor(k) or k < 1 then
				listKeysOk = false
			end
		else
			return `{path} has a {typeof(k)} key: use string keys`
		end
		local problem = checkSaveable(v, `{path}.{tostring(k)}`, depth + 1)
		if problem then
			return problem
		end
	end
	-- WHY: a DataStore save fails for a table that mixes string and number keys, and
	-- for number keys that are not exactly 1..n (every save of every player fails).
	if hasStringKey and hasNumberKey then
		return `{path} mixes number and string keys: use string keys only, or a list`
	end
	if hasNumberKey then
		if not listKeysOk then
			return `{path} has number keys that are not a list 1, 2, 3...: use string keys`
		end
		for i = 1, count do
			if value[i] == nil then
				return `{path} has number keys that are not a list 1, 2, 3...: use string keys`
			end
		end
	end
	return nil
end

-- True for a list default (a table with number keys 1..n). Lists are one value:
-- they are copied when the field is missing and never merged element by element.
local function isList(value: any): boolean
	return type(value) == "table" and value[1] ~= nil
end

-- Fills fields of `target` that are nil from `template`. Dictionaries merge key by key;
-- lists and other values are copied only when the field is nil (a saved list is kept as is).
local function reconcileDefaults(target: { [any]: any }, template: { [any]: any }): ()
	for k, v in pairs(template) do
		local current = target[k]
		if current == nil then
			target[k] = if type(v) == "table" then Table.DeepCopy(v) else v
		elseif type(current) == "table" and type(v) == "table" and not isList(v) and not isList(current) then
			reconcileDefaults(current, v)
		end
	end
end

-- Deep-merges `source` into `target`: nested dictionaries merge key by key, lists and
-- other values replace.
local function deepMerge(target: { [any]: any }, source: { [any]: any }): ()
	for k, v in pairs(source) do
		if type(v) == "table" and type(target[k]) == "table" and not isList(v) and not isList(target[k]) then
			deepMerge(target[k], v)
		else
			target[k] = if type(v) == "table" then Table.DeepCopy(v) else v
		end
	end
end

-- Returns the path of the first leaf in `value` that is already a built-in field of
-- `builtIn` (a DEFAULT_PROFILE table), or nil. Built-in leaves are filled first, so a
-- game default for them would never apply.
local function findBuiltInLeaf(value: { [any]: any }, builtIn: { [any]: any }, path: string): string?
	for k, v in pairs(value) do
		local b = builtIn[k]
		if b ~= nil then
			local childPath = `{path}.{tostring(k)}`
			if type(b) == "table" and type(v) == "table" and not isList(b) and not isList(v) then
				local found = findBuiltInLeaf(v, b, childPath)
				if found then
					return found
				end
			else
				return childPath
			end
		end
	end
	return nil
end

-- Adds default values for the game's own saved fields. Every player who does not have a
-- field yet gets it when their data loads (new players, and fields added in an update),
-- before Data.WaitFor / Data.OnLoaded return the data. Nested tables are deep-merged:
-- `{ Settings = { Volume = 1 } }` adds `Settings.Volume` and keeps the built-in settings.
-- A list (`{ "Sword", "Bow" }`) is one value: a player gets it only when the field is
-- missing, and a saved list is never merged with it.
-- Values must be saveable: numbers, strings, booleans, and tables of them that use string
-- keys only or are a list 1, 2, 3... (a table that mixes the two is refused).
-- Built-in fields (Coins, Level, Settings.Music, ...) and names starting with "__" are
-- refused (warned).
-- Call it at the top of a Script, before players load. A late call warns and fills the
-- players already loaded too. Calling it again merges into the earlier defaults.
-- Returns false when any field was refused.
function DataManager.SetDefaults(defaults: { [string]: any }): boolean
	if type(defaults) ~= "table" then
		warn(`[DataManager] SetDefaults expects a table of field = default value, got {typeof(defaults)}`)
		return false
	end
	local accepted: { [string]: any } = {}
	local allOk = true
	for key, value in pairs(defaults) do
		local refused: string? = nil
		if type(key) ~= "string" then
			refused = `key {tostring(key)} is a {typeof(key)}: use string keys`
		elseif string.sub(key, 1, 2) == "__" then
			refused = `"{key}": names starting with "__" are reserved`
		else
			local builtIn = (DataManager.DEFAULT_PROFILE :: any)[key]
			if builtIn ~= nil and (type(builtIn) ~= "table" or type(value) ~= "table") then
				refused = `"{key}" is a built-in field: its default cannot change`
			else
				refused = checkSaveable(value, key, 1)
				if not refused and type(builtIn) == "table" then
					local leaf = findBuiltInLeaf(value, builtIn, key)
					if leaf then
						refused = `"{leaf}" is a built-in field: its default cannot change`
					end
				end
			end
		end
		if refused then
			warn(`[DataManager] SetDefaults: {refused} (ignored)`)
			allOk = false
		else
			accepted[key] = value
		end
	end
	deepMerge(gameDefaults, accepted)

	if anyProfileLoaded then
		warn("[DataManager] SetDefaults was called after player data loaded: call it at the top of a Script, before players join. Filling the players already loaded now.")
		for userId, profile in pairs(loadedProfiles) do
			local data = profile.Data
			if type(data) == "table" then
				local missing: { string } = {}
				for key in pairs(accepted) do
					if data[key] == nil then
						table.insert(missing, key)
					end
				end
				reconcileDefaults(data, accepted)
				local player = Players:GetPlayerByUserId(userId)
				if player then
					for _, key in ipairs(missing) do
						DataManager.OnDataChanged:Fire(player, key, data[key])
					end
				end
			end
		end
	end
	return allOk
end

-- ── Lifecycle ──
local function onPlayerAdded(player: Player)
	if isClosing then
		-- Server is shutting down; do not start a load we cannot guarantee to flush.
		return
	end
	local key = `{PROFILE_KEY_PREFIX}{player.UserId}`
	local loadOk, loaded = pcall(function()
		return getProfileStore():LoadProfileAsync(key)
	end)
	local profile = if loadOk then loaded else nil
	if not profile then
		-- No profile (session lock held elsewhere, server shutting down, or an error):
		-- kick so the player never plays on unsaved data. Details go to the server log only.
		warn(`[DataManager] Could not load profile {key} for {player.Name}: {if loadOk then "no profile returned (session locked or shutting down)" else loaded}`)
		if player.Parent then
			player:Kick(KICK_LOAD_FAILED)
		end
		return
	end

	profile:AddUserId(player.UserId)
	profile:Reconcile()
	Table.Reconcile(profile.Data, DataManager.DEFAULT_PROFILE :: any)
	-- Game fields from SetDefaults, right after the built-in template (before migration).
	reconcileDefaults(profile.Data, gameDefaults)
	anyProfileLoaded = true

	-- ── Schema migration (Phase 17.4) ──
	-- WHY here: run AFTER Reconcile (so every template field exists) and BEFORE
	-- loadedProfiles is populated (so no consumer can Get() un-migrated data).
	-- Migrate reads/writes profile.Data.__version and walks single-step
	-- migrations up to DataMigration's currentVersion; no-op when already current.
	DataMigration.Migrate(profile.Data)

	profile:ListenToRelease(function()
		-- Our own releases (PlayerRemoving, shutdown flush) clear the map entry BEFORE
		-- calling Release, so only a release we did not start — another server taking
		-- the session — still finds this profile in the map. Kick only in that case;
		-- before, every normal leave kicked the departing player too.
		if loadedProfiles[player.UserId] ~= profile then
			return
		end
		loadedProfiles[player.UserId] = nil
		if player.Parent then
			warn(`[DataManager] Profile of {player.Name} was released by another server; kicked`)
			player:Kick(KICK_SESSION_TAKEN)
		end
	end)

	if player.Parent == nil then
		-- Player left before we finished loading.
		profile:Release()
		return
	end

	profile.Data.LastLogin = os.time()
	loadedProfiles[player.UserId] = profile
	DataManager.OnLoaded:Fire(player, profile.Data)
end

local function onPlayerRemoving(player: Player)
	local profile = loadedProfiles[player.UserId]
	if profile then
		-- Claim before releasing so the ListenToRelease handler treats this as ours.
		loadedProfiles[player.UserId] = nil
		profile:Release()
		-- Fire INSIDE the guard so the claim (nil-ing the map) also gates the signal:
		-- prevents a double OnReleased when BindToClose races PlayerRemoving on shutdown.
		DataManager.OnReleased:Fire(player)
	end
end

-- ── Phase 17.3 — shutdown flush (defense-in-depth) ──
-- WHY: the real loleris ProfileService registers its OWN game:BindToClose that saves+releases
-- every active session, so the core save guarantee already exists in production. This block is
-- belt-and-suspenders: it (1) makes the Studio in-memory stub flush deterministically, (2) fires
-- our DataManager.OnReleased Signal for every player (loleris does not), and (3) flushes profiles
-- CONCURRENTLY inside the deadline. Double-release is prevented by nil-ing loadedProfiles[uid]
-- BEFORE releasing, so any concurrent onPlayerRemoving / ListenToRelease becomes a no-op.
local function flushProfileOnClose(userId: number, profile: any): ()
	-- Claim the profile: clearing the map first makes a racing release a no-op.
	loadedProfiles[userId] = nil

	-- Optional disaster-recovery snapshot BEFORE release (data is still in hand).
	if typeof(profile.Data) == "table" then
		writeBackup(userId, profile.Data)
	end

	-- Force a final persist, then hand the session back. Both are pcall-guarded: a stub that
	-- lacks Save must not abort the shutdown loop for the other players. (In production this
	-- doubles with loleris's own save-on-release — acceptable for a shutdown-only path; it makes
	-- the Studio stub flush deterministically.)
	if typeof(profile.Save) == "function" then
		pcall(function()
			profile:Save()
		end)
	end
	if typeof(profile.Release) == "function" then
		pcall(function()
			profile:Release()
		end)
	end

	local player = Players:GetPlayerByUserId(userId)
	if player then
		DataManager.OnReleased:Fire(player)
	end
end

local function onClose(): ()
	isClosing = true

	-- Snapshot the keys first: flushProfileOnClose mutates loadedProfiles as it runs.
	local pending: { number } = {}
	for userId in pairs(loadedProfiles) do
		table.insert(pending, userId)
	end
	if #pending == 0 then
		return
	end

	-- Flush every profile concurrently so N async releases overlap inside the deadline.
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
end

-- Test-only seed: install a synthetic profile so MockPlayer calls don't throw
-- "profile not loaded". Real Player profiles still go through ProfileService.
-- Use ONLY from run_script_in_play_mode tests / repl — never from production code.
function DataManager._SeedForTest(player: any, data: { [string]: any }?): ()
	if loadedProfiles[player.UserId] then
		return -- don't clobber a real profile
	end
	-- Synthesise the minimum profile shape: `.Data` table + a no-op `.Save`.
	-- Reconcile against DEFAULT_PROFILE so existing accessors that read fields
	-- like Coins/XP don't see nil where they expect numbers.
	local synthetic = {
		Data = data or {},
		Save = function(_self) end,
	}
	Table.Reconcile(synthetic.Data, DataManager.DEFAULT_PROFILE :: any)
	reconcileDefaults(synthetic.Data, gameDefaults)
	loadedProfiles[player.UserId] = synthetic
end

Lifecycle.Define(DataManager, {
	Name = "Data",
	Needs = {},
	Init = function()
		-- Config first: a broken Config.Data fails Init before any hook is connected.
		readConfig()
		-- Hook current + future players (a player may already exist if the service
		-- starts after PlayerAdded fired). Loads yield, so each runs on its own thread.
		for _, player in ipairs(Players:GetPlayers()) do
			task.spawn(onPlayerAdded, player)
		end
		Players.PlayerAdded:Connect(onPlayerAdded)
		Players.PlayerRemoving:Connect(onPlayerRemoving)
		game:BindToClose(onClose)
	end,
})

return DataManager
