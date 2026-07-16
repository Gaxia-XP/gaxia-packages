--!strict
-- Fixtures: factories for reproducible test GUIs. Returned trees are parented
-- to caller — Fixtures itself does not pollute the DataModel.
local Fixtures = {}

function Fixtures.themedButton(): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = "PlayButton"
	btn.Size = UDim2.fromOffset(160, 44)
	btn.Position = UDim2.fromScale(0.5, 0.5)
	btn.AnchorPoint = Vector2.new(0.5, 0.5)
	btn.BackgroundColor3 = Color3.fromRGB(70, 130, 200)
	btn.Text = "Play"
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.AutoButtonColor = true
	btn:SetAttribute("Variant", "primary")
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 12); c.Parent = btn
	return btn
end

function Fixtures.listFrame(): Frame
	local f = Instance.new("Frame")
	f.Name = "List"
	f.Size = UDim2.fromOffset(200, 240)
	f.BackgroundColor3 = Color3.fromRGB(40, 40, 44)
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 4); layout.Parent = f
	for i = 1, 3 do
		local row = Instance.new("TextLabel")
		row.Name = "Row" .. i
		row.Size = UDim2.new(1, 0, 0, 24)
		row.BackgroundTransparency = 1
		row.Text = "Item " .. i
		row.Parent = f
	end
	return f
end

-- A Frame that organises its buttons inside a plain Folder — the case that
-- regressed (the Serializer used to skip Folders and drop the whole subtree).
function Fixtures.groupedFrame(): Frame
	local f = Instance.new("Frame")
	f.Name = "Panel"
	f.Size = UDim2.fromOffset(220, 120)
	f.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
	local group = Instance.new("Folder")
	group.Name = "Buttons"
	group.Parent = f
	for i = 1, 2 do
		local b = Instance.new("TextButton")
		b.Name = "Btn" .. i
		b.Size = UDim2.fromOffset(80, 28)
		b.Text = "B" .. i
		b.Parent = group
	end
	return f
end

return Fixtures
