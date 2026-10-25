-- Game Dump: a Roblox Studio plugin that gathers the whole place into one text
-- view: the instance hierarchy (with attributes and tags) and the full source
-- of every script. Click "Dump Game" on the toolbar, then in each part click
-- inside it, press Ctrl+A and Ctrl+C, and paste the parts in order.

local CollectionService = game:GetService("CollectionService")

local SKIP_SERVICES = {
	CoreGui = true,
	CorePackages = true,
	Players = true, -- only holds live players while playtesting
}

local INDENT = "  "

-- A TextBox refuses Text longer than 200000 characters, so the dump is split
-- into parts below this size.
local CHUNK_LIMIT = 180000

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

local layout = Instance.new("UIListLayout")
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 8)
layout.Parent = scroll

local function showText(text, layoutOrder)
	local box = Instance.new("TextBox")
	box.LayoutOrder = layoutOrder
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
	box.Text = text
	box.Parent = scroll
end

local function showParts(parts)
	for _, child in ipairs(scroll:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	for index, part in ipairs(parts) do
		local label = Instance.new("TextLabel")
		label.LayoutOrder = index * 2 - 1
		label.Size = UDim2.new(1, -12, 0, 20)
		label.BackgroundTransparency = 1
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Font = Enum.Font.GothamBold
		label.TextSize = 14
		label.TextColor3 = Color3.fromRGB(255, 200, 80)
		label.Text = string.format("Part %d of %d (click inside, Ctrl+A, Ctrl+C)", index, #parts)
		label.Parent = scroll

		showText(part, index * 2)
	end
end

-- Splits text into pieces of at most CHUNK_LIMIT characters, cutting at the
-- last newline in each piece so that no line is split.
local function splitIntoParts(text)
	local parts = {}
	local start = 1
	while start <= #text do
		local stop = math.min(start + CHUNK_LIMIT - 1, #text)
		if stop < #text then
			local lastNewline = text:sub(start, stop):match(".*()\n")
			if lastNewline then
				stop = start + lastNewline - 1
			end
		end
		table.insert(parts, text:sub(start, stop))
		start = stop + 1
	end
	return parts
end

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
		showParts(splitIntoParts(text))
		print(string.format("[Game Dump] %d instances, %d scripts, %d characters", instanceCount, scriptCount, #text))
	else
		showParts({ "Dump failed: " .. tostring(text) })
	end
	widget.Enabled = true
end)
