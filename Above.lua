local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Safe remote folder & event fetching
local remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
if not remotes then
	warn("Remotes folder not found! Check game structure.")
	return
end

local SwingEvent = remotes:WaitForChild("RequestSwing", 5)
local EquipEvent = remotes:WaitForChild("RequestEquipSlot", 5)
local DropEvent = remotes:WaitForChild("RequestDrop", 5)

local Hub = workspace:WaitForChild("Hub", 5)
local Guardians = Hub and Hub:WaitForChild("Guardians", 5)
local ResourceField = Hub and Hub:WaitForChild("ResourceField", 5)

----------------------------------------------------------------
-- Settings & Config
----------------------------------------------------------------
local Config = {
	Timestamps = {
		LastHit = 0,
		HitCooldown = 0.1, -- mob swing delay
	}
}

local STAND_DISTANCE = 4          -- resources stand distance
local SIDE_OFFSET = 2             -- resources side offset
local REPOSITION_DIST = 8
local SWING_DELAY_RES = 0
local TOGGLE_KEY = Enum.KeyCode.K
local SKIP_KEY = Enum.KeyCode.J
local MIN_Y_POSITION = 200

local TREE_KEYWORDS = { "tree" }
local MOB_SLOT = nil
local MAX_RESOURCE_TIME = 10
local RESOURCE_COOLDOWN = 30

local COLOR_ON = Color3.fromRGB(50, 170, 80)
local COLOR_OFF = Color3.fromRGB(170, 50, 50)
local COLOR_TAB_ON = Color3.fromRGB(70, 110, 190)
local COLOR_TAB_OFF = Color3.fromRGB(55, 55, 62)
local COLOR_SUB_ON = Color3.fromRGB(90, 130, 80)
local COLOR_SUB_OFF = Color3.fromRGB(65, 65, 75)

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local enabled = false
local shownTab = nil
local resourceFilter = "Both"
local runId = 0
local currentTarget = nil
local skipRequested = false
local skipped = {}
local cooldowns = {}
local equipped = nil
local pages, tabs = {}, {}
local filterButtons = {}

-- Drop loop state
local dropEnabled = false
local dropItemName = "IronOre"
local dropSpeed = 0.1

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------
local function getRoot()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function mobAlive(mob)
	if not mob or not mob.Parent then return false end
	local hum = mob:FindFirstChildOfClass("Humanoid")
	if hum then
		return hum.Health > 0
	end
	return true
end

local function isTree(res)
	local name = res.Name:lower()
	for _, keyword in ipairs(TREE_KEYWORDS) do
		if name:find(keyword, 1, true) then
			return true
		end
	end
	return false
end

local function resourceAvailable(res)
	if not res or not res.Parent then return false end
	
	local swingPart = res:FindFirstChild("Plane") or (res:IsA("Model") and res.PrimaryPart) or res
	if not swingPart then return false end

	local hp = res:GetAttribute("Health") or swingPart:GetAttribute("Health")
	if type(hp) == "number" and hp <= 0 then return false end
	
	local tree = isTree(res)
	if resourceFilter == "Trees" and not tree then return false end
	if resourceFilter == "Others" and tree then return false end
	
	return true
end

local MODES = {
	Mobs = {
		folder = Guardians,
		isCandidate = function(m) return m:IsA("Model") or m:IsA("BasePart") end,
		isValid = mobAlive,
		swingTarget = function(m) 
			if m:IsA("Model") then
				return m.PrimaryPart or m:FindFirstChild("HumanoidRootPart") or m:FindFirstChildWhichIsA("BasePart")
			end
			return m
		end,
		position = function(m) return m:GetPivot().Position end,
		tool = function() return MOB_SLOT end,
	},
	Resources = {
		folder = ResourceField,
		isCandidate = function(r) return r:IsA("Model") or r:IsA("BasePart") end,
		isValid = resourceAvailable,
		swingTarget = function(r) 
			return r:FindFirstChild("Plane") or (r:IsA("Model") and r.PrimaryPart) or r 
		end,
		position = function(r)
			if r:IsA("Model") then
				local primary = r.PrimaryPart or r:FindFirstChild("Plane")
				if primary and primary:IsA("BasePart") then
					return primary.Position
				end
				return r:GetPivot().Position
			elseif r:IsA("BasePart") then
				return r.Position
			end
			return nil
		end,
		tool = function(r) return isTree(r) and "Axe" or "Pickaxe" end,
		maxTime = MAX_RESOURCE_TIME,
	},
}

