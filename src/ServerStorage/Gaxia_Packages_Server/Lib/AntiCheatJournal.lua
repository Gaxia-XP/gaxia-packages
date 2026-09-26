--!strict
-- ─────────────────────────────────────────────────────────────
-- AntiCheatJournal.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/AntiCheatJournal
-- Purpose : Durability + visibility for AntiCheat. The orchestrator's flags
--           vanished on shutdown (in-memory, cleared on leave) so false
--           positives couldn't be audited and thresholds couldn't be tuned.
--           This subscribes to AntiCheat.OnFlag/OnAction, keeps a recent ring
--           buffer + per-player history, and flushes each entry to a pluggable
--           sink (default: warn; games SetSink to DataStore / Messaging / a
--           Discord webhook — the bootstrap's "plug your logger here" slot).
--
-- Access  : Gaxia.Journal  (server)
--   Gaxia.Journal.SetSink(function(entry) postToDiscord(entry) end)
--   for _, e in ipairs(Gaxia.Journal.GetForPlayer(player)) do ... end
--
-- Lifecycle: Start subscribes to AntiCheat.OnFlag/OnAction (not in the default
--            Features: it records from the moment it starts — list "Journal" in
--            Features to record from boot).
-- ─────────────────────────────────────────────────────────────
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Signal    = require(ReplicatedStorage.Gaxia_Packages.Shared.Signal)
local Lifecycle = require(script.Parent.ServiceLifecycle)
-- The orchestrator (not a Need: Start only subscribes to its signals, which never
-- starts AntiCheat).
local AntiCheat = require(script.Parent.Parent.AntiCheat)

local MAX_BUFFER : number = 250  -- recent entries kept in memory

export type Entry = {
	userId: number,
	name: string,
	reason: string,
	severity: string,
	count: number?,
	kind: string?,      -- set for action entries ("soft"|"hard"|"observe")
	action: boolean,    -- true = OnAction entry, false = OnFlag entry
	time: number,       -- os.time()
}

local Journal = {}

-- (entry) for every recorded flag / action
Journal.OnEntry = Signal.new() :: Signal.Signal<Entry>

local buffer: { Entry } = {}
local byUser: { [number]: { Entry } } = {}

local sink: (entry: Entry) -> () = function(entry)
	warn(`[AntiCheatJournal] {entry.name} · {entry.reason} ({entry.severity}{if entry.action then " ACTION" else ""})`)
end

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
	Journal.OnEntry:Fire(entry)
	local ok, err = pcall(sink, entry)
	if not ok then
		warn(`[AntiCheatJournal] sink errored: {err}`)
	end
end

-- ── Public API ──

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
	AntiCheat.OnAction:Connect(function(player: Player, reason: string, kind: string)
		record({ userId = player.UserId, name = player.Name, reason = reason, severity = kind, kind = kind, action = true, time = os.time() })
	end)
end

Lifecycle.Define(Journal, {
	Name = "Journal",
	Needs = {},
	Start = subscribe,
})

return Journal
