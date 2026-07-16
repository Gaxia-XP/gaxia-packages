--!strict
--[[
	Math.lua
	Location: ReplicatedStorage/Gaxia_Packages/Shared/Util/Math
	Purpose: Numerical helpers for interpolation, rounding, ranges, and
	         random sampling. All functions are pure.
--]]

local Math = {}

-- ── Interpolation ──

-- Linear interpolation: t=0 → a, t=1 → b. Not clamped.
function Math.Lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Inverse of Lerp: returns the t such that Lerp(a, b, t) == v.
-- Returns 0 when a == b (degenerate range — avoids divide-by-zero).
function Math.InverseLerp(a: number, b: number, v: number): number
	if a == b then
		return 0
	end
	return (v - a) / (b - a)
end

-- ── Rounding ──

-- Rounds to `places` decimal digits (default 0).
function Math.Round(n: number, places: number?): number
	local p: number = places or 0
	local mult: number = 10 ^ p
	return math.floor(n * mult + 0.5) / mult
end

-- Rounds to the nearest multiple of `multiple` (e.g., snap-to-grid in 1D).
function Math.RoundToNearest(n: number, multiple: number): number
	if multiple == 0 then
		return n
	end
	return math.floor(n / multiple + 0.5) * multiple
end

-- Pass-through to math.clamp for naming consistency in the API surface.
function Math.Clamp(n: number, min: number, max: number): number
	return math.clamp(n, min, max)
end

-- ── Range mapping ──

-- Linearly remaps `value` from [inMin, inMax] to [outMin, outMax].
-- Not clamped — caller can wrap with Clamp if needed.
function Math.MapRange(value: number, inMin: number, inMax: number, outMin: number, outMax: number): number
	if inMin == inMax then
		return outMin
	end
	local t: number = (value - inMin) / (inMax - inMin)
	return outMin + (outMax - outMin) * t
end

-- ── Random ──

-- Random float in [min, max].
function Math.RandomFloat(min: number, max: number): number
	return min + math.random() * (max - min)
end

-- Random integer in [min, max], inclusive on both ends.
function Math.RandomInt(min: number, max: number): number
	return math.random(min, max)
end

-- ── Misc ──

-- Returns -1, 0, or 1 based on the sign of `n`.
function Math.Sign(n: number): number
	if n > 0 then return 1 end
	if n < 0 then return -1 end
	return 0
end

-- True iff `n` is NaN. NaN is the only value where n ~= n.
function Math.IsNaN(n: number): boolean
	return n ~= n
end

-- True if |a - b| <= epsilon. Default epsilon = 1e-5 (good for floats).
function Math.Approximately(a: number, b: number, epsilon: number?): boolean
	local eps: number = epsilon or 1e-5
	return math.abs(a - b) <= eps
end

-- Snaps `n` to the nearest grid line at intervals of `gridSize`.
-- Distinct from RoundToNearest only in intent: this names the grid use case.
function Math.Snap(n: number, gridSize: number): number
	if gridSize == 0 then
		return n
	end
	return math.floor(n / gridSize + 0.5) * gridSize
end

return Math
