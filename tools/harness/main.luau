--!nocheck
-- Gaxia boot harness: runs a Roblox place headlessly under Lune and reports
-- what Studio Play would show (errors, warnings, prints, hangs, kicks).
-- Called by tools/run-game.mjs:  lune run tools/harness/main.luau <tree.json> <options.json>
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local luau = require("@lune/luau")

local H = require("./runtime/state")

local args = process.args
local tree = serde.decode("json", fs.readFile(args[1]))
H.options = serde.decode("json", fs.readFile(args[2]))
local EPOCH = H.options.epoch or 1767225600 -- 2026-01-01T00:00:00Z
function H.epoch()
	return EPOCH
end

local S = require("./runtime/sched")
require("./runtime/signal")
local D = require("./runtime/datatypes")
local I = require("./runtime/instance")
I.loadClassDb(H.options.harnessDir .. "/classdb.json")
require("./runtime/classes")
local W = require("./runtime/world")
require("./runtime/services")
require("./runtime/net")
require("./runtime/data")
local P = require("./runtime/players")

H.closeCallbacks = {}

-- ── build the DataModel ──────────────────────────────────────────────────────
local function convertProp(raw, key, value)
	local kind = raw.class.members[key]
	local code = if kind then string.sub(kind, 2) else "?"
	local v = value
	if type(value) == "table" then
		-- Rojo explicit form { "Vector3": [1,2,3] } or implicit array
		local tname, data = next(value)
		if type(tname) == "string" and #value == 0 then
			code, v = tname, data
		end
		if type(v) == "table" then
			if code == "Vector3" then
				v = D.Vector3.new(v[1], v[2], v[3])
			elseif code == "Vector2" then
				v = D.Vector2.new(v[1], v[2])
			elseif code == "Color3" then
				v = D.Color3.new(v[1], v[2], v[3])
			elseif code == "Color3uint8" then
				v = D.Color3.fromRGB(v[1], v[2], v[3])
			elseif code == "UDim2" then
				v = D.UDim2.new(v[1][1], v[1][2], v[2][1], v[2][2])
			elseif code == "UDim" then
				v = D.UDim.new(v[1], v[2])
			elseif code == "CFrame" then
				v = D.CFrame.new(v.position and v.position[1] or v[1] or 0, v.position and v.position[2] or v[2] or 0, v.position and v.position[3] or v[3] or 0)
			else
				H.note("harness: project property " .. key .. " of type " .. tostring(code) .. " was not converted")
				return nil
			end
		end
	end
	if type(code) == "string" and string.sub(code, 1, 1) == "E" and type(v) ~= "userdata" then
		local enum = D.getEnum(string.sub(code, 2))
		for _, item in enum:GetEnumItems() do
			if item.Name == v or item.Value == v then
				return item
			end
		end
	end
	return v
end

local function build(node, parent)
	local cls = node.c or "Folder"
	local raw = I.new(cls, nil)
	raw.Name = node.n
	raw.source = node.s
	raw.file = node.f
	if not raw.class.known then
		H.note("unmodeled class " .. cls .. " (generic instance that accepts any property)")
	end
	for k, v in node.p or {} do
		local cv = convertProp(raw, k, v)
		if cv ~= nil then
			if k == "Disabled" then
				raw.props.Enabled = not cv
			end
			raw.props[k] = cv
		end
	end
	for k, v in node.a or {} do
		raw.attrs[k] = v
	end
	for _, t in node.t or {} do
		raw.tags[t] = true
	end
	I.setParent(raw, parent)
	for _, child in node.k or {} do
		build(child, raw)
	end
	return raw
end

H.game = I.new("DataModel", nil)
H.game.Name = "Place1"
for _, name in { "Workspace", "Players", "Lighting", "ReplicatedFirst", "ReplicatedStorage", "ServerScriptService", "ServerStorage",
	"StarterGui", "StarterPack", "StarterPlayer", "Teams", "SoundService", "Chat", "TextChatService", "LocalizationService",
	"TestService", "RunService" } do
	I.service(name)
