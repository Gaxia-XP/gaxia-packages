--!strict
--[[
	Module : ClientAntiCheat
	Location: ReplicatedStorage.Gaxia_Packages.Client.ClientAntiCheat
	Purpose : Lightweight client-side detection of common executor artefacts.
	          Reports findings through the bounded AntiCheat.Report Net RPC —
	          server treats these as HINTS, never as ground truth.

	Sampling cadence is intentionally slow (every 5s) — the client is a
	hostile environment, sophisticated cheats will still pass these checks,
	but the cheap ones (getrenv, _G pollution, executor globals, foreign
	ScreenGui injection) get caught for free.

	Reports are deduplicated by kind so we don't spam the server.
]]

local RunService = game:GetService("RunService")

-- WHY this explicit type:
-- The early-return guard below needs to match the module's real return shape
-- so Luau collapses the (server-return | client-return) union into a single
-- typed value. This module intentionally exposes no public methods — the
-- work happens inside background sampler + heartbeat loops at require time.
export type ClientAntiCheat = {}

-- Server-require returns an empty table so other modules can still import.
if not RunService:IsClient() then
	return ({} :: any) :: ClientAntiCheat
end

-- ── Services ──
local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

-- ── Constants ──
local SAMPLE_INTERVAL: number = 5 -- seconds between full scans
local REPORT_COOLDOWN: number = 30 -- seconds; same kind re-reportable only after this
local REPORT_RPC: string = "AntiCheat.Report"
local HEARTBEAT_RPC: string = "AntiCheat.Heartbeat"

-- Executor / debugger globals to look for in _G and shared.
local EXECUTOR_GLOBALS: { [string]: string } = {
	syn = "Synapse",
	["secure_call"] = "Synapse",
	getsynasm = "Synapse",
	["KRNL_LOADED"] = "Krnl",
	getexecutorname = "ExecutorMarker",
	identifyexecutor = "ExecutorMarker",
	is_synapse_function = "Synapse",
}

-- Module
local ClientAntiCheat = {}

local lastSentByKind: { [string]: number } = {}
local seenForeignGuis: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local netService: any? = nil

-- ── Helpers ──

-- Resolve Net only from the background loops below. ClientAntiCheat may be
-- lazy-required through the package loader's non-yielding __index path, while
-- NetService itself can wait for replicated remotes during its first require.
local function getNet(): any?
	if netService then
		return netService
	end
	local packageRoot = script.Parent.Parent
	local shared = packageRoot:FindFirstChild("Shared")
	local netModule = shared and shared:FindFirstChild("NetService")
	if not netModule or not netModule:IsA("ModuleScript") then
		return nil
	end
	local ok, loaded = pcall(require, netModule)
	if ok then
		netService = loaded
		return netService
	end
	return nil
end

-- Send a report unless we've already sent the same kind very recently.
local function report(kind: string, payload: any?): ()
	local now = os.clock()
	local last = lastSentByKind[kind]
	if last and (now - last) < REPORT_COOLDOWN then
		return
	end
	lastSentByKind[kind] = now

	local Net = getNet()
	if Net then
		-- Client evidence is telemetry only. Net gives it the same bounded,
		-- replay-protected transport as every other client-to-server request.
		pcall(function()
			Net.Client.Fire(REPORT_RPC, { kind = kind, payload = payload })
		end)
	end
end

-- ── Detectors ──

-- _G / shared pollution. Native Roblox keeps _G empty unless game code writes
-- to it; many cheats stash bookkeeping there.
local function scanGlobals(): ()
	-- _G is plain table — count entries; >0 means *someone* is writing.
	for key, _ in pairs(_G) do
		-- Whitelist common dev keys you might use legitimately. Default policy:
		-- never write to _G; treat any presence as suspicious.
		report("GlobalPollution", `_G.{tostring(key)}`)
		break -- one report is enough; pollution = pollution
	end
	for key, _ in pairs(shared) do
		report("GlobalPollution", `shared.{tostring(key)}`)
		break
	end
end

-- Executor markers — these globals are inserted by the executor itself and
-- become visible to LocalScripts running in that environment.
local function scanExecutorGlobals(): ()
	for name, kind in pairs(EXECUTOR_GLOBALS) do
		local value = (_G :: any)[name]
		if value == nil then
			-- Some executors hide the global from _G but expose via getfenv.
			local fenv = getfenv(0)
			value = fenv and (fenv :: any)[name]
		end
		if value ~= nil then
			report(kind, `Global '{name}' present`)
		end
	end
end

-- getfenv / getrenv mutation. If the standard library globals get hooked,
-- their `tostring` differs from a freshly-required functions in this script.
local function scanFEnvMutation(): ()
	-- A cheap heuristic: check that `print` is still the standard function
	-- (executors that hook print sometimes change its tostring representation).
	-- This is not bulletproof, but executors rarely bother to spoof tostring.
	local ok, repr = pcall(tostring, print)
	if ok and typeof(repr) == "string" then
		if not repr:match("^function:") then
			-- Non-standard tostring of print → likely hooked.
			report("GetFEnvMutation", `print tostring={repr}`)
		end
	end
end

-- Foreign ScreenGui injection: executors often inject UI into PlayerGui that
-- isn't from StarterGui. We can't be perfect (game code may add UI at runtime),
-- so we only flag ScreenGuis NOT tagged Gaxia_Packages AND with names matching
-- known executor patterns.
local FOREIGN_GUI_NAME_PATTERNS: { string } = {
	"^Syn",
	"Synapse",
	"^Krnl",
	"Executor",
	"^Dex$",
	"^DARK_DEX$",
}

local function scanForeignGui(): ()
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end
	for _, child in ipairs(playerGui:GetChildren()) do
		if child:IsA("ScreenGui") and not seenForeignGuis[child] then
			seenForeignGuis[child] = true
			local name = child.Name
			for _, pattern in ipairs(FOREIGN_GUI_NAME_PATTERNS) do
				if name:match(pattern) then
					report("ScreenGuiInjection", `Name='{name}'`)
					break
				end
			end
		end
	end
end

-- Aggregate sampler. Each branch is pcall-isolated so one detector crashing
-- doesn't take down the others.
local function tick(): ()
	pcall(scanGlobals)
	pcall(scanExecutorGlobals)
	pcall(scanFEnvMutation)
	pcall(scanForeignGui)
end

-- ── Boot ──

task.spawn(function()
	-- Initial warm-up wait so player GUI / scripts have time to settle and we
	-- don't fight other systems for the main thread immediately on join.
	task.wait(SAMPLE_INTERVAL)
	while true do
		tick()
		task.wait(SAMPLE_INTERVAL)
	end
end)

-- ── Heartbeat ──
-- Periodic ping on AntiCheat.Heartbeat proves this module is alive and the
-- channel is intact. HeartbeatGuard (server) flags players whose pings stop
-- (= ClientAntiCheat deleted or script blocked). The report is intentionally
-- telemetry-only: silence is never enough to punish a player automatically.
local HEARTBEAT_INTERVAL: number = 5

task.spawn(function()
	task.wait(SAMPLE_INTERVAL) -- align with first sampler pass
	while true do
		local Net = getNet()
		if Net then
			pcall(function()
				Net.Client.Fire(HEARTBEAT_RPC, {})
			end)
		end
		task.wait(HEARTBEAT_INTERVAL)
	end
end)

return ClientAntiCheat :: ClientAntiCheat
