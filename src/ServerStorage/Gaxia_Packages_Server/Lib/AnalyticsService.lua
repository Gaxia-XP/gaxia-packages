--!strict
-- ─────────────────────────────────────────────────────────────
-- AnalyticsService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/AnalyticsService
-- Purpose : Typed event funnel. Track(player, event, props) routes to a single
--           pluggable sink (default: print; games SetSink to GameAnalytics /
--           PlayFab / Roblox AnalyticsService). Auto-subscribes the framework's
--           existing signals (Economy.OnTransaction, Level.OnLevelUp,
--           Quest.OnQuestComplete) so the core funnel works with zero wiring.
--
-- Access  : Gaxia.Analytics  (server)
--   Gaxia.Analytics.SetSink(function(player, event, props) myBackend(player, event, props) end)
--   Gaxia.Analytics.Track(player, "tutorial_step", { step = 3 })
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal = SharedPkg.Signal

local Analytics = {}

-- (player, event, props)
Analytics.OnEvent = Signal.new()

local sink: (player: Player, event: string, props: { [string]: any }) -> () = function(player, event, props)
	-- Default sink: human-readable print. Replace via SetSink for a real backend.
	print(`[Analytics] {player.Name} · {event}`)
end

-- Lazy server loader for auto-subscribe.
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

-- ── Public API ──

function Analytics.SetSink(fn: (player: Player, event: string, props: { [string]: any }) -> ()): ()
	if typeof(fn) == "function" then
		sink = fn
	end
end

function Analytics.Track(player: Player, event: string, props: { [string]: any }?): ()
	if typeof(player) ~= "Instance" or typeof(event) ~= "string" then
		return
	end
	local p = props or {}
	Analytics.OnEvent:Fire(player, event, p)
	local ok, err = pcall(sink, player, event, p)
	if not ok then
		warn(`[Analytics] sink errored for '{event}': {err}`)
	end
end

-- ── Auto-subscribe the framework's existing signals (deferred, off the load path) ──
local subscribed = false
local function autoSubscribe(): ()
	if subscribed then
		return
	end
	subscribed = true
	local G = server()

	local Economy = G.Economy
	if Economy and Economy.OnTransaction then
		Economy.OnTransaction:Connect(function(player: Player, currency: string, delta: number, newBalance: number, kind: string)
			Analytics.Track(player, "currency_change", { currency = currency, delta = delta, balance = newBalance, kind = kind })
		end)
	end

	local Level = G.Level
	if Level and Level.OnLevelUp then
		Level.OnLevelUp:Connect(function(player: Player, newLevel: any)
			Analytics.Track(player, "level_up", { level = newLevel })
		end)
	end

	local Quest = G.Quest
	if Quest and Quest.OnQuestComplete then
		Quest.OnQuestComplete:Connect(function(player: Player, questId: any)
			Analytics.Track(player, "quest_complete", { quest = questId })
		end)
	end
end

task.spawn(autoSubscribe)

return Analytics
