--!strict
-- ─────────────────────────────────────────────────────────────
-- DataMigration.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/DataMigration
-- Purpose : Schema versioning for DataManager profiles. Register
--           migration functions and run them in order on load.
-- Integration: After ProfileStore Reconcile, call
--           DataMigration.Migrate(profile.Data) to upgrade old
--           saves to the current schema before gameplay starts.
-- ─────────────────────────────────────────────────────────────

local CollectionService = game:GetService("CollectionService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal = SharedPkg.Signal

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

DataMigration.OnMigrated = Signal.new()

-- ── Public API ──

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

function DataMigration.SetCurrentVersion(v: number): ()
	currentVersion = v
end

function DataMigration.GetCurrentVersion(): number
	return currentVersion
end

function DataMigration.Migrate(data: { [string]: any }): boolean
	-- WHY: default __version = 0 so fresh profiles still walk the chain to current.
	local version: number = (data.__version :: number?) or 0
	local startVersion: number = version
	local migrated: boolean = false

	while version < currentVersion do
		local entry: MigrationEntry? = migrations[version]
		if not entry then
			warn(`[DataMigration] No migration registered from v{version} -> target v{currentVersion}. Chain incomplete.`)
			break
		end

		local ok, err = pcall(entry.fn, data)
		if not ok then
			warn(`[DataMigration] Migration v{entry.fromVersion} -> v{entry.toVersion} failed: {err}`)
			break
		end

		version = entry.toVersion
		data.__version = version
		migrated = true
	end

	if migrated then
		DataMigration.OnMigrated:Fire(nil, startVersion, version)
	end

	return migrated
end

return DataMigration
