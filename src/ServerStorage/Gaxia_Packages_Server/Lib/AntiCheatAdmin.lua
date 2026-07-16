--!strict
-- ─────────────────────────────────────────────────────────────
-- AntiCheatAdmin.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/AntiCheatAdmin
-- Purpose : Moderator-facing AntiCheat dashboard as chat commands, registered
--           through AdminCommands (role-gated, chat-bridged). Surfaces the
--           AntiCheatJournal + flag counts + BanService so a moderator can
--           inspect and act in-game:
--             /acflags <player>   — list a player's flags
--             /acclear <player>   — clear a player's flags
--             /acban <player> <reason> [seconds]
--             /acunban <userId>
--             /ac <on|off|status|reset> [Detector]  — live AntiCheat kill-switch
--             /flag <set|get> <key> [value]         — generic runtime flag override
--
-- Touch Gaxia.AntiCheatAdmin at boot to register the commands (auto-registers on
-- load too; explicit Register() is idempotent).
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local Players       = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local AntiCheatAdmin = {}

local GaxiaServer: any = nil
local function server(): any
	if not GaxiaServer then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server"):WaitForChild("init")
		GaxiaServer = require(serverInit :: any)
	end
	return GaxiaServer
end

-- Hardened resolver (mirrors AdminCommands.findPlayerByPartialName, which is
-- module-local): blank and ambiguous queries resolve to nil — never "first
-- player in GetPlayers()" — and an exact name match beats any prefix match
-- (the old single-pass loop returned an earlier-joined "Bobby" for "bob").
local function findPlayer(query: string?): (Player?, string?)
	local q = (query or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
	if q == "" then
		return nil, "no target player specified"
	end
	local prefixMatch: Player? = nil
	local prefixCount = 0
	for _, p in ipairs(Players:GetPlayers()) do
		local name = p.Name:lower()
		if name == q then
			return p, nil
		end
		if name:sub(1, #q) == q then
			prefixCount += 1
			prefixMatch = p
		end
	end
	if prefixCount == 1 then
		return prefixMatch, nil
	end
	if prefixCount > 1 then
		return nil, `ambiguous target — {prefixCount} players match "{query}"`
	end
	return nil, "player not found"
end

local registered = false
function AntiCheatAdmin.Register(): ()
	if registered then
		return
	end
	registered = true
	local G = server()
	local Admin = G.Admin
	if not Admin or not Admin.Register then
		warn("[AntiCheatAdmin] AdminCommands unavailable — dashboard commands not registered")
		return
	end

	Admin.Register("acflags", { role = "moderator", help = "List a player's AntiCheat flags" }, function(caller: Player, args: { string }): string?
		local target = findPlayer(args[1]) or caller
		local entries = G.Journal.GetForPlayer(target)
		if #entries == 0 then
			return `{target.Name}: no flags`
		end
		local parts = {}
		for _, e in ipairs(entries) do
			table.insert(parts, `{e.reason}({e.severity})`)
		end
		return `{target.Name} [{#entries}]: {table.concat(parts, ", ")}`
	end)

	Admin.Register("acclear", { role = "admin", help = "Clear a player's AntiCheat flags" }, function(caller: Player, args: { string }): string?
		local target = findPlayer(args[1]) or caller
		G.AntiCheat.ClearFlags(target)
		return `cleared {target.Name}'s AntiCheat flags`
	end)

	Admin.Register("acban", { role = "admin", help = "Ban a player: /acban <player> <reason> [seconds]" }, function(caller: Player, args: { string }): (string?, boolean?)
		local target, why = findPlayer(args[1])
		if not target then
			return why or "player not found", true
		end
		-- Same self/creator/rank protection as /ban — this pack is a second ban
		-- entry point and must re-apply the same guard, or a delegated admin can
		-- ban the owner through /acban while /ban refuses. FAIL CLOSED when the
		-- guard is missing (mixed-version Lib folder): a security guard that
		-- anticipates its own absence must refuse, not proceed.
		if not Admin.ProtectTarget then
			return "target protection unavailable — /acban refused", true
		end
		local blocked = Admin.ProtectTarget(caller, target)
		if blocked then
			return blocked, true
		end
		local reason = args[2] or "AntiCheat"
		-- NaN/inf/negative guard (audit convention): tonumber("nan") is NaN,
		-- NaN expiresAt never compares expired → an accidental PERMANENT ban
		-- reported as temp; negative seconds = instantly-expired record.
		local seconds: number? = nil
		if args[3] ~= nil and args[3] ~= "" then
			local n = tonumber(args[3])
			if not n or n ~= n or n == math.huge or n < 1 then
				return "seconds must be a positive number (omit for permanent)", true
			end
			seconds = math.floor(n)
		end
		local persisted = G.Ban.Ban(target.UserId, reason, seconds)
		local line = `banned {target.Name}: {reason}{if seconds then ` ({seconds}s)` else " (permanent)"}`
		if persisted == false then
			-- Kick happened but the DataStore write failed (or no store): this
			-- ban dies with the server. Same surface rule as /ban.
			return `{line} — WARNING: not persisted (session-only)`
		end
		return line
	end)

	Admin.Register("acunban", { role = "admin", help = "Unban a userId: /acunban <userId>" }, function(_caller: Player, args: { string }): (string?, boolean?)
		local uid = tonumber(args[1])
		if not uid then
			return "usage: /acunban <userId>", true
		end
		local persisted = G.Ban.Unban(uid)
		if persisted == false then
			return `unbanned {uid} — WARNING: persisted record removal failed; the ban may re-apply elsewhere`
		end
		return `unbanned {uid}`
	end)

	-- ── Live AntiCheat enable/disable + generic flag control ──

	-- Audit trail: server-log line (always) + Analytics event (if wired). Answers
	-- "who flipped what" without standing up a new store.
	local function audit(caller: Player, action: string): ()
		print(`[AntiCheatAdmin] AUDIT {caller.Name}({caller.UserId}): {action}`)
		pcall(function()
			G.Analytics.Track("admin_config", { by = caller.UserId, action = action })
		end)
	end

	local function parseValue(s: string?): any
		if s == nil then return true end
		if s == "true" then return true end
		if s == "false" then return false end
		local n = tonumber(s)
		if n ~= nil then return n end
		return s
	end

	Admin.Register("ac", { role = "admin", help = "AntiCheat: /ac <on|off|status|reset> [Detector]" }, function(caller: Player, args: { string }): (string?, boolean?)
		local AC = G.AntiCheat
		local sub = (args[1] or "status"):lower()
		local det = args[2]
		if sub == "status" then
			local disabled: { string } = {}
			for _, name in ipairs(AC.GetDetectorNames()) do
				if not AC.IsDetectorEnabled(name) then
					table.insert(disabled, name)
				end
			end
			return `AntiCheat {if AC.IsEnabled() then "ON" else "OFF"} · disabled detectors: {if #disabled > 0 then table.concat(disabled, ", ") else "none"}`
		elseif sub == "reset" then
			AC.ClearOverrides()
			audit(caller, "ac reset (cleared overrides)")
			return "AntiCheat overrides cleared — reverted to Config defaults"
		elseif sub == "on" or sub == "off" then
			local on = sub == "on"
			if det then
				AC.SetDetectorEnabled(det, on)
				audit(caller, `detector {det} = {sub}`)
				return `detector {det}: {sub}`
			end
			AC.SetEnabled(on)
			audit(caller, `AntiCheat master = {sub}`)
			return `AntiCheat: {sub}`
		end
		-- Rejection (unknown subcommand) — must carry failed=true or it renders
		-- as a green success toast / ✓ audit row (post-audit handler contract).
		return "usage: /ac <on|off|status|reset> [Detector]", true
	end)

	Admin.Register("flag", { role = "admin", help = "Runtime flag: /flag <set|get> <key> [value]" }, function(caller: Player, args: { string }): (string?, boolean?)
		local sub = (args[1] or ""):lower()
		local key = args[2]
		if sub == "get" and key then
			return `{key} = {tostring(G.EConfig.Get(key, nil))} (overridden: {tostring(G.EConfig.IsOverridden(key))})`
		elseif sub == "set" and key then
			local val = parseValue(args[3])
			G.EConfig.Set(key, val)
			audit(caller, `flag {key} = {tostring(val)}`)
			return `flag {key} = {tostring(val)}`
		elseif sub == "clear" and key then
			G.EConfig.Clear(key)
			audit(caller, `flag {key} cleared`)
			return `flag {key} cleared (reverted to default)`
		end
		return "usage: /flag <set|get|clear> <key> [value]", true
	end)
end

task.spawn(AntiCheatAdmin.Register)

return AntiCheatAdmin
