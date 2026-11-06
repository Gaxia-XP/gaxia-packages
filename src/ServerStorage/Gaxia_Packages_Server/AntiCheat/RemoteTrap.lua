--!strict
--[[
	Module : RemoteTrap
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.RemoteTrap
	Purpose : Observe-only tripwires for client calls that no shipped client
	          should make. A honeypot RemoteEvent has no game behavior, while
	          outbound-only RemoteEvents report a wrong-direction attempt.

	These signals raise trap evidence (source "trap"), but AntiCheat runs in
	observe mode until Config.AntiCheat.Enforce = true, and AntiCheatEnforcement
	only ever kicks on trap evidence. A trap is never authentication, never grants
	state, and must not be the sole basis for a permanent ban.

	Disable it like any detector: Config.AntiCheat.RemoteTrap.Enabled = false or
	`/ac off RemoteTrap` (the host's Flag is dropped while it is disabled).
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Types = require(script.Parent.Parent.Types)

-- ── Types ──
type DetectorHost = Types.DetectorHost

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

local function watch(remote: RemoteEvent, code: string, orchestrator: DetectorHost): ()
	if watched[remote] then
		return
	end
	watched[remote] = true
	remote.OnServerEvent:Connect(function(player: Player)
		-- Nothing else happens here: no payload logging, response, game work or
		-- client-facing difference that would turn the tripwire into an oracle.
		-- Cap identical evidence so one malicious loop cannot turn the journal or
		-- enforcement decision stream into a denial-of-service vector. (The host's
		-- Flag already drops the flag while this detector is disabled.)
		local byCode = lastTripAt[player]
		if not byCode then
			byCode = {}
			lastTripAt[player] = byCode
		end
		local now = os.clock()
		local last = byCode[code]
		if last and now - last < TRIP_COOLDOWN_SECONDS then
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
	return if current:IsA("RemoteEvent") then current :: RemoteEvent else nil
end

function RemoteTrap.Init(orchestrator: DetectorHost): ()
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
