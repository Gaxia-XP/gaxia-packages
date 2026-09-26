--!strict
-- ─────────────────────────────────────────────────────────────
-- AdminPanel.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/AdminPanel
-- Purpose : In-game admin panel GUI over the server AdminCommands registry.
--           Three tabs — Players (click a player → role-permitted actions),
--           Commands (role-filtered list → per-arg form → run), Audit (live
--           feed of command results). Pure front-end: every action round-trips
--           through Events/Admin/Action and the server re-validates the
--           caller's role (AdminCommands.Run). Self-owns its toolbar button
--           (moderator+ only), F2 hotkey, and role-hint subscription.
--
-- Access  : Gaxia.UI.AdminPanel  (client)
--   Gaxia.UI.AdminPanel.Open() / .Close() / .Toggle()
-- ─────────────────────────────────────────────────────────────
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

-- Role hint from the server's AdminCommands: the reply to Events/Admin/Action
-- { type = "role" } and the { type = "role", ... } push on Events/Admin/Inbound.
-- `role` is the AdminCommands role name (tiers are configurable, so a string).
export type RoleHint = {
	type: "role"?,
	role: string?,
	isModerator: boolean?,
}

local Panel = {}
-- The module's own type (every function below): `Gaxia.UI.AdminPanel.<method>`
-- autocompletes and the server stub shares it.
export type AdminPanel = typeof(Panel)

-- ── Server stub (the lazy UI proxy may require this on the server) ──
if not RunService:IsClient() then
	return (
		{
			Open = function() end,
			Close = function() end,
			Toggle = function() end,
			SetRole = function(_) end,
		} :: any
	) :: typeof(Panel)
end

local Theme = require(script.Parent.Parent.Parent.Shared.Theme)
local Components = require(script.Parent.Components)
local Toast = require(script.Parent.Toast)

-- ── Remote handles (resolved lazily; created by AdminCommands at boot) ──
local function adminAction(): RemoteFunction?
	local events = ReplicatedStorage:WaitForChild("Events", 10)
	local folder = events and events:WaitForChild("Admin", 10)
	local action = folder and folder:WaitForChild("Action", 10)
	return action :: RemoteFunction?
end

-- invoke(envelope) -> (ok: boolean, result: any). Assumes the server handler
-- returns (boolean, any): pcall prepends its own success bool, so on a clean
-- call `a` = the server's ok and `b` = its value/reason.
local function invoke(envelope: any): (boolean, any)
	local action = adminAction()
	if not action then
		return false, "admin service offline"
	end
	local ok, a, b = pcall(function()
		return action:InvokeServer(envelope)
	end)
	if not ok then
		return false, tostring(a)
	end
	return a, b
end

-- ── Module state ──
local screenGui: ScreenGui? = nil
local body: Frame? = nil -- the content area below the tab bar (cleared per tab)
local TAB_NAMES = { "Players", "Commands", "Audit" }

local auditBuffer: { any } = {} -- newest-last; capped at AUDIT_CAP
local AUDIT_CAP = 50

local function adminInbound(): RemoteEvent?
	local events = ReplicatedStorage:WaitForChild("Events", 10)
	local folder = events and events:WaitForChild("Admin", 10)
	local inbound = folder and folder:WaitForChild("Inbound", 10)
	return inbound :: RemoteEvent?
end

-- forward decls (defined in this task + later tasks)
local renderCommands: () -> ()
local renderPlayers: () -> ()
local renderAudit: () -> ()
local openPlayerActions: (target: any, players: { any }, cmdList: { any }) -> ()

local function clearBody(): ()
	if not body then
		return
	end
	-- Task 3's Audit tab disconnects its subscription via this hook before the
	-- body is wiped. Stored as a dynamic field (cast through `any` so strict
	-- Luau accepts it) so renderAudit can register/clear it.
	local onLeave = (Panel :: any)._onLeaveTab
	if onLeave then
		onLeave()
		;(Panel :: any)._onLeaveTab = nil
	end
	for _, c in ipairs(body:GetChildren()) do
		c:Destroy()
	end
end

