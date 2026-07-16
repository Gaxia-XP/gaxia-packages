--!strict
-- ─────────────────────────────────────────────────────────────
-- PerformanceBenchmark.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Shared/PerformanceBenchmark.lua
-- Purpose:  Microbenchmark utility — time a function over N
--           iterations and report min/avg/max, or compare two.
-- ─────────────────────────────────────────────────────────────


-- ── Types ──
export type BenchResult = {
	label      : string,
	iterations : number,
	totalMs    : number,
	avgMs      : number,
	minMs      : number,
	maxMs      : number,
}

export type CompareResult = {
	a      : BenchResult,
	b      : BenchResult,
	faster : string,
	ratio  : number,
}

-- ── Constants ──
local DEFAULT_ITERATIONS: number = 1000
local MS_PER_SECOND: number = 1000
local ROUND_DECIMALS: number = 4

local PerformanceBenchmark = {}

-- WHY: format with 4 decimals to expose sub-ms differences without spam.
local function fmt(n: number): string
	return string.format(`%.{ROUND_DECIMALS}f`, n)
end

-- ── Measure ──
-- WHY os.clock() not tick(): os.clock is monotonic and CPU-time based with
-- much higher resolution — essential for sub-millisecond measurements.
function PerformanceBenchmark.Measure(label: string, fn: () -> (), iterations: number?): BenchResult
	local n: number = iterations or DEFAULT_ITERATIONS
	local totalMs: number = 0
	local minMs: number = math.huge
	local maxMs: number = 0

	for _ = 1, n do
		local t0: number = os.clock()
		fn()
		local elapsedMs: number = (os.clock() - t0) * MS_PER_SECOND
		totalMs += elapsedMs
		if elapsedMs < minMs then
			minMs = elapsedMs
		end
		if elapsedMs > maxMs then
			maxMs = elapsedMs
		end
	end

	local avgMs: number = totalMs / n
	local result: BenchResult = {
		label      = label,
		iterations = n,
		totalMs    = totalMs,
		avgMs      = avgMs,
		minMs      = minMs,
		maxMs      = maxMs,
	}

	print(`[Bench] {label}: {n} iters — avg {fmt(avgMs)}ms (min {fmt(minMs)}ms, max {fmt(maxMs)}ms)`)
	return result
end

-- ── Compare ──
function PerformanceBenchmark.Compare(
	a: { label: string, fn: () -> () },
	b: { label: string, fn: () -> () },
	iterations: number?
): CompareResult
	local resA: BenchResult = PerformanceBenchmark.Measure(a.label, a.fn, iterations)
	local resB: BenchResult = PerformanceBenchmark.Measure(b.label, b.fn, iterations)

	local faster: string
	local ratio: number
	if resA.avgMs <= resB.avgMs then
		faster = resA.label
		-- WHY: guard against zero-avg division when fn is essentially a no-op.
		ratio = if resA.avgMs > 0 then resB.avgMs / resA.avgMs else math.huge
		print(`{resA.label} is {fmt(ratio)}x faster than {resB.label}`)
	else
		faster = resB.label
		ratio = if resB.avgMs > 0 then resA.avgMs / resB.avgMs else math.huge
		print(`{resB.label} is {fmt(ratio)}x faster than {resA.label}`)
	end

	local result: CompareResult = {
		a      = resA,
		b      = resB,
		faster = faster,
		ratio  = ratio,
	}
	return result
end

return PerformanceBenchmark
