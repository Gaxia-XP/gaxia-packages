--!strict
-- ─────────────────────────────────────────────────────────────
-- InviteToast.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/InviteToast
-- Purpose : Subscribes to the Friend / Guild / Party Inbound RemoteEvents and
--           shows each "invite" / "request" as a Toast.ShowAction toast with
--           Accept and Decline buttons. Accept / Decline call the service's
--           Net RPC (Friend.AcceptRequest / Friend.DeclineRequest,
--           Guild.AcceptInvite / Guild.DeclineInvite, Party.AcceptInvite /
--           Party.DeclineInvite) through Gaxia.Net.Client.Invoke. Only a Decline
--           click declines: a toast left alone goes away after
--           INVITE_TOAST_DURATION (30 s) without answering, so the invite stays
--           open on the server and the chat commands (/accept, /partyjoin,
--           /guildjoin) still work until it expires there.
--
-- Access  : Gaxia.UI.InviteToast  (client) — reach it once from a LocalScript
--   at game start (`local _ = Gaxia.UI.InviteToast`, or `require` the
--   ModuleScript), no further calls needed. Returning `true` instead of a
--   module table keeps the boot side-effect explicit.
--   Requiring it does not wait: each of the Friend, Guild and Party Inbound
--   remotes is looked up on its own thread (up to 10 s per missing folder or
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
local Net = require(script.Parent.Parent.Parent.Shared.NetService)

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

-- Why a social RPC refused, or nil when it succeeded. Net rejects as
-- `{ ok = false, code }`; the services answer `{ ok = true, data = { ok, reason } }`
-- (Guild puts the reason in `data.data`).
local function refusal(result: Net.RpcResult): any?
	if result.ok ~= true then
		return result.code
	end
	local data = result.data
	if typeof(data) == "table" and data.ok == false then
		return data.reason or data.data or "refused"
	end
	return nil
end

-- Sends one answer to the service. A refused accept shows an error toast; a failed call warns.
local function answer(rpc: string, payload: { [string]: any }, isAccept: boolean): ()
	local okCall, result = pcall(Net.Client.Invoke, rpc, payload)
	if not okCall then
		warn(`[InviteToast] {rpc} failed: {tostring(result)}`)
		return
	end
	local reason = refusal(result)
	if reason ~= nil and isAccept then
		Toast.Show({ Text = `Could not accept: {tostring(reason)}`, Variant = "error" })
	end
end

local function show(text: string, acceptRpc: string, declineRpc: string, payload: { [string]: any }): ()
	Toast.ShowAction({
		Title = "Invite",
		Text = text,
		Variant = "info",
		AcceptText = "Accept",
		DeclineText = "Decline",
		Duration = INVITE_TOAST_DURATION,
		DeclineOnTimeout = false, -- an ignored toast must not cancel the server-side invite
		OnAccept = function()
			answer(acceptRpc, payload, true)
		end,
		OnDecline = function()
			answer(declineRpc, payload, false)
		end,
	})
end

-- Wires one service: waits for its Inbound remote on its own thread, then
-- turns each matching message into an action toast.
local function listen(folderName: string, inboundName: string, onMessage: (msg: { [string]: any }) -> ()): ()
	task.spawn(function()
		local inbound = waitRemote(folderName, inboundName)
		if not (inbound and inbound:IsA("RemoteEvent")) then
			return -- that package is not installed / not running: no invites from it
		end
		(inbound :: RemoteEvent).OnClientEvent:Connect(function(msg: any)
			if typeof(msg) == "table" then
				onMessage(msg)
			end
		end)
	end)
end

listen("Friend", "Inbound", function(msg)
	if msg.type == "request" then
		show(`{tostring(msg.fromName or "?")} sent you a friend request`,
			"Friend.AcceptRequest", "Friend.DeclineRequest", { fromUserId = msg.from })
	end
end)

listen("Guild", "Inbound", function(msg)
	if msg.type == "invite" then
		show(`{tostring(msg.fromName or "?")} invited you to {tostring(msg.name or "a guild")}`,
			"Guild.AcceptInvite", "Guild.DeclineInvite", { guildId = msg.guildId })
	end
end)

listen("Party", "InviteInbound", function(msg)
	if msg.type == "invite" then
		show(`{tostring(msg.fromName or "?")} invited you to a party`,
			"Party.AcceptInvite", "Party.DeclineInvite", { partyId = msg.partyId })
	end
end)

return true
