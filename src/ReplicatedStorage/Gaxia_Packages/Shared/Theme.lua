--!strict
-- ─────────────────────────────────────────────────────────────
-- Theme.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Shared/Theme
-- Purpose : Single source of UI design tokens (color / font / spacing / radius).
--           The dark palette was duplicated as literal Color3.fromRGB across
--           Templates + DialogSystem + Tooltip + HUD + Inventory + Notification
--           — one tweak meant editing 6+ files. Read tokens from here instead;
--           SetTheme() merges overrides and fires OnThemeChanged so responsive
--           scaling, colorblind palettes, text-scale and per-game reskins all
--           build on one layer.
--
-- Access  : Gaxia.Theme  (shared)
--   local t = Gaxia.Theme.Get()
--   label.TextColor3 = Gaxia.Theme.Color("Text")
--   Gaxia.Theme.SetTheme({ Color = { Primary = Color3.fromRGB(255,120,180) } })
-- ─────────────────────────────────────────────────────────────

-- Built-in token names. Color/Spacing/Radius take them (so the names autocomplete)
-- but also accept any string, for tokens a game adds via SetTheme. FontName lists
-- the built-in keys of Get().Font. (Tokens stays map-typed so SetTheme can add keys.)
export type ColorName = "Background" | "BackgroundDeep" | "Surface" | "Primary" | "Success"
	| "Danger" | "Warning" | "Text" | "TextMuted"
export type FontName = "Regular" | "Medium" | "Bold"
export type SpacingName = "XS" | "S" | "M" | "L" | "XL"
export type RadiusName = "S" | "M" | "L" | "Pill"

export type Tokens = {
	Color: { [string]: Color3 },
	Font: { [string]: Enum.Font },
	Spacing: { [string]: number },
	Radius: { [string]: number },
}

local Theme = {}

local tokens: Tokens = {
	Color = {
		Background     = Color3.fromRGB(28, 30, 38),
		BackgroundDeep = Color3.fromRGB(18, 19, 26),
		Surface        = Color3.fromRGB(40, 43, 54),
		Primary        = Color3.fromRGB(120, 170, 255),
		Success        = Color3.fromRGB(120, 255, 150),
		Danger         = Color3.fromRGB(255, 95, 95),
		Warning        = Color3.fromRGB(255, 200, 90),
		Text           = Color3.fromRGB(235, 238, 245),
		TextMuted      = Color3.fromRGB(150, 158, 175),
	},
	Font = {
		Regular = Enum.Font.Gotham,
		Medium  = Enum.Font.GothamMedium,
		Bold    = Enum.Font.GothamBold,
	},
	Spacing = { XS = 4, S = 8, M = 12, L = 16, XL = 24 },
	Radius  = { S = 4, M = 8, L = 12, Pill = 999 },
}

local listeners: { (tokens: Tokens) -> () } = {}

-- ── Public API ──

function Theme.Get(): Tokens
	return tokens
end

-- Unknown names return white.
function Theme.Color(name: ColorName | string): Color3
	return tokens.Color[name] or Color3.new(1, 1, 1)
end

-- Unknown names return 0.
function Theme.Spacing(name: SpacingName | string): number
	return tokens.Spacing[name] or 0
end

-- Unknown names return 0.
function Theme.Radius(name: RadiusName | string): number
	return tokens.Radius[name] or 0
end

-- Shallow-merge a partial override per category (Color/Font/Spacing/Radius) and
-- notify listeners. Only the keys you pass change.
function Theme.SetTheme(partial: { [string]: { [string]: any } }): ()
	for category, values in pairs(partial) do
		local target = (tokens :: any)[category]
		if typeof(target) == "table" and typeof(values) == "table" then
			for k, v in pairs(values) do
				target[k] = v
			end
		end
	end
	for _, fn in ipairs(listeners) do
		-- (widened to ...any so pcall's (ok, err) typechecks for a `-> ()` listener)
		local ok, err = pcall(fn :: (Tokens) -> ...any, tokens)
		if not ok then
			warn(`[Theme] OnThemeChanged listener errored: {err}`)
		end
	end
end

-- Returns an unsubscribe function.
function Theme.OnThemeChanged(fn: (tokens: Tokens) -> ()): () -> ()
	table.insert(listeners, fn)
	return function()
		local i = table.find(listeners, fn)
		if i then
			table.remove(listeners, i)
		end
	end
end

return Theme