end
I.service("ServerStorage").hideChildren = true
I.service("ServerScriptService").hideChildren = true
local sp = I.service("StarterPlayer")
for _, cls in { "StarterPlayerScripts", "StarterCharacterScripts" } do
	local c = I.new(cls, nil)
	c.Name = cls
	I.setParent(c, sp)
end
local terrain = I.new("Terrain", nil)
terrain.Name = "Terrain"
I.setParent(terrain, I.service("Workspace"))
H.settingsRaw = I.new("GlobalSettings", nil)
H.userSettingsRaw = I.new("UserSettings", nil)
P.setupChat()

for _, node in tree.k or {} do
	local svc = I.service(node.c or node.n)
	for k, v in node.a or {} do
		svc.attrs[k] = v
	end
	for _, child in node.k or {} do
		-- merge folders that already exist (StarterPlayerScripts, ...)
		local existing = I.findChild(svc, child.n, nil)
		if existing and (child.c == nil or child.c == "Folder" or child.c == existing.ClassName) and existing.source == nil and child.s == nil then
			for _, gc in child.k or {} do
				build(gc, existing)
			end
		else
			build(child, svc)
		end
	end
end

-- ── worlds ───────────────────────────────────────────────────────────────────
local server = W.new("server", "server", nil)
H.cameraFor(server)

-- ── scenario API ─────────────────────────────────────────────────────────────
local function findPath(path: string, world)
	local node = nil
	for part in string.gmatch(path, "[^%.]+") do
		if node == nil then
			node = I.service(part)
		else
			node = I.findChild(node, part, world)
		end
		if node == nil then
			return nil
		end
	end
	return node
end

local function playerByName(p)
	if type(p) == "table" and I.isRaw[p] then
		return p
	end
	for _, plr in P.list do
		if plr.Name == p then
			return plr
		end
	end
	error("harness: no player " .. tostring(p), 3)
end

