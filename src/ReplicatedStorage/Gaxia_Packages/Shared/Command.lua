--!strict
-- ─────────────────────────────────────────────────────────────
-- Command.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Shared/Command
-- Purpose : High-level command pattern over NetService. Instead of one
--           RemoteEvent per action, the server registers NAMED commands (each
--           with an optional Guard schema + handler) and clients Send(name,
--           payload) through a single channel. Server-authoritative: unknown
--           commands and schema-invalid payloads are dropped; the channel is
--           rate-limited by NetService.
--
-- Access  : Gaxia.Command  (shared)
--   -- server:
--   Gaxia.Command.Register("Buy", {
--     schema  = Gaxia.Guard.strictInterface({ id = Gaxia.Guard.string, qty = Gaxia.Guard.integer }),
--     handler = function(player, payload) shop(player, payload.id, payload.qty) end,
--   })
--   -- client:
--   Gaxia.Command.Send("Buy", { id = "Sword", qty = 1 })
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local RunService = game:GetService("RunService")
local IS_SERVER : boolean = RunService:IsServer()

-- Sibling Shared modules (present, pure-enough bodies → FindFirstChild require).
local Net = require(script.Parent:FindFirstChild("NetService") :: ModuleScript) :: any

local COMMAND_REMOTE : string = "GaxiaCommand"
local CHANNEL_RATE   : number = 30   -- commands/sec/player across the whole channel

export type Command = {
	schema: ((value: any) -> (boolean, string?))?,
	handler: (player: Player, payload: any) -> (),
}

local Command = {}

local commands: { [string]: Command } = {}
local serverWired = false

local function ensureServerChannel(): ()
	if serverWired then
		return
	end
	serverWired = true
	Net.OnServer(COMMAND_REMOTE, function(player: Player, name: any, payload: any)
		if typeof(name) ~= "string" then
			return
		end
		local cmd = commands[name]
		if not cmd then
			return -- unknown command — drop
		end
		if cmd.schema then
			local ok = cmd.schema(payload)
			if not ok then
				return -- payload failed its schema — drop
			end
		end
		cmd.handler(player, payload)
	end, { rate = CHANNEL_RATE })
end

-- ── Public API ──

-- Server: register (or replace) a named command.
function Command.Register(name: string, def: Command): ()
	assert(IS_SERVER, "Command.Register is server-only")
	assert(typeof(name) == "string" and #name > 0, "Command.Register requires a name")
	assert(typeof(def) == "table" and typeof(def.handler) == "function", "Command needs a handler")
	commands[name] = def
	ensureServerChannel()
end

function Command.Unregister(name: string): ()
	commands[name] = nil
end

function Command.IsRegistered(name: string): boolean
	return commands[name] ~= nil
end

-- Client: send a command to the server.
function Command.Send(name: string, payload: any?): ()
	assert(not IS_SERVER, "Command.Send is client-only")
	Net.FireServer(COMMAND_REMOTE, name, payload)
end

return Command
