--!strict
-- ─────────────────────────────────────────────────────────────
-- InviteToast.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/InviteToast
-- Purpose : Subscribes to the Friend / Guild / Party Inbound RemoteEvents and
--           shows each "invite" / "request" as a Toast.ShowAction toast with
--           Accept and Decline buttons. Accept / Decline call the service's
--           Action RemoteFunction. Only a Decline click declines: a toast left
--           alone goes away after INVITE_TOAST_DURATION (30 s) without answering,
--           so the invite stays open on the server and the chat commands
--           (/accept, /partyjoin, /guildjoin) still work until it expires there.
--
-- Access  : Gaxia.UI.InviteToast  (client) — reach it once from a LocalScript
--   at game start (`local _ = Gaxia.UI.InviteToast`, or `require` the
--   ModuleScript), no further calls needed. Returning `true` instead of a
--   module table keeps the boot side-effect explicit.
--   Requiring it does not wait: each of the Friend, Guild and Party remote
--   pairs is looked up on its own thread (up to 10 s per missing folder or
--   remote), so a package that is not installed only skips its invites.
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

local REMOTE_WAIT : number = 10
local INVITE_TOAST_DURATION : number = 30

local function waitRemote(folderName: string, name: string): Instance?
	local Events = ReplicatedStorage:WaitForChild("Events", REMOTE_WAIT)
	if not Events then
		return nil
	end
	local folder = Events:WaitForChild(folderName, REMOTE_WAIT)
	if not folder then
		return nil
	end
	return folder:WaitForChild(name, REMOTE_WAIT)
end

-- Sends one answer to the service. A refused accept shows an error toast; a failed call warns.
local function answer(action: RemoteFunction, envelope: { [string]: any }): ()
	local okCall, ok, reason = pcall(function()
		return action:InvokeServer(envelope)
	end)
	if not okCall then
		warn(`[InviteToast] {action:GetFullName()} failed: {tostring(ok)}`)
		return
	end
	if ok == false and envelope.type == "accept" then
		Toast.Show({ Text = `Could not accept: {tostring(reason)}`, Variant = "error" })
	end
end

local function show(text: string, action: RemoteFunction, accept: { [string]: any }, decline: { [string]: any }): ()
	Toast.ShowAction({
		Title = "Invite",
		Text = text,
		Variant = "info",
		AcceptText = "Accept",
		DeclineText = "Decline",
		Duration = INVITE_TOAST_DURATION,
		DeclineOnTimeout = false, -- an ignored toast must not cancel the server-side invite
		OnAccept = function()
			answer(action, accept)
		end,
		OnDecline = function()
			answer(action, decline)
		end,
	})
end

-- Wires one service: waits for its Inbound / Action remotes on its own thread,
-- then turns each matching message into an action toast.
local function listen(folderName: string, inboundName: string, actionName: string, onMessage: (msg: { [string]: any }, action: RemoteFunction) -> ()): ()
	task.spawn(function()
		local inbound = waitRemote(folderName, inboundName)
		local action = waitRemote(folderName, actionName)
		if not (inbound and inbound:IsA("RemoteEvent") and action and action:IsA("RemoteFunction")) then
			return -- that package is not installed / not running: no invites from it
		end
		local actionFn = action :: RemoteFunction
		(inbound :: RemoteEvent).OnClientEvent:Connect(function(msg: any)
			if typeof(msg) == "table" then
				onMessage(msg, actionFn)
			end
		end)
	end)
end

listen("Friend", "Inbound", "Action", function(msg, action)
	if msg.type == "request" then
		local from = msg.from
		show(`{tostring(msg.fromName or "?")} sent you a friend request`, action,
			{ type = "accept", from = from }, { type = "decline", from = from })
	end
end)

listen("Guild", "Inbound", "Action", function(msg, action)
	if msg.type == "invite" then
		local guildId = msg.guildId
		show(`{tostring(msg.fromName or "?")} invited you to {tostring(msg.name or "a guild")}`, action,
			{ type = "accept", guildId = guildId }, { type = "decline", guildId = guildId })
	end
end)

listen("Party", "InviteInbound", "InviteAction", function(msg, action)
	if msg.type == "invite" then
		local partyId = msg.partyId
		show(`{tostring(msg.fromName or "?")} invited you to a party`, action,
			{ type = "accept", partyId = partyId }, { type = "decline", partyId = partyId })
	end
end)

return true
