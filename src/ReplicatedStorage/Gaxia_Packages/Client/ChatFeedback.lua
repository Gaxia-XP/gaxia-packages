--!strict
--[[
	Module : ChatFeedback
	Location: ReplicatedStorage/Gaxia_Packages/Client/ChatFeedback
	Purpose : Client-side delivery for server chat-command replies.
	          TextChannel:DisplaySystemMessage is a CLIENT-ONLY API, so the
	          server (ChatCommandSystem.reply) fires Events/Chat/SystemMessage
	          at the caller and this module renders it locally — a TCS system
	          line when TextChatService is active, SetCore
	          ChatMakeSystemMessage fallback for legacy chat.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService   = game:GetService("TextChatService")
local StarterGui        = game:GetService("StarterGui")

local ChatFeedback = {}

-- ── Display ──
local function display(text: string): ()
	-- Modern path: local system line in the general channel (caller-only).
	local channels = TextChatService:FindFirstChild("TextChannels")
	local general = channels and channels:FindFirstChild("RBXGeneral")
	if general and general:IsA("TextChannel") then
		local ok = pcall(function()
			(general :: TextChannel):DisplaySystemMessage(text)
		end)
		if ok then return end
	end
	-- Legacy chat fallback. pcall: SetCore throws until the chat core registers.
	pcall(function()
		StarterGui:SetCore("ChatMakeSystemMessage", { Text = text })
	end)
end

ChatFeedback.Display = display

-- ── Wire on require ──
-- The module is pre-warmed by Gaxia_ClientBootstrap so this subscription is
-- live before the player can type a command.
task.spawn(function()
	local events = ReplicatedStorage:WaitForChild("Events", 30)
	if not events then return end
	local chatFolder = events:WaitForChild("Chat", 30)
	if not chatFolder then return end
	local remote = chatFolder:WaitForChild("SystemMessage", 30)
	if remote and remote:IsA("RemoteEvent") then
		remote.OnClientEvent:Connect(function(text: unknown)
			if typeof(text) == "string" and #text > 0 then
				display(text)
			end
		end)
	end
end)

return ChatFeedback