local function ensureGui(): ScreenGui
	if screenGui and screenGui.Parent then
		return screenGui
	end
	local tokens = Theme.Get()
	local gui = Instance.new("ScreenGui")
	gui.Name = "GaxiaAdminPanel"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50
	gui.Enabled = true
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	screenGui = gui

	local frame = Instance.new("Frame")
	frame.Name = "Window"
	frame.Size = UDim2.new(0, 560, 0, 460)
	frame.Position = UDim2.new(0.5, -280, 0.5, -230)
	frame.BackgroundColor3 = tokens.Color.Background
	frame.BorderSizePixel = 0
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, tokens.Radius.M)
	corner.Parent = frame

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -80, 0, 34)
	title.Position = UDim2.new(0, 12, 0, 8)
	title.BackgroundTransparency = 1
	title.Text = "Admin Panel"
	title.TextColor3 = tokens.Color.Primary
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Font = tokens.Font.Bold
	title.TextSize = 20
	title.Parent = frame

	local close = Components.Button({
		Text = "✕",
		Size = UDim2.fromOffset(28, 28),
		Position = UDim2.new(1, -36, 0, 10),
		Variant = "surface",
		Parent = frame,
		OnClick = function()
			Panel.Close()
		end,
	})
	close.Name = "CloseBtn"

	local tabs = Components.Tabs({
		Tabs = TAB_NAMES,
		Active = 2, -- default to Commands (the discoverability win)
		Size = UDim2.new(1, -24, 0, 36),
		Position = UDim2.new(0, 12, 0, 46),
		Parent = frame,
		OnChanged = function(_index: number, name: string)
			-- Each render fn self-clears (calls clearBody() at its top), which
			-- also fires the old tab's _onLeaveTab before the new tab draws.
			if name == "Players" then
				renderPlayers()
			elseif name == "Commands" then
				renderCommands()
			elseif name == "Audit" then
				renderAudit()
			end
		end,
	})
	tabs.Instance.Name = "Tabs"

	local content = Instance.new("Frame")
	content.Name = "Body"
	content.Size = UDim2.new(1, -24, 1, -96)
	content.Position = UDim2.new(0, 12, 0, 88)
	content.BackgroundTransparency = 1
	content.Parent = frame
	body = content

	return gui
end

