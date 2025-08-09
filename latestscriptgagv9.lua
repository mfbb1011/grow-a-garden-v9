-- TOCHIPYRO (robust) - persistent pet enlargement for garden plots
-- Put this into a LocalScript (StarterPlayerScripts / PlayerGui / etc.)

local DEBUG = false               -- set true to see debug prints
local CONTINUOUS_ENFORCE = false  -- set true only if server constantly resets sizes (heavy)

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local ENLARGE_SCALE = 1.75
local enlargedPetIds = {}                     -- persistent IDs you chose to enlarge
local scaledModels = setmetatable({}, {__mode="k"}) -- weak keys for models already scaled
local originalSizes = setmetatable({}, {__mode="k"}) -- store original sizes/scales for enforcement

local function debugPrint(...)
    if DEBUG then
        print("[TOCHIPYRO DEBUG]", ...)
    end
end

-- Helper: identify a model from any instance (model or ancestor model)
local function modelFromInstance(inst)
    if not inst then return nil end
    if inst:IsA("Model") then return inst end
    return inst:FindFirstAncestorOfClass("Model")
end

-- Heuristic: is this likely a pet model (has BasePart and no Humanoid)
local function isLikelyPetModel(model)
    if not model or not model:IsA("Model") then return false end
    if model:FindFirstChildOfClass("Humanoid") then return false end
    if model:FindFirstChildWhichIsA("BasePart") then return true end
    return false
end

-- Robust pet unique id extraction (tries many common attributes/Value objects, falls back to name)
local function getPetUniqueId(petModel)
    if not petModel then return nil end
    local keys = {"PetID","PetUID","UUID","UniqueId","ID","Id","OwnerUserId","OwnerId"}
    for _, k in ipairs(keys) do
        local v = petModel:GetAttribute(k)
        if v ~= nil then return tostring(v) end
    end
    -- scan for Value objects that contain id-ish names
    for _, v in ipairs(petModel:GetDescendants()) do
        if v:IsA("StringValue") or v:IsA("IntValue") or v:IsA("NumberValue") or v:IsA("ObjectValue") then
            local n = v.Name:lower()
            if n:find("pet") or n:find("id") or n:find("uid") or n:find("owner") then
                if v.Value ~= nil then return tostring(v.Value) end
            end
        end
    end
    -- fallback to model name
    return petModel.Name
end

-- scale model parts & joints once per model (idempotent via scaledModels map)
local function scaleModelWithJoints(model, scaleFactor)
    if not model or scaledModels[model] then return end
    debugPrint("Scaling model:", model:GetFullName())
    for _, obj in ipairs(model:GetDescendants()) do
        if obj:IsA("BasePart") then
            if not originalSizes[obj] then originalSizes[obj] = obj.Size end
            obj.Size = obj.Size * scaleFactor
        elseif obj:IsA("SpecialMesh") then
            if not originalSizes[obj] then originalSizes[obj] = obj.Scale end
            obj.Scale = obj.Scale * scaleFactor
        elseif obj:IsA("Motor6D") then
            -- scale just the position component, keep rotation
            local p0 = obj.C0.Position
            local r0 = obj.C0 - p0
            obj.C0 = CFrame.new(p0 * scaleFactor) * r0
            local p1 = obj.C1.Position
            local r1 = obj.C1 - p1
            obj.C1 = CFrame.new(p1 * scaleFactor) * r1
        end
    end
    scaledModels[model] = true
end

-- Apply scaling if model matches an ID you've marked to keep enlarged
local function applyScaleIfTracked(model)
    if not isLikelyPetModel(model) then return false end
    local id = getPetUniqueId(model)
    if not id then return false end
    if not enlargedPetIds[id] then return false end
    -- Try to apply scaling (safe even if model is partially constructed)
    scaleModelWithJoints(model, ENLARGE_SCALE)
    debugPrint("applyScaleIfTracked ->", model:GetFullName(), "id:", id)
    return true
end

