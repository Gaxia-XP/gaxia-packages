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
--
-- Lifecycle: Start subscribes to Economy.OnTransaction, Level.OnLevelUp and
--            Quest.OnQuestComplete (subscribing never starts those services).
--            Not in the default Features: list "Analytics" to funnel from boot.
-- ─────────────────────────────────────────────────────────────
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Signal         = require(ReplicatedStorage.Gaxia_Packages.Shared.Signal)
local Lifecycle      = require(script.Parent.ServiceLifecycle)
local EconomyService = require(script.Parent.EconomyService)
local LevelSystem    = require(script.Parent.LevelSystem)
local QuestSystem    = require(script.Parent.QuestSystem)

export type Props = { [string]: any }
export type Sink = (player: Player, event: string, props: Props) -> ()

local Analytics = {}

-- (player, event, props) for every tracked event (props is {} when none were given)
Analytics.OnEvent = Signal.new() :: Signal.Signal<Player, string, Props>

local sink: Sink = function(player, event, props)
	-- Default sink: human-readable print. Replace via SetSink for a real backend.
	print(`[Analytics] {player.Name} · {event}`)
end

-- ── Public API ──

function Analytics.SetSink(fn: Sink): ()
	if typeof(fn) == "function" then
		sink = fn
	end
end

function Analytics.Track(player: Player, event: string, props: Props?): ()
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

-- ── Auto-subscribe the framework's existing signals ──
local function autoSubscribe(): ()
	EconomyService.OnTransaction:Connect(function(player: Player, currency: string, delta: number, newBalance: number, kind: string)
		Analytics.Track(player, "currency_change", { currency = currency, delta = delta, balance = newBalance, kind = kind })
	end)

	LevelSystem.OnLevelUp:Connect(function(player: Player, newLevel: any)
		Analytics.Track(player, "level_up", { level = newLevel })
	end)

	QuestSystem.OnQuestComplete:Connect(function(player: Player, questId: any)
		Analytics.Track(player, "quest_complete", { quest = questId })
	end)
end

Lifecycle.Define(Analytics, {
	Name = "Analytics",
	Needs = {},
	Start = autoSubscribe,
})

return Analytics