-- ── Arg form: render one widget per arg token, gather values, run ──
-- ── /unban: list of active bans (click to unban) ──
-- The generic arg form gave /unban a raw userId text box; admins should see
-- WHO is banned. Renders the server's "bans" envelope (admin-gated:
-- BanService.ListBans + resolved usernames) as a ScrollList with a per-row
-- Unban button, plus a manual userId fallback for records beyond the list cap.
local function openUnbanList(cmd: any): ()
	clearBody()
	local b = body :: Frame
	local tokens = Theme.Get()

	local header = Instance.new("TextLabel")
	header.Size = UDim2.new(1, 0, 0, 24)
	header.BackgroundTransparency = 1
	header.Text = "/unban  —  active bans (click to unban)"
	header.TextColor3 = tokens.Color.Text
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Font = tokens.Font.Medium
	header.TextSize = 15
	header.Parent = b

	local okB, bans = invoke({ type = "bans" })
	local banList = (okB and typeof(bans) == "table") and bans or {}

	local function runUnban(userId: string)
		local ok, reason = invoke({ type = "run", name = cmd.name, args = { userId } })
		Toast.Show({
			Title = ok and "Admin" or "Blocked",
			Text = (typeof(reason) == "string" and reason ~= "") and reason
				or (ok and `/unban {userId}` or `/unban failed`),
			Variant = ok and "success" or "error",
			Duration = 3,
		})
		if ok then
			openUnbanList(cmd) -- refresh: the unbanned row should disappear
		end
	end

	if #banList == 0 then
		local empty = Instance.new("TextLabel")
		empty.Size = UDim2.new(1, 0, 0, 28)
		empty.Position = UDim2.new(0, 0, 0, 30)
		empty.BackgroundTransparency = 1
		empty.Text = if okB then "No active bans." else `Could not load bans: {tostring(bans)}`
		empty.TextColor3 = tokens.Color.TextMuted
		empty.TextXAlignment = Enum.TextXAlignment.Left
		empty.Font = tokens.Font.Regular
		empty.TextSize = 14
		empty.Parent = b
	else
		local list = Components.ScrollList({
			Items = banList,
			ItemHeight = 40,
			Size = UDim2.new(1, 0, 1, -126),
			Position = UDim2.new(0, 0, 0, 30),
			Parent = b,
			Render = function(item: any, _index: number, frame: Frame)
				frame:ClearAllChildren() -- ScrollList recycles pooled frames; wipe first
				local expires = "permanent"
				if typeof(item.expiresAt) == "number" then
					local left = math.max(0, item.expiresAt - os.time())
					expires = if left >= 3600
						then `{math.floor(left / 3600)}h left`
						else `{math.ceil(left / 60)}m left`
				end
				local label = Instance.new("TextLabel")
				label.Size = UDim2.new(1, -96, 1, -4)
				label.BackgroundTransparency = 1
				label.Text = `{item.name or "?"} ({item.userId})  —  {tostring(item.reason)}  ·  {expires}`
				label.TextColor3 = tokens.Color.Text
				label.TextXAlignment = Enum.TextXAlignment.Left
				label.TextTruncate = Enum.TextTruncate.AtEnd
				label.Font = tokens.Font.Regular
				label.TextSize = 14
				label.Parent = frame
				local btn = Components.Button({
					Text = "Unban",
					Size = UDim2.fromOffset(88, 32),
					Position = UDim2.new(1, -88, 0, 2),
					Variant = "danger",
					Parent = frame,
					OnClick = function()
						runUnban(tostring(item.userId))
					end,
				})
				btn.Name = "UnbanBtn"
			end,
		})
		list.Instance.Name = "BanList"
	end

	-- Manual fallback: ids beyond the list cap, or while DataStore listing fails.
	local manualLabel = Instance.new("TextLabel")
	manualLabel.Size = UDim2.new(0, 90, 0, 36)
	manualLabel.Position = UDim2.new(0, 0, 1, -88)
	manualLabel.BackgroundTransparency = 1
	manualLabel.Text = "userId:"
	manualLabel.TextColor3 = tokens.Color.TextMuted
	manualLabel.TextXAlignment = Enum.TextXAlignment.Left
	manualLabel.Font = tokens.Font.Regular
	manualLabel.TextSize = 14
	manualLabel.Parent = b
	local manualBox = Components.TextInput({
		Placeholder = "number",
		Size = UDim2.fromOffset(220, 36),
		Position = UDim2.new(0, 96, 1, -88),
		Parent = b,
	})
	local manualRun = Components.Button({
		Text = "Unban id",
		Size = UDim2.fromOffset(110, 36),
		Position = UDim2.new(0, 324, 1, -88),
		Variant = "primary",
		Parent = b,
		OnClick = function()
			runUnban(manualBox.Text)
		end,
	})
	manualRun.Name = "ManualUnbanBtn"

	local back = Components.Button({
		Text = "‹ Back",
		Size = UDim2.fromOffset(80, 38),
		Position = UDim2.new(0, 0, 1, -44),
		Variant = "surface",
		Parent = b,
		OnClick = function()
			renderCommands()
		end,
	})
	back.Name = "BackBtn"
end

