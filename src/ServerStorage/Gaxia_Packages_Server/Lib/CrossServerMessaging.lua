--!strict
-- ─────────────────────────────────────────────────────────────
-- CrossServerMessaging.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/CrossServerMessaging
-- Purpose : MessagingService wrapper with JSON encode/decode and
--           a token-bucket rate limiter so we stay well under the
--           ~150/min per-server cap and never throw on transient
--           publish failures.
--
-- Lifecycle: pure API (nothing to set up).
-- ─────────────────────────────────────────────────────────────

local MessagingService = game:GetService("MessagingService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Signal    = require(ReplicatedStorage.Gaxia_Packages.Shared.Signal)
local Lifecycle = require(script.Parent.ServiceLifecycle)
local Config    = require(script.Parent.Parent.Config)
local EConfig   = require(script.Parent.EffectiveConfig)

-- Config default <- runtime Flag override via Gaxia.EConfig. Read per-call so an
-- admin can retune the rate limiter live without a redeploy.
-- `configured` is Config.CrossServer[key] (nil falls back to `default`).
local function crossServerCfg(key: string, configured: number?, default: number): number
	return EConfig.Get("CrossServer." .. key, configured or default)
end

-- ── Module ──
local CrossServerMessaging = {}

-- WHY: 2 messages/sec sustained, burst of 10, well under MessagingService's 150/min cap.
local TOKEN_REFILL_PER_SEC: number = 2
local TOKEN_BURST_MAX: number = 10

local tokens: number = TOKEN_BURST_MAX
local lastRefill: number = os.clock()

-- (topic, reason) when a publish is dropped / fails or a received message cannot be handled
CrossServerMessaging.OnError = Signal.new() :: Signal.Signal<string, string>

-- ── Helpers ──

local function refillTokens(): ()
	local now: number = os.clock()
	local elapsed: number = now - lastRefill
	if elapsed > 0 then
		local burstMax: number = crossServerCfg("TokenBurstMax", Config.CrossServer.TokenBurstMax, TOKEN_BURST_MAX)
		local refillPerSec: number = crossServerCfg("TokenRefillPerSec", Config.CrossServer.TokenRefillPerSec, TOKEN_REFILL_PER_SEC)
		tokens = math.min(burstMax, tokens + elapsed * refillPerSec)
		lastRefill = now
	end
end

local function tryConsumeToken(): boolean
	refillTokens()
	if tokens >= 1 then
		tokens -= 1
		return true
	end
	return false
end

local function isPrimitive(v: any): boolean
	local t: string = typeof(v)
	return t == "string" or t == "number" or t == "boolean"
end

-- ── Public API ──

function CrossServerMessaging.Subscribe(topic: string, handler: (data: any, sentTimestamp: number) -> ()): RBXScriptConnection
	-- WHY: MessagingService wraps payloads in {Data, Sent}; we further JSON-decode our envelope.
	local connection: RBXScriptConnection
	local ok, result = pcall(function()
		return MessagingService:SubscribeAsync(topic, function(message: any)
			local raw: any = message.Data
			local sent: number = message.Sent

			local decodeOk, decoded = pcall(function()
				return HttpService:JSONDecode(raw)
			end)
			if not decodeOk then
				CrossServerMessaging.OnError:Fire(topic, `JSONDecode failed: {decoded}`)
				return
			end

			-- Unwrap the {value=...} envelope used for primitives.
			local payload: any = decoded
			if typeof(decoded) == "table" and decoded.__primitive == true then
				payload = decoded.value
			end

			local handlerOk, handlerErr = pcall(handler, payload, sent)
			if not handlerOk then
				CrossServerMessaging.OnError:Fire(topic, `Handler errored: {handlerErr}`)
			end
		end)
	end)

	if not ok then
		CrossServerMessaging.OnError:Fire(topic, `SubscribeAsync failed: {result}`)
		error(`[CrossServerMessaging] SubscribeAsync failed for topic '{topic}': {result}`)
	end

	connection = result :: RBXScriptConnection
	return connection
end

function CrossServerMessaging.Publish(topic: string, data: any): boolean
	if not tryConsumeToken() then
		warn(`[CrossServerMessaging] Rate limit hit, dropping publish to '{topic}'`)
		CrossServerMessaging.OnError:Fire(topic, "Rate limited (token bucket empty)")
		return false
	end

	-- WHY: wrap primitives so subscribers always get a consistent decode shape.
	local toEncode: any = data
	if isPrimitive(data) then
		toEncode = { __primitive = true, value = data }
	end

	local encodeOk, encoded = pcall(function()
		return HttpService:JSONEncode(toEncode)
	end)
	if not encodeOk then
		CrossServerMessaging.OnError:Fire(topic, `JSONEncode failed: {encoded}`)
		return false
	end

	local publishOk, publishErr = pcall(function()
		MessagingService:PublishAsync(topic, encoded)
	end)
	if not publishOk then
		CrossServerMessaging.OnError:Fire(topic, `PublishAsync failed: {publishErr}`)
		return false
	end

	return true
end

-- Pure API: nothing to set up. Registered so Features / IsEnabled know it.
Lifecycle.Define(CrossServerMessaging, {
	Name = "Messages",
	Needs = {},
})

return CrossServerMessaging