local harness = {}
-- userId (optional): join with this UserId, e.g. the UserId of a player who left
-- (a rejoin to the same server). Default: the next free UserId.
function harness.join(name, userId)
	name = name or ("Player" .. (#P.list + 1))
	local plr = P.join(name, userId)
	S.flush()
	return plr
end
function harness.leave(p)
	P.leave(playerByName(p), "left")
	S.flush()
end
function harness.advance(seconds)
	S.advance(seconds or 1)
end
function harness.players()
	local out = {}
	for _, p in P.list do
		if not p.left then
			table.insert(out, p)
		end
	end
	return out
end
function harness.time()
	return S.clock
end
local function inWorld(world, fn, ...)
	local results
	local co = S.spawn(function(...)
		results = table.pack(fn(...))
	end, world, ...)
	S.flush()
	local waited = 0
	while coroutine.status(co) ~= "dead" and waited < 10 do
		S.step()
		waited += S.FRAME
	end
	if coroutine.status(co) ~= "dead" then
		-- Do not return a silent nil: say the call is still yielding (it keeps running).
		H.emit({
			t = "scenario",
			text = "(harness call still yielding after 10 s; it returned nil and keeps running in the background)",
			time = S.clock,
		})
	end
	return results
end
function harness.fireServer(p, path, ...)
	local plr = playerByName(p)
	local world = plr.clientWorld
	local remote = findPath(path, world)
	if not remote then
		error("harness.fireServer: no remote at " .. path, 2)
	end
	local args = table.pack(...)
	inWorld(world, function()
		I.wrap(world, remote):FireServer(table.unpack(args, 1, args.n))
	end)
end
function harness.invokeServer(p, path, ...)
	local plr = playerByName(p)
	local world = plr.clientWorld
	local remote = findPath(path, world)
	if not remote then
		error("harness.invokeServer: no remote at " .. path, 2)
	end
	local args = table.pack(...)
	local r = inWorld(world, function()
		return I.wrap(world, remote):InvokeServer(table.unpack(args, 1, args.n))
	end)
	if r then
		return table.unpack(r, 1, r.n)
	end
	return nil
end
function harness.purchase(p, productId)
	H.purchase(playerByName(p), productId)
	S.flush()
end
function harness.chat(p, text)
	P.chat(playerByName(p), text)
	S.flush()
end
-- What Roblox passes to Activated: (InputObject, clickCount). A stub mouse click.
local function clickInput(world)
	local raw = I.new("InputObject", nil)
	raw.Name = "InputObject"
	raw.props.UserInputType = D.Enum.UserInputType.MouseButton1
	raw.props.UserInputState = D.Enum.UserInputState.End
	raw.props.KeyCode = D.Enum.KeyCode.Unknown
	raw.props.Position = D.Vector3.zero
	raw.props.Delta = D.Vector3.zero
	return I.wrap(world, raw)
end

-- Click a button in the player's PlayerGui: by path ("ShopGui.Frame.BuyButton",
-- under PlayerGui) or by the text shown on it ("Buy 100 Gems").
local function clickNode(node, world)
	for _, ev in { "MouseButton1Down", "MouseButton1Up", "MouseButton1Click", "Activated" } do
		local s = node.sigs and node.sigs[ev]
		if s then
			if ev == "Activated" then
				H.sig.fireWorld(s, world, clickInput(world), 1)
			elseif ev == "MouseButton1Click" then
				H.sig.fireWorld(s, world)
			else
				H.sig.fireWorld(s, world, 0, 0)
			end
		end
	end
	S.flush()
end

-- Can a player click this button now? Roblox only delivers clicks to a button
-- that is on screen: it and every GuiObject above it are Visible, its ScreenGui
-- (LayerCollector) is Enabled, and it is Interactable.
local function readable(raw, world, key)
	local ok, v = pcall(I.readProp, raw, world, key)
	if ok then
		return v
	end
	return nil
end
local function onScreen(node, world, gui)
	if readable(node, world, "Interactable") == false then
		return false, "Interactable = false"
	end
	local n = node
	while n and n ~= gui do
		if n.class.isA.GuiObject and readable(n, world, "Visible") == false then
			return false, (if n == node then "Visible = false" else n.Name .. ".Visible = false")
		end
		if n.class.isA.LayerCollector and readable(n, world, "Enabled") == false then
			return false, n.Name .. ".Enabled = false"
		end
		n = n.Parent
	end
	return n == gui, "not in PlayerGui"
end

function harness.clickButton(p, path)
	local plr = playerByName(p)
	local world = plr.clientWorld
	local gui = I.findChild(plr, "PlayerGui", nil)
	local node = gui
	for part in string.gmatch(path, "[^%.]+") do
		node = node and I.findChild(node, part, world)
	end
	if node == nil and gui then
		for _, d in I.visibleDescendants(gui, world, {}) do
			if d.class.isA.GuiButton and (d.props.Text == path or d.Name == path) then
				node = d
				break
			end
		end
	end
	if node == nil then
		error("harness.clickButton: no button at PlayerGui." .. path .. " and no button with that text", 2)
	end
	local ok, why = onScreen(node, world, gui)
	if not ok then
		-- still clicked (the scenario asked for it), but say a player could not
		H.emit({ t = "scenario", text = "note: clicked " .. path .. " although a player could not (" .. why .. ")", time = S.clock })
	end
	clickNode(node, world)
end
-- Every button in a player's PlayerGui that has a click handler connected, as
-- "Gui.Frame.Button" paths (sorted, so runs are deterministic). Used by
-- tools/harness/scenarios/click-all.lua (check-playbooks --run).
-- With onlyClickable, buttons a player cannot click right now are left out
-- (returned separately as `hidden`).
local function buttonNodes(p, onlyClickable)
	local plr = playerByName(p)
	local world = plr.clientWorld
	local gui = I.findChild(plr, "PlayerGui", nil)
	local out, hidden = {}, {}
	if gui == nil then
		return out, world, hidden
	end
	for _, d in I.visibleDescendants(gui, world, {}) do
		if d.class.isA.GuiButton and d.sigs then
			local hooked = false
			for _, ev in { "MouseButton1Down", "MouseButton1Up", "MouseButton1Click", "Activated" } do
				if d.sigs[ev] then
					hooked = true
				end
			end
			if hooked then
				local parts = {}
				local node = d
				while node and node ~= gui do
					table.insert(parts, 1, node.Name)
					node = node.Parent
				end
				local entry = { path = table.concat(parts, "."), node = d }
				if onlyClickable then
					local ok, why = onScreen(d, world, gui)
					entry.why = why
					table.insert(if ok then out else hidden, entry)
				else
					table.insert(out, entry)
				end
			end
		end
	end
	local byPath = function(a, b)
		return a.path < b.path
	end
	table.sort(out, byPath)
	table.sort(hidden, byPath)
	return out, world, hidden
end
function harness.buttons(p)
	local out = {}
	for _, b in buttonNodes(p) do
		table.insert(out, b.path)
	end
	return out
end
-- Click every button a player can click in their PlayerGui once, `gap`
-- simulated seconds apart (default 0.5). After each click the list is rebuilt,
-- so a button revealed by an earlier click (a confirm dialog) is clicked in a
-- later pass; hidden buttons are skipped. Returns the clicked paths and the
-- paths that stayed hidden.
function harness.clickAll(p, gap)
	local clicked, done = {}, {}
	local hiddenLeft = {}
	for _ = 1, 200 do
		local list, world, hidden = buttonNodes(p, true)
		hiddenLeft = hidden
		local nextOne = nil
		for _, b in list do
			if not done[b.node] and b.node.Parent ~= nil then
				nextOne = b
				break
			end
		end
		if nextOne == nil then
			break
		end
		done[nextOne.node] = true
		clickNode(nextOne.node, world)
		table.insert(clicked, nextOne.path)
		S.advance(gap or 0.5)
	end
	local skipped = {}
	for _, b in hiddenLeft do
		if not done[b.node] then
			table.insert(skipped, b.path .. " (" .. b.why .. ")")
		end
	end
	return clicked, skipped
end
-- ── touches and tools ────────────────────────────────────────────────────────
-- The harness has no physics, so parts never touch by themselves. A scenario
-- makes them touch: harness.touch(part, hitPart) fires part.Touched(hitPart)
-- and hitPart.Touched(part), like Roblox when two parts meet.
local function scenarioError(text, level)
	error(text, (level or 1) + 1)
end
-- a part given as a path ("Workspace.Lava") or an Instance (from runServer)
local function partArg(fnName, v, argN)
	local raw = nil
	if type(v) == "string" then
		raw = findPath(v, server)
		if raw == nil then
			scenarioError(string.format("harness.%s: argument %d: no instance at %s", fnName, argN, v), 3)
		end
	else
		raw = I.import(v)
		if type(raw) ~= "table" or not I.isRaw[raw] then
			scenarioError(string.format("harness.%s: argument %d must be a part path (\"Workspace.Lava\") or a part, got %s", fnName, argN, typeof(v)), 3)
		end
	end
	if not raw.class.isA.BasePart then
		scenarioError(string.format("harness.%s: argument %d (%s) is a %s, not a BasePart: only parts touch", fnName, argN, I.fullName(raw), raw.ClassName), 3)
	end
	return raw
end
local function inWorkspace(raw)
	local n = raw.Parent
	while n do
		if n.ClassName == "Workspace" then
			return true
		end
		n = n.Parent
	end
	return false
end
-- Can these two parts touch? Roblox fires Touched only for parts in the
-- Workspace whose CanTouch is true (on both), and only when at least one of
-- them is physically simulated: two Anchored parts never fire Touched, even
-- when they overlap. (Only the Anchored property is checked: a part welded to
-- an anchored part counts as simulated here.)
local function canTouch(a, b)
	for _, r in { a, b } do
		if not inWorkspace(r) then
			return false, I.fullName(r) .. " is not in the Workspace"
		end
		if readable(r, server, "CanTouch") == false then
			return false, I.fullName(r) .. ".CanTouch = false"
		end
	end
	if readable(a, server, "Anchored") == true and readable(b, server, "Anchored") == true then
		return false, I.fullName(a) .. " and " .. I.fullName(b) .. " are both Anchored (one of them must move)"
	end
	return true, nil
end
local function fireTouch(event, a, b, worlds)
	for _, world in worlds do
		local sa = a.sigs and a.sigs[event]
		local sb = b.sigs and b.sigs[event]
		if I.visible(a, world) and I.visible(b, world) then
			H.sig.fireWorld(sa, world, b)
			H.sig.fireWorld(sb, world, a)
		end
	end
	S.flush()
end
local function touchParts(fnName, a, b, endAfter, worlds)
	local ok, why = canTouch(a, b)
	if not ok then
		H.emit({ t = "scenario", text = string.format("note: harness.%s did nothing: %s (Roblox would not fire Touched)", fnName, why), time = S.clock })
		return false
	end
	fireTouch("Touched", a, b, worlds)
	if endAfter ~= nil then
		if type(endAfter) ~= "number" then
			scenarioError(string.format("harness.%s: endAfter must be a number of seconds, got %s", fnName, typeof(endAfter)), 3)
		end
		S.advance(endAfter)
		fireTouch("TouchEnded", a, b, worlds)
	end
	return true
end
-- harness.touch(part, hitPart, endAfter?): part.Touched(hitPart) and
-- hitPart.Touched(part) fire on the server. With endAfter (seconds), that much
-- time passes and TouchEnded fires the same way. Returns false (and logs why)
-- when Roblox would not fire it (a part outside the Workspace, CanTouch false,
-- or both parts Anchored).
function harness.touch(part, hitPart, endAfter)
	return touchParts("touch", partArg("touch", part, 1), partArg("touch", hitPart, 2), endAfter, { server })
end
function harness.touchEnded(part, hitPart)
	local a, b = partArg("touchEnded", part, 1), partArg("touchEnded", hitPart, 2)
	fireTouch("TouchEnded", a, b, { server })
end
-- harness.touchWith(player, part, endAfter?, limb?): the player's character
-- touches `part` with its HumanoidRootPart (or `limb`, e.g. "LeftFoot"; a
-- character without that part uses its first part). Fires on the server and on
-- that player's client (Roblox's client sees its own character's touches).
function harness.touchWith(p, part, endAfter, limb)
	local plr = playerByName(p)
	local char = plr.props.Character
	if char == nil then
		scenarioError("harness.touchWith: " .. plr.Name .. " has no character yet (it spawns 0.1 s after join: harness.advance(1) first)", 2)
	end
	local hit = I.findChild(char, limb or "HumanoidRootPart", nil)
	if hit == nil or not hit.class.isA.BasePart then
		if limb then
			scenarioError("harness.touchWith: " .. plr.Name .. "'s character has no part named " .. limb, 2)
		end
		hit = nil
		for _, c in char.children do
			if c.class.isA.BasePart then
				hit = c
				break
			end
		end
		if hit == nil then
			scenarioError("harness.touchWith: " .. plr.Name .. "'s character has no part", 2)
		end
	end
	local target = partArg("touchWith", part, 2)
	local worlds = { server }
	if plr.clientWorld then
		table.insert(worlds, plr.clientWorld)
	end
	return touchParts("touchWith", target, hit, endAfter, worlds)
end

local function findTool(container, name, world)
	local c = I.findChild(container, name, world)
	if c and c.class.isA.Tool then
		return c
	end
	return nil
end
local function mouseFor(world)
	if not world.mouse then
		world.mouse = I.new("PlayerMouse", world.id)
		world.mouse.Name = "Instance"
	end
	return world.mouse
end
-- harness.activateTool(player, toolName): the player clicks with a Tool. If the
-- tool is in their Backpack it is equipped first (any other equipped tool goes
-- back to the Backpack; Unequipped / Equipped fire). Then, like a mouse click,
-- Activated fires on the player's client and on the server (Roblox sends the
-- click to the server), and Deactivated when the button is released. A tool
-- that is not Enabled, or has ManualActivationOnly, is not activated by a click.
function harness.activateTool(p, toolName)
	local plr = playerByName(p)
	local cw = plr.clientWorld
	local char = plr.props.Character
	if char == nil then
		scenarioError("harness.activateTool: " .. plr.Name .. " has no character yet (it spawns 0.1 s after join: harness.advance(1) first)", 2)
	end
	local tool = findTool(char, toolName, cw)
	if tool == nil then
		local backpack = I.findChild(plr, "Backpack", nil)
		tool = backpack and findTool(backpack, toolName, cw)
		if tool == nil then
			scenarioError("harness.activateTool: " .. plr.Name .. " has no Tool named " .. tostring(toolName) .. " in Backpack or in the character", 2)
		end
		for _, c in table.clone(char.children) do
			if c.class.isA.Tool then
				I.setParent(c, backpack)
				H.sig.fireWorld(c.sigs and c.sigs.Unequipped, server)
				H.sig.fireWorld(c.sigs and c.sigs.Unequipped, cw)
			end
		end
		I.setParent(tool, char)
		H.sig.fireWorld(tool.sigs and tool.sigs.Equipped, server)
		H.sig.fireWorld(tool.sigs and tool.sigs.Equipped, cw, mouseFor(cw))
		S.flush()
	end
	if readable(tool, cw, "Enabled") == false or readable(tool, cw, "ManualActivationOnly") == true then
		H.emit({
			t = "scenario",
			text = "note: harness.activateTool(" .. tostring(toolName) .. ") did not fire Activated: the tool has "
				.. (if readable(tool, cw, "Enabled") == false then "Enabled = false" else "ManualActivationOnly = true"),
			time = S.clock,
		})
		return false
	end
	local worlds = { cw }
	if I.visible(tool, server) then
		table.insert(worlds, 1, server)
	end
	for _, ev in { "Activated", "Deactivated" } do
		for _, world in worlds do
			H.sig.fireWorld(tool.sigs and tool.sigs[ev], world)
		end
		S.flush()
	end
	return true
