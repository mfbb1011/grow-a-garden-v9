-- TOCHIPYRO — improved persistent pet enlargement (more robust for gardens)
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local ENLARGE_SCALE = 1.75
local ENFORCE_INTERVAL = 1 -- seconds

-- stored fingerprints of pets you asked to enlarge
local enlargedFingerprints = {} -- array of fingerprint tables

-- active tracked pet instances -> data
local trackedPets = {} -- [Model] = {originalSizes = {}, originalMeshScales = {}, originalC0s = {}, originalC1s = {}, fingerprint = fp, alive = true}

-- Rainbow color helper
local function rainbowColor(t)
    local hue = (tick() * 0.5 + t) % 1
    return Color3.fromHSV(hue, 1, 1)
end

-- safe helper to get mesh id string
local function meshIdOf(obj)
    if obj:IsA("SpecialMesh") then
        return tostring(obj.MeshId or "")
    elseif obj:IsA("MeshPart") then
        return tostring(obj.MeshId or "")
    end
    return ""
end

-- fingerprint builder: id, name, and a small set of meshIds
local function buildFingerprint(model)
    if not model then return nil end
    local id = model:GetAttribute("PetID") or model:GetAttribute("OwnerUserId") or model.Name
    local name = model.Name
    local meshIds = {}
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("SpecialMesh") or d:IsA("MeshPart") then
            local mid = meshIdOf(d)
            if mid ~= "" then
                meshIds[mid] = true
            end
        end
    end
    -- convert to list
    local list = {}
    for k,_ in pairs(meshIds) do table.insert(list, k) end
    return {id = id, name = name, meshes = list}
end

-- heuristic match (id match preferred; otherwise name or any mesh overlap)
local function fingerprintMatches(a, b)
    if not a or not b then return false end
    if a.id and b.id and a.id == b.id then return true end
    if a.name and b.name and a.name == b.name then return true end
    -- mesh overlap
    local set = {}
    for _,m in ipairs(a.meshes or {}) do set[m] = true end
    for _,m in ipairs(b.meshes or {}) do
        if set[m] then return true end
    end
    return false
end

