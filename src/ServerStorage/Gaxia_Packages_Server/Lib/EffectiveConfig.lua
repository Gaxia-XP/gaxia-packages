--!strict
-- ─────────────────────────────────────────────────────────────
-- EffectiveConfig.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/EffectiveConfig
-- Purpose : The resolver that turns the framework's config into a TWO-LAYER
--           system without touching the static surface. Every tunable now has an
--           "effective" value = runtime Flag override (Gaxia.Flags, live, no
--           redeploy) IF set, otherwise the static default (Gaxia.Config, boot-
--           time, server-private). Services read `EConfig.Get(flagKey, default)`
--           / `EConfig.Enabled(...)` instead of freezing a Config value at boot,
--           so an admin command can flip a detector or feature mid-session.
--           Flags are session-scoped (RAM/attributes) — restart reverts to Config.
--
-- Access  : Gaxia.EConfig  (server)
--   if EConfig.Enabled("AntiCheat.Enabled", Config.AntiCheat.Enabled) then ... end
--   local mult = EConfig.Get("AntiCheat.Speed.ToleranceMultiplier", cfg.Speed.ToleranceMultiplier)
--   EConfig.Set("AntiCheat.Enabled", false)   -- runtime override (admin command)
-- ─────────────────────────────────────────────────────────────
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Flags = require(ReplicatedStorage.Gaxia_Packages.Shared.Flags)

local EConfig = {}

-- Overrides whose type did not match the default, already warned about
-- (key + type + value), so a bad override warns once, not on every read.
local warnedMismatch: { [string]: boolean } = {}

-- Effective value: runtime Flag override (if one is set) else the static default.
-- An override whose type differs from the default's (a string or `true` for a
-- number setting) is ignored with a warning and the default is returned.
-- With a nil default any override is returned as is.
function EConfig.Get(flagKey: string, default: any): any
	local override = Flags.Get(flagKey, nil)
	if override == nil then
		return default
	end
	if default ~= nil and typeof(override) ~= typeof(default) then
		local key = `{flagKey}|{typeof(override)}|{tostring(override)}`
		if not warnedMismatch[key] then
			warnedMismatch[key] = true
			warn(
				`[EConfig] ignoring override {flagKey} = {tostring(override)} ({typeof(override)}): `
					.. `this setting is a {typeof(default)}, so {tostring(default)} is used. `
					.. `Set a {typeof(default)} (for example /flag set {flagKey} {tostring(default)}) or /flag clear {flagKey}`
			)
		end
		return default
	end
	return override
end

-- Boolean convenience: effective value coerced to a strict boolean (a non-boolean
-- override is ignored with a warning, so the default applies).
function EConfig.Enabled(flagKey: string, default: boolean): boolean
	return EConfig.Get(flagKey, default) == true
end

-- True if a runtime override is currently set for this key (ignores the default).
function EConfig.IsOverridden(flagKey: string): boolean
	return Flags.Get(flagKey, nil) ~= nil
end

-- Set a runtime override (server-only; replicates via Flags). Sugar over Flags.Set
-- so callers go through one resolver rather than poking Flags directly.
function EConfig.Set(flagKey: string, value: any): ()
	Flags.Set(flagKey, value)
end

-- Remove the override so the key falls back to its static Config default.
function EConfig.Clear(flagKey: string): ()
	pcall(function()
		Flags.Set(flagKey, nil)
	end)
end

return EConfig
