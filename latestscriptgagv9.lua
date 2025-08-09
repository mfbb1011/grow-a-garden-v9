-- TOCHIPYRO Enhanced Pet Enlarger + Hotbar KG Update for Grow a Garden

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local RunService = game:GetService("RunService")
local workspace = game:GetService("Workspace")

local ENLARGE_SCALE = 1.75
local WEIGHT_MULTIPLIER = 2.5

local enlargedPetIds = {}
local petUpdateLoops = {}
local originalWeights = {}
local hotbarUpdateLoop = nil

-- Deep find Weight NumberValue inside pet model
local function findWeightNumberValue(model)
    for _, obj in ipairs(model:GetDescendants()) do
        if obj.Name:lower() == "weight" and obj:IsA("NumberValue") then
            return obj
        end
    end
    return nil
end

-- Get unique pet ID
local function getPetUniqueId(petModel)
    if not petModel then return nil end
    return petModel:GetAttribute("PetID") or petModel:GetAttribute("OwnerUserId") or petModel.Name
end

-- Scale model with joints
local function scaleModelWithJoints(model, scaleFactor)
    for _, obj in ipairs(model:GetDescendants()) do
        if obj:IsA("BasePart") then
            obj.Size = obj.Size * scaleFactor
        elseif obj:IsA("SpecialMesh") then
            obj.Scale = obj.Scale * scaleFactor
        elseif obj:IsA("Motor6D") then
            obj.C0 = CFrame.new(obj.C0.Position * scaleFactor) * (obj.C0 - obj.C0.Position)
            obj.C1 = CFrame.new(obj.C1.Position * scaleFactor) * (obj.C1 - obj.C1.Position)
        end
    end
    model:SetAttribute("TOCHIPYRO_Enlarged", true)
    model:SetAttribute("TOCHIPYRO_Scale", scaleFactor)
end

-- Update Hotbar KG
local function updateHotbarKG(newWeight)
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if not playerGui then return end
    local hotbar = playerGui:FindFirstChild("Hotbar") or playerGui:FindFirstChild("PetHotbar") or playerGui:FindFirstChildWhichIsA("ScreenGui")
    if not hotbar then return end

    for _, gui in ipairs(hotbar:GetDescendants()) do
        if gui:IsA("TextLabel") and gui.Text:lower():find("kg") then
            gui.Text = string.format("%.1f KG", newWeight)
        end
    end
end

-- Auto-refresh hotbar weight so it never reverts
local function startHotbarLoop(newWeight)
    if hotbarUpdateLoop then
        hotbarUpdateLoop:Disconnect()
        hotbarUpdateLoop = nil
    end
    hotbarUpdateLoop = RunService.Heartbeat:Connect(function()
        updateHotbarKG(newWeight)
    end)
end

-- Increase pet weight in the model and GUI
local function increaseWeight(petModel)
    local weightValue = findWeightNumberValue(petModel)
    if not weightValue then
        warn("[TOCHIPYRO] Could not find Weight NumberValue in pet:", petModel.Name)
        return
    end

    local id = getPetUniqueId(petModel)
    if not id then
        warn("[TOCHIPYRO] Pet missing unique ID, skipping weight update")
        return
    end

    if not originalWeights[id] then
        originalWeights[id] = weightValue.Value
    end

    local newWeight = originalWeights[id] * WEIGHT_MULTIPLIER
    weightValue.Value = newWeight
    petModel:SetAttribute("Weight", newWeight)
    petModel:SetAttribute("weight", newWeight)

    print(string.format("[TOCHIPYRO] Weight updated from %.2f to %.2f for pet %s", originalWeights[id], newWeight, petModel.Name))

    updateHotbarKG(newWeight)
    startHotbarLoop(newWeight)
end

-- Mark pet ID as enlarged
local function markPetAsEnlarged(petModel)
    local id = getPetUniqueId(petModel)
    if id then
        enlargedPetIds[id] = true
    end
end

