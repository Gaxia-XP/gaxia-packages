--!strict
-- ─────────────────────────────────────────────────────────────
-- AntiCheatJournal.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/AntiCheatJournal
-- Purpose : Durability + visibility for AntiCheat. The orchestrator's flags
--           vanished on shutdown (in-memory, cleared on leave) so false
--           positives couldn't be audited and thresholds couldn't be tuned.
--           This subscribes to AntiCheat.OnFlag/OnAction, keeps a recent ring
--           buffer + per-player history (the last MAX_PER_PLAYER entries of each
--           player in the server; freed 30 s after they leave), and flushes each
--           entry to a pluggable sink (default: none — nothing in Output; games
--           SetSink to DataStore / Messaging / a Discord webhook, or
--           SetSink(Journal.WarnSink) for one Output line per entry).
--
-- Access  : Gaxia.Journal  (server)
--   Gaxia.Journal.SetSink(function(entry) postToDiscord(entry) end)
--   for _, e in ipairs(Gaxia.Journal.GetForPlayer(player)) do ... end
--
-- Lifecycle: Start subscribes to AntiCheat.OnFlag/OnAction and frees a player's
--            history when they leave. Listed in the default Features, so it
--            records from boot (otherwise from the moment game code touches it).
-- ─────────────────────────────────────────────────────────────
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Signal    = require(ReplicatedStorage.Gaxia_Packages.Shared.Signal)
local Lifecycle = require(script.Parent.ServiceLifecycle)
local Types     = require(script.Parent.Parent.Types)
-- The orchestrator (not a Need: Start only subscribes to its signals, which never
-- starts AntiCheat).
local AntiCheat = require(script.Parent.Parent.AntiCheat)

local MAX_BUFFER     : number = 250 -- recent entries kept in memory (all players)
local MAX_PER_PLAYER : number = 100 -- entries kept per player (GetForPlayer)
local LEAVE_GRACE_SECONDS : number = 30 -- a leaver's history is freed after this

export type Entry = {
	userId: number,
	name: string,
	reason: string,
	severity: string,
	count: number?,
	kind: Types.ActionKind?, -- set for action entries
	action: boolean,    -- true = OnAction entry, false = OnFlag entry
	time: number,       -- os.time()
}

local Journal = {}

-- (entry) for every recorded flag / action
Journal.OnEntry = Signal.new() :: Signal.Signal<Entry>

local buffer: { Entry } = {}
local byUser: { [number]: { Entry } } = {}

-- A sink that warns one Output line per entry (the default sink is silent):
-- Journal.SetSink(Journal.WarnSink).
function Journal.WarnSink(entry: Entry): ()
	warn(`[AntiCheatJournal] {entry.name} · {entry.reason} ({entry.severity}{if entry.action then " ACTION" else ""})`)
end

-- Default: no sink. Every flag already fires OnFlag / OnEntry, and observe-mode
-- hard actions warn once from the orchestrator; a warn per flag spammed Output.
local sink: (entry: Entry) -> () = function(_entry: Entry) end

local function record(entry: Entry): ()
	table.insert(buffer, entry)
	if #buffer > MAX_BUFFER then
		table.remove(buffer, 1)
	end
	local hist = byUser[entry.userId]
	if not hist then
		hist = {}
		byUser[entry.userId] = hist
	end
	table.insert(hist, entry)
	if #hist > MAX_PER_PLAYER then
		table.remove(hist, 1)
	end
	Journal.OnEntry:Fire(entry)
	local ok, err = pcall(sink, entry)
	if not ok then
		warn(`[AntiCheatJournal] sink errored: {err}`)
	end
end

-- ── Public API ──

-- Replace the sink every entry is sent to (one sink: the last call wins).
-- Journal.SetSink(Journal.WarnSink) prints each entry to Output.
function Journal.SetSink(fn: (entry: Entry) -> ()): ()
	if typeof(fn) == "function" then
		sink = fn
	end
end

function Journal.GetRecent(n: number?): { Entry }
	local count = n or #buffer
	local out: { Entry } = {}
	local startIdx = math.max(1, #buffer - count + 1)
	for i = startIdx, #buffer do
		table.insert(out, buffer[i])
	end
	return out
end

-- This player's entries (oldest first, at most the last 100). Kept while they are
-- in the server and for 30 s after they leave.
function Journal.GetForPlayer(player: Player): { Entry }
	return byUser[player.UserId] or {}
end

function Journal.Clear(): ()
	table.clear(buffer)
	table.clear(byUser)
end

-- ── Subscribe to the orchestrator ──
local function subscribe(): ()
	AntiCheat.OnFlag:Connect(function(player: Player, reason: string, severity: string, count: number?)
		record({ userId = player.UserId, name = player.Name, reason = reason, severity = severity, count = count, action = false, time = os.time() })
	end)
	AntiCheat.OnAction:Connect(function(player: Player, reason: string, kind: Types.ActionKind)
		record({ userId = player.UserId, name = player.Name, reason = reason, severity = kind, kind = kind, action = true, time = os.time() })
	end)
	-- Per-player history only for players in the server (GetRecent keeps leavers).
	-- Freed LEAVE_GRACE_SECONDS after they leave, so the game's own PlayerRemoving
	-- handlers can still read it; kept when they rejoin within the grace.
	Players.PlayerRemoving:Connect(function(player: Player)
		local userId = player.UserId
		task.delay(LEAVE_GRACE_SECONDS, function()
			if Players:GetPlayerByUserId(userId) == nil then
				byUser[userId] = nil
			end
		end)
	end)
end

Lifecycle.Define(Journal, {
	Name = "Journal",
	Needs = {},
	Start = subscribe,
})

return Journal
