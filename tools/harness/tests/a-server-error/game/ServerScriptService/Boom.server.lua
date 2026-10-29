-- A runtime error at the top level of a server Script.
local config = nil
print("before the error")
local speed = config.WalkSpeed -- line 4: attempt to index nil
print("never printed", speed)
