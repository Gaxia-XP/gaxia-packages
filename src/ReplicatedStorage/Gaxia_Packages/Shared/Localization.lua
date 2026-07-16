--!strict
-- ─────────────────────────────────────────────────────────────
-- Localization.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Shared/Localization
-- Purpose : i18n seam — a single chokepoint every user-facing string flows
--           through, so a game can ship one language now and add more later
--           without re-touching every UI file. Load(locale, table) registers a
--           catalog; T(key, vars) returns the localized string with {var}
--           interpolation, falling back through the default locale to the raw
--           key (so a missing translation degrades to readable text, never an
--           error). SetLocale fires OnLocaleChanged so live UI can re-render.
--
-- Access  : Gaxia.Localization  (shared)
--   Gaxia.Localization.Load("en", { greeting = "Hi {name}!", coins = "{n} coins" })
--   Gaxia.Localization.T("greeting", { name = "Gax" })   --> "Hi Gax!"
--   Gaxia.Localization.SetLocale("th")
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local DEFAULT_LOCALE : string = "en"

local Localization = {}

type Catalog = { [string]: string }
local catalogs: { [string]: Catalog } = {}
local currentLocale : string = DEFAULT_LOCALE
local listeners: { (locale: string) -> () } = {}

-- ── Interpolation: replace {token} from `vars`; unknown tokens stay literal ──
local function interpolate(s: string, vars: { [string]: any }?): string
	if not vars then
		return s
	end
	return (s:gsub("{(%w+)}", function(name: string): string
		local v = vars[name]
		return if v ~= nil then tostring(v) else "{" .. name .. "}"
	end))
end

-- ── Public API ──

-- Merge entries into a locale's catalog (call repeatedly to extend).
function Localization.Load(locale: string, entries: { [string]: string }): ()
	local cat = catalogs[locale]
	if not cat then
		cat = {}
		catalogs[locale] = cat
	end
	for k, v in pairs(entries) do
		cat[k] = v
	end
end

function Localization.SetLocale(locale: string): ()
	if locale == currentLocale then
		return
	end
	currentLocale = locale
	for _, fn in ipairs(listeners) do
		local ok, err = pcall(fn, locale)
		if not ok then
			warn(`[Localization] OnLocaleChanged listener errored: {err}`)
		end
	end
end

function Localization.GetLocale(): string
	return currentLocale
end

-- Translate `key` in the current locale (then default locale, then the key
-- itself), interpolating {token} from `vars`.
function Localization.T(key: string, vars: { [string]: any }?): string
	local cat = catalogs[currentLocale]
	local raw = cat and cat[key]
	if raw == nil and currentLocale ~= DEFAULT_LOCALE then
		local def = catalogs[DEFAULT_LOCALE]
		raw = def and def[key]
	end
	if raw == nil then
		return key
	end
	return interpolate(raw, vars)
end

-- True if `key` exists in the current or default locale.
function Localization.Has(key: string): boolean
	local cat = catalogs[currentLocale]
	if cat and cat[key] ~= nil then
		return true
	end
	local def = catalogs[DEFAULT_LOCALE]
	return (def ~= nil and def[key] ~= nil)
end

-- Returns an unsubscribe function.
function Localization.OnLocaleChanged(fn: (locale: string) -> ()): () -> ()
	table.insert(listeners, fn)
	return function()
		local i = table.find(listeners, fn)
		if i then
			table.remove(listeners, i)
		end
	end
end

return Localization