-- scale model by using stored originals (so we don't compound scaling)
local function applyScaleUsingOriginals(model, data, scale)
    if not model or not data then return end
    -- BaseParts
    for part, origSize in pairs(data.originalSizes) do
        if part and part.Parent then
            pcall(function() part.Size = origSize * scale end)
        end
    end
    -- SpecialMesh / MeshPart scales
    for mesh, origScale in pairs(data.originalMeshScales) do
        if mesh and mesh.Parent then
            pcall(function() mesh.Scale = origScale * scale end)
        end
    end
    -- Motor6D C0/C1 (use originally captured CFrames)
    for mot, origC0 in pairs(data.originalC0s) do
        if mot and mot.Parent then
            pcall(function()
                mot.C0 = CFrame.new(origC0.Position * scale) * (origC0 - origC0.Position)
            end)
        end
    end
    for mot, origC1 in pairs(data.originalC1s) do
        if mot and mot.Parent then
            pcall(function()
                mot.C1 = CFrame.new(origC1.Position * scale) * (origC1 - origC1.Position)
            end)
        end
    end
end

-- capture originals for a new tracked pet and immediately apply scale
local function trackAndEnlargeInstance(model, fingerprint)
    if not model or trackedPets[model] then return end
    local data = {
        originalSizes = {},
        originalMeshScales = {},
        originalC0s = {},
        originalC1s = {},
        fingerprint = fingerprint,
        alive = true,
    }

    -- capture & set
    for _, obj in ipairs(model:GetDescendants()) do
        if obj:IsA("BasePart") then
            data.originalSizes[obj] = obj.Size
        elseif obj:IsA("SpecialMesh") then
            data.originalMeshScales[obj] = obj.Scale
        elseif obj:IsA("MeshPart") then
            -- MeshPart scale is handled as BasePart.Size (MeshPart.Scale property does not exist)
            if not data.originalSizes[obj] then
                data.originalSizes[obj] = obj.Size
            end
        elseif obj:IsA("Motor6D") then
            data.originalC0s[obj] = obj.C0
            data.originalC1s[obj] = obj.C1
        end
    end

    -- store
    trackedPets[model] = data

    -- mark attribute on model to help quick detection if the same instance moves
    pcall(function() model:SetAttribute("TOCHIPYRO_Enlarged", true) end)

    -- apply scale once now using originals (so we don't compound)
    applyScaleUsingOriginals(model, data, ENLARGE_SCALE)
    print("[TOCHIPYRO] Applied enlargement to instance:", model.Name)

    -- reapply on parent changes (so when moved into garden we re-apply)
    local ancestryConn
    ancestryConn = model.AncestryChanged:Connect(function(child, parent)
        if not trackedPets[model] then
            if ancestryConn then ancestryConn:Disconnect() end
            return
        end
        -- small delay for replication
        task.delay(0.07, function()
            if trackedPets[model] then
                applyScaleUsingOriginals(model, trackedPets[model], ENLARGE_SCALE)
                print("[TOCHIPYRO] Re-applied enlargement after AncestryChanged:", model.Name)
            end
        end)
    end)

    -- enforcement loop — keeps sizes set in case server/client scripts reset them
    task.spawn(function()
        while trackedPets[model] and model.Parent and trackedPets[model].alive do
            applyScaleUsingOriginals(model, trackedPets[model], ENLARGE_SCALE)
            task.wait(ENFORCE_INTERVAL)
        end
        -- cleanup
        trackedPets[model] = nil
    end)
end

-- try to auto-enlarge a model if it matches any fingerprint we saved
local function tryAutoEnlarge(model)
    if not model or not model:IsA("Model") then return end
    -- quick check: if it already has our attribute, re-apply
    if model:GetAttribute("TOCHIPYRO_Enlarged") then
        local fp = buildFingerprint(model)
        trackAndEnlargeInstance(model, fp)
        return
    end
    -- check against saved fingerprints
    local modelFp = buildFingerprint(model)
    if not modelFp then return end
    for _, savedFp in ipairs(enlargedFingerprints) do
        if fingerprintMatches(savedFp, modelFp) then
            -- found a match; enlarge this instance
            trackAndEnlargeInstance(model, savedFp)
            return
        end
    end
end

-- on child added (for specific containers)
local function onPetAdded(child)
    -- model only
    if not child or not child:IsA("Model") then return end
    -- small delay for the model to finish replicating/initializing
    task.delay(0.05, function()
        tryAutoEnlarge(child)
    end)
end

-- scan workspace for likely garden/plot folders and other containers
local function findPetContainers()
    local containers = {
        workspace,
        workspace:FindFirstChild("Pets"),
        workspace:FindFirstChild("PetSlots"),
        LocalPlayer.Character,
        LocalPlayer:FindFirstChild("Backpack"),
    }

    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Folder") or obj:IsA("Model") then
            local nameLower = string.lower(obj.Name)
            if nameLower:find("garden") or nameLower:find("plot") or nameLower:find("pet") then
                table.insert(containers, obj)
            end
        end
    end

    -- dedupe
    local seen = {}
    local out = {}
    for _, c in ipairs(containers) do
        if c and not seen[c] then
            seen[c] = true
            table.insert(out, c)
        end
    end
    return out
end

-- watch containers
local function connectAllContainers()
    local petContainers = findPetContainers()
    for _, container in ipairs(petContainers) do
        if container and container.ChildAdded then
            container.ChildAdded:Connect(onPetAdded)
        end
    end
end

-- also watch workspace.DescendantAdded to catch creations anywhere
workspace.DescendantAdded:Connect(function(desc)
    if desc:IsA("Model") then
        task.delay(0.03, function() tryAutoEnlarge(desc) end)
    end
end)

-- initial pass: try existing models in workspace
for _, d in ipairs(workspace:GetDescendants()) do
    if d:IsA("Model") then
        tryAutoEnlarge(d)
    end
end

-- connect containers initially (and you can call this again if you want to refresh)
connectAllContainers()

-- Held pet detection (same as before)
local function getHeldPet()
    local char = LocalPlayer.Character
    if not char then return nil end
    for _, obj in ipairs(char:GetDescendants()) do
        if obj:IsA("Model") and obj:FindFirstChildWhichIsA("BasePart") and not obj:FindFirstChildOfClass("Humanoid") then
            return obj
        end
    end
    return nil
end

-- enlarge the currently held pet, store its fingerprint, and start tracking
local function enlargeCurrentHeldPet()
    local pet = getHeldPet()
    if pet then
        local fp = buildFingerprint(pet) or { id = pet.Name, name = pet.Name, meshes = {} }
        -- store fingerprint (if not already stored)
        local already = false
        for _, v in ipairs(enlargedFingerprints) do
            if fingerprintMatches(v, fp) then already = true break end
        end
        if not already then
            table.insert(enlargedFingerprints, fp)
        end

        -- track and enlarge this instance now
        trackAndEnlargeInstance(pet, fp)
        print("[TOCHIPYRO] Enlarged pet and saved fingerprint:", pet.Name)
    else
        warn("[TOCHIPYRO] No pet found to enlarge.")
    end
end

-- GUI Creation (kept same as your UI)
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
        Title.TextColor3 = rainbowColor(0)
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

-- Button Events
SizeButton.MouseButton1Click:Connect(enlargeCurrentHeldPet)

MoreButton.MouseButton1Click:Connect(function()
    MoreFrame.Visible = not MoreFrame.Visible
end)

CloseButton.MouseButton1Click:Connect(function()
    ScreenGui:Destroy()
end)

BypassButton.MouseButton1Click:Connect(function()
    print("[TOCHIPYRO] Bypass pressed (placeholder).")
end)
