--!strict
--[[
	String.lua
	Location: ReplicatedStorage/Gaxia_Packages/Shared/Util/String
	Purpose: String manipulation, formatting, and parsing helpers.
	         All functions return new strings (Lua strings are immutable).
--]]

local String = {}

-- ── Constants ──
local DEFAULT_RANDOM_CHARSET: string =
	"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

-- Threshold/divisor pairs for FormatNumber. Order matters (largest first).
local NUMBER_SUFFIXES: {{threshold: number, divisor: number, suffix: string}} = {
	{threshold = 1e12, divisor = 1e12, suffix = "T"},
	{threshold = 1e9,  divisor = 1e9,  suffix = "B"},
	{threshold = 1e6,  divisor = 1e6,  suffix = "M"},
	{threshold = 1e3,  divisor = 1e3,  suffix = "K"},
}

-- ── Trim ──

-- Removes whitespace from both ends.
function String.Trim(s: string): string
	-- %s* on each side; (.-) to capture lazily.
	return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- Removes whitespace only from the left.
function String.TrimStart(s: string): string
	return (s:gsub("^%s+", ""))
end

-- Removes whitespace only from the right.
function String.TrimEnd(s: string): string
	return (s:gsub("%s+$", ""))
end

-- ── Split / Predicates ──

-- Splits `s` on literal `sep` (no patterns). Empty sep returns characters.
function String.Split(s: string, sep: string): {string}
	if sep == "" then
		local out: {string} = table.create(#s)
		for i = 1, #s do
			out[i] = s:sub(i, i)
		end
		return out
	end
	-- string.split is a Roblox built-in that does literal splitting.
	return string.split(s, sep)
end

function String.StartsWith(s: string, prefix: string): boolean
	return s:sub(1, #prefix) == prefix
end

function String.EndsWith(s: string, suffix: string): boolean
	if suffix == "" then return true end
	return s:sub(-#suffix) == suffix
end

-- True if `s` contains `sub` as a literal substring.
function String.Contains(s: string, sub: string): boolean
	-- 1, true → start at 1, plain (no patterns).
	return string.find(s, sub, 1, true) ~= nil
end

-- ── Number formatting ──

-- Formats large numbers as 1.5K / 1M / 1.5B / 1T.
-- Drops trailing ".0" for cleaner display (1.0K → 1K).
function String.FormatNumber(n: number): string
	local abs: number = math.abs(n)
	local sign: string = if n < 0 then "-" else ""
	for _, entry in ipairs(NUMBER_SUFFIXES) do
		if abs >= entry.threshold then
			local scaled: number = abs / entry.divisor
			-- One decimal, then strip ".0".
			local formatted: string = string.format("%.1f", scaled):gsub("%.0$", "")
			return `{sign}{formatted}{entry.suffix}`
		end
	end
	return tostring(n)
end

-- Formats seconds as M:SS or H:MM:SS.
function String.FormatTime(seconds: number): string
	local total: number = math.floor(seconds)
	local hours: number = math.floor(total / 3600)
	local minutes: number = math.floor((total % 3600) / 60)
	local secs: number = total % 60
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, secs)
	end
	return string.format("%d:%02d", minutes, secs)
end

-- Inserts thousands separators: 1234567 → "1,234,567". Negatives supported.
function String.FormatCommas(n: number): string
	local sign: string = if n < 0 then "-" else ""
	local digits: string = tostring(math.abs(n))
	-- Split integer and decimal portions.
	local intPart: string, decPart: string = digits:match("^(%d+)(%.?%d*)$")
	if not intPart then
		return tostring(n)
	end
	-- Walk right-to-left inserting commas every 3 digits.
	local reversed: string = intPart:reverse()
	local withCommas: string = reversed:gsub("(%d%d%d)", "%1,")
	withCommas = withCommas:reverse()
	-- Strip a leading comma left over from reversal (e.g., ",123,456").
	if withCommas:sub(1, 1) == "," then
		withCommas = withCommas:sub(2)
	end
	return `{sign}{withCommas}{decPart or ""}`
end

-- ── Misc ──

-- Naive English pluralization: appends "s" when count != 1.
function String.Pluralize(word: string, count: number): string
	if count == 1 then
		return word
	end
	return word .. "s"
end

-- Uppercases the first character.
function String.Capitalize(s: string): string
	if #s == 0 then return s end
	return s:sub(1, 1):upper() .. s:sub(2)
end

function String.Lower(s: string): string
	return s:lower()
end

function String.Upper(s: string): string
	return s:upper()
end

-- Returns `s` repeated `n` times. n <= 0 returns "".
function String.Repeat(s: string, n: number): string
	if n <= 0 then return "" end
	return string.rep(s, n)
end

-- Random alphanumeric string of `length` from `charset` (default A-Za-z0-9).
function String.RandomString(length: number, charset: string?): string
	local set: string = charset or DEFAULT_RANDOM_CHARSET
	local setLen: number = #set
	if setLen == 0 or length <= 0 then return "" end
	-- table.create + table.concat is far cheaper than concat-in-loop.
	local chars: {string} = table.create(length)
	for i = 1, length do
		local idx: number = math.random(1, setLen)
		chars[i] = set:sub(idx, idx)
	end
	return table.concat(chars)
end

return String
