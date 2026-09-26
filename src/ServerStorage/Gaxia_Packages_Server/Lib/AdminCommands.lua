--!strict
-- ─────────────────────────────────────────────────────────────
-- Module : AdminCommands
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/AdminCommands
-- Purpose : Role-gated server-side admin command registry with
--           persistent bans + roles via DataStore. Provides built-in
--           moderation commands (kick/ban/teleport/give/etc.) and an
--           extensible Register() for game-specific commands.
-- ─────────────────────────────────────────────────────────────

local Players              = game:GetService("Players")
local DataStoreService     = game:GetService("DataStoreService")
local ReplicatedStorage    = game:GetService("ReplicatedStorage")
local ServerStorage        = game:GetService("ServerStorage")

-- ── Lazy server (Config + EConfig) ──
-- Call-time only: requiring the server package at module load yields under the
-- loader's no-yield __index metamethod ("attempt to yield across metamethod").
local _server: any = nil
local function server(): any
	if not _server then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server")
		_server = require(serverInit :: any)
	end
	return _server
end

-- ── Shared lib (Signal) ──
local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal    = SharedPkg.Signal

-- ── Lazy direct-path service refs (avoid require recursion) ──
local _itemServiceRef : any = nil
local function getItemService(): any
	if _itemServiceRef ~= nil then return _itemServiceRef end
	local lib = (script.Parent :: any)
	local mod = lib:FindFirstChild("ItemService")
	if mod and mod:IsA("ModuleScript") then
		local ok, m = pcall(require, mod)
		if ok then _itemServiceRef = m end
	end
	return _itemServiceRef
end

local _playerServiceRef : any = nil
local function getPlayerService(): any
	if _playerServiceRef ~= nil then return _playerServiceRef end
	local lib = (script.Parent :: any)
	local mod = lib:FindFirstChild("PlayerService")
	if mod and mod:IsA("ModuleScript") then
		local ok, m = pcall(require, mod)
		if ok then _playerServiceRef = m end
	end
	return _playerServiceRef
end

-- ── Server config (declarative admin surface) ──
-- FindFirstChild (no WaitForChild): loaded under the server loader's no-yield
-- __index; Config sits at the package root and its body is a pure table.
local Config = require((script.Parent :: any).Parent:FindFirstChild("Config") :: ModuleScript) :: any
local AdminConfig = (Config.Admin or {}) :: any

-- Operator kill switch (Config.Admin.Enabled = false). Honored the same way
-- AntiCheat/Webhook honor theirs: Register no-ops, Run refuses, and the side
-- effects below (remote surface, chat bridge, role hooks, creator auto-grant)
-- are skipped. The key existed in Config but was never read — a silently
-- non-functional kill switch on a security-sensitive subsystem.
local ADMIN_ENABLED: boolean = AdminConfig.Enabled ~= false

-- ── Role tier (numeric for easy comparison) ──
-- WHY numeric tiers: a single `>=` check works for arbitrary new roles
-- without exhaustive string comparisons in every handler. Config.Admin.Tiers
-- can add/override tiers (e.g. helper = 1).
local ROLE_TIER : { [string]: number } = {
	default   = 0,
	moderator = 1,
	admin     = 2,
	owner     = 3,
}
if typeof(AdminConfig.Tiers) == "table" then
	for role, tier in pairs(AdminConfig.Tiers) do
		ROLE_TIER[role] = tier
	end
end

-- Alias (alias → real command) + disabled-command sets, built once from Config.
local ALIASES : { [string]: string } = {}
if typeof(AdminConfig.Aliases) == "table" then
	for alias, real in pairs(AdminConfig.Aliases) do
		ALIASES[tostring(alias):lower()] = tostring(real):lower()
	end
end
local DISABLED : { [string]: boolean } = {}
if typeof(AdminConfig.Disabled) == "table" then
	for _, cmdName in ipairs(AdminConfig.Disabled) do
		DISABLED[tostring(cmdName):lower()] = true
	end
end

local _stores = (AdminConfig.Stores or {}) :: any
-- Bans are owned by BanService (Gaxia.Ban) — single source of truth for the
-- whole framework. AdminCommands' /ban /unban commands and the PlayerAdded
-- ban gate delegate to it so the on-disk record shape, in-memory cache,
-- expiresAt-aware IsBanned, and OnBan/OnUnban signals (Webhook auto-report)
-- all stay consistent. AdminCommands still owns Roles persistence directly
-- because it's the role registry.
local ROLES_STORE = DataStoreService:GetDataStore(_stores.Roles or "GaxiaRoles")

-- ── In-memory state ──
local roleByUserId   : { [number]: string }  = {}

type CommandOpts = {
	role    : string,
	args    : { string }?,
	help    : string?,
}

-- Handlers return (message, failed?). The second value marks a REJECTION
-- (guard block, bad input, target not found) as opposed to a success line:
-- Run's pcall can't tell them apart from the string alone, and "didn't error"
-- used to render guard-blocked bans as green success toasts and ✓ audit rows.
type CommandEntry = {
	name    : string,
	role    : string,
	args    : { string },
	help    : string,
	handler : (caller: Player, args: { string }) -> (string?, boolean?),
}

local commands : { [string]: CommandEntry } = {}