end

local scenarioRun = 0
local function runSource(world, source)
	scenarioRun += 1
	local raw = I.new("Script", nil)
	raw.Name = "HarnessScenario" .. scenarioRun
	raw.source = source
	local env = setmetatable({ script = I.wrap(world, raw) }, { __index = world.globals })
	local fn, err = luau.load(source, { debugName = "=" .. raw.Name, environment = env, injectGlobals = false })
	if not fn then
		error("harness.run: " .. tostring(err), 3)
	end
	local r = inWorld(world, fn)
	if r then
		return table.unpack(r, 1, r.n)
	end
	return nil
end
function harness.runServer(source)
	return runSource(server, source)
end
function harness.runClient(p, source)
	return runSource(playerByName(p).clientWorld, source)
end
function harness.autoBuy(on)
	H.options.autoBuy = on ~= false
end
function harness.exists(path)
	return findPath(path, nil) ~= nil
end
-- A scenario value as text: arrays as "{a, b, c}", other tables as "{k = v, ...}"
-- (sorted), so logs are readable and the same on every run.
local function show(v, depth)
	if type(v) ~= "table" or I.isRaw[v] or getmetatable(v) ~= nil then
		return H.stable(D.tostring(v))
	end
	if depth > 3 then
		return "{...}"
	end
	local parts = {}
	local n = rawlen(v)
	for i = 1, n do
		parts[i] = show(v[i], depth + 1)
	end
	local keys = {}
	for k in v do
		if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
			table.insert(keys, k)
		end
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	for _, k in keys do
		table.insert(parts, tostring(k) .. " = " .. show(v[k], depth + 1))
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end
function harness.log(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = show((select(i, ...)), 0)
	end
	H.emit({ t = "scenario", text = table.concat(parts, " "), time = S.clock })
end

-- ── run ──────────────────────────────────────────────────────────────────────
local function boot()
	H.running = true
	W.considerTree(H.game)
	S.flush()
end

local function shutdown()
	for _, p in harness.players() do
		P.leave(p, "left")
	end
	S.flush()
	S.advance(1)
	-- game:BindToClose: every callback runs; the server waits up to 30 s for them
	local threads = {}
	for _, cb in H.closeCallbacks do
		table.insert(threads, S.spawn(cb.fn, cb.world))
	end
	S.flush()
	local waited = 0
	local function pending()
		for _, co in threads do
			if coroutine.status(co) ~= "dead" then
				return true
			end
		end
		return false
	end
	while pending() and waited < 30 do
		S.step()
		waited += S.FRAME
	end
	if pending() then
		H.warn("server", "game:BindToClose callbacks did not finish within 30 seconds (Roblox shuts the server down anyway)")
	end
	H.emit({ t = "closed", callbacks = #H.closeCallbacks, seconds = waited })
end

-- Threads blocked (not sleeping) for at least 5 s — Roblox's "infinite yield"
-- threshold — on something that cannot happen by itself. Called for a client
-- world when its player leaves, and for the rest at the end of the run.
local HANG_AFTER = 5
function H.reportHangs(onlyWorld)
	for _, b in S.blocked() do
		local w = b.info.waiting
		local world = b.info.world
		if (onlyWorld == nil or world == onlyWorld) and w.kind ~= "signal" and not w.timeout and not b.info.hangReported then
			if S.clock - (w.since or 0) >= HANG_AFTER - 1e-6 then
				b.info.hangReported = true
				H.emit({
					t = "hang", world = if world then world.id else "?", kind = w.kind, text = w.text, since = w.since,
					trace = H.traceOf(b.co), at = S.clock,
				})
			end
		end
	end
end

local function report()
	H.reportHangs(nil)
	local signalWaits = 0
	for _, b in S.blocked() do
		if b.info.waiting.kind == "signal" then
			signalWaits += 1
		end
	end
	H.flushRepeats()
	H.emit({
		t = "end", clock = S.clock, counts = H.counts, remotes = H.remoteStats or {}, dataStore = H.dsStats or {},
		signalWaits = signalWaits, sleepers = S.pendingSleepers(),
	})
end

local ok, err = xpcall(function()
	boot()
	if H.options.scenarioFile then
		-- a mistake in the scenario file is reported as a SCENARIO ERROR, not a harness bug
		local sok, serr = xpcall(function()
			local source = fs.readFile(H.options.scenarioFile)
			local env = setmetatable({ harness = harness, print = harness.log }, { __index = _G })
			local fn = luau.load(source, { debugName = "=scenario", environment = env })
			local result = fn()
			if type(result) == "function" then
				result(harness)
			end
		end, function(e)
			return S.cleanMessage(e) .. "\n" .. (S.formatTrace(debug.traceback(nil, 2)) or "")
		end)
		if not sok then
			H.emit({ t = "scenarioError", message = serr, time = S.clock })
		end
	else
		S.advance(2)
		for i = 1, H.options.players or 1 do
			harness.join("Player" .. i)
		end
		S.advance(H.options.seconds or 10)
	end
	shutdown()
end, function(e)
	return tostring(e) .. "\n" .. debug.traceback(nil, 2)
end)
if not ok then
	H.harnessError(err)
end
report()
