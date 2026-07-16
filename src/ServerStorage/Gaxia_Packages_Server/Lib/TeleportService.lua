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
--           erroring. Dependency for PartyService (24.8).
--
-- Access  : Gaxia.Teleport  (server)
--   Gaxia.Teleport.To(player, 123456, { Data = { fromLobby = true } })
--   local code = Gaxia.Teleport.ReserveServer(123456)
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages"):WaitForChild("init")) :: any
local Signal = SharedPkg.Signal

-- ── Lazy server (Config + EConfig) — resolved at CALL-TIME, never module load ──
local ServerStorage = game:GetService("ServerStorage")
local _server: any = nil
local function server(): any
	if not _server then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server"):WaitForChild("init")
		_server = require(serverInit :: any)
	end
	return _server
end

export type TeleportOpts = { Data: any?, ReservedAccessCode: string? }

local Teleport = {}

Teleport.OnTeleportFailed = Signal.new() -- (players, placeId, err)

-- Defaults sourced from Config.Teleport.Retry at CALL-TIME (server package require
-- yields under the loader metamethod, so it can't happen at module load). Built once
-- on first access; Configure() overrides apply on top of the Config-sourced defaults.
local config: { [string]: any } = nil :: any

local function ensureConfig(): { [string]: any }
	if not config then
		local r = (server().Config.Teleport or {}).Retry or {}
		config = {
			MaxAttempts = r.MaxAttempts or 4,
			BaseDelay = r.BaseDelay or 1,   -- seconds
			MaxDelay = r.MaxDelay or 15,
		}
	end
	return config
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

local function toList(players: any): { Player }
	if typeof(players) == "Instance" then
		return { players }
	end
	return players
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

function Teleport.To(players: any, placeId: number, opts: TeleportOpts?): (boolean, any)
	local list = toList(players)
	local options = buildOptions(opts)
	local config = ensureConfig()
	local lastErr: any = nil
	for attempt = 1, config.MaxAttempts do
		local ok, result = pcall(function()
			return TeleportService:TeleportAsync(placeId, list, options)
		end)
		if ok then
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

function Teleport.ToPrivate(players: any, placeId: number, accessCode: string, opts: TeleportOpts?): (boolean, any)
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

function Teleport.GetPlaceInstance(placeId: number, userId: number): (any?, any?, string?)
	local ok, a, b = pcall(function()
		return TeleportService:GetPlayerPlaceInstanceAsync(userId)
	end)
	if not ok then
		return nil, nil, tostring(a)
	end
	return a, b, nil
end

return Teleport