local AdminCommands = {}
AdminCommands.OnCommand = Signal.new() -- (caller, name, args, success, message?)

-- ── Role API ──
function AdminCommands.GetRole(player: Player): string
	return roleByUserId[player.UserId] or "default"
end

function AdminCommands.SetRole(userId: number, role: string): ()
	if ROLE_TIER[role] == nil then
		warn(`[AdminCommands] unknown role: {role}`)
		return
	end
	roleByUserId[userId] = role
	-- WHY pcall: DataStore can throw on rate-limit / network; never crash caller.
	task.spawn(function()
		local ok, err = pcall(function()
			ROLES_STORE:SetAsync(tostring(userId), role)
		end)
		if not ok then
			warn(`[AdminCommands] failed to persist role for {userId}: {tostring(err)}`)
		end
	end)
end

function AdminCommands.IsAtLeast(player: Player, role: string): boolean
	local need = ROLE_TIER[role]
	if need == nil then return false end
	local cur = ROLE_TIER[AdminCommands.GetRole(player)] or 0
	return cur >= need
end

-- userId-keyed variants: the escalation exemption needs role answers without a
-- Player instance in hand. These read the IN-MEMORY registry only — a userId
-- that is offline, just-evicted, or whose async DataStore role row hasn't
-- landed yet resolves to "default". Callers must treat a non-staff answer as
-- best-effort, never as proof the user holds no persisted role.
function AdminCommands.GetRoleForUserId(userId: number): string
	return roleByUserId[userId] or "default"
end

function AdminCommands.IsUserIdAtLeast(userId: number, role: string): boolean
	local need = ROLE_TIER[role]
	if need == nil then return false end
	local cur = ROLE_TIER[AdminCommands.GetRoleForUserId(userId)] or 0
	return cur >= need
end

-- ── Lazy ChatCommandSystem ref for the chat bridge ──
-- Direct-path require (avoid GaxiaServer recursion). May be nil if Chat module
-- isn't installed; bridge then becomes a no-op and AdminCommands is callable
-- only via AdminCommands.Run() directly.
local _chatRef : any = nil
local function getChatSystem(): any
	if _chatRef ~= nil then return _chatRef end
	local lib = (script.Parent :: any)
	local mod = lib:FindFirstChild("ChatCommandSystem")
	if mod and mod:IsA("ModuleScript") then
		local ok, m = pcall(require, mod)
		if ok then _chatRef = m end
	end
	return _chatRef
end

-- ── Lazy AntiCheat ref for the admin-action whitelist ──
-- WHY: admin commands (/speed, /teleport, /give, /respawn ...) legitimately
-- mutate state that anti-cheat detectors are designed to flag. Without a
-- whitelist hook those detectors will (correctly!) flag the very same player
-- the admin just modified and the orchestrator may kick them. We resolve the
-- AntiCheat orchestrator lazily because it sits in a sibling folder, not in
-- Lib/ — and we cannot use GaxiaServer here without risking require recursion.
local _antiCheatRef : any = nil
local function getAntiCheat(): any
	if _antiCheatRef ~= nil then return _antiCheatRef end
	local pkgRoot = (script.Parent :: any).Parent     -- Gaxia_Packages_Server
	local acFolder = pkgRoot and pkgRoot:FindFirstChild("AntiCheat")
	local initMod  = acFolder and acFolder
	if initMod and initMod:IsA("ModuleScript") then
		local ok, m = pcall(require, initMod)
		if ok then _antiCheatRef = m end
	end
	return _antiCheatRef
end

-- Reason families whitelisted around admin actions. Matching is family-aware
-- (AntiCheat loader isWhitelisted): an entry covers the bare reason AND every
-- namespaced "<entry>:<kind>" variant a detector emits (HumanoidState:Climbing,
-- Heuristic:SustainedSpeed, ...). Extra entries are harmless; a missing entry
-- means an admin action can still be flagged by that detector.
-- DELIBERATELY EXCLUDED: "ClientReport" (ExploitSignatureScanner) — client
-- executor reports must never be masked by an admin action, or /speed on a
-- target would hide a live executor detection for the whitelist window.
local ADMIN_WHITELIST_REASONS : { string } = {
	"Speed", "Fly", "NoClip", "Teleport",
	"StatTamper", "Heartbeat", "HumanoidState",
	"Combat", "Backpack", "ToolDupe",
	"Animation", "RemoteRate",
	"Heuristic", "WorldBounds",
}

-- Whitelist `player` from every AntiCheat reason for `duration` seconds, and
-- wipe any pending flag counts so the orchestrator does not act on stale
-- counts that crossed the threshold *before* the admin action.
local function whitelistAdminAction(player: Player?, duration: number)
	if player == nil then return end
	local ac = getAntiCheat()
	if not ac then return end
	for _, reason in ipairs(ADMIN_WHITELIST_REASONS) do
		if ac.Whitelist then ac.Whitelist(player, reason, duration) end
		if ac.ClearFlags then ac.ClearFlags(player, reason) end
	end
end