local function equip(slot)
	if not slot or not EquipEvent or slot == equipped then return end
	EquipEvent:FireServer(slot)
	equipped = slot
	task.wait(0.3)
end

----------------------------------------------------------------
-- AutoFarm Logic for Mobs (Swaying in air above slime)
----------------------------------------------------------------
local function runMobAutoFarm()
	if not Guardians then return end
	local closestDist = math.huge
	local closestEntry = nil
	local closestPos = nil

	local hrp = getRoot()
	local hum = getHumanoid()
	if not hrp or not hum then return end

	for _, v in ipairs(Guardians:GetChildren()) do
		if MODES.Mobs.isCandidate(v) and mobAlive(v) then
			local pos = MODES.Mobs.position(v)
			if pos and pos.Y >= MIN_Y_POSITION then
				local distance = (pos - hrp.Position).Magnitude
				if distance < closestDist then
					closestDist = distance
					closestEntry = v
					closestPos = pos
				end
			end
		end
	end

	if closestEntry and closestPos then
		currentTarget = closestEntry
		hum.PlatformStand = true
		hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		hrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0)

		local direction = (closestPos - hrp.Position).Unit
		local rightVector = direction:Cross(Vector3.new(0, 1, 0))
		if rightVector.Magnitude == 0 then
			rightVector = Vector3.new(1, 0, 0)
		else
			rightVector = rightVector.Unit
		end

		local swayAmount = math.sin(tick() * 5) * 2.5
		local newPosition = closestPos - (direction * 2.5) + (rightVector * swayAmount) + Vector3.new(0, 2.5, 0)
		
		hrp.CFrame = CFrame.new(newPosition, closestPos)

		if (tick() - Config.Timestamps.LastHit >= Config.Timestamps.HitCooldown) then
			Config.Timestamps.LastHit = tick()
			local swingTarget = MODES.Mobs.swingTarget(closestEntry)
			if swingTarget and SwingEvent then
				SwingEvent:FireServer(swingTarget)
			end
		end
	else
		currentTarget = nil
		hum.PlatformStand = false
	end
end

----------------------------------------------------------------
-- Resource Farm Loop (Ground snapping)
----------------------------------------------------------------
local function placeNearResource(mode, entry)
	local char = player.Character
	local hrp = getRoot()
	local hum = getHumanoid()
	local targetPos = mode.position(entry)
	if not (char and hrp and hum and targetPos) then return end

	local away = Vector3.new(hrp.Position.X - targetPos.X, 0, hrp.Position.Z - targetPos.Z)
	if away.Magnitude < 0.1 then
		away = Vector3.new(1, 0, 0)
	else
		away = away.Unit
	end

	local sideVec = Vector3.new(-away.Z, 0, away.X)
	local standXZ = targetPos + (away * STAND_DISTANCE) + (sideVec * SIDE_OFFSET)

	local ignore = { char, entry }
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true

	local groundY = targetPos.Y
	local rayOrigin = Vector3.new(standXZ.X, targetPos.Y + 6, standXZ.Z)
	local rayDirection = Vector3.new(0, -25, 0)

	for i = 1, 3 do
		params.FilterDescendantsInstances = ignore
		local hit = workspace:Raycast(rayOrigin, rayDirection, params)
		if hit then
			local hitPart = hit.Instance
			local nameLower = hitPart.Name:lower()
			if nameLower:find("tree") or nameLower:find("leaf") or nameLower:find("branch") or nameLower:find("foliage") then
				table.insert(ignore, hitPart)
			else
				groundY = hit.Position.Y
				break
			end
		else
			break
		end
	end

	local y = groundY + hum.HipHeight + (hrp.Size.Y / 2) + 0.2
	if hum.RigType == Enum.HumanoidRigType.R6 then
		y = y + 2
	end

	local standPos = Vector3.new(standXZ.X, y, standXZ.Z)
	hrp.CFrame = CFrame.lookAt(standPos, Vector3.new(targetPos.X, y, targetPos.Z))
	hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
	hrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
