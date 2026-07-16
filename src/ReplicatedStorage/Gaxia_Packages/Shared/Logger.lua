--!strict
--[[
	Logger.lua
	Location: ReplicatedStorage/Gaxia_Packages/Shared/Logger
	Purpose: Lightweight leveled logger with scoped child loggers and
	         positional `{}` placeholder substitution.

	Usage:
		local Logger = require(...).Logger -- root singleton
		Logger:Info("Player {} joined with {} coins", player.Name, 100)
		local sub = Logger:Scope("Combat")
		sub:Warn("Hit {} dealt {} damage", target.Name, dmg)
--]]

-- ── Types ──
export type Level = "DEBUG" | "INFO" | "WARN" | "ERROR"

export type Logger = {
	_context: string,
	_root:    any, -- back-reference to the root singleton (where state lives)
	SetLevel:   (self: Logger, level: Level) -> (),
	SetEnabled: (self: Logger, level: Level, enabled: boolean) -> (),
	Scope:      (self: Logger, context: string) -> Logger,
	Debug:      (self: Logger, msg: string, ...any) -> (),
	Info:       (self: Logger, msg: string, ...any) -> (),
	Warn:       (self: Logger, msg: string, ...any) -> (),
	Error:      (self: Logger, msg: string, ...any) -> (),
}

-- ── Level ordering (DEBUG = 1 ... ERROR = 4) ──
local LEVEL_ORDER: { [string]: number } = {
	DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4,
}

local DEFAULT_CONTEXT = "GaxiaPackages"

-- ── Module ──
local Logger = {}
Logger.__index = Logger

-- ── Internal state lives on the root only ──

local function newRoot(context: string): Logger
	local self = setmetatable({
		_context = context,
		_minLevel = 1, -- DEBUG by default; use SetLevel to raise
		_enabled  = { DEBUG = true, INFO = true, WARN = true, ERROR = true },
	}, Logger)
	-- Self-reference so children all read the same state.
	-- rawset avoids the Luau "ambiguous syntax" warning that triggers when a
	-- line starts with `(` after a parenthesised expression on the previous
	-- line — the parser would otherwise read `Logger)(self :: any)` as a call.
	rawset(self :: any, "_root", self)
	return (self :: any) :: Logger
end

-- The exported singleton.
local root: Logger = newRoot(DEFAULT_CONTEXT)

-- ── Helpers ──

-- Replace each `{}` placeholder positionally with tostring(args[i]).
-- Extras are appended as space-separated tail.
local function format(msg: string, ...: any): string
	local args = table.pack(...)
	local i = 0
	local out = (msg:gsub("{}", function()
		i += 1
		return tostring(args[i])
	end))
	-- Append any leftover args so callers don't lose them.
	if i < args.n then
		local tail = {}
		for j = i + 1, args.n do
			tail[#tail + 1] = tostring(args[j])
		end
		out = `{out} {table.concat(tail, " ")}`
	end
	return out
end

-- HH:MM:SS in 24-hour local time. os.date("*t") gives a small struct.
local function timestamp(): string
	local t = os.date("*t") :: any
	return string.format("%02d:%02d:%02d", t.hour, t.min, t.sec)
end

-- ── Configuration ──

function Logger:SetLevel(level: Level): ()
	local r = (self :: any)._root
	r._minLevel = LEVEL_ORDER[level] or 1
end

function Logger:SetEnabled(level: Level, enabled: boolean): ()
	local r = (self :: any)._root
	r._enabled[level] = enabled
end

-- Create a child that shares state but tags messages with `context`.
function Logger:Scope(context: string): Logger
	local child = setmetatable({
		_context = context,
		_root    = (self :: any)._root,
	}, Logger)
	return (child :: any) :: Logger
end

-- ── Internal emit ──

local function emit(self: Logger, level: Level, msg: string, ...: any): ()
	local r = (self :: any)._root
	if not r._enabled[level] then return end
	if (LEVEL_ORDER[level] or 0) < r._minLevel then return end

	local line = `[{level} {timestamp()}] [{(self :: any)._context}] {format(msg, ...)}`

	if level == "ERROR" then
		-- level=2 so the traceback points at the caller, not this file.
		error(line, 2)
	elseif level == "WARN" then
		warn(line)
	else
		print(line)
	end
end

function Logger:Debug(msg: string, ...: any): () emit(self, "DEBUG", msg, ...) end
function Logger:Info (msg: string, ...: any): () emit(self, "INFO",  msg, ...) end
function Logger:Warn (msg: string, ...: any): () emit(self, "WARN",  msg, ...) end
function Logger:Error(msg: string, ...: any): () emit(self, "ERROR", msg, ...) end

return root