-- How long an admin action's effect is "protected" from anti-cheat. Long
-- enough to actually test a /speed change end-to-end, short enough that a
-- compromised admin account cannot stay invisible to detectors indefinitely.
-- Read at call-time from central Config (default unchanged at 30s).
local DEFAULT_ADMIN_ACTION_WHITELIST_SECONDS : number = 30
local function adminActionWhitelistSeconds(): number
	local s = server()
	local v = tonumber(s.EConfig.Get(
		"Admin.ActionWhitelistSeconds",
		(s.Config.Admin or {}).ActionWhitelistSeconds or DEFAULT_ADMIN_ACTION_WHITELIST_SECONDS
	))
	-- Coerce: a runtime "/flag set" override is stored unvalidated, and an
	-- omitted value parses to boolean true. Un-coerced, that value reached
	-- AntiCheat.Whitelist's os.clock()+duration arithmetic and errored BEFORE
	-- Run's handler pcall — killing every admin command including the
	-- "/flag clear" recovery until server restart. Degrade to the default.
	if v == nil or v ~= v then
		return DEFAULT_ADMIN_ACTION_WHITELIST_SECONDS
	end
	return v
end

-- ── Register ──
-- WHY this also forwards into ChatCommandSystem:
-- Every admin command must be reachable from in-game chat (`/speed Player 100`).
-- The chat bridge registers a thin pass-through that lets ChatCommandSystem
-- gate by role + split args, then re-enters AdminCommands.Run with the raw
-- string list (so AdminCommands' own player-name resolution still applies).
function AdminCommands.Register(
	name: string,
	opts: CommandOpts,
	handler: (caller: Player, args: { string }) -> (string?, boolean?)
): ()
	if not ADMIN_ENABLED then return end
	local lname = name:lower()
	commands[lname] = {
		name    = lname,
		role    = opts.role,
		args    = opts.args or {},
		help    = opts.help or "",
		handler = handler,
	}

	-- Forward into chat. The bridge handler returns Run's descriptive message so
	-- ChatCommandSystem.reply delivers the real outcome — success line, guard
	-- rejection, "disabled" — to the caller. (It used to return nil: every
	-- chat-issued admin command was completely silent, success and guard-block
	-- indistinguishable.)
	local chat = getChatSystem()
	if chat and chat.Register then
		local function bridge(chatName: string)
			chat.Register(chatName, {
				roles = { opts.role },
				args  = {},                 -- pass through raw strings; AdminCommands parses itself
				help  = opts.help or "",
			}, function(caller, argList)
				local ok, message = AdminCommands.Run(caller, lname, argList)
				return message or (if ok then nil else `/{lname} failed.`)
			end)
		end
		bridge(lname)
		-- Config.Admin.Aliases resolve inside Run, but chat dispatch needs its
		-- own registration per alias or "/sp ..." dies in ChatCommandSystem as
		-- an unknown command before ever reaching Run.
		for alias, real in pairs(ALIASES) do
			if real == lname then
				bridge(alias)
			end
		end
	end
end

-- ── Helpers ──
-- WHY `caller` is optional: most call sites have access to the player issuing
-- the command and want "me" / "self" / "." to resolve to themselves. When
-- caller is nil (e.g. console-style invocations with no actor), the aliases
-- silently fall through to normal name matching.
local SELF_ALIASES : { [string]: boolean } = {
	["me"]   = true,
	["self"] = true,
	["."]    = true,
}

-- Marks a handler return as a rejection (see CommandEntry.handler). Use for
-- every "the command did NOT do its job" return; plain `return message` keeps
-- meaning success.
local function fail(message: string?): (string?, boolean)
	return message, true
end

-- Returns (player, nil) on a unique match, (nil, reason) otherwise. The reason
-- distinguishes blank and ambiguous targets from plain not-found so destructive
-- commands never guess: a blank query used to prefix-match the FIRST player in
-- GetPlayers() (sub(1, 0) == "" is true for everyone), and an ambiguous prefix
-- silently picked join order — both could kick/ban the wrong player.
local function findPlayerByPartialName(query: string, caller: Player?): (Player?, string?)
	local q = (query:match("^%s*(.-)%s*$") or ""):lower()
	if q == "" then
		return nil, "No target player specified."
	end
	if caller and SELF_ALIASES[q] then return caller, nil end
	-- Exact match wins
	for _, p in Players:GetPlayers() do
		if p.Name:lower() == q then return p, nil end
	end
	-- Unique username prefix; only when none, unique DisplayName prefix.
	local matches: { Player } = {}
	for _, p in Players:GetPlayers() do
		if p.Name:lower():sub(1, #q) == q then table.insert(matches, p) end
	end
	if #matches == 0 then
		for _, p in Players:GetPlayers() do
			if p.DisplayName:lower():sub(1, #q) == q then table.insert(matches, p) end
		end
	end
	if #matches == 1 then return matches[1], nil end
	if #matches > 1 then
		local names: { string } = {}
		for i = 1, math.min(#matches, 5) do names[i] = matches[i].Name end
		return nil, `Ambiguous target "{query}" matches {#matches} players: {table.concat(names, ", ")}`
	end
	return nil, `Player not found: {query}`
end

-- ── Run ──
-- Returns (ok, message?). `ok` is true only when the command actually did its
-- job: handler errors AND explicit rejections (handlers returning a second
-- value of true via fail()) both yield false. `message` is the descriptive
-- result string — a success line like "Banned X", or a rejection like
-- "You can't target yourself" — surfaced so the Admin Panel toast and chat
-- reply show the real outcome with the right styling.
function AdminCommands.Run(caller: Player, name: string, argList: { string }): (boolean, string?)
	if not ADMIN_ENABLED then
		return false, "Admin system is disabled."
	end
	-- Resolve Config.Admin.Aliases, then reject Config.Admin.Disabled commands.
	local lname = name:lower()
	lname = ALIASES[lname] or lname
	if DISABLED[lname] then
		AdminCommands.OnCommand:Fire(caller, name, argList, false, "That command is disabled.")
		return false, "That command is disabled."
	end
	local cmd = commands[lname]
	if not cmd then
		AdminCommands.OnCommand:Fire(caller, name, argList, false, `Unknown command: /{lname}`)
		return false, `Unknown command: /{lname}`
	end
	if not AdminCommands.IsAtLeast(caller, cmd.role) then
		AdminCommands.OnCommand:Fire(caller, name, argList, false, `You don't have permission to run /{lname}.`)
		return false, `You don't have permission to run /{lname}.`
	end

	-- ── Self-alias rewrite ──
	-- Rewrite "me" / "self" / "." in any arg slot to the caller's username so
	-- every handler's own findPlayerByPartialName(args[i]) lookup just works
	-- without each handler having to know about aliases. We mutate argList in
	-- place because it is constructed per-call (ChatCommandSystem.splitArgs).
	for i, raw in ipairs(argList) do
		if SELF_ALIASES[raw:lower()] then
			argList[i] = caller.Name
		end
	end

	-- ── Anti-cheat whitelist (before the handler) ──
	-- WHY before-handler: detectors may run on the *next* sampler tick (every
	-- SAMPLER_INTERVAL ≈ 0.5s) — that tick can land before our handler returns
	-- if the handler yields. Pre-whitelisting closes that window. We always
	-- whitelist the caller (admin may target themselves: `/speed me 200`) AND
	-- the first arg if it resolves to a player (most commands' target slot).
	-- pcall: a whitelist failure (bad runtime flag, AntiCheat API drift) must
	-- never block command dispatch — this code runs before the handler pcall,
	-- and an error here once locked out every command incl. the recovery one.
	local wlOk, wlErr = pcall(function()
		local whitelistSeconds = adminActionWhitelistSeconds()
		whitelistAdminAction(caller, whitelistSeconds)
		local target = if argList[1] ~= nil then findPlayerByPartialName(argList[1], caller) else nil
		if target and target ~= caller then
			whitelistAdminAction(target, whitelistSeconds)
		end
	end)
	if not wlOk then
		warn(`[AdminCommands] anti-cheat whitelist failed (continuing): {tostring(wlErr)}`)
	end

	local ok, result, failed = pcall(function()
		return cmd.handler(caller, argList)
	end)
	-- succeeded = ran without erroring AND was not an explicit rejection.
	local succeeded = ok and failed ~= true
	-- On a normal return `result` is the handler's message (success line or
	-- rejection text); on error it's the error text (warned, not surfaced).
	local message = (ok and typeof(result) == "string") and result or nil
	AdminCommands.OnCommand:Fire(caller, name, argList, succeeded, message)
	if not ok then
		warn(`[AdminCommands] handler error in {name}: {tostring(result)}`)
	end
	return succeeded, message
end

-- ── Moderation guard ──
-- Protect destructive actions (ban/kick) from being aimed at yourself, the
-- place owner, or anyone of equal-or-higher rank. Returns an error string to
-- show the caller when the action is blocked, or nil when it's allowed. This is
-- the SINGLE guard for both chat commands and the Admin Panel — the panel's
-- `run` envelope re-enters these same handlers, so the protection covers both.
-- WHY each rule:
--   • self      — stops the classic "I banned myself and got locked out" footgun.
--   • creator   — the place owner must never be bannable by a delegated admin
--                 (belt-and-suspenders: the rank rule already blocks an owner-
--                 tier target, but this also holds if AutoGrantCreator is off or
--                 the creator's role row hasn't loaded yet).
--   • rank      — a delegated admin can't ban/kick an equal or a superior, so a
--                 compromised admin account can't take down the owner or peers.
local function protectTarget(caller: Player, target: Player): string?
	if target.UserId == caller.UserId then
		return "You can't target yourself with that."
	end
	if game.CreatorType == Enum.CreatorType.User and target.UserId == game.CreatorId then
		return "You can't target the place owner."
	end
	local callerTier = ROLE_TIER[AdminCommands.GetRole(caller)] or 0
	local targetTier = ROLE_TIER[AdminCommands.GetRole(target)] or 0
	if targetTier >= callerTier then
		return "You can't target someone of equal or higher rank."
	end
	return nil
end

-- Public wrapper: extension command packs (e.g. AntiCheatAdmin's /acban)
-- register their own destructive commands and must apply the SAME target
-- protection — a second ban entry point without this guard is how a delegated
-- admin bans the owner.
function AdminCommands.ProtectTarget(caller: Player, target: Player): string?
	return protectTarget(caller, target)
end

-- ── Built-in commands ──

-- /kick <player> [reason]
AdminCommands.Register("kick", { role = "moderator", args = { "player", "string" }, help = "Kick a player" },
	function(caller: Player, args: { string }): string?
		local target, why = findPlayerByPartialName(args[1] or "")
		if not target then return fail(why) end
		local blocked = protectTarget(caller, target)
		if blocked then return fail(blocked) end
		-- Greedy tail-join: chat splits unquoted words into separate args, so
		-- "/kick Bob being toxic" used to kick with reason "being". Reason is
		-- the last declared parameter, so joining the remainder is safe.
		local reason = if #args >= 2 then table.concat(args, " ", 2) else "Kicked by moderator"
		target:Kick(reason)
		return `Kicked {target.Name}`
	end)

-- /ban <player> [reason]
-- Delegates to BanService.Ban — one ban code path for the whole framework.
-- BanService.Ban persists the table-shape record, fires OnBan (Webhook auto-
-- report), updates BanService's session cache, and kicks the player itself.
AdminCommands.Register("ban", { role = "admin", args = { "player", "string" }, help = "Ban a player (persistent)" },
	function(caller: Player, args: { string }): string?
		local target, why = findPlayerByPartialName(args[1] or "")
		if not target then return fail(why) end
		local blocked = protectTarget(caller, target)
		if blocked then return fail(blocked) end
		-- Greedy tail-join (see /kick): the ban record + webhook report used to
		-- persist only the first word of an unquoted multi-word reason.
		local reason = if #args >= 2 then table.concat(args, " ", 2) else "Banned"
		local persisted = server().Ban.Ban(target.UserId, reason)
		if persisted == false then
			-- The kick happened, but the DataStore write failed (or no store):
			-- this ban dies with the server. Don't let the admin believe otherwise.
			return `Banned {target.Name} — WARNING: not persisted (session-only)`
		end
		return `Banned {target.Name}`
	end)

-- /unban <userId>
-- Delegates to BanService.Unban — clears BanService's cache + DataStore +
-- fires OnUnban for Webhook auto-report. There is no AdminCommands-owned
-- ban state left to clear.
AdminCommands.Register("unban", { role = "admin", args = { "number" }, help = "Unban a userId" },
	function(_caller: Player, args: { string }): string?
		local uid = tonumber(args[1])
		if not uid then return fail("Invalid userId") end
		local persisted = server().Ban.Unban(uid)
		if persisted == false then
			return `Unbanned {uid} — WARNING: persisted record removal failed; the ban may re-apply elsewhere`
		end
		return `Unbanned {uid}`
	end)

-- /give <player> <itemId> [count]
AdminCommands.Register("give", { role = "admin", args = { "player", "string", "number" }, help = "Give items" },
	function(_caller: Player, args: { string }): string?
		local target, why = findPlayerByPartialName(args[1] or "")
		if not target then return fail(why) end
		local itemId = args[2]
		if itemId == nil or itemId:match("^%s*$") then
			return fail("No itemId specified.")
		end
		-- Validate the count instead of silently coercing: tonumber("nan") is NaN
		-- (truthy, so `or 1` never saves it), fractions floor silently downstream,
		-- and non-numeric input used to become 1 without telling the caller.
		local count = 1
		if args[3] ~= nil then
			local n = tonumber(args[3])
			if n == nil or n ~= n or n == math.huge or n ~= math.floor(n) or n < 1 then
				return fail(`Invalid count: {args[3]} (need a positive integer)`)
			end
			count = n
		end
		-- Catalog check is opt-in: games that never register item definitions
		-- keep free-form ids; once a catalog exists, typos are rejected instead
		-- of minting phantom persistent inventory keys.
		local itemDef = server().ItemDef
		if itemDef and itemDef.Count() > 0 and not itemDef.Has(itemId) then
			return fail(`Unknown item: {itemId}`)
		end
		local itemSvc = getItemService()
		if itemSvc and itemSvc.Give then
			local ok, delta = itemSvc.Give(target, itemId, count)
			if not ok then
				return fail(`Could not give {itemId} to {target.Name} (inventory not loaded yet?)`)
			end
			local delivered = delta or count
			if delivered ~= count then
				return `Gave {delivered}x {itemId} to {target.Name} (requested {count}, stack clamped)`
			end
			return `Gave {delivered}x {itemId} to {target.Name}`
		end
		return fail("ItemService not available")
	end)

-- /teleport <player> <targetPlayer>
AdminCommands.Register("teleport", { role = "moderator", args = { "player", "player" }, help = "Teleport A to B" },
	function(_caller: Player, args: { string }): string?
		local who, whyWho = findPlayerByPartialName(args[1] or "")
		if not who then return fail(whyWho) end
		local to, whyTo = findPlayerByPartialName(args[2] or "")
		if not to then return fail(whyTo) end
		-- Destination is the TARGET's CFrame, offset back 3 studs so the two
		-- characters don't spawn inside each other. PlayerService.Teleport takes
		-- (player, CFrame) — passing the `to` Player directly is the bug that
		-- raised "CoordinateFrame expected, got Instance".
		local toChar = to.Character
		local toHRP = toChar and toChar:FindFirstChild("HumanoidRootPart")
		if not toHRP then
			return fail(`{to.Name} has no character to teleport to`)
		end
		local dest = (toHRP :: BasePart).CFrame + Vector3.new(0, 0, 3)

		local ps = getPlayerService()
		if ps and ps.Teleport then
			-- Preferred: PlayerService.Teleport also whitelists the AntiCheat
			-- Teleport detector so the moved player isn't flagged for the jump.
			ps.Teleport(who, dest)
		else
			-- Fallback direct teleport (PlayerService not installed). Note: this
			-- path does NOT whitelist anti-cheat — PlayerService is eager-loaded
			-- at boot, so it effectively never runs.
			local fromChar = who.Character
			local hrp1 = fromChar and fromChar:FindFirstChild("HumanoidRootPart")
			if not hrp1 then
				return fail(`{who.Name} has no character to teleport`)
			end
			(hrp1 :: BasePart).CFrame = dest
		end
		return `Teleported {who.Name} to {to.Name}`
	end)

-- /speed <player> <number>
AdminCommands.Register("speed", { role = "admin", args = { "player", "number" }, help = "Set WalkSpeed" },
	function(_caller: Player, args: { string }): string?
		local target, why = findPlayerByPartialName(args[1] or "")
		if not target then return fail(why) end
		-- Validate instead of silently defaulting to 16: negative WalkSpeed gets
		-- the target anti-cheat flagged and kicked once the admin whitelist
		-- window expires (detector baseline floors at 8 while |speed| is real).
		local n = tonumber(args[2])
		if n == nil or n ~= n or n == math.huge or n < 0 then
			return fail(`Invalid speed: {args[2] or ""} (need a finite number >= 0)`)
		end
		-- No-character guard: SetWalkSpeed resolves the humanoid with a bounded
		-- wait; refuse up front so the command replies instantly and truthfully.
		if not target.Character then
			return fail(`{target.Name} has no character`)
		end
		local ps = getPlayerService()
		if ps and ps.SetWalkSpeed then
			local ok, applied = ps.SetWalkSpeed(target, n)
			if not ok then
				return fail(`Could not set WalkSpeed — {target.Name} has no humanoid`)
			end
			if applied ~= nil and applied ~= n then
				return `Set {target.Name}.WalkSpeed = {applied} (requested {n}, clamped)`
			end
		else
			local char = target.Character
			local hum  = char and char:FindFirstChildOfClass("Humanoid") :: Humanoid?
			if not hum then return fail(`{target.Name} has no humanoid`) end
			hum.WalkSpeed = n
		end
		return `Set {target.Name}.WalkSpeed = {n}`
	end)

-- /heal <player>
AdminCommands.Register("heal", { role = "moderator", args = { "player" }, help = "Heal to full" },
	function(_caller: Player, args: { string }): string?
		local target, why = findPlayerByPartialName(args[1] or "")
		if not target then return fail(why) end
		local char = target.Character
		local hum  = char and char:FindFirstChildOfClass("Humanoid") :: Humanoid?
		if not hum then
			return fail(`{target.Name} has no character to heal`)
		end
		if hum.Health <= 0 then
			-- Setting Health on a Dead-state Humanoid does not revive it — the
			-- old unconditional "Healed X" was a lie for exactly the most common
			-- use of /heal (someone just died).
			return fail(`{target.Name} is dead — use /respawn`)
		end
		hum.Health = hum.MaxHealth
		return `Healed {target.Name}`
	end)

-- /respawn <player>
AdminCommands.Register("respawn", { role = "moderator", args = { "player" }, help = "Force respawn" },
	function(_caller: Player, args: { string }): string?
		local target, why = findPlayerByPartialName(args[1] or "")
		if not target then return fail(why) end
		target:LoadCharacter()
		return `Respawned {target.Name}`
	end)

-- /role <player> <roleName>
AdminCommands.Register("role", { role = "owner", args = { "player", "string" }, help = "Set player role" },
	function(caller: Player, args: { string }): string?
		local target, why = findPlayerByPartialName(args[1] or "")
		if not target then return fail(why) end
		-- Same guard as /ban /kick: no self (a bare "/role me" used to silently
		-- self-demote because args[2] defaulted to "default"), no creator, no
		-- equal-or-higher rank — an owner cannot demote a peer owner.
		local blocked = protectTarget(caller, target)
		if blocked then return fail(blocked) end
		local role = args[2]
		if role == nil or role:match("^%s*$") then
			return fail("Usage: /role <player> <roleName>")
		end
		if ROLE_TIER[role] == nil then return fail(`Unknown role: {role}`) end
		-- No minting peers: a freshly granted equal rank could immediately
		-- demote the grantor (irreversible escalation while no other owner is
		-- around). Additional owners are seeded via Config.Admin.Bootstrap.
		local callerTier = ROLE_TIER[AdminCommands.GetRole(caller)] or 0
		if (ROLE_TIER[role] or 0) >= callerTier then
			return fail("You can't grant a role at or above your own. Seed peers via Config.Admin.Bootstrap.")
		end
		-- A demotion below a Bootstrap floor doesn't stick — the floor re-applies
		-- in memory on every join and the persisted row is upgrade-only on load.
		-- Refuse with the reason instead of reporting a change that reverts.
		if typeof(AdminConfig.Bootstrap) == "table" then
			local seeded = (AdminConfig.Bootstrap :: any)[target.UserId]
			if typeof(seeded) == "string" and (ROLE_TIER[role] or 0) < (ROLE_TIER[seeded] or 0) then
				return fail(`{target.Name} is Bootstrap-floored to {seeded} — the change would revert on next join. Edit Config.Admin.Bootstrap to demote.`)
			end
		end
		AdminCommands.SetRole(target.UserId, role)
		return `Set {target.Name} role = {role}`
	end)

-- ── Persistence: load roles, enforce on join ──
-- WHY load lazily per-player on PlayerAdded instead of bulk-listing: DataStore
-- has no efficient "list all keys" — we check the specific userId at join.
-- Ban enforcement is owned by BanService.gate (see BanService.lua) so the
-- entire stack shares one ban code path with consistent record shape,
-- expiresAt-aware IsBanned, session cache, and OnBan/OnUnban signals.
-- BanService is eager-loaded by Gaxia_ServerBootstrap BEFORE Admin, so its
-- gate is connected before AdminCommands ever runs.
local function loadPersistedRole(p: Player)
	task.spawn(function()
		local ok, role = pcall(function()
			return ROLES_STORE:GetAsync(tostring(p.UserId))
		end)
		if ok and typeof(role) == "string" and ROLE_TIER[role] ~= nil then
			-- Upgrade-only: a persisted role may PROMOTE a player but must never
			-- demote below a sync-applied Bootstrap/creator floor (set before this
			-- async load lands).
			local current = ROLE_TIER[roleByUserId[p.UserId] or "default"] or 0
			if (ROLE_TIER[role] or 0) > current then
				roleByUserId[p.UserId] = role
			end
		end
	end)
end
if ADMIN_ENABLED then
	Players.PlayerAdded:Connect(loadPersistedRole)
	-- Catch-up for players already in-game when this module initializes (Studio
	-- play-solo, late require, dev-mount) — mirrors the autoGrantOwner loop
	-- below; without it their persisted role never loads at all.
	for _, p in ipairs(Players:GetPlayers()) do
		loadPersistedRole(p)
	end
	Players.PlayerRemoving:Connect(function(p: Player)
		-- Evict so the next join re-reads the persisted role. The join load is
		-- upgrade-only, so without eviction a demotion issued on ANOTHER server
		-- never lands here: the stale elevated entry outranks the persisted row
		-- for this server's whole lifetime.
		roleByUserId[p.UserId] = nil
	end)
end

-- ── Auto-grant owner to the game's creator ──
-- WHY: a freshly-deployed framework has zero admins in the DataStore, so even
-- the place owner can't run /speed. Grant "owner" on join when the player's
-- UserId matches the User-owned place's CreatorId; group-owned places skip
-- this (game owner there is the group, not a single player).
local function autoGrantOwner(p: Player)
	-- Creator auto-grant (User-owned places), gated by Config.Admin.AutoGrantCreator.
	if AdminConfig.AutoGrantCreator ~= false
		and game.CreatorType == Enum.CreatorType.User
		and p.UserId == game.CreatorId then
		AdminCommands.SetRole(p.UserId, "owner")
	end
	-- Config.Admin.Bootstrap floor: in-memory only (re-applied each boot, NOT
	-- persisted) so it also seeds group-owned places that get no creator grant.
	if typeof(AdminConfig.Bootstrap) == "table" then
		local seeded = (AdminConfig.Bootstrap :: any)[p.UserId]
		if typeof(seeded) == "string" and ROLE_TIER[seeded] ~= nil then
			local current = ROLE_TIER[roleByUserId[p.UserId] or "default"] or 0
			if (ROLE_TIER[seeded] or 0) > current then
				roleByUserId[p.UserId] = seeded
			end
		end
	end
end
if ADMIN_ENABLED then
	for _, p in ipairs(Players:GetPlayers()) do autoGrantOwner(p) end
	Players.PlayerAdded:Connect(autoGrantOwner)
end

-- ── Admin Panel: role-filtered schema + minimal player list ──
-- describeFor returns only the commands `player` is allowed to run, so a
-- moderator's client never learns that owner-only commands exist. listPlayers
-- returns the minimal public shape the Players tab needs (no PII beyond what is
-- already visible in-game).
local function describeFor(player: Player): { any }
	local out = {}
	for _, entry in pairs(commands) do
		if AdminCommands.IsAtLeast(player, entry.role) then
			table.insert(out, {
				name = entry.name,
				role = entry.role,
				args = entry.args,
				help = entry.help,
			})
		end
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

local function listPlayers(): { any }
	local out = {}
	for _, p in ipairs(Players:GetPlayers()) do
		table.insert(out, {
			userId = p.UserId,
			name = p.Name,
			displayName = p.DisplayName,
			role = AdminCommands.GetRole(p),
		})
	end
	return out
end

-- Username cache for the bans list. GetNameFromUserIdAsync yields and
-- throttles, so resolve once per userId per server; deleted/unknown ids
-- resolve to nil and the panel shows the raw userId instead.
local nameByUserId: { [number]: string } = {}
local function nameForUserId(userId: number): string?
	local cached = nameByUserId[userId]
	if cached then return cached end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and typeof(name) == "string" then
		nameByUserId[userId] = name
		return name
	end
	return nil
end

-- ── Admin Panel RemoteFunction/RemoteEvent surface ──
-- Mirrors the Friend/Guild/Party Remote blocks (Phase 26). The GUI is pure
-- convenience: every `run` goes through AdminCommands.Run, which performs the
-- authoritative role check. A spoofed client cannot escalate.
-- Skipped entirely when the Admin kill switch is off: no Events/Admin remotes
-- are created, so a disabled build exposes no admin surface to clients at all.
if ADMIN_ENABLED then
	local Events = ReplicatedStorage:FindFirstChild("Events") or Instance.new("Folder")
	Events.Name = "Events"
	Events.Parent = ReplicatedStorage
	local AdminFolder = Events:FindFirstChild("Admin") or Instance.new("Folder")
	AdminFolder.Name = "Admin"
	AdminFolder.Parent = Events
	local Action = AdminFolder:FindFirstChild("Action") or Instance.new("RemoteFunction")
	Action.Name = "Action"
	Action.Parent = AdminFolder
	local Inbound = AdminFolder:FindFirstChild("Inbound") or Instance.new("RemoteEvent")
	Inbound.Name = "Inbound"
	Inbound.Parent = AdminFolder

	Action.OnServerInvoke = function(player: Player, envelope: any): (boolean, any)
		if typeof(envelope) ~= "table" or typeof(envelope.type) ~= "string" then
			return false, "bad envelope"
		end
		local t = envelope.type
		-- Gate the read endpoints: listPlayers includes each player's admin role,
		-- which is NOT otherwise visible in-game — ungated, any client could
		-- enumerate the live staff roster to evade or target moderators. "role"
		-- stays open (it only returns the invoker's own role, which the client
		-- needs pre-gate to decide whether to show the toolbar button); "run"
		-- gates itself inside AdminCommands.Run.
		if t == "schema" then
			if not AdminCommands.IsAtLeast(player, "moderator") then
				return false, "forbidden"
			end
			return true, describeFor(player)
		end
		if t == "players" then
			if not AdminCommands.IsAtLeast(player, "moderator") then
				return false, "forbidden"
			end
			return true, listPlayers()
		end
		if t == "bans" then
			-- Same tier as /unban, the command this list feeds. Returns active
			-- ban records with resolved usernames so the panel renders a
			-- click-to-unban list instead of a raw userId box.
			if not AdminCommands.IsAtLeast(player, "admin") then
				return false, "forbidden"
			end
			local limit = tonumber(server().EConfig.Get(
				"Admin.BanListLimit",
				AdminConfig.BanListLimit or 50
			)) or 50
			local bans = server().Ban.ListBans(limit)
			for _, b in ipairs(bans) do
				b.name = nameForUserId(b.userId)
			end
			return true, bans
		end
		if t == "role" then
			return true,
				{
					role = AdminCommands.GetRole(player),
					isModerator = AdminCommands.IsAtLeast(player, "moderator"),
				}
		end
		if t == "run" then
			if typeof(envelope.name) ~= "string" then
				return false, "bad command name"
			end
			local argList: { string } = {}
			if typeof(envelope.args) == "table" then
				for _, v in ipairs(envelope.args) do
					table.insert(argList, tostring(v))
				end
			end
			-- Strip trailing blanks: untouched panel TextBoxes submit "" which is
			-- truthy in Luau, so every `args[i] or <default>` fallback was dead
			-- from the panel (bans persisted with reason ""). Trailing only — a
			-- blank slot between filled slots must keep positions stable.
			while #argList > 0 and argList[#argList]:match("^%s*$") do
				table.remove(argList)
			end
			-- Surface the handler's descriptive message so the panel toast shows
			-- the real outcome ("Banned X" / "You can't target yourself" / …)
			-- rather than a generic line. Falls back to a generic reason when a
			-- handler returned nothing.
			local ok, message = AdminCommands.Run(player, envelope.name, argList)
			return ok, message or (if ok then nil else "Command failed or role insufficient.")
		end
		return false, "unknown action"
	end

	-- Audit: broadcast every command result to moderator+ clients only.
	AdminCommands.OnCommand:Connect(function(caller: Player, name: string, args: { string }, success: boolean, message: string?)
		for _, p in ipairs(Players:GetPlayers()) do
			if AdminCommands.IsAtLeast(p, "moderator") then
				Inbound:FireClient(p, {
					type = "cmd",
					at = os.time(),
					caller = caller.Name,
					name = name,
					args = args,
					success = success,
					message = message,
				})
			end
		end
	end)

	-- Role hint at join so the client can show/hide the toolbar button.
	local function pushRoleHint(p: Player)
		Inbound:FireClient(p, {
			type = "role",
			role = AdminCommands.GetRole(p),
			isModerator = AdminCommands.IsAtLeast(p, "moderator"),
		})
	end
	Players.PlayerAdded:Connect(function(p)
		task.spawn(pushRoleHint, p)
	end)
	for _, p in ipairs(Players:GetPlayers()) do
		task.spawn(pushRoleHint, p)
	end
end

return AdminCommands