-- preset: optional { [argIndex] = value } to pre-fill (Players tab uses this to
-- lock arg 1 to the clicked target).
local function openArgForm(cmd: any, players: { any }, preset: { [number]: string }?): ()
	-- /unban gets its own view: a list of who is actually banned beats a raw
	-- userId text box.
	if cmd.name == "unban" then
		return openUnbanList(cmd)
	end
	clearBody()
	local b = body :: Frame
	local tokens = Theme.Get()

	local header = Instance.new("TextLabel")
	header.Size = UDim2.new(1, 0, 0, 24)
	header.BackgroundTransparency = 1
	header.Text = `/{cmd.name}  —  {cmd.help ~= "" and cmd.help or "(no description)"}`
	header.TextColor3 = tokens.Color.Text
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Font = tokens.Font.Medium
	header.TextSize = 15
	header.Parent = b

	local playerNames: { string } = {}
	for _, p in ipairs(players) do
		table.insert(playerNames, p.name)
	end

	local getters: { () -> string } = {}
	local y = 32
	for i, token in ipairs(cmd.args) do
		local labelRow = Instance.new("TextLabel")
		labelRow.Size = UDim2.new(0, 90, 0, 36)
		labelRow.Position = UDim2.new(0, 0, 0, y)
		labelRow.BackgroundTransparency = 1
		labelRow.Text = `{token}:`
		labelRow.TextColor3 = tokens.Color.TextMuted
		labelRow.TextXAlignment = Enum.TextXAlignment.Left
		labelRow.Font = tokens.Font.Regular
		labelRow.TextSize = 14
		labelRow.Parent = b

		local presetVal = preset and preset[i]
		if token == "player" then
			local dd = Components.Dropdown({
				Options = (#playerNames > 0) and playerNames or { "(no players)" },
				Value = presetVal,
				Size = UDim2.fromOffset(360, 36),
				Position = UDim2.new(0, 96, 0, y),
				Parent = b,
			})
			getters[i] = function()
				return dd.Get()
			end
		else
			local box = Components.TextInput({
				Placeholder = token,
				Text = presetVal,
				Size = UDim2.fromOffset(360, 36),
				Position = UDim2.new(0, 96, 0, y),
				Parent = b,
			})
			getters[i] = function()
				return box.Text
			end
		end
		y += 44
	end

	local run = Components.Button({
		Text = `Run /{cmd.name}`,
		Size = UDim2.fromOffset(160, 38),
		Position = UDim2.new(0, 0, 0, y + 6),
		Variant = "primary",
		Parent = b,
		OnClick = function()
			local args: { string } = {}
			for i = 1, #cmd.args do
				args[i] = getters[i] and getters[i]() or ""
			end
			local ok, reason = invoke({ type = "run", name = cmd.name, args = args })
			Toast.Show({
				-- Show the server's own message (e.g. "Banned X" / "You can't
				-- target yourself") when present; fall back to a generic line.
				Title = ok and "Admin" or "Blocked",
				Text = (typeof(reason) == "string" and reason ~= "") and reason
					or (ok and `/{cmd.name} ran` or `/{cmd.name} failed`),
				Variant = ok and "success" or "error",
				Duration = 3,
			})
		end,
	})
	run.Name = "RunBtn"

	local back = Components.Button({
		Text = "‹ Back",
		Size = UDim2.fromOffset(80, 38),
		Position = UDim2.new(0, 172, 0, y + 6),
		Variant = "surface",
		Parent = b,
		OnClick = function()
			renderCommands()
		end,
	})
	back.Name = "BackBtn"
end

-- Per-target action menu: every permitted command whose first arg is a player,
-- as a button that opens the arg form with the player slot locked to `target`.
openPlayerActions = function(target: any, players: { any }, cmdList: { any }): ()
	clearBody()
	local b = body :: Frame
	local tokens = Theme.Get()

	local header = Instance.new("TextLabel")
	header.Size = UDim2.new(1, 0, 0, 24)
	header.BackgroundTransparency = 1
	header.Text = `Actions for {target.name}  [{target.role}]`
	header.TextColor3 = tokens.Color.Text
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Font = tokens.Font.Medium
	header.TextSize = 15
	header.Parent = b

	local targeted: { any } = {}
	for _, cmd in ipairs(cmdList) do
		if cmd.args[1] == "player" then
			table.insert(targeted, cmd)
		end
	end

	local list = Components.ScrollList({
		Items = targeted,
		ItemHeight = 38,
		Size = UDim2.new(1, 0, 1, -52),
		Position = UDim2.new(0, 0, 0, 30),
		Parent = b,
		Render = function(item: any, _index: number, frame: Frame)
			frame:ClearAllChildren() -- ScrollList recycles pooled frames; wipe first
			local variant = (item.name == "ban" or item.name == "kick") and "danger" or "surface"
			local btn = Components.Button({
				Text = `/{item.name}  {item.help}`,
				Size = UDim2.new(1, 0, 1, -4),
				Position = UDim2.new(),
				Variant = variant,
				Parent = frame,
				OnClick = function()
					if #item.args == 1 then
						local ok, reason = invoke({ type = "run", name = item.name, args = { target.name } })
						Toast.Show({
							Title = ok and "Admin" or "Blocked",
							Text = (typeof(reason) == "string" and reason ~= "") and reason
								or (ok and `/{item.name} {target.name}` or `/{item.name} failed`),
							Variant = ok and "success" or "error",
							Duration = 3,
						})
					else
						openArgForm(item, players, { [1] = target.name })
					end
				end,
			})
			btn.TextXAlignment = Enum.TextXAlignment.Left
		end,
	})
	list.Instance.Name = "ActionList"

	local back = Components.Button({
		Text = "‹ Back",
		Size = UDim2.fromOffset(80, 36),
		Position = UDim2.new(0, 0, 1, -40),
		Variant = "surface",
		Parent = b,
		OnClick = function()
			renderPlayers()
		end,
	})
	back.Name = "BackBtn"
end

-- ── Commands tab ──
renderCommands = function(): ()
	clearBody()
	local b = body :: Frame
	local tokens = Theme.Get()

	local okS, schema = invoke({ type = "schema" })
	local okP, players = invoke({ type = "players" })
	if not okS or typeof(schema) ~= "table" then
		local empty = Instance.new("TextLabel")
		empty.Size = UDim2.new(1, 0, 0, 28)
		empty.BackgroundTransparency = 1
		empty.Text = "No commands available (or admin service offline)."
		empty.TextColor3 = tokens.Color.TextMuted
		empty.Font = tokens.Font.Regular
		empty.TextSize = 14
		empty.Parent = b
		return
	end
	local playerList = (okP and typeof(players) == "table") and players or {}

	-- Convention: every ScrollList Render must `frame:ClearAllChildren()` first —
	-- ScrollList recycles pooled frames (Task 3's Players/Audit lists must follow this).
	local list = Components.ScrollList({
		Items = schema,
		ItemHeight = 40,
		Size = UDim2.new(1, 0, 1, 0),
		Position = UDim2.new(),
		Parent = b,
		Render = function(item: any, _index: number, frame: Frame)
			frame:ClearAllChildren() -- ScrollList recycles pooled frames; wipe prior render before drawing
			local btn = Components.Button({
				Text = `/{item.name}   [{item.role}]   {item.help}`,
				Size = UDim2.new(1, 0, 1, -4),
				Position = UDim2.new(),
				Variant = "surface",
				Parent = frame,
				OnClick = function()
					openArgForm(item, playerList, nil)
				end,
			})
			btn.TextXAlignment = Enum.TextXAlignment.Left
		end,
	})
	list.Instance.Name = "CommandList"
end

-- ── Players tab ──
renderPlayers = function(): ()
	clearBody()
	local b = body :: Frame
	local tokens = Theme.Get()

	local okP, players = invoke({ type = "players" })
	local okS, schema = invoke({ type = "schema" })
	local playerList = (okP and typeof(players) == "table") and players or {}
	local cmdList = (okS and typeof(schema) == "table") and schema or {}

	if #playerList == 0 then
		local empty = Instance.new("TextLabel")
		empty.Size = UDim2.new(1, 0, 0, 28)
		empty.BackgroundTransparency = 1
		empty.Text = "No players online."
		empty.TextColor3 = tokens.Color.TextMuted
		empty.Font = tokens.Font.Regular
		empty.TextSize = 14
		empty.Parent = b
		return
	end

	local list = Components.ScrollList({
		Items = playerList,
		ItemHeight = 36,
		Size = UDim2.new(1, 0, 1, 0),
		Position = UDim2.new(),
		Parent = b,
		Render = function(item: any, _index: number, frame: Frame)
			frame:ClearAllChildren() -- ScrollList recycles pooled frames; wipe first
			local btn = Components.Button({
				Text = `{item.name}   [{item.role}]`,
				Size = UDim2.new(1, 0, 1, -4),
				Position = UDim2.new(),
				Variant = "surface",
				Parent = frame,
				OnClick = function()
					openPlayerActions(item, players, cmdList)
				end,
			})
			btn.TextXAlignment = Enum.TextXAlignment.Left
		end,
	})
	list.Instance.Name = "PlayerList"
end

-- ── Audit tab ──
renderAudit = function(): ()
	clearBody()
	local b = body :: Frame
	local tokens = Theme.Get()

	local list = Components.ScrollList({
		Items = {},
		ItemHeight = 30,
		Size = UDim2.new(1, 0, 1, 0),
		Position = UDim2.new(),
		Parent = b,
		Render = function(item: any, _index: number, frame: Frame)
			frame:ClearAllChildren() -- ScrollList recycles pooled frames; wipe first
			local row = Instance.new("TextLabel")
			row.Size = UDim2.new(1, 0, 1, -2)
			row.BackgroundTransparency = 1
			local mark = item.success and "✓" or "✗"
			local argStr = table.concat(item.args or {}, " ")
			local msgStr = if typeof(item.message) == "string" and item.message ~= ""
				then ` — {item.message}`
				else ""
			row.Text = `{mark} {item.caller}: /{item.name} {argStr}{msgStr}`
			row.TextColor3 = item.success and tokens.Color.Success or tokens.Color.Danger
			row.TextXAlignment = Enum.TextXAlignment.Left
			row.Font = tokens.Font.Regular
			row.TextSize = 13
			row.Parent = frame
		end,
	})
	list.Instance.Name = "AuditList"

	local function refresh()
		local rev: { any } = {}
		for i = #auditBuffer, 1, -1 do
			table.insert(rev, auditBuffer[i])
		end
		list.SetItems(rev)
	end
	refresh()

	local inbound = adminInbound()
	local conn: RBXScriptConnection? = nil
	if inbound then
		conn = inbound.OnClientEvent:Connect(function(msg: any)
			if typeof(msg) == "table" and msg.type == "cmd" then
				-- Buffering lives in the always-on module subscription (bottom of
				-- this file) so history accumulates whatever tab/panel state the
				-- player is in; this per-tab connection only refreshes the view.
				-- task.defer: let the buffering handler insert first regardless
				-- of signal connection order.
				task.defer(refresh)
			end
		end)
	end

	;(Panel :: any)._onLeaveTab = function()
		if conn then
			conn:Disconnect()
			conn = nil
		end
	end
end

-- ── Public API ──
function Panel.Open(): ()
	ensureGui()
	renderCommands() -- default tab (self-clears)
end

function Panel.Close(): ()
	if screenGui then
		clearBody()
		screenGui:Destroy()
		screenGui = nil
		body = nil
	end
end

function Panel.Toggle(): ()
	if screenGui and screenGui.Parent then
		Panel.Close()
	else
		Panel.Open()
	end
end

-- ── Toolbar button (self-owned; shown only for moderator+) ──
local toolbarGui: ScreenGui? = nil
local isModerator = false

local function ensureToolbar(): ()
	if toolbarGui and toolbarGui.Parent then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "GaxiaAdminToolbar"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 49
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	toolbarGui = gui

	local btn = Components.Button({
		Text = "🛡 Admin",
		Size = UDim2.fromOffset(96, 32),
		Position = UDim2.new(0, 8, 0, 8),
		Variant = "primary",
		Parent = gui,
		OnClick = function()
			Panel.Toggle()
		end,
	})
	btn.Name = "AdminToolbarBtn"
	gui.Enabled = isModerator
end

function Panel.SetRole(roleHint: RoleHint?): ()
	if typeof(roleHint) == "table" then
		isModerator = roleHint.isModerator == true
	end
	ensureToolbar()
	if toolbarGui then
		toolbarGui.Enabled = isModerator
	end
end

-- ── Role hint: pull at load + subscribe to server push ──
task.spawn(function()
	-- Pull (covers module-loaded-after-server-push race).
	local ok, hint = invoke({ type = "role" })
	if ok and typeof(hint) == "table" then
		Panel.SetRole(hint)
	end
	-- Push (covers /role changes mid-session) + ALWAYS-ON audit buffering: the
	-- buffer used to fill only while the Audit tab held its own connection, so
	-- everything broadcast while the panel was closed or on another tab — i.e.
	-- nearly all command traffic — was permanently lost and the tab opened empty.
	local inbound = adminInbound()
	if inbound then
		inbound.OnClientEvent:Connect(function(msg: any)
			if typeof(msg) ~= "table" then
				return
			end
			if msg.type == "role" then
				Panel.SetRole(msg)
			elseif msg.type == "cmd" then
				table.insert(auditBuffer, msg)
				while #auditBuffer > AUDIT_CAP do
					table.remove(auditBuffer, 1)
				end
			end
		end)
	end
end)

-- ── F2 hotkey (always toggles; content is server-gated) ──
UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.F2 then
		Panel.Toggle()
	end
end)

return Panel
