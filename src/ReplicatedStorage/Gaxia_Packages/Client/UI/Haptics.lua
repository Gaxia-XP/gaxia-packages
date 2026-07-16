--!strict
-- ─────────────────────────────────────────────────────────────
-- Haptics.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/Haptics
-- Purpose : Gamepad rumble feedback. Raw HapticService is awkward — you must
--           check IsVibrationSupported, drive Large/Small motors separately,
--           and remember to zero them or the controller buzzes forever. This
--           wraps it: Pulse(intensity,dur) for one-shots, Play("Hit") for named
--           multi-step patterns, a single in-flight effect that Stop() always
--           clears, an enable toggle, and silent no-op when no controller is
--           present (so callers never branch on support).
--
-- Access  : Gaxia.UI.Haptics  (client)
--   Gaxia.UI.Haptics.Play("Hit")
--   Gaxia.UI.Haptics.Pulse(0.6, 0.1)
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local RunService = game:GetService("RunService")

export type Step = { Large: number, Small: number, Duration: number }

local Haptics = {}

-- Named rumble patterns: ordered motor steps (Large = low-freq, Small = high-freq).
local PATTERNS: { [string]: { Step } } = {
	Pickup  = { { Large = 0.0, Small = 0.4, Duration = 0.08 } },
	Hit     = { { Large = 0.7, Small = 0.3, Duration = 0.12 } },
	Success = { { Large = 0.2, Small = 0.6, Duration = 0.10 } },
	Error   = {
		{ Large = 0.5, Small = 0.5, Duration = 0.10 },
		{ Large = 0.0, Small = 0.0, Duration = 0.06 },
		{ Large = 0.5, Small = 0.5, Duration = 0.10 },
	},
}

-- ── Server stub ──
if not RunService:IsClient() then
	return ({
		Pulse = function() end,
		Play = function() end,
		Stop = function() end,
		SetEnabled = function() end,
		IsEnabled = function(): boolean return false end,
		IsSupported = function(): boolean return false end,
		RegisterPattern = function() end,
		GetPatterns = function(): any return {} end,
	} :: any)
end

-- ── Client implementation ──
local HapticService = game:GetService("HapticService")

local GAMEPAD : Enum.UserInputType = Enum.UserInputType.Gamepad1
local LARGE = Enum.VibrationMotor.Large
local SMALL = Enum.VibrationMotor.Small

local enabled : boolean = true
local current: thread? = nil

local function supported(): boolean
	local ok, result = pcall(function()
		return HapticService:IsVibrationSupported(GAMEPAD)
	end)
	return ok and result == true
end

local function zero(): ()
	pcall(function()
		HapticService:SetMotor(GAMEPAD, LARGE, 0)
		HapticService:SetMotor(GAMEPAD, SMALL, 0)
	end)
end

-- ── Public API ──

function Haptics.IsSupported(): boolean
	return supported()
end

function Haptics.IsEnabled(): boolean
	return enabled
end

function Haptics.SetEnabled(on: boolean): ()
	enabled = on
	if not on then
		Haptics.Stop()
	end
end

function Haptics.Stop(): ()
	if current then
		pcall(task.cancel, current)
		current = nil
	end
	zero()
end

-- One-shot: buzz both motors at `intensity` for `duration` (default 0.1s).
function Haptics.Pulse(intensity: number, duration: number?): ()
	if not enabled or not supported() then
		return
	end
	Haptics.Stop()
	local amt = math.clamp(intensity, 0, 1)
	current = task.spawn(function()
		HapticService:SetMotor(GAMEPAD, LARGE, amt)
		HapticService:SetMotor(GAMEPAD, SMALL, amt)
		task.wait(duration or 0.1)
		zero()
		current = nil
	end)
end

-- Play a named multi-step pattern.
function Haptics.Play(name: string): ()
	local steps = PATTERNS[name]
	if not steps then
		warn(`[Haptics] no pattern '{name}'`)
		return
	end
	if not enabled or not supported() then
		return
	end
	Haptics.Stop()
	current = task.spawn(function()
		for _, step in ipairs(steps) do
			HapticService:SetMotor(GAMEPAD, LARGE, math.clamp(step.Large, 0, 1))
			HapticService:SetMotor(GAMEPAD, SMALL, math.clamp(step.Small, 0, 1))
			task.wait(step.Duration)
		end
		zero()
		current = nil
	end)
end

function Haptics.RegisterPattern(name: string, steps: { Step }): ()
	PATTERNS[name] = steps
end

function Haptics.GetPatterns(): { string }
	local names: { string } = {}
	for name in pairs(PATTERNS) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

return Haptics
