--!strict
--[[
	Module : RemoteTrap
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.RemoteTrap
	Purpose : Observe-only tripwires for client calls that no shipped client
	          should make. A honeypot RemoteEvent has no game behavior, while
	          outbound-only RemoteEvents report a wrong-direction attempt.

	These signals raise trap evidence but AntiCheatEnforcement starts in observe
	mode. A trap is never authentication, never grants state, and must not be
	the sole basis for a permanent ban.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemoteTrap = {}
RemoteTrap.Name = "RemoteTrap"

local watched: { [RemoteEvent]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local lastTripAt: { [Player]: { [string]: number } } = setmetatable({}, { __mode = "k" }) :: any
local TRIP_COOLDOWN_SECONDS: number = 5

local OUTBOUND_ONLY: { { string } } = {
	{ "Friend", "Inbound" },
	{ "Party", "InviteInbound" },
	{ "Guild", "Inbound" },
	{ "Admin", "Inbound" },
	{ "Chat", "SystemMessage" },
}

local function getOrCreateEvents(): Folder
	local existing = ReplicatedStorage:FindFirstChild("Events")
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		error(`[RemoteTrap] ReplicatedStorage.Events is {existing.ClassName}, expected Folder`)
	end
	local events = Instance.new("Folder")
	events.Name = "Events"
	events.Parent = ReplicatedStorage
	return events
end

local function watch(remote: RemoteEvent, code: string, orchestrator: any): ()
	if watched[remote] then
		return
	end
	watched[remote] = true
	remote.OnServerEvent:Connect(function(player: Player)
		-- Nothing else happens here: no payload logging, response, game work or
		-- client-facing difference that would turn the tripwire into an oracle.
		-- Cap identical evidence so one malicious loop cannot turn the journal or
		-- enforcement decision stream into a denial-of-service vector.
		if
			orchestrator.IsDetectorEnabled
			and not orchestrator.IsDetectorEnabled(RemoteTrap.Name)
		then
			return
		end
		local byCode = lastTripAt[player]
		if not byCode then
			byCode = {}
			lastTripAt[player] = byCode
		end
		local now = os.clock()
		if byCode[code] and now - byCode[code] < TRIP_COOLDOWN_SECONDS then
			return
		end
		byCode[code] = now
		orchestrator.Flag(player, `RemoteTrap:{code}`, "hard", "trap")
	end)
end

local function findPath(events: Folder, path: { string }): RemoteEvent?
	local current: Instance = events
	for _, name in ipairs(path) do
		local nextChild = current:FindFirstChild(name)
		if not nextChild then
			return nil
		end
		current = nextChild
	end
	return if current:IsA("RemoteEvent") then current else nil
end

function RemoteTrap.Init(orchestrator: any): ()
	local events = getOrCreateEvents()

	-- Per-server entropy keeps this from becoming a documented static remote.
	-- It remains replicated, so it only deters opportunistic generic tooling.
	local trap = Instance.new("RemoteEvent")
	trap.Name = `_gx_probe_{string.gsub(HttpService:GenerateGUID(false), "-", "")}`
	trap.Parent = events
	watch(trap, "Honeypot", orchestrator)

	local function attachOutboundOnly(): ()
		for _, path in ipairs(OUTBOUND_ONLY) do
			local remote = findPath(events, path)
			if remote then
				watch(remote, `WrongDirection:{table.concat(path, "/")}`, orchestrator)
			end
		end
	end

	attachOutboundOnly()
	-- Most service-owned outbound remotes are created lazily. Re-checking the
	-- small explicit allowlist on descendant additions avoids distributed
	-- connections while never treating arbitrary new remotes as traps.
	events.DescendantAdded:Connect(function()
		attachOutboundOnly()
	end)
end

return RemoteTrap
