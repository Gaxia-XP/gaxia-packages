--!strict
-- ─────────────────────────────────────────────────────────────
-- TeleportService.lua  (Gaxia.Teleport)
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/TeleportService
-- Purpose : Hardened wrapper over Roblox TeleportService (the repo had none).
--           Raw TeleportAsync throws on transient failures, silently drops
--           teleport data if you forget TeleportOptions, and reserved-server
--           flows are fiddly. This adds: bounded retry with exponential backoff,
--           one-call teleport-data packing, ReserveServer + ToPrivate for
--           co-op/lobby, and GetArrivingData on the receiving side. Everything is
--           pcall-guarded so it degrades to (false, err) in Studio instead of
--           erroring. A teleport that starts but then fails (TeleportInitFailed:
--           Flooded / Failure) is retried with the same backoff; any other
--           failure, or the last retry, fires OnTeleportFailed.
--           Dependency for PartyService (24.8).
--
-- Access  : Gaxia.Teleport  (server)
--   Gaxia.Teleport.To(player, 123456, { Data = { fromLobby = true } })
--   local code = Gaxia.Teleport.ReserveServer(123456)
-- ─────────────────────────────────────────────────────────────
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Signal    = require(ReplicatedStorage.Gaxia_Packages.Shared.Signal)
local Lifecycle = require(script.Parent.ServiceLifecycle)
local Config    = require(script.Parent.Parent.Config)

export type TeleportOpts = { Data: any?, ReservedAccessCode: string? }

local Teleport = {}

-- (players, placeId, err) once To/ToPrivate has used up every retry without success,
-- or when a started teleport fails later (TeleportInitFailed) and is not retried:
-- then players is that one player and err is "<TeleportResult name>: <message>".
Teleport.OnTeleportFailed = Signal.new() :: Signal.Signal<{ Player }, number, any>

-- Teleports that TeleportAsync accepted, per player, until the player leaves (it
-- worked) or TeleportInitFailed gives up on it.
type Pending = { placeId: number, options: TeleportOptions, attempt: number }
local pending: { [Player]: Pending } = {}

-- Defaults sourced from Config.Teleport.Retry on first use (Configure/To/ToPrivate),
-- built once; Configure() overrides apply on top of the Config-sourced defaults.
local config: { [string]: any }? = nil

local function ensureConfig(): { [string]: any }
	local existing = config
	if existing then
		return existing
	end
	local r = Config.Teleport.Retry
	local cfg: { [string]: any } = {
		MaxAttempts = r.MaxAttempts or 4,
		BaseDelay = r.BaseDelay or 1,   -- seconds
		MaxDelay = r.MaxDelay or 15,
	}
	config = cfg
	return cfg
end

function Teleport.Configure(partial: { [string]: any }): ()
	local cfg = ensureConfig()
	for k, v in pairs(partial) do
		cfg[k] = v
	end
end

-- ── PURE: exponential backoff for attempt N (1-based), capped ──
function Teleport.ComputeBackoff(attempt: number, base: number, maxDelay: number): number
	return math.min(base * 2 ^ (attempt - 1), maxDelay)
end

-- ── PURE: whether a TeleportInitFailed result is worth retrying ──
-- Flooded (too many teleport requests) and Failure (a transient error) are retried;
-- the rest (GameFull, GameNotFound, Unauthorized, IsTeleporting, ...) are not.
function Teleport.IsRetryable(result: Enum.TeleportResult): boolean
	return result == Enum.TeleportResult.Flooded or result == Enum.TeleportResult.Failure
end

local function toList(players: Player | { Player }): { Player }
	if typeof(players) == "Instance" then
		return { players :: Player }
	end
	return players :: { Player }
end

local function buildOptions(opts: TeleportOpts?): TeleportOptions
	local options = Instance.new("TeleportOptions")
	if opts then
		if opts.Data ~= nil then
			options:SetTeleportData(opts.Data)
		end
		if opts.ReservedAccessCode then
			options.ReservedServerAccessCode = opts.ReservedAccessCode
		end
	end
	return options
end

-- ── Teleport with retry ──