end

local function pickResourceTarget(mode)
	local hrp = getRoot()
	if not hrp or not mode.folder then return nil end
	local now = os.clock()

	local function search(ignoreSkipped)
		local best, bestDist = nil, math.huge
		for _, entry in ipairs(mode.folder:GetChildren()) do
			if mode.isCandidate(entry) then
				local pos = mode.position(entry)
				if pos and pos.Y >= MIN_Y_POSITION then
					if not mode.isValid(entry) then
						skipped[entry] = nil
					elseif not (cooldowns[entry] and cooldowns[entry] > now)
						and not (ignoreSkipped and skipped[entry]) then
						local dist = (pos - hrp.Position).Magnitude
						if dist < bestDist then
							best, bestDist = entry, dist
						end
					end
				end
			end
		end
		return best
	end

	local entry = search(true)
	if not entry and next(skipped) then
		skipped = {}
		entry = search(false)
	end
	return entry
end

local function resourceFarmLoop(id)
	local mode = MODES["Resources"]
	local status = pages["Resources"].status
	local function alive()
		return enabled and shownTab == "Resources" and id == runId
	end

	while alive() do
		local entry = pickResourceTarget(mode)
		if not entry then
			currentTarget = nil
			status.Text = "Waiting for targets..."
			task.wait(0.5)
		else
			currentTarget = entry
			status.Text = "Target: " .. entry.Name

			equip(mode.tool(entry))
			if not alive() then break end
			placeNearResource(mode, entry)

			local started = os.clock()
			while alive() and mode.isValid(entry) and not skipRequested and getRoot() do
				if mode.maxTime and os.clock() - started > mode.maxTime then
					cooldowns[entry] = os.clock() + RESOURCE_COOLDOWN
					break
				end
				local swingTarget = mode.swingTarget(entry)
				if not swingTarget then break end

				local pos = mode.position(entry)
				if pos and (getRoot().Position - pos).Magnitude > REPOSITION_DIST then
					placeNearResource(mode, entry)
				end

				if SwingEvent then
					SwingEvent:FireServer(swingTarget)
				end
				task.wait(SWING_DELAY_RES)
			end

			if skipRequested then
				skipRequested = false
				if mode.isValid(entry) then
					skipped[entry] = true
				end
			end
			task.wait()
		end
	end

	if id == runId then
		currentTarget = nil
	end
end

----------------------------------------------------------------
-- Toggles & Tab Management
----------------------------------------------------------------
RunService.Heartbeat:Connect(function()
	if enabled and shownTab == "Mobs" then
		runMobAutoFarm()
	end
end)

local function setEnabled(modeName, state)
	enabled = state
	runId += 1
	skipRequested = false
	skipped = {}
	cooldowns = {}
	equipped = nil
	currentTarget = nil

	local hum = getHumanoid()
	if hum and not enabled then
		hum.PlatformStand = false
	end

	for name, p in pairs(pages) do
		if name ~= "Drop" then
			local on = enabled and name == modeName
			p.toggle.Text = on and "ON" or "OFF"
			p.toggle.BackgroundColor3 = on and COLOR_ON or COLOR_OFF
			if not on then
				p.status.Text = "Idle"
			end
		end
	end

	if enabled and modeName == "Resources" then
		task.spawn(resourceFarmLoop, runId)
	end
end

