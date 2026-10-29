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
function harness.join(name)
	name = name or ("Player" .. (#P.list + 1))
	local plr = P.join(name)
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
-- Click a button in the player's PlayerGui: by path ("ShopGui.Frame.BuyButton",
-- under PlayerGui) or by the text shown on it ("Buy 100 Gems").
local function clickNode(node, world)
	for _, ev in { "MouseButton1Down", "MouseButton1Up", "MouseButton1Click", "Activated" } do
		local s = node.sigs and node.sigs[ev]
		if s then
			H.sig.fireWorld(s, world, if ev == "Activated" then nil else 0, if ev == "Activated" then 1 else 0)
		end
	end
	S.flush()
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
	clickNode(node, world)
end
-- Every button in a player's PlayerGui that has a click handler connected, as
-- "Gui.Frame.Button" paths (sorted, so runs are deterministic). Used by
-- tools/harness/scenarios/click-all.lua (check-playbooks --run).
local function buttonNodes(p)
	local plr = playerByName(p)
	local world = plr.clientWorld
	local gui = I.findChild(plr, "PlayerGui", nil)
	local out = {}
	if gui == nil then
		return out, world
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
				table.insert(out, { path = table.concat(parts, "."), node = d })
			end
		end
	end
	table.sort(out, function(a, b)
		return a.path < b.path
	end)
	return out, world
end
function harness.buttons(p)
	local out = {}
	for _, b in buttonNodes(p) do
		table.insert(out, b.path)
	end
	return out
end
-- Click every hooked button in the player's PlayerGui once, `gap` simulated
-- seconds apart (default 0.5). Returns the clicked paths.
function harness.clickAll(p, gap)
	local list, world = buttonNodes(p)
	local clicked = {}
	for _, b in list do
		if b.node.Parent ~= nil then
			clickNode(b.node, world)
			table.insert(clicked, b.path)
			S.advance(gap or 0.5)
		end
	end
	return clicked
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
function harness.log(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = D.tostring((select(i, ...)))
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
