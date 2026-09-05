--!strict
-- ─────────────────────────────────────────────────────────────
-- AntiCheatJournal.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/AntiCheatJournal
-- Purpose : Durability + visibility for AntiCheat. The orchestrator's flags
--           vanished on shutdown (in-memory, cleared on leave) so false
--           positives couldn't be audited and thresholds couldn't be tuned.
--           This subscribes to AntiCheat.OnFlag/OnAction and enforcement
--           decisions, keeps a recent ring buffer + per-player history, and
--           flushes each entry to a pluggable
--           sink (default: warn; games SetSink to DataStore / Messaging / a
--           Discord webhook — the bootstrap's "plug your logger here" slot).
--
-- Access  : Gaxia.Journal  (server)
--   Gaxia.Journal.SetSink(function(entry) postToDiscord(entry) end)
--   for _, e in ipairs(Gaxia.Journal.GetForPlayer(player)) do ... end
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal = SharedPkg.Signal

local MAX_BUFFER: number = 250 -- recent entries kept in memory
local MAX_PER_USER: number = 100 -- bounded player history kept in memory

export type Entry = {
	userId: number,
	name: string,
	reason: string,
	severity: string,
	count: number?,
	kind: string?, -- set for candidate/enforcement entries ("soft"|"hard")
	source: string, -- server | transport | trap | client | client_liveness
	event: "flag" | "candidate" | "enforcement",
	-- Retained for existing sinks: true for a threshold candidate, or an
	-- enforcement decision that actually applied a Kick/Ban.
	action: boolean,
	decision: string?, -- observe | kick | temp_ban | perm_ban | deduped | exempt
	applied: boolean?,
	strikeCount: number?,
	time: number, -- os.time()
}

local Journal = {}

-- (entry)
Journal.OnEntry = Signal.new()

local buffer: { Entry } = {}
local byUser: { [number]: { Entry } } = {}

local sink: (entry: Entry) -> () = function(entry)
	local outcome = if entry.event == "candidate"
		then " CANDIDATE"
		elseif
			entry.event == "enforcement"
		then ` ENFORCEMENT:{entry.decision or "observe"}{if entry.applied
			then " APPLIED"
			else ""}`
		else ""
	warn(
		`[AntiCheatJournal] {entry.name} · {entry.reason} ({entry.severity}{outcome}; source={entry.source})`
	)
end

local GaxiaServer: any = nil
local function server(): any
	if not GaxiaServer then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server")
		GaxiaServer = require(serverInit :: any)
	end
	return GaxiaServer
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
	if #hist > MAX_PER_USER then
		table.remove(hist, 1)
	end
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

-- ── Subscribe to the orchestrator (deferred, off the load metamethod path) ──
local subscribed = false
local function subscribe(): ()
	if subscribed then
		return
	end
	subscribed = true
	local AC = server().AntiCheat
	if not AC then
		return
	end
	if AC.OnFlag then
		AC.OnFlag:Connect(
			function(
				player: Player,
				reason: string,
				severity: string,
				count: number?,
				source: string?
			)
				record({
					userId = player.UserId,
					name = player.Name,
					reason = reason,
					severity = severity,
					count = count,
					source = source or "server",
					event = "flag",
					action = false,
					time = os.time(),
				})
			end
		)
	end
	if AC.OnAction then
		AC.OnAction:Connect(
			function(player: Player, reason: string, kind: string, count: number?, source: string?)
				record({
					userId = player.UserId,
					name = player.Name,
					reason = reason,
					severity = kind,
					count = count,
					kind = kind,
					source = source or "server",
					event = "candidate",
					action = true,
					time = os.time(),
				})
			end
		)
	end

	local Enforcement = server().Enforcement
	if Enforcement and Enforcement.OnDecision then
		Enforcement.OnDecision:Connect(
			function(
				player: Player,
				reason: string,
				kind: string,
				source: string?,
				decision: string,
				applied: boolean,
				strikeCount: number
			)
				record({
					userId = player.UserId,
					name = player.Name,
					reason = reason,
					severity = kind,
					kind = kind,
					source = source or "server",
					event = "enforcement",
					action = applied,
					decision = decision,
					applied = applied,
					strikeCount = strikeCount,
					time = os.time(),
				})
			end
		)
	end
end

task.spawn(subscribe)

return Journal