local function setDropEnabled(state)
	dropEnabled = state
	local dropPage = pages["Drop"]
	if dropPage then
		dropPage.toggle.Text = dropEnabled and "ON" or "OFF"
		dropPage.toggle.BackgroundColor3 = dropEnabled and COLOR_ON or COLOR_OFF
		dropPage.status.Text = dropEnabled and ("Dropping: " .. dropItemName) or "Idle"
	end

	if dropEnabled then
		spawn(function()
			while dropEnabled and DropEvent do
				pcall(function()
					DropEvent:FireServer(dropItemName, 1)
				end)
				task.wait(math.max(0.001, dropSpeed))
			end
		end)
	end
end

local function skipCurrent()
	if enabled and currentTarget then
		skipRequested = true
	end
end

local function setResourceFilter(filterName)
	resourceFilter = filterName
	for name, btn in pairs(filterButtons) do
		local selected = (name == filterName)
		btn.BackgroundColor3 = selected and COLOR_SUB_ON or COLOR_SUB_OFF
	end
	skipped = {}
	cooldowns = {}
end

local function showTab(name)
	if name == shownTab then return end
	
	if enabled then
		setEnabled(shownTab, false)
	end

	shownTab = name
	for n, p in pairs(pages) do
		p.page.Visible = (n == name)
	end
	for n, t in pairs(tabs) do
		t.BackgroundColor3 = (n == name) and COLOR_TAB_ON or COLOR_TAB_OFF
	end
end

----------------------------------------------------------------
-- GUI Construction
----------------------------------------------------------------
local old = playerGui:FindFirstChild("FarmGui")
if old then old:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "FarmGui"
gui.ResetOnSpawn = false
gui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(240, 210)
frame.Position = UDim2.new(0, 20, 0.4, 0)
frame.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
frame.BorderSizePixel = 0
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 24)
title.BackgroundColor3 = Color3.fromRGB(45, 45, 52)
title.BorderSizePixel = 0
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextColor3 = Color3.new(1, 1, 1)
title.Text = "Farm & Drop Hub (drag me)"
title.Parent = frame
Instance.new("UICorner", title).CornerRadius = UDim.new(0, 8)

local function makeButton(parent, text, pos, size, color, textSize)
	local b = Instance.new("TextButton")
	b.Size = size
	b.Position = pos
	b.BackgroundColor3 = color
	b.BorderSizePixel = 0
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Font = Enum.Font.GothamBold
	b.TextSize = textSize or 14
	b.Text = text
	b.Parent = parent
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
	return b
end

