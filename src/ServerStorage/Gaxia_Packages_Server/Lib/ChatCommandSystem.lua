--!strict
-- ─────────────────────────────────────────────────────────────
-- Module : ChatCommandSystem
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/ChatCommandSystem
-- Purpose : Parse slash-command chat messages, run typed arg
--           coercion, gate by AdminCommands roles, and dispatch
--           to registered handlers. Supports modern TextChatService
--           with LegacyChat fallback.
-- ─────────────────────────────────────────────────────────────

local Players           = game:GetService("Players")
local TextChatService   = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal    = SharedPkg.Signal

-- Config-driven command prefix (default "/"). FindFirstChild: no-yield require.
local Config = require((script.Parent :: any).Parent:FindFirstChild("Config") :: ModuleScript) :: any
local PREFIX : string = ((Config.Admin or {}) :: any).CommandPrefix or "/"
local PREFIX_LEN : number = #PREFIX

-- ── Lazy AdminCommands ref (sibling in same Lib folder) ──
local _adminRef : any = nil
local function getAdmin(): any
	if _adminRef ~= nil then return _adminRef end
	local lib = (script.Parent :: any)
	local mod = lib:FindFirstChild("AdminCommands")
	if mod and mod:IsA("ModuleScript") then
		local ok, m = pcall(require, mod)
		if ok then _adminRef = m end
	end
	return _adminRef
end

type CmdOpts = {
	roles : { string }?,
	args  : { string }?,
	help  : string?,
}

type CmdEntry = {
	name    : string,
	roles   : { string },
	args    : { string },
	help    : string,
	handler : (caller: Player, args: { string }) -> string?,
}

local commands : { [string]: CmdEntry } = {}

local ChatCommandSystem = {}
ChatCommandSystem.OnCommand = Signal.new()

