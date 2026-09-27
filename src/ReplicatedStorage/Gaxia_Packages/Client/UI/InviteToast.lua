--!strict
-- ─────────────────────────────────────────────────────────────
-- InviteToast.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/InviteToast
-- Purpose : Subscribes to Friend / Guild / Party Inbound RemoteEvents and
--           surfaces a toast for each "invite" / "request" event. The toast is
--           supposed to expose Accept and Decline actions, but the current
--           sibling Toast component only ships `Show()` (text + variant — no
--           action buttons). Until a ShowAction variant lands, we fall back to
--           a plain warn() so the events still log somewhere visible in dev
--           builds — and we feature-detect Toast.ShowAction so the day the
--           proper component lands, no edit here is needed.
--
-- Access  : Gaxia.UI.InviteToast  (client) — just `require` it from a
--   LocalScript at game start, no further calls needed. Returning `true`
--   instead of a module table keeps the boot side-effect explicit.
--   Requiring it WAITS (up to 10 s per missing folder/remote; about 20 s when
--   PartyService is not running) for the Friend, Guild and Party remotes, so
--   `require` the ModuleScript directly from a LocalScript. Reaching it through
--   Gaxia.UI.InviteToast runs it inside the loader's __index, which cannot wait:
--   that fails (nil + warning) whenever one of those remotes is missing.
-- ─────────────────────────────────────────────────────────────
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- ── Server stub ──
-- If this module is required on the server (via the UI namespace proxy in the
-- loader) we no-op out — connecting to RemoteEvents from the server side via
-- :OnClientEvent would fault.
if not RunService:IsClient() then
	return true
end

local Toast = require(script.Parent.Toast)

local function waitRemote(folderName: string, name: string): Instance?
	local Events = ReplicatedStorage:WaitForChild("Events", 10)
	if not Events then
		return nil
	end
	local folder = Events:WaitForChild(folderName, 10)
	if not folder then
		return nil
	end
	return folder:WaitForChild(name, 10)
end

local FriendInbound = waitRemote("Friend", "Inbound") :: RemoteEvent?
local FriendAction = waitRemote("Friend", "Action") :: RemoteFunction?
local GuildInbound = waitRemote("Guild", "Inbound") :: RemoteEvent?
local GuildAction = waitRemote("Guild", "Action") :: RemoteFunction?
local PartyInbound = waitRemote("Party", "InviteInbound") :: RemoteEvent?
local PartyAction = waitRemote("Party", "InviteAction") :: RemoteFunction?

local function show(text: string, onAccept: () -> (), onDecline: () -> ()): ()
	-- Feature-detect a future ShowAction(text, acceptLabel, onAccept, declineLabel, onDecline)
	-- (not part of Toast's API yet, hence the `any` index).
	if Toast and typeof((Toast :: any).ShowAction) == "function" then
		(Toast :: any).ShowAction(text, "Accept", onAccept, "Decline", onDecline)
		return
	end
	-- Fallback: surface the invite so dev/QA can see it, even without buttons.
	-- The Accept/Decline closures are intentionally still captured here so a
	-- future ShowAction wire-up needs zero code change at the call sites.
	warn(`[InviteToast] {text} (accept/decline unavailable — Toast.ShowAction not implemented)`)
	-- Reference the closures so strict-mode doesn't flag them unused.
	local _ = onAccept
	local _ = onDecline
end

if FriendInbound and FriendAction then
	FriendInbound.OnClientEvent:Connect(function(msg)
		if typeof(msg) ~= "table" then
			return
		end
		if msg.type == "request" then
			local from = msg.from
			show(`{tostring(msg.fromName or "?")} sent you a friend request`, function()
				(FriendAction :: RemoteFunction):InvokeServer({ type = "accept", from = from })
			end, function()
				(FriendAction :: RemoteFunction):InvokeServer({ type = "decline", from = from })
			end)
		end
	end)
end

if GuildInbound and GuildAction then
	GuildInbound.OnClientEvent:Connect(function(msg)
		if typeof(msg) ~= "table" then
			return
		end
		if msg.type == "invite" then
			local guildId = msg.guildId
			show(
				`{tostring(msg.fromName or "?")} invited you to {tostring(msg.name or "a guild")}`,
				function()
					(GuildAction :: RemoteFunction):InvokeServer({
						type = "accept",
						guildId = guildId,
					})
				end,
				function()
					(GuildAction :: RemoteFunction):InvokeServer({
						type = "decline",
						guildId = guildId,
					})
				end
			)
		end
	end)
end

if PartyInbound and PartyAction then
	PartyInbound.OnClientEvent:Connect(function(msg)
		if typeof(msg) ~= "table" then
			return
		end
		if msg.type == "invite" then
			local partyId = msg.partyId
			show(`{tostring(msg.fromName or "?")} invited you to a party`, function()
				(PartyAction :: RemoteFunction):InvokeServer({ type = "accept", partyId = partyId })
			end, function()
				(PartyAction :: RemoteFunction):InvokeServer({ type = "decline", partyId = partyId })
			end)
		end
	end)
end

return true