local function makePage(index, modeName)
	local totalWidth = 240
	local padding = 10
	local spacing = 6
	local tabWidth = (totalWidth - (padding * 2) - (spacing * 2)) / 3
	local tabX = padding + (index - 1) * (tabWidth + spacing)

	local tab = makeButton(frame, modeName, UDim2.fromOffset(tabX, 30), UDim2.fromOffset(tabWidth, 24), COLOR_TAB_OFF, 11)
	tabs[modeName] = tab

	local page = Instance.new("Frame")
	page.Size = UDim2.new(1, 0, 1, -58)
	page.Position = UDim2.fromOffset(0, 58)
	page.BackgroundTransparency = 1
	page.Visible = false
	page.Parent = frame

	local startY = 0

	if modeName == "Resources" then
		local btnWidth = (240 - 30) / 3
		local fAll = makeButton(page, "All", UDim2.fromOffset(10, 0), UDim2.fromOffset(btnWidth, 24), COLOR_SUB_ON, 11)
		local fTrees = makeButton(page, "Trees", UDim2.fromOffset(15 + btnWidth, 0), UDim2.fromOffset(btnWidth, 24), COLOR_SUB_OFF, 11)
		local fOthers = makeButton(page, "Others", UDim2.fromOffset(20 + btnWidth * 2, 0), UDim2.fromOffset(btnWidth, 24), COLOR_SUB_OFF, 11)

		filterButtons["Both"] = fAll
		filterButtons["Trees"] = fTrees
		filterButtons["Others"] = fOthers

		fAll.MouseButton1Click:Connect(function() setResourceFilter("Both") end)
		fTrees.MouseButton1Click:Connect(function() setResourceFilter("Trees") end)
		fOthers.MouseButton1Click:Connect(function() setResourceFilter("Others") end)

		startY = 30
	elseif modeName == "Drop" then
		local itemBox = Instance.new("TextBox")
		itemBox.Size = UDim2.new(1, -20, 0, 26)
		itemBox.Position = UDim2.fromOffset(10, 0)
		itemBox.BackgroundColor3 = Color3.fromRGB(45, 45, 52)
		itemBox.BorderSizePixel = 0
		itemBox.TextColor3 = Color3.new(1, 1, 1)
		itemBox.PlaceholderText = "Item Name"
		itemBox.Text = dropItemName
		itemBox.Font = Enum.Font.Gotham
		itemBox.TextSize = 13
		itemBox.Parent = page
		Instance.new("UICorner", itemBox).CornerRadius = UDim.new(0, 6)

		itemBox.FocusLost:Connect(function()
			if itemBox.Text ~= "" then
				dropItemName = itemBox.Text
			end
		end)

		local speedBox = Instance.new("TextBox")
		speedBox.Size = UDim2.new(1, -20, 0, 26)
		speedBox.Position = UDim2.fromOffset(10, 32)
		speedBox.BackgroundColor3 = Color3.fromRGB(45, 45, 52)
		speedBox.BorderSizePixel = 0
		speedBox.TextColor3 = Color3.new(1, 1, 1)
		speedBox.PlaceholderText = "Speed (seconds)"
		speedBox.Text = tostring(dropSpeed)
		speedBox.Font = Enum.Font.Gotham
		speedBox.TextSize = 13
		speedBox.Parent = page
		Instance.new("UICorner", speedBox).CornerRadius = UDim.new(0, 6)

		speedBox.FocusLost:Connect(function()
			local num = tonumber(speedBox.Text)
			if num then
				dropSpeed = num
			else
				speedBox.Text = tostring(dropSpeed)
			end
		end)

		startY = 64
	end

	local toggle = makeButton(page, "OFF", UDim2.fromOffset(10, startY), UDim2.new(1, -20, 0, 32), COLOR_OFF, 16)
	
	local skip = nil
	if modeName ~= "Drop" then
		skip = makeButton(page, "Skip >>", UDim2.fromOffset(10, startY + 38), UDim2.new(1, -20, 0, 32), Color3.fromRGB(60, 90, 160), 16)
	end

	local status = Instance.new("TextLabel")
	status.Size = UDim2.new(1, -20, 0, 18)
	status.Position = UDim2.fromOffset(10, startY + (modeName == "Drop" and 38 or 76))
	status.BackgroundTransparency = 1
	status.Font = Enum.Font.Gotham
	status.TextSize = 12
	status.TextColor3 = Color3.fromRGB(200, 200, 200)
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.Text = "Idle"
	status.Parent = page

	pages[modeName] = { page = page, toggle = toggle, status = status }

	tab.MouseButton1Click:Connect(function() showTab(modeName) end)
	
	if modeName == "Drop" then
		toggle.MouseButton1Click:Connect(function() setDropEnabled(not dropEnabled) end)
	else
		toggle.MouseButton1Click:Connect(function() setEnabled(modeName, not enabled) end)
		if skip then
			skip.MouseButton1Click:Connect(skipCurrent)
		end
	end
end

makePage(1, "Mobs")
makePage(2, "Resources")
makePage(3, "Drop")

-- Dragging logic
local dragging, dragStart, startPos
title.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPos = frame.Position
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
			end
		end)
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch) then
		local delta = input.Position - dragStart
		frame.Position = UDim2.new(
			startPos.X.Scale, startPos.X.Offset + delta.X,
			startPos.Y.Scale, startPos.Y.Offset + delta.Y
		)
	end
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == TOGGLE_KEY then
		if shownTab == "Drop" then
			setDropEnabled(not dropEnabled)
		else
			setEnabled(shownTab, not enabled)
		end
	elseif input.KeyCode == SKIP_KEY and shownTab ~= "Drop" then
		skipCurrent()
	end
end)

player.CharacterAdded:Connect(function()
	equipped = nil
end)

showTab("Mobs")
