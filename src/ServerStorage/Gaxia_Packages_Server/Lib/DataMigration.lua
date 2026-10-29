--!strict
-- ─────────────────────────────────────────────────────────────
-- DataMigration.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/DataMigration
-- Purpose : Schema versioning for DataManager profiles. Register
--           migration functions and run them in order on load.
-- Integration: After ProfileService Reconcile, call
--           DataMigration.Migrate(profile.Data) to upgrade old
--           saves to the current schema before gameplay starts.
--           Migrate is atomic: steps run on a deep copy that is
--           committed only when every step succeeds.
-- ─────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal    = require(ReplicatedStorage.Gaxia_Packages.Shared.Signal)
local Lifecycle = require(script.Parent.ServiceLifecycle)

-- ── Types ──
export type MigrationFn = (data: { [string]: any }) -> ()

type MigrationEntry = {
	fromVersion: number,
	toVersion: number,
	fn: MigrationFn,
}

-- ── Module ──
local DataMigration = {}

-- WHY: registered migrations live here keyed by fromVersion for fast lookup.
local migrations: { [number]: MigrationEntry } = {}
local currentVersion: number = 1

-- (player — always nil: Migrate only sees the data table, fromVersion, toVersion)
-- once per Migrate call that upgraded the data (every step succeeded)
DataMigration.OnMigrated = Signal.new() :: Signal.Signal<Player?, number, number>

-- ── Helpers ──

-- Saved data is plain tables (no cycles, no metatables), but stay cycle-safe anyway.
local function deepCopy(value: any, seen: { [any]: any }?): any
	if type(value) ~= "table" then
		return value
	end
	local cache: { [any]: any } = seen or {}
	if cache[value] ~= nil then
		return cache[value]
	end
	local out: { [any]: any } = {}
	cache[value] = out
	for k, v in pairs(value) do
		out[deepCopy(k, cache)] = deepCopy(v, cache)
	end
	return out
end

-- ── Public API ──

-- Registers the step that upgrades saved data from `fromVersion` to `toVersion` (toVersion > fromVersion).
-- Steps run in version order (each step starts at the version the previous one ended at),
-- whatever order they were registered in. Registering a second step from the same version replaces the first (warns).
function DataMigration.Register(fromVersion: number, toVersion: number, fn: MigrationFn): ()
	-- WHY: enforce strictly increasing single-step migrations so the chain is deterministic.
	if toVersion <= fromVersion then
		warn(`[DataMigration] Refusing to register: toVersion ({toVersion}) must be > fromVersion ({fromVersion})`)
		return
	end
	if migrations[fromVersion] then
		warn(`[DataMigration] Overwriting existing migration from v{fromVersion}`)
	end
	migrations[fromVersion] = {
		fromVersion = fromVersion,
		toVersion = toVersion,
		fn = fn,
	}
end

-- Sets the newest data version. Saves below it are upgraded on load.
function DataMigration.SetCurrentVersion(v: number): ()
	currentVersion = v
end

-- Returns the newest data version (default 1).
function DataMigration.GetCurrentVersion(): number
	return currentVersion
end

-- Upgrades `data` (in place) from data.__version to the current version, running each step in version order.
-- All or nothing: the steps run on a copy, and `data` changes only when every step succeeds.
-- When a step is missing or errors, `data` is left exactly as it was (the warning names the step) and the
-- steps run again on the next load. Returns true when `data` was upgraded, false when nothing changed.
function DataMigration.Migrate(data: { [string]: any }): boolean
	-- WHY: default __version = 0 so fresh profiles still walk the chain to current.
	local startVersion: number = (data.__version :: number?) or 0
	if startVersion >= currentVersion then
		return false
	end

	-- WHY a copy: a step that errors halfway must not leave a half-upgraded save behind.
	local working: { [string]: any } = deepCopy(data)
	local version: number = startVersion

	while version < currentVersion do
		local entry: MigrationEntry? = migrations[version]
		if not entry then
			warn(`[DataMigration] No migration registered from v{version} -> target v{currentVersion}. Chain incomplete; data left at v{startVersion}.`)
			return false
		end

		local ok, err = pcall(entry.fn, working)
		if not ok then
			warn(`[DataMigration] Migration v{entry.fromVersion} -> v{entry.toVersion} failed: {err} (data left at v{startVersion})`)
			return false
		end

		version = entry.toVersion
		working.__version = version
	end

	-- Commit: replace the contents of `data` in place (callers hold this table).
	for key in pairs(data) do
		data[key] = nil
	end
	for key, value in pairs(working) do
		data[key] = value
	end

	DataMigration.OnMigrated:Fire(nil, startVersion, version)
	return true
end

-- Pure registry: nothing to set up. Registered so Features / IsEnabled know it.
Lifecycle.Define(DataMigration, {
	Name = "Migration",
	Needs = {},
})

return DataMigration
