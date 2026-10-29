harness.advance(1)
local p = harness.join("Player1")
harness.advance(2)
print("sword:", harness.activateTool(p, "Sword"))
print("equipped:", harness.runServer([[return game.Players.Player1.Character:FindFirstChild("Sword") ~= nil]]))
-- a click does nothing on a ManualActivationOnly tool
print("wand click:", harness.activateTool(p, "Wand"))
-- Tool:Activate() on the server fires Activated on the server only
harness.runServer([[game.Players.Player1.Character.Wand:Activate()]])
-- Tool:Activate() on a tool that is not equipped does nothing
harness.runServer([[game.Players.Player1.Backpack.Sword:Activate()]])
harness.advance(1)