-- Teleports one player or a group to placeId, retrying a failed request with
-- exponential backoff (Config.Teleport.Retry / Configure). Returns (true,
-- TeleportAsyncResult) once Roblox accepted it, or (false, err) after the last try
-- (OnTeleportFailed fires). A teleport that fails after it was accepted is retried
-- through TeleportInitFailed. Yields.
function Teleport.To(players: Player | { Player }, placeId: number, opts: TeleportOpts?): (boolean, any)
	local list = toList(players)
	local options = buildOptions(opts)
	local config = ensureConfig()
	local lastErr: any = nil
	for attempt = 1, config.MaxAttempts do
		local ok, result = pcall(function()
			return TeleportService:TeleportAsync(placeId, list, options)
		end)
		if ok then
			for _, player in list do
				pending[player] = { placeId = placeId, options = options, attempt = attempt }
			end
			return true, result
		end
		lastErr = result
		if attempt < config.MaxAttempts then
			task.wait(Teleport.ComputeBackoff(attempt, config.BaseDelay, config.MaxDelay))
		end
	end
	Teleport.OnTeleportFailed:Fire(list, placeId, lastErr)
	return false, lastErr
end

-- ── Reserved servers ──

function Teleport.ReserveServer(placeId: number): (string?, string?, string?)
	local ok, code, privateId = pcall(function()
		return TeleportService:ReserveServer(placeId)
	end)
	if not ok then
		return nil, nil, tostring(code)
	end
	return code, privateId, nil
end

function Teleport.ToPrivate(players: Player | { Player }, placeId: number, accessCode: string, opts: TeleportOpts?): (boolean, any)
	local merged: TeleportOpts = {
		Data = opts and opts.Data,
		ReservedAccessCode = accessCode,
	}
	return Teleport.To(players, placeId, merged)
end

-- ── Receiving side ──

function Teleport.GetArrivingData(player: Player): any
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if not ok or typeof(joinData) ~= "table" then
		return nil
	end
	return joinData.TeleportData
end

-- Where user `userId` is playing now: returns (placeId, jobId) of their server, for
-- example to follow a friend with TeleportService:TeleportToPlaceInstance. Pass the
-- place you expect, or 0 for any place: a user in another place returns
-- (nil, nil, "in another place"). Not online, not found or an error: (nil, nil, reason).
-- Yields; never errors.
function Teleport.GetPlaceInstance(placeId: number, userId: number): (number?, string?, string?)
	-- GetPlayerPlaceInstanceAsync returns (isThisServer, errorMessage, placeId, jobId).
	local ok, first, errorMessage, foundPlaceId, jobId = pcall(function()
		return TeleportService:GetPlayerPlaceInstanceAsync(userId)
	end)
	if not ok then
		return nil, nil, tostring(first)
	end
	if typeof(foundPlaceId) ~= "number" or foundPlaceId == 0 or typeof(jobId) ~= "string" or jobId == "" then
		local reason = if typeof(errorMessage) == "string" and errorMessage ~= "" then errorMessage else "not in a game"
		return nil, nil, reason
	end
	if placeId ~= 0 and foundPlaceId ~= placeId then
		return nil, nil, "in another place"
	end
	return foundPlaceId, jobId, nil
end

-- ── Started teleports that fail (TeleportInitFailed) ──

local function onTeleportInitFailed(player: Player, result: Enum.TeleportResult, errorMessage: string, placeId: number): ()
	local entry = pending[player]
	if not entry then
		return -- not a teleport this service started
	end
	local cfg = ensureConfig()
	if Teleport.IsRetryable(result) and entry.attempt < cfg.MaxAttempts and player:IsDescendantOf(Players) then
		entry.attempt += 1
		task.delay(Teleport.ComputeBackoff(entry.attempt - 1, cfg.BaseDelay, cfg.MaxDelay), function()
			if pending[player] ~= entry or not player:IsDescendantOf(Players) then
				return
			end
			local ok, err = pcall(function()
				return TeleportService:TeleportAsync(entry.placeId, { player }, entry.options)
			end)
			if not ok then
				pending[player] = nil
				Teleport.OnTeleportFailed:Fire({ player }, entry.placeId, err)
			end
		end)
		return
	end
	pending[player] = nil
	Teleport.OnTeleportFailed:Fire({ player }, placeId, `{result.Name}: {errorMessage}`)
end

-- Init listens for teleports that fail after TeleportAsync accepted them, and
-- forgets a player's pending teleport when they leave (the teleport worked).
Lifecycle.Define(Teleport, {
	Name = "Teleport",
	Needs = {},
	Init = function()
		TeleportService.TeleportInitFailed:Connect(onTeleportInitFailed)
		Players.PlayerRemoving:Connect(function(player: Player)
			pending[player] = nil
		end)
	end,
})

return Teleport
