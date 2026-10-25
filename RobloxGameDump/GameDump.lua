-- Game Dump: a Roblox Studio plugin that gathers the whole place into one text
-- view: the instance hierarchy (with attributes and tags) and the full source
-- of every script. Click "Dump Game" on the toolbar, then click inside the
-- window, press Ctrl+A and Ctrl+C.

local CollectionService = game:GetService("CollectionService")

local SKIP_SERVICES = {
	CoreGui = true,
	CorePackages = true,
	Players = true, -- only holds live players while playtesting
}

local INDENT = "  "

local toolbar = plugin:CreateToolbar("Game Dump")
local button = toolbar:CreateButton("Dump Game", "Dump hierarchy and all scripts into a copyable text view", "")

local widget = plugin:CreateDockWidgetPluginGui(
	"GameDumpWidget",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, true, false, 800, 600, 400, 300)
)
widget.Title = "Game Dump"

local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.fromScale(1, 1)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.CanvasSize = UDim2.fromScale(0, 0)
scroll.ScrollBarThickness = 8
scroll.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
scroll.BorderSizePixel = 0
scroll.Parent = widget

local box = Instance.new("TextBox")
box.Size = UDim2.new(1, -12, 0, 0)
box.AutomaticSize = Enum.AutomaticSize.Y
box.MultiLine = true
box.TextWrapped = true
box.ClearTextOnFocus = false
box.TextXAlignment = Enum.TextXAlignment.Left
box.TextYAlignment = Enum.TextYAlignment.Top
box.Font = Enum.Font.Code
box.TextSize = 14
box.TextColor3 = Color3.fromRGB(220, 220, 220)
box.BackgroundTransparency = 1
box.Text = "Click 'Dump Game' on the toolbar."
box.Parent = scroll

-- Appends one instance (and its children) to the hierarchy list.
local function walk(instance, depth, hierarchy, scripts)
	local line = string.rep(INDENT, depth) .. instance.Name .. " [" .. instance.ClassName .. "]"

	local attributeNames = {}
	for name in pairs(instance:GetAttributes()) do
		table.insert(attributeNames, name)
	end
	table.sort(attributeNames)
	if #attributeNames > 0 then
		local attributeTexts = {}
		for _, name in ipairs(attributeNames) do
			table.insert(attributeTexts, name .. " = " .. tostring(instance:GetAttribute(name)))
		end
		line = line .. "  {" .. table.concat(attributeTexts, ", ") .. "}"
	end

	local tags = CollectionService:GetTags(instance)
	if #tags > 0 then
		table.sort(tags)
		line = line .. "  tags: " .. table.concat(tags, ", ")
	end

	table.insert(hierarchy, line)

	if instance:IsA("LuaSourceContainer") then
		table.insert(scripts, instance)
	end

	for _, child in ipairs(instance:GetChildren()) do
		walk(child, depth + 1, hierarchy, scripts)
	end
end

local function buildDump()
	local hierarchy, scripts = {}, {}
	for _, service in ipairs(game:GetChildren()) do
		if not SKIP_SERVICES[service.Name] then
			walk(service, 0, hierarchy, scripts)
		end
	end

	local out = {
		"##### HIERARCHY (" .. #hierarchy .. " instances) #####",
		table.concat(hierarchy, "\n"),
		"",
		"##### SCRIPTS (" .. #scripts .. ") #####",
	}

	for _, container in ipairs(scripts) do
		local ok, source = pcall(function()
			return container.Source
		end)
		table.insert(out, "")
		table.insert(out, "===== " .. container:GetFullName() .. " [" .. container.ClassName .. "] =====")
		table.insert(out, ok and source or ("-- could not read source: " .. tostring(source)))
	end

	return table.concat(out, "\n"), #hierarchy, #scripts
end

button.Click:Connect(function()
	local ok, text, instanceCount, scriptCount = pcall(buildDump)
	if ok then
		box.Text = text
		print(string.format("[Game Dump] %d instances, %d scripts, %d characters", instanceCount, scriptCount, #text))
	else
		box.Text = "Dump failed: " .. tostring(text)
	end
	widget.Enabled = true
end)