-- Monitor pet for persistence
local function startPetMonitor(petModel)
    local id = getPetUniqueId(petModel)
    if not id then return end
    if petUpdateLoops[id] then
        petUpdateLoops[id]:Disconnect()
        petUpdateLoops[id] = nil
    end
    petUpdateLoops[id] = RunService.Heartbeat:Connect(function()
        if not petModel or not petModel.Parent then
            if petUpdateLoops[id] then
                petUpdateLoops[id]:Disconnect()
                petUpdateLoops[id] = nil
            end
            return
        end
        if enlargedPetIds[id] and not petModel:GetAttribute("TOCHIPYRO_Enlarged") then
            scaleModelWithJoints(petModel, ENLARGE_SCALE)
            increaseWeight(petModel)
            print("[TOCHIPYRO] Reapplied enlargement to pet:", petModel.Name)
        end
    end)
end

-- Get held pet
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
                if obj:IsA("Model") and obj:FindFirstChildWhichIsA("BasePart") then
                    local owner = obj:GetAttribute("Owner") or obj:GetAttribute("OwnerUserId")
                    if owner == LocalPlayer.Name or owner == tostring(LocalPlayer.UserId) then
                        return obj
                    end
                end
            end
        end
    end
    return nil
end

-- Enlarge current pet
local function enlargeCurrentPet()
    local pet = getHeldPet()
    if not pet then
        warn("[TOCHIPYRO] No held pet found to enlarge!")
        return
    end
    scaleModelWithJoints(pet, ENLARGE_SCALE)
    increaseWeight(pet)
    markPetAsEnlarged(pet)
    startPetMonitor(pet)
    print("[TOCHIPYRO] Enlarged pet:", pet.Name)
end

-- Auto enlarge on spawn
local function onPetAdded(pet)
    if not pet:IsA("Model") then return end
    task.wait(0.1)
    local id = getPetUniqueId(pet)
    if not id then return end
    startPetMonitor(pet)
    if enlargedPetIds[id] then
        scaleModelWithJoints(pet, ENLARGE_SCALE)
        increaseWeight(pet)
        print("[TOCHIPYRO] Auto-enlarged pet on spawn:", pet.Name)
    end
end

-- Connect to containers
local petContainers = {workspace, workspace:FindFirstChild("Pets"), workspace:FindFirstChild("PetSlots"), workspace:FindFirstChild("GardenSlots")}
for _, container in pairs(petContainers) do
    if container then
        container.ChildAdded:Connect(onPetAdded)
    end
end

-- Character monitoring
local function setupCharacterMonitoring()
    if LocalPlayer.Character then
        LocalPlayer.Character.ChildAdded:Connect(onPetAdded)
    end
end
LocalPlayer.CharacterAdded:Connect(setupCharacterMonitoring)
setupCharacterMonitoring()

-- Simple UI
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "TOCHIPYRO_Script"
ScreenGui.Parent = game.CoreGui

local MainFrame = Instance.new("Frame")
MainFrame.Size = UDim2.new(0, 280, 0, 140)
MainFrame.Position = UDim2.new(0.5, -140, 0.5, -70)
MainFrame.BackgroundColor3 = Color3.new(0, 0, 0)
MainFrame.BackgroundTransparency = 0.5
MainFrame.BorderSizePixel = 0
MainFrame.Parent = ScreenGui

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, 0, 0, 40)
Title.BackgroundTransparency = 1
Title.Font = Enum.Font.GothamBold
Title.Text = "TOCHIPYRO Script"
Title.TextSize = 26
Title.Parent = MainFrame

spawn(function()
    while Title and Title.Parent do
        for h = 0, 1, 0.01 do
            Title.TextColor3 = Color3.fromHSV(h, 1, 1)
            task.wait(0.02)
        end
    end
end)

local SizeButton = Instance.new("TextButton")
SizeButton.Size = UDim2.new(1, -20, 0, 40)
SizeButton.Position = UDim2.new(0, 10, 0, 50)
SizeButton.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
SizeButton.TextColor3 = Color3.new(1, 1, 1)
SizeButton.Text = "Size Enlarge + Weight"
SizeButton.Font = Enum.Font.GothamBold
SizeButton.TextScaled = true
SizeButton.Parent = MainFrame

SizeButton.MouseButton1Click:Connect(enlargeCurrentPet)

print("[TOCHIPYRO] Pet enlarger with hotbar weight update loaded!")
