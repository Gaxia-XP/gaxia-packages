--!strict
-- ─────────────────────────────────────────────────────────────
-- Accessibility.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/Accessibility
-- Purpose : Accessibility preferences that the rest of the UI honours. Colour-
--           blind players can't tell the red "danger" from the green "success";
--           small fixed text is unreadable on a phone or for low-vision players;
--           motion can trigger nausea. This layers reversible overrides on
--           Gaxia.Theme (colourblind-safe + high-contrast palettes restore from
--           a snapshot, so toggling off returns exactly to base) plus a global
--           TextScale and a ReducedMotion flag that MotionService/tweens check.
--
-- Access  : Gaxia.UI.Accessibility  (client)
--   Gaxia.UI.Accessibility.SetColorblindMode("Deuteranopia")
--   Gaxia.UI.Accessibility.SetTextScale(1.25)
--   if Gaxia.UI.Accessibility.ReducedMotion() then tween:Cancel() end
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local RunService = game:GetService("RunService")

export type Settings = {
	ColorblindMode: string,
	TextScale: number,
	HighContrast: boolean,
	ReducedMotion: boolean,
}

local Accessibility = {}

-- Colourblind-safe overrides for the semantic colours (kept distinguishable per
-- deficiency). "None" is empty → restores the snapshot.
local CB_PALETTES: { [string]: { [string]: Color3 } } = {
	None = {},
	Deuteranopia = { Success = Color3.fromRGB(80, 160, 255), Danger = Color3.fromRGB(255, 160, 40), Warning = Color3.fromRGB(245, 225, 80) },
	Protanopia   = { Success = Color3.fromRGB(70, 150, 255), Danger = Color3.fromRGB(255, 150, 30), Warning = Color3.fromRGB(240, 220, 70) },
	Tritanopia   = { Success = Color3.fromRGB(0, 200, 170),  Danger = Color3.fromRGB(255, 80, 120), Warning = Color3.fromRGB(255, 150, 150) },
}
local CB_KEYS = { "Success", "Danger", "Warning" }

local HIGH_CONTRAST: { [string]: Color3 } = {
	Text           = Color3.fromRGB(255, 255, 255),
	TextMuted      = Color3.fromRGB(225, 225, 225),
	Background     = Color3.fromRGB(0, 0, 0),
	BackgroundDeep = Color3.fromRGB(0, 0, 0),
	Surface        = Color3.fromRGB(35, 35, 35),
}

-- ── Server stub ──
if not RunService:IsClient() then
	return ({
		SetColorblindMode = function() end,
		SetTextScale = function() end,
		GetTextScale = function(): number return 1 end,
		SetHighContrast = function() end,
		SetReducedMotion = function() end,
		ReducedMotion = function(): boolean return false end,
		Get = function(): any return { ColorblindMode = "None", TextScale = 1, HighContrast = false, ReducedMotion = false } end,
		OnChanged = function(): any return function() end end,
	} :: any)
end

-- ── Client implementation ──
local Theme = require(script.Parent.Parent.Parent.Shared.Theme)

-- Snapshot the base colours we override, so toggles are exactly reversible.
local baseColors: { [string]: Color3 } = {}
do
	for _, k in ipairs(CB_KEYS) do
		baseColors[k] = Theme.Color(k)
	end
	for k in pairs(HIGH_CONTRAST) do
		baseColors[k] = Theme.Color(k)
	end
end

local state: Settings = {
	ColorblindMode = "None",
	TextScale = 1,
	HighContrast = false,
	ReducedMotion = false,
}
local listeners: { (s: Settings) -> () } = {}

local function fire(): ()
	for _, fn in ipairs(listeners) do
		local ok, err = pcall(fn, state)
		if not ok then
			warn(`[Accessibility] OnChanged listener errored: {err}`)
		end
	end
end

-- ── Public API ──

function Accessibility.SetColorblindMode(mode: string): ()
	local override = CB_PALETTES[mode]
	if not override then
		warn(`[Accessibility] unknown colorblind mode '{mode}'`)
		return
	end
	local palette: { [string]: Color3 } = {}
	for _, k in ipairs(CB_KEYS) do
		palette[k] = override[k] or baseColors[k]
	end
	Theme.SetTheme({ Color = palette })
	state.ColorblindMode = mode
	fire()
end

function Accessibility.SetTextScale(scale: number): ()
	state.TextScale = math.clamp(scale, 0.5, 2.0)
	fire()
end

function Accessibility.GetTextScale(): number
	return state.TextScale
end

function Accessibility.SetHighContrast(on: boolean): ()
	if on then
		Theme.SetTheme({ Color = HIGH_CONTRAST })
	else
		local restore: { [string]: Color3 } = {}
		for k in pairs(HIGH_CONTRAST) do
			restore[k] = baseColors[k]
		end
		Theme.SetTheme({ Color = restore })
	end
	state.HighContrast = on
	fire()
end

function Accessibility.SetReducedMotion(on: boolean): ()
	state.ReducedMotion = on
	fire()
end

function Accessibility.ReducedMotion(): boolean
	return state.ReducedMotion
end

function Accessibility.Get(): Settings
	return {
		ColorblindMode = state.ColorblindMode,
		TextScale = state.TextScale,
		HighContrast = state.HighContrast,
		ReducedMotion = state.ReducedMotion,
	}
end

-- Returns an unsubscribe function.
function Accessibility.OnChanged(fn: (s: Settings) -> ()): () -> ()
	table.insert(listeners, fn)
	return function()
		local i = table.find(listeners, fn)
		if i then
			table.remove(listeners, i)
		end
	end
end

return Accessibility