-- ── Argument type parsers ──
-- WHY: type hints let handlers receive raw strings AND get pre-validation;
-- we return strings (uniform) but ParseArgs gives a typed mixed array.
-- Blank queries and ambiguous prefixes return nil instead of guessing: a blank
-- query used to prefix-match the FIRST player in GetPlayers(), and the first
-- prefix/substring hit silently won by join order (same bug class as
-- AdminCommands.findPlayerByPartialName — keep both resolvers in sync).
local function parsePlayer(s: string): Player?
	local q = (s:match("^%s*(.-)%s*$") or ""):lower()
	if q == "" then return nil end
	for _, p in Players:GetPlayers() do
		if p.Name:lower() == q then return p end
	end
	local match: Player? = nil
	for _, p in Players:GetPlayers() do
		if p.Name:lower():sub(1, #q) == q then
			if match then return nil end -- ambiguous: refuse to guess
			match = p
		end
	end
	if match then return match end
	for _, p in Players:GetPlayers() do
		if p.DisplayName:lower():sub(1, #q) == q then
			if match then return nil end
			match = p
		end
	end
	return match
end

local function parseBool(s: string): boolean
	local low = s:lower()
	return low == "true" or low == "1" or low == "yes"
end

function ChatCommandSystem.ParseArgs(typeList: { string }, argList: { string }): { any }?
	local out : { any } = {}
	for i, t in ipairs(typeList) do
		local raw = argList[i]
		if raw == nil then
			-- WHY: missing optional arg is allowed — handler decides.
			out[i] = nil
		elseif t == "player" then
			local p = parsePlayer(raw)
			if not p then return nil end
			out[i] = p
		elseif t == "number" then
			local n = tonumber(raw)
			if n == nil then return nil end
			out[i] = n
		elseif t == "boolean" then
			out[i] = parseBool(raw)
		else
			out[i] = raw -- "string" or unknown
		end
	end
	return out
end

-- ── Register / Run ──
function ChatCommandSystem.Register(
	name: string,
	opts: CmdOpts,
	handler: (caller: Player, args: { string }) -> string?
): ()
	commands[name:lower()] = {
		name    = name:lower(),
		roles   = opts.roles or {},
		args    = opts.args or {},
		help    = opts.help or "",
		handler = handler,
	}
end

-- WHY splitArgs handles quoted strings: `/say "hello world"` should be one arg.
local function splitArgs(rest: string): { string }
	local out : { string } = {}
	local i = 1
	local n = #rest
	while i <= n do
		local c = rest:sub(i, i)
		if c == " " or c == "\t" then
			i += 1
		elseif c == '"' then
			local j = rest:find('"', i + 1, true)
			if j then
				table.insert(out, rest:sub(i + 1, j - 1))
				i = j + 1
			else
				table.insert(out, rest:sub(i + 1))
				break
			end
		else
			local j = rest:find("%s", i) or (n + 1)
			table.insert(out, rest:sub(i, j - 1))
			i = j
		end
	end
	return out
end

-- Lazily-created RemoteEvent for client-side display. WHY a remote:
-- TextChannel:DisplaySystemMessage is a CLIENT-ONLY API — calling it from this
-- server module never showed anything (the pcall swallowed the failure), so
-- every chat reply ("Permission denied.", /help output, handler responses) was
-- silently dropped. The Gaxia.ChatFeedback client module renders these locally.
local _replyRemote: RemoteEvent? = nil
local function replyRemote(): RemoteEvent
	if _replyRemote then return _replyRemote :: RemoteEvent end
	local events = ReplicatedStorage:FindFirstChild("Events") or Instance.new("Folder")
	events.Name = "Events"
	events.Parent = ReplicatedStorage
	local chatFolder = events:FindFirstChild("Chat") or Instance.new("Folder")
	chatFolder.Name = "Chat"
	chatFolder.Parent = events
	local remote = chatFolder:FindFirstChild("SystemMessage")
	if not (remote and remote:IsA("RemoteEvent")) then
		remote = Instance.new("RemoteEvent")
		remote.Name = "SystemMessage"
		remote.Parent = chatFolder
	end
	_replyRemote = remote :: RemoteEvent
	return _replyRemote :: RemoteEvent
end
-- Create it when the chat system loads, not on the first reply: the client's
-- ChatFeedback waits at most 30 s for Events/Chat/SystemMessage, so a remote that
-- appeared later left every reply after that silently dropped.
replyRemote()

local function reply(caller: Player, text: string?): ()
	if text == nil then return end
	pcall(function()
		replyRemote():FireClient(caller, text)
	end)
end

function ChatCommandSystem.Run(caller: Player, raw: string): boolean
	if raw:sub(1, PREFIX_LEN) ~= PREFIX then return false end
	local body = raw:sub(PREFIX_LEN + 1)
	local spaceIdx = body:find("%s")
	local name : string
	local rest : string
	if spaceIdx then
		name = body:sub(1, spaceIdx - 1)
		rest = body:sub(spaceIdx + 1)
	else
		name = body
		rest = ""
	end
	local cmd = commands[name:lower()]
	if not cmd then
		ChatCommandSystem.OnCommand:Fire(caller, name, {}, false)
		return false
	end
	-- Role gate
	if #cmd.roles > 0 then
		local admin = getAdmin()
		local allowed = false
		if admin then
			for _, role in cmd.roles do
				if admin.IsAtLeast(caller, role) then
					allowed = true
					break
				end
			end
		end
		if not allowed then
			reply(caller, "Permission denied.")
			ChatCommandSystem.OnCommand:Fire(caller, name, {}, false)
			return false
		end
	end
	local argList = splitArgs(rest)
	local ok, response = pcall(function()
		return cmd.handler(caller, argList)
	end)
	if ok then
		if typeof(response) == "string" then
			reply(caller, response)
		end
		ChatCommandSystem.OnCommand:Fire(caller, name, argList, true)
		return true
	else
		warn(`[ChatCommandSystem] handler error in {name}: {tostring(response)}`)
		ChatCommandSystem.OnCommand:Fire(caller, name, argList, false)
		return false
	end
end

-- ── Built-in commands ──
ChatCommandSystem.Register("help", { args = { "string" }, help = "List commands or show help for one" },
	function(_caller: Player, args: { string }): string?
		if args[1] then
			local c = commands[args[1]:lower()]
			if not c then return `Unknown command: {args[1]}` end
			return `/{c.name} — {c.help}`
		end
		local names : { string } = {}
		for n in commands do table.insert(names, n) end
		table.sort(names)
		return `Commands: {table.concat(names, ", ")}`
	end)

ChatCommandSystem.Register("credits", { help = "Show credits" },
	function(_caller: Player, _args: { string }): string?
		return "Powered by Gaxia_Packages"
	end)

-- ── Chat hooks ──
-- WHY both paths: experiences may have TextChatService disabled (LegacyChatService)
-- depending on TextChatService.ChatVersion setting.

-- Server-side intercept: redact the original message if it's a command.
local function hookChannel(channel: Instance): ()
	if not channel:IsA("TextChannel") then return end
	channel.ShouldDeliverCallback = function(msg: TextChatMessage, _target: TextSource): boolean
		local text = msg.Text
		if text:sub(1, PREFIX_LEN) ~= PREFIX then return true end
		local src = msg.TextSource
		if not src then return true end
		local player = Players:GetPlayerByUserId(src.UserId)
		if not player then return true end
		-- WHY task.spawn: ShouldDeliverCallback must return promptly; command may take time.
		task.spawn(function()
			ChatCommandSystem.Run(player, text)
		end)
		return false -- redact original
	end
end

local function tryHookTextChatService(): boolean
	local ok, err = pcall(function()
		-- Wait until channels are populated (TCS sets these up on first message)
		task.spawn(function()
			local channels = TextChatService:WaitForChild("TextChannels", 10)
			if not channels then return end
			-- Hook EVERY text channel — present and future. Only-RBXGeneral meant
			-- a command typed in team chat (RBXTeam<N>) or a whisper didn't run
			-- AND the raw command line (target name + moderation reason) was
			-- delivered verbatim to everyone in that channel.
			for _, ch in ipairs(channels:GetChildren()) do
				hookChannel(ch)
			end
			channels.ChildAdded:Connect(hookChannel)
		end)
	end)
	if not ok then
		warn(`[ChatCommandSystem] TCS hook failed: {tostring(err)}`)
		return false
	end
	return true
end

local function hookLegacyChat(): ()
	local function onPlayer(p: Player)
		p.Chatted:Connect(function(msg: string)
			if msg:sub(1, PREFIX_LEN) == PREFIX then
				ChatCommandSystem.Run(p, msg)
			end
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do onPlayer(p) end
end

-- WHY both: TextChatService is the modern path; legacy Chatted still fires on
-- some legacy-configured experiences. Hooking both is safe — TCS redacts so
-- there's no double-dispatch (legacy Chatted doesn't fire for TCS messages).
tryHookTextChatService()
hookLegacyChat()

return ChatCommandSystem
