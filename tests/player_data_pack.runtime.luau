-- Runtime test of packs/player-data's DataManager in the standalone Luau CLI (not Roblox).
-- scripts/test-player-data-pack.py prepends `local SOURCES = {...}` (each pack module's text) and
-- `local VARIANT = "default" | "custom"`. ProfileStore is replaced by a fake: the real one is pinned upstream
-- text, checked by hash and compile only. Signal, DataMigration, DataConfig and DataManager run as shipped.

local warns = {}
local function warnHook(...)
	local parts = table.pack(...)
	for i = 1, parts.n do
		parts[i] = tostring(parts[i])
	end
	table.insert(warns, table.concat(parts, " "))
end

-- A tiny signal for the fake engine objects (Players.PlayerAdded, profile.OnSessionEnd).
local function engineSignal()
	local handlers = {}
	return {
		Connect = function(_, fn)
			table.insert(handlers, fn)
			return { Disconnect = function() end }
		end,
		Fire = function(_, ...)
			for _, fn in handlers do
				fn(...)
			end
		end,
	}
end

local task = {
	spawn = function(f, ...)
		local co = if type(f) == "thread" then f else coroutine.create(f)
		local ok, err = coroutine.resume(co, ...)
		assert(ok, err)
		return co
	end,
	defer = function(f, ...)
		return task.spawn(f, ...)
	end,
	wait = function()
		error("task.wait was not expected in this test")
	end,
}

-- The fake ProfileStore: records calls and hands out profiles that behave like ProfileStore 1.0.3's.
local storeCalls = { new = {}, sessions = {} }
local function deepCopy(t)
	local out = {}
	for k, v in t do
		out[k] = if type(v) == "table" then deepCopy(v) else v
	end
	return out
end
local fakeProfileStore = {
	New = function(name, template)
		table.insert(storeCalls.new, { name = name, template = template })
		return {
			StartSessionAsync = function(_, key, params)
				assert(type(params.Cancel) == "function", "StartSessionAsync gets a Cancel")
				local profile = {
					Key = key,
					Data = {},
					saves = 0,
					ended = 0,
					userIds = {},
					OnSessionEnd = engineSignal(),
				}
				function profile:Reconcile()
					for k, v in template do
						if self.Data[k] == nil then
							self.Data[k] = if type(v) == "table" then deepCopy(v) else v
						end
					end
				end
				function profile:AddUserId(id)
					table.insert(self.userIds, id)
				end
				function profile:Save()
					self.saves += 1
				end
				function profile:EndSession()
					self.ended += 1
				end
				storeCalls.sessions[key] = profile
				return profile
			end,
		}
	end,
}

-- The fake place: Players, the services DataManager names, and the pack's folder.
local players = { list = {}, PlayerAdded = engineSignal(), PlayerRemoving = engineSignal() }
function players:GetPlayers()
	return self.list
end
function players:GetPlayerByUserId(id)
	for _, p in self.list do
		if p.UserId == id then
			return p
		end
	end
	return nil
end
local closeHandlers = {}
local services = {
	Players = players,
	ServerScriptService = {},
	DataStoreService = {
		GetDataStore = function()
			error("no DataStore in this test")
		end,
	},
	CollectionService = {},
}
local game = {
	GetService = function(_, name)
		return assert(services[name], "unexpected service " .. name)
	end,
	BindToClose = function(_, fn)
		table.insert(closeHandlers, fn)
	end,
}

local folder = { Name = "PlayerData", children = {} }
function folder:FindFirstChild(name)
	return self.children[name]
end
setmetatable(folder, {
	__index = function(self, name)
		local child = rawget(self, "children")[name]
		if child == nil then
			error(`{name} is not a valid member of PlayerData`)
		end
		return child
	end,
})

local loaded = {}
local function requireNode(node)
	if node.fake then
		return node.fake
	end
	if loaded[node] == nil then
		local env = setmetatable({
			script = node,
			game = game,
			task = task,
			warn = warnHook,
			require = requireNode,
			typeof = type,
			Enum = { DataStoreRequestType = { SetIncrementAsync = "SetIncrementAsync" } },
		}, { __index = _G })
		local fn = assert(loadstring(node.source, "=" .. node.Name))
		setfenv(fn, env)
		local result = fn()
		if node.Name == "DataConfig" and VARIANT == "custom" then
			result.Template = { Wins = 0, Pets = { "Cat" } }
		end
		loaded[node] = result
	end
	return loaded[node]
end

for _, name in { "DataManager", "DataConfig", "DataMigration", "Signal" } do
	folder.children[name] = { Name = name, Parent = folder, source = assert(SOURCES[name], name) }
end
folder.children.ProfileStore = { Name = "ProfileStore", Parent = folder, fake = fakeProfileStore }

local function newPlayer(id)
	local player = { UserId = id, Parent = players, kicked = nil }
	function player:Kick(reason)
		self.kicked = reason
	end
	return player
end

-- 1. Requiring DataManager starts no session and needs nothing outside its folder.
local DataManager = requireNode(folder.children.DataManager)
assert(#storeCalls.new == 0, "ProfileStore is resolved on the first player, not at require")
local config = requireNode(folder.children.DataConfig)
assert(DataManager.DEFAULT_PROFILE == config.Template, "the template comes from DataConfig")

-- 2. A player joins: the session starts with DataConfig's name and key prefix, and the data is the template.
local loadedSeen = {}
DataManager.OnLoaded:Connect(function(player, data)
	table.insert(loadedSeen, { player = player, data = data })
end)
local alice = newPlayer(1)
table.insert(players.list, alice)
players.PlayerAdded:Fire(alice)
assert(#storeCalls.new == 1 and storeCalls.new[1].name == config.StoreName, "ProfileStore.New gets DataConfig.StoreName")
local profile = assert(storeCalls.sessions[config.KeyPrefix .. "1"], "the session key is KeyPrefix .. UserId")
assert(profile.userIds[1] == 1, "the profile records the player's UserId")
assert(DataManager.IsLoaded(alice), "the player is loaded")
assert(#loadedSeen == 1 and loadedSeen[1].player == alice, "OnLoaded fires once")
assert(type(DataManager.Get(alice, "LastLogin")) == "number", "LastLogin is set")
assert(DataManager.WaitFor(alice) == profile.Data, "WaitFor returns the data once loaded")

if VARIANT == "custom" then
	assert(DataManager.Get(alice, "Wins") == 0, "a custom template's field is there")
	assert(DataManager.Get(alice, "Coins") == nil, "the library's default fields are not added to a custom template")
	assert(DataManager.Get(alice, "__version") == 1, "a template without __version still starts at schema 1")
	for _, line in warns do
		assert(not string.find(line, "Chain incomplete", 1, true), "no migration warning: " .. line)
	end
else
	assert(DataManager.Get(alice, "Coins") == 0 and DataManager.Get(alice, "Level") == 1, "the default template")
	assert(DataManager.Get(alice, "__version") == 1, "schema 1")
end

-- 3. Set writes the data and fires OnDataChanged.
local changed = {}
DataManager.OnDataChanged:Connect(function(player, key, value)
	table.insert(changed, { player, key, value })
end)
assert(DataManager.Set(alice, "Gold", 5) == true, "Set on a loaded player")
assert(DataManager.Get(alice, "Gold") == 5, "Set is read back")
assert(#changed == 1 and changed[1][1] == alice and changed[1][2] == "Gold" and changed[1][3] == 5, "OnDataChanged fires")
assert(DataManager.Set(newPlayer(99), "Gold", 1) == false, "Set on a player that is not loaded")

-- 4. The player leaves: the session ends once and OnReleased fires.
local released = 0
DataManager.OnReleased:Connect(function()
	released += 1
end)
players.PlayerRemoving:Fire(alice)
assert(profile.ended == 1 and released == 1 and not DataManager.IsLoaded(alice), "the session ends on leave")

-- 5. _SeedForTest fills from the template with copies, not the template's own tables.
local mock = { UserId = -5 }
DataManager._SeedForTest(mock, { Extra = true })
assert(DataManager.Get(mock, "Extra") == true, "the seed keeps its own fields")
local templateTable = if VARIANT == "custom" then "Pets" else "Settings"
local seeded = DataManager.Get(mock, templateTable)
assert(type(seeded) == "table" and seeded ~= config.Template[templateTable], "a template table is copied")

-- 6. BindToClose saves and ends every loaded session.
assert(#closeHandlers == 1, "DataManager binds one close handler")
local bob = newPlayer(2)
table.insert(players.list, bob)
players.PlayerAdded:Fire(bob)
local bobProfile = storeCalls.sessions[config.KeyPrefix .. "2"]
closeHandlers[1]()
assert(bobProfile.saves >= 1 and bobProfile.ended == 1, "close saves and ends the session")

print(`[PLAYER_DATA_PACK] {VARIANT}: PASS`)