-- Try repeated attempts for models (some garden spawns finish loading after a delay)
local function tryScaleRepeated(model, attempts, waitInterval)
    attempts = attempts or 8
    waitInterval = waitInterval or 0.35
    spawn(function()
        for i = 1, attempts do
            if not model or not model.Parent then return end
            applyScaleIfTracked(model)
            task.wait(waitInterval)
        end
    end)
end

-- When something appears anywhere in workspace, detect its model and try scale
workspace.DescendantAdded:Connect(function(inst)
    local model = modelFromInstance(inst)
    if model and isLikelyPetModel(model) then
        debugPrint("DescendantAdded detected model:", model:GetFullName())
        tryScaleRepeated(model, 10, 0.4)
    end
end)

-- Also scan existing models on script load (in case pets are already placed)
for _, inst in ipairs(workspace:GetDescendants()) do
    local model = modelFromInstance(inst)
    if model and isLikelyPetModel(model) then
        tryScaleRepeated(model, 4, 0.25)
    end
end

-- Mark a pet ID to be persistent and immediately attempt to scale any matching models
local function markPetAsEnlarged(petModel)
    local id = getPetUniqueId(petModel)
    if id then
        enlargedPetIds[id] = true
        debugPrint("Marked ID enlarged:", id)
        -- immediately try to find any existing models with that ID
        for _, inst in ipairs(workspace:GetDescendants()) do
            local m = modelFromInstance(inst)
            if m and isLikelyPetModel(m) and getPetUniqueId(m) == id then
                tryScaleRepeated(m, 6, 0.3)
            end
        end
    end
end

-- Find held pet in character (best-effort)
local function getHeldPet()
    local char = LocalPlayer and LocalPlayer.Character
    if not char then return nil end
    for _, obj in ipairs(char:GetDescendants()) do
        if obj:IsA("Model") and obj:FindFirstChildWhichIsA("BasePart") and not obj:FindFirstChildOfClass("Humanoid") then
            return obj
        end
    end
    -- fallback: tools which might be pets
    for _, tool in ipairs(char:GetChildren()) do
        if tool:IsA("Tool") then
            local m = modelFromInstance(tool)
            if m and isLikelyPetModel(m) then return m end
        end
    end
    return nil
end

-- Enlarge currently held pet and mark persistent
local function enlargeCurrentHeldPet()
    local pet = getHeldPet()
    if pet then
        scaleModelWithJoints(pet, ENLARGE_SCALE)
        markPetAsEnlarged(pet)
        print("[TOCHIPYRO] Enlarged pet and marked persistent:", getPetUniqueId(pet))
    else
        warn("[TOCHIPYRO] No pet found to enlarge (hold the pet and try again).")
    end
end

-- Optional continuous enforcement if the server keeps resetting sizes (slow)
if CONTINUOUS_ENFORCE then
    RunService.Heartbeat:Connect(function()
        for model, _ in pairs(scaledModels) do
            if model and model.Parent then
                for _, obj in ipairs(model:GetDescendants()) do
                    if obj:IsA("BasePart") then
                        local orig = originalSizes[obj] or obj.Size
                        obj.Size = orig * ENLARGE_SCALE
                    elseif obj:IsA("SpecialMesh") then
                        local orig = originalSizes[obj] or obj.Scale
                        obj.Scale = orig * ENLARGE_SCALE
                    end
                end
            end
        end
    end)
end

-- GUI (same as before, hook SizeButton to enlargeCurrentHeldPet)
-- (You can keep your previous GUI creation and simply change the SizeButton handler:)
-- SizeButton.MouseButton1Click:Connect(enlargeCurrentHeldPet)
--
-- For convenience, if you don't use a GUI: uncomment the line below to bind a key:
-- game:GetService("UserInputService").InputBegan:Connect(function(input, processed)
--     if processed then return end
--     if input.KeyCode == Enum.KeyCode.G then enlargeCurrentHeldPet() end -- press G to mark held pet
-- end)
