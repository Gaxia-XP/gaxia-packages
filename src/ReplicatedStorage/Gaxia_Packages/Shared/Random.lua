--!strict
-- ─────────────────────────────────────────────────────────────
-- Random.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Shared/Random
-- Purpose : Seeded, testable RNG wrapper. Named reproducible streams +
--           Int/Float/Bool/Choice/Weighted/Shuffle so loot, crits and spawns
--           are auditable (replay a disputed roll) and unit-testable instead
--           of leaning on unseedable math.random.
--
-- Access  : Gaxia.Random  (shared — client + server)
--   local s = Gaxia.Random.Stream("Loot", 1234)
--   s.Weighted({ {item="A", weight=3}, {item="B", weight=1} })
--   Gaxia.Random.Int(1, 6)   -- default (unseeded) stream
-- ─────────────────────────────────────────────────────────────

-- One Weighted() entry; T = the item's type.
export type WeightedEntry<T = any> = { item: T, weight: number }

export type Stream = {
	Int: (min: number, max: number) -> number,
	Float: (min: number, max: number) -> number,
	Number: () -> number,
	Bool: (chance: number?) -> boolean,
	-- A uniformly random element; nil for an empty list.
	Choice: <T>(list: { T }) -> T?,
	-- A weight-proportional item; nil when no entry has a positive weight.
	Weighted: <T>(entries: { WeightedEntry<T> }) -> T?,
	-- A shuffled COPY (the input is untouched).
	Shuffle: <T>(list: { T }) -> { T },
	Raw: () -> Random,
}

local RandomService = {}

-- Build a Stream wrapping a Roblox Random.
local function makeStream(rng: Random): Stream
	local s = {}

	function s.Int(min: number, max: number): number
		return rng:NextInteger(min, max)
	end
	function s.Float(min: number, max: number): number
		return rng:NextNumber(min, max)
	end
	function s.Number(): number
		return rng:NextNumber()
	end
	function s.Bool(chance: number?): boolean
		return rng:NextNumber() < (chance or 0.5)
	end
	function s.Choice<T>(list: { T }): T?
		if #list == 0 then
			return nil
		end
		return list[rng:NextInteger(1, #list)]
	end
	-- Weighted pick: entries = { { item = X, weight = w }, ... }. Negative weights clamp to 0.
	function s.Weighted<T>(entries: { WeightedEntry<T> }): T?
		local total = 0
		for _, e in ipairs(entries) do
			total += math.max(0, e.weight)
		end
		if total <= 0 then
			return nil
		end
		local r = rng:NextNumber() * total
		local acc = 0
		for _, e in ipairs(entries) do
			acc += math.max(0, e.weight)
			if r <= acc then
				return e.item
			end
		end
		return entries[#entries].item
	end
	-- Fisher–Yates shuffle on a copy (input untouched).
	function s.Shuffle<T>(list: { T }): { T }
		local out = table.clone(list)
		for i = #out, 2, -1 do
			local j = rng:NextInteger(1, i)
			out[i], out[j] = out[j], out[i]
		end
		return out
	end
	function s.Raw(): Random
		return rng
	end

	return s :: Stream
end

-- Deterministic seed from a stream name (so Stream("Loot") is reproducible
-- across servers without an explicit seed).
local function nameToSeed(name: string): number
	local h = 0
	for i = 1, #name do
		h = (h * 31 + string.byte(name, i)) % 2147483647
	end
	return h
end

-- ── Public API ──

-- New stream. Omit seed for a non-deterministic generator.
function RandomService.new(seed: number?): Stream
	if seed ~= nil then
		return makeStream(Random.new(seed))
	end
	return makeStream(Random.new())
end

-- Named reproducible stream, cached so repeated calls share one sequence.
local namedStreams: { [string]: Stream } = {}
function RandomService.Stream(name: string, seed: number?): Stream
	local existing = namedStreams[name]
	if existing then
		return existing
	end
	local s = makeStream(Random.new(seed or nameToSeed(name)))
	namedStreams[name] = s
	return s
end

-- ── Default (unseeded) stream convenience delegators ──
local default = makeStream(Random.new())
RandomService.Int      = default.Int
RandomService.Float    = default.Float
RandomService.Number   = default.Number
RandomService.Bool     = default.Bool
RandomService.Choice   = default.Choice
RandomService.Weighted = default.Weighted
RandomService.Shuffle  = default.Shuffle

return RandomService
