-- TOCHIPYRO Enhanced (client-side)
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ENLARGE_SCALE = 1.75

local petContainers = {
    workspace,
    workspace:FindFirstChild("Pets"),
    workspace:FindFirstChild("PetSlots"),
    workspace:FindFirstChild("GardenSlots"),
}

local enlargedPetIds = {}         -- exact ids (preferred)
local enlargedPetNames = {}       -- fallback by name
local fingerprintMap = {}         -- fallback by mesh fingerprint
local petUpdateLoops = {}

-- small helper: build a simple fingerprint from SpecialMesh MeshId/TextureId
local function getFingerprint(model)
    local parts = {}
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("SpecialMesh") then
            parts[#parts+1] = tostring(d.MeshId or "") .. "|" .. tostring(d.TextureId or "")
        end
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

-- same as your getPetUniqueId but slightly more defensive
local function getPetUniqueId(petModel)
    if not petModel then return nil end
    local id = petModel:GetAttribute("PetID")
            or petModel:GetAttribute("UniqueID")
            or petModel:GetAttribute("PetGUID")
            or petModel:GetAttribute("OwnerUserId")
    if id then return tostring(id) end
    local owner = petModel:GetAttribute("Owner") or LocalPlayer.Name
    return petModel.Name .. "_" .. tostring(owner)
end

-- scale function (kept your behavior, only added safety)
local function scaleModelWithJoints(model, scaleFactor)
    if not model or not model.Parent then return end

    for _, obj in ipairs(model:GetDescendants()) do
        if obj:IsA("BasePart") then
            obj.Size = obj.Size * scaleFactor
            if obj.CanSetNetworkOwnership then
                pcall(function() obj:SetNetworkOwner(LocalPlayer) end)
            end
        elseif obj:IsA("SpecialMesh") then
            obj.Scale = obj.Scale * scaleFactor
        elseif obj:IsA("Decal") or obj:IsA("Texture") then
            if obj.StudsPerTileU then
                obj.StudsPerTileU = obj.StudsPerTileU * scaleFactor
                obj.StudsPerTileV = obj.StudsPerTileV * scaleFactor
            end
        elseif obj:IsA("Motor6D") or obj:IsA("Weld") or obj:IsA("WeldConstraint") then
            -- keep your existing joint-handling (avoid risky changes)
            if obj:IsA("Motor6D") then
                local c0Pos = obj.C0.Position * scaleFactor
                local c1Pos = obj.C1.Position * scaleFactor
                obj.C0 = CFrame.new(c0Pos) * (obj.C0 - obj.C0.Position)
                obj.C1 = CFrame.new(c1Pos) * (obj.C1 - obj.C1.Position)
            elseif obj:IsA("Weld") then
                local c0Pos = obj.C0.Position * scaleFactor
                local c1Pos = obj.C1.Position * scaleFactor
                obj.C0 = CFrame.new(c0Pos) * (obj.C0 - obj.C0.Position)
                obj.C1 = CFrame.new(c1Pos) * (obj.C1 - obj.C1.Position)
            end
        end
    end

    model:SetAttribute("TOCHIPYRO_Enlarged", true)
    model:SetAttribute("TOCHIPYRO_Scale", scaleFactor)
end

-- helper to apply scaling multiple times (to survive quick server rewrites)
local function reapplyEnlargeTo(pet)
    if not pet then return end
    -- try several times with small delays
    for i = 1, 6 do
        task.delay(0.05 * i, function()
            if pet and pet.Parent then
                pcall(function()
                    scaleModelWithJoints(pet, ENLARGE_SCALE)
                end)
            end
        end)
    end
end

local function markPetAsEnlarged(pet)
    local id = getPetUniqueId(pet)
    if id then
        enlargedPetIds[id] = true
    end
    enlargedPetNames[pet.Name] = true
    local fp = getFingerprint(pet)
    if fp ~= "" then fingerprintMap[fp] = true end
    pet:SetAttribute("TOCHIPYRO_EnlargedWanted", true) -- mark local model
    print("[TOCHIPYRO] Marked:", pet.Name, "id:", id, "fp:", #fp>0 and fp or "none")
end

-- monitoring loop (keeps a pet enlarged if it loses attribute)
local function startPetMonitoring(pet)
    local id = getPetUniqueId(pet)
    if not id then return end

    if petUpdateLoops[id] then
        petUpdateLoops[id]:Disconnect()
    end

    petUpdateLoops[id] = RunService.Heartbeat:Connect(function()
        if not pet or not pet.Parent then
            if petUpdateLoops[id] then petUpdateLoops[id]:Disconnect() petUpdateLoops[id] = nil end
            return
        end

        -- If we want it enlarged but attribute missing, reapply
        if (enlargedPetIds[id] or enlargedPetNames[pet.Name]) and not pet:GetAttribute("TOCHIPYRO_Enlarged") then
            reapplyEnlargeTo(pet)
            print("[TOCHIPYRO] Re-applied enlargement to:", pet.Name)
        end
    end)
end

-- onPetAdded: called when a model appears in monitored containers
local function onPetAdded(pet)
    if not pet or not pet:IsA("Model") then return end
    task.wait(0.05)
    local id = getPetUniqueId(pet)
    local fp = getFingerprint(pet)

    -- direct match
    if id and enlargedPetIds[id] then
        reapplyEnlargeTo(pet)
        startPetMonitoring(pet)
        print("[TOCHIPYRO] Auto-enlarged by ID:", pet.Name, id)
        return
    end

    -- fingerprint match
    if fp ~= "" and fingerprintMap[fp] then
        reapplyEnlargeTo(pet)
        startPetMonitoring(pet)
        print("[TOCHIPYRO] Auto-enlarged by fingerprint:", pet.Name)
        return
    end

    -- name fallback (check owner if possible)
    if enlargedPetNames[pet.Name] then
        local owner = pet:GetAttribute("Owner") or pet:GetAttribute("OwnerUserId")
        if not owner or tostring(owner) == tostring(LocalPlayer.Name) or tostring(owner) == tostring(LocalPlayer.UserId) then
            reapplyEnlargeTo(pet)
            startPetMonitoring(pet)
            print("[TOCHIPYRO] Auto-enlarged by name fallback:", pet.Name)
            return
        end
    end
end

-- setup container monitoring (covers GardenSlots and nested slot children)
local function setupContainerMonitoring()
    for _, container in ipairs(petContainers) do
        if container then
            container.ChildAdded:Connect(function(child)
                onPetAdded(child)
            end)
            container.DescendantAdded:Connect(function(descendant)
                if descendant:IsA("Model") and descendant:FindFirstChildWhichIsA("BasePart") then
                    onPetAdded(descendant)
                end
            end)
        end
    end

    -- monitor player character too
    local function setupCharacterMonitoring()
        if LocalPlayer.Character then
            LocalPlayer.Character.ChildAdded:Connect(onPetAdded)
            LocalPlayer.Character.DescendantAdded:Connect(function(desc)
                if desc:IsA("Model") and desc:FindFirstChildWhichIsA("BasePart") then
                    onPetAdded(desc)
                end
            end)
        end
    end
    LocalPlayer.CharacterAdded:Connect(setupCharacterMonitoring)
    if LocalPlayer.Character then setupCharacterMonitoring() end
end

-- run it
setupContainerMonitoring()

-- helper to find currently held pet (keeps your original logic)
local function getHeldPet()
    local char = LocalPlayer.Character
    if not char then return nil end
    for _, obj in ipairs(char:GetDescendants()) do
        if obj:IsA("Model") and obj:FindFirstChildWhichIsA("BasePart") and not obj:FindFirstChildOfClass("Humanoid") and obj ~= char then
            return obj
        end
    end
    local gardenSlots = workspace:FindFirstChild("GardenSlots")
    if gardenSlots then
        for _, slot in ipairs(gardenSlots:GetChildren()) do
            for _, obj in ipairs(slot:GetDescendants()) do
                if obj:IsA("Model") and obj:FindFirstChildWhichIsA("BasePart") and obj:GetAttribute("Owner") == LocalPlayer.Name then
                    return obj
                end
            end
        end
    end
    return nil
end

-- enlargeCurrentHeldPet (also stores fingerprints)
local function enlargeCurrentHeldPet()
    local pet = getHeldPet()
    if pet then
        scaleModelWithJoints(pet, ENLARGE_SCALE)
        markPetAsEnlarged(pet)
        startPetMonitoring(pet)
        -- force small movement to encourage replication
        if pet.PrimaryPart then
            local originalCFrame = pet.PrimaryPart.CFrame
            pet.PrimaryPart.CFrame = originalCFrame + Vector3.new(0, 0.01, 0)
            task.wait(0.08)
            pet.PrimaryPart.CFrame = originalCFrame
        end
        print("[TOCHIPYRO] Enlarged pet (manual):", pet.Name)
    else
        warn("[TOCHIPYRO] No pet found to enlarge.")
    end
end

-- GUI (your GUI code — keep same)
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "TOCHIPYRO_Script"
ScreenGui.Parent = game.CoreGui

local MainFrame = Instance.new("Frame")
MainFrame.Size = UDim2.new(0, 280, 0, 190)
MainFrame.Position = UDim2.new(0.5, -140, 0.5, -95)
MainFrame.BackgroundColor3 = Color3.new(0, 0, 0)
MainFrame.BackgroundTransparency = 0.5
MainFrame.BorderSizePixel = 0
MainFrame.Parent = ScreenGui

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, 0, 0, 45)
Title.BackgroundTransparency = 1
Title.Font = Enum.Font.GothamBold
Title.Text = "TOCHIPYRO Script"
Title.TextSize = 28
Title.Parent = MainFrame

task.spawn(function()
    while Title and Title.Parent do
        Title.TextColor3 = Color3.fromHSV((tick() * 0.5) % 1, 1, 1)
        task.wait(0.1)
    end
end)

local SizeButton = Instance.new("TextButton")
SizeButton.Size = UDim2.new(1, -20, 0, 40)
SizeButton.Position = UDim2.new(0, 10, 0, 55)
SizeButton.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
SizeButton.TextColor3 = Color3.new(1, 1, 1)
SizeButton.Text = "Size Enlarge"
SizeButton.Font = Enum.Font.GothamBold
SizeButton.TextScaled = true
SizeButton.Parent = MainFrame

local MoreButton = Instance.new("TextButton")
MoreButton.Size = UDim2.new(1, -20, 0, 40)
MoreButton.Position = UDim2.new(0, 10, 0, 105)
MoreButton.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
MoreButton.TextColor3 = Color3.new(1, 1, 1)
MoreButton.Text = "More"
MoreButton.Font = Enum.Font.GothamBold
MoreButton.TextScaled = true
MoreButton.Parent = MainFrame

-- More frame elements...
local MoreFrame = Instance.new("Frame")
MoreFrame.Size = UDim2.new(0, 210, 0, 150)
MoreFrame.Position = UDim2.new(0.5, -105, 0.5, -75)
MoreFrame.BackgroundColor3 = Color3.fromRGB(128, 0, 128)
MoreFrame.BackgroundTransparency = 0.5
MoreFrame.Visible = false
MoreFrame.Parent = ScreenGui

local UIStroke = Instance.new("UIStroke")
UIStroke.Thickness = 2
UIStroke.Color = Color3.fromRGB(200, 0, 200)
UIStroke.Parent = MoreFrame

local BypassButton = Instance.new("TextButton")
BypassButton.Size = UDim2.new(1, -20, 0, 40)
BypassButton.Position = UDim2.new(0, 10, 0, 10)
BypassButton.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
BypassButton.TextColor3 = Color3.new(1, 1, 1)
BypassButton.Text = "Bypass"
BypassButton.Font = Enum.Font.GothamBold
BypassButton.TextScaled = true
BypassButton.Parent = MoreFrame

local CloseButton = Instance.new("TextButton")
CloseButton.Size = UDim2.new(1, -20, 0, 40)
CloseButton.Position = UDim2.new(0, 10, 0, 65)
CloseButton.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
CloseButton.TextColor3 = Color3.new(1, 1, 1)
CloseButton.Text = "Close UI"
CloseButton.Font = Enum.Font.GothamBold
CloseButton.TextScaled = true
CloseButton.Parent = MoreFrame

SizeButton.MouseButton1Click:Connect(enlargeCurrentHeldPet)
MoreButton.MouseButton1Click:Connect(function() MoreFrame.Visible = not MoreFrame.Visible end)
CloseButton.MouseButton1Click:Connect(function()
    for id, connection in pairs(petUpdateLoops) do
        connection:Disconnect()
    end
    ScreenGui:Destroy()
end)
BypassButton.MouseButton1Click:Connect(function()
    print("[TOCHIPYRO] Bypass pressed (placeholder).")
end)

print("[TOCHIPYRO] Enhanced pet enlarger loaded — check Output for debug messages.")
