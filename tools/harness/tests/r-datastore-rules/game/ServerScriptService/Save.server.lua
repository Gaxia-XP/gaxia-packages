local ds = game:GetService("DataStoreService"):GetDataStore("Main")
local function try(name, f)
	local ok, e = pcall(f)
	print(name, ok, if ok then "" else e)
end
try("mixed", function() ds:SetAsync("a", { 1, 2, x = 3 }) end)
try("numkeys", function() ds:SetAsync("b", { [10] = 1, [20] = 2 }) end)
try("noval", function() ds:SetAsync("c") end)
local c = {}
c.x = { y = c }
try("json", function() game:GetService("HttpService"):JSONEncode(c) end)
-- the classic bug: an Instance nested in the saved table (uncaught: a red error at this line)
ds:SetAsync("player_1", { inventory = { sword = workspace } })
