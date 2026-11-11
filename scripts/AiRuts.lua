-- AutoSwitch : ornières des véhicules conduits par l'IA
-- Fichier chargé par AutoSwitch.lua (après Common.lua).

-------------------------------------------------------------------------------
-- 1.0.4.1 : le jeu ne fait pas creuser le sol aux véhicules conduits par l'IA.
--   AutoSwitch le fait, mais seulement :
--   - quand l'IA conduit vraiment (ouvrier du jeu, FarmPilot / AutoDrive, Courseplay),
--     outils attelés compris ;
--   - quand le véhicule est dans un champ. Hors champ (route, chemin, cour), jamais.
--   Pour un véhicule IA hors champ, la déformation reste coupée même si un autre mod
--   la rallume (TTD remet 1,0 aux véhicules IA, même sur la route).
--   À la fin de l'IA, chaque roue retrouve son intensité d'avant, comme le jeu.
--   Les véhicules conduits par le joueur ne sont pas touchés.
--   Ornières plus légères : l'intensité envoyée au moteur (TTD, MoreRealistic ou jeu)
--   est multipliée par AI_FACTOR pour les roues d'un véhicule IA.
--
-- 1.0.5.0 : hors champ, TTD 3.8 enfonçait le sol 2 à 6 fois plus que le jeu, même sur
--   le béton, et creusait le terrain pour de bon (« Déformation des chemins ruraux »).
--   Pour tous les véhicules (joueur compris), roue par roue, selon la couche du terrain :
--   - champ : inchangé ;
--   - béton, asphalte, pavés, pierre : aucune déformation ;
--   - gravier : intensité limitée à GRAVEL_CAP ;
--   - terre, herbe, sable, chemins : intensité limitée à SOFT_CAP.
--   Le creusement permanent de TTD est réduit à TTD_DIG_FACTOR et coupé dès qu'une roue
--   est sur un sol dur.
-------------------------------------------------------------------------------
AS_AiRuts = {}
AS_AiRuts.ENABLED = true
AS_AiRuts.INTERVAL = 150            -- ms entre deux contrôles
AS_AiRuts.FIELD_SCALE = 1.0         -- intensité mini dans un champ (TTD la règle s'il est là)
AS_AiRuts.AI_FACTOR = 0.5           -- ornières IA : moitié de l'intensité normale
AS_AiRuts.SOFT_CAP = 0.5            -- hors champ, terre / herbe : intensité maxi (jeu = 1)
AS_AiRuts.GRAVEL_CAP = 0.3          -- hors champ, gravier : intensité maxi
AS_AiRuts.TTD_DIG_FACTOR = 0.3      -- creusement permanent de TTD : 30 %
AS_AiRuts.SURFACE_INTERVAL = 300    -- ms entre deux lectures du sol
AS_AiRuts.CELL = 2                  -- m : sol relu seulement si la roue a changé de case

AS_AiRuts.HARD = { "CONCRETE", "ASPHALT", "STONE", "ROCK", "PAV", "TILE", "PLATE", "COBBLE",
    "BRICK", "BETON", "TARMAC" }
AS_AiRuts.GRAVEL = { "GRAVEL", "PEBBLE", "BALLAST", "GRIT", "CHIPPING", "KIES", "GRAVIER" }

AS_AiRuts.hooked = false
AS_AiRuts.timer = 0
AS_AiRuts.touched = setmetatable({}, { __mode = "k" })   -- wheelPhysics -> intensité d'avant
AS_AiRuts.nodeFactor = {}                                 -- nœud de roue IA -> facteur
AS_AiRuts.nodeCap = {}                                    -- [nœud][wheelShape] hors champ -> intensité maxi
AS_AiRuts.surfTimer = 0

local function rootOf(v)
    if v == nil then return nil end
    if v.getRootVehicle ~= nil then
        local ok, r = pcall(v.getRootVehicle, v)
        if ok and r ~= nil then return r end
    end
    return v
end

function AS_AiRuts.isAiDriven(v)
    if v == nil then return false end
    if v.getIsAIActive ~= nil then
        local ok, r = pcall(v.getIsAIActive, v)
        if ok and r == true then return true end
    end
    if v.ad ~= nil and v.ad.stateModule ~= nil and v.ad.stateModule.isActive ~= nil then
        local ok, r = pcall(v.ad.stateModule.isActive, v.ad.stateModule)
        if ok and r == true then return true end
    end
    if v.getIsCpActive ~= nil then
        local ok, r = pcall(v.getIsCpActive, v)
        if ok and r == true then return true end
    end
    return false
end

function AS_AiRuts.isOnField(v)
    if v.getIsOnField ~= nil then
        local ok, r = pcall(v.getIsOnField, v)
        if ok and r ~= nil then return r == true end
    end
    local spec = v.spec_tractorTerrainDynamics
    if spec ~= nil and spec.currentTTDState ~= nil then
        return spec.currentTTDState == "field"
    end
    return false
end

-- Un autre mod ne peut pas rallumer la déformation d'un véhicule IA hors champ
function AS_AiRuts:hook()
    if self.hooked or WheelPhysics == nil or type(WheelPhysics.setDisplacementAllowed) ~= "function" then return end
    local orig = WheelPhysics.setDisplacementAllowed
    self.origSetAllowed = orig
    WheelPhysics.setDisplacementAllowed = function(wp, allowed, ...)
        if allowed and AS_AiRuts.ENABLED then
            local veh = wp.vehicle or (wp.wheel ~= nil and wp.wheel.vehicle) or nil
            local root = rootOf(veh)
            if root ~= nil and root.__asAiRutsOff == true then
                allowed = false
            end
        end
        return orig(wp, allowed, ...)
    end
    -- intensité réduite pour les roues IA, quel que soit le mod qui l'envoie
    local origDisp = _G.setWheelShapeTerrainDisplacement
    if type(origDisp) == "function" and self.origDisp == nil then
        self.origDisp = origDisp
        local ok = pcall(function()
            _G.setWheelShapeTerrainDisplacement = function(node, shape, scale, ...)
                if type(scale) == "number" then
                    local f = AS_AiRuts.nodeFactor[node]
                    if f ~= nil then scale = scale * f end
                    local caps = AS_AiRuts.nodeCap[node]
                    local cap = caps ~= nil and caps[shape] or nil
                    if cap ~= nil and scale > cap then scale = cap end
                end
                return origDisp(node, shape, scale, ...)
            end
        end)
        if not ok then self.origDisp = nil end
    end
    self.hooked = true
end

function AS_AiRuts:setAllowed(wp, allowed)
    local f = self.origSetAllowed or wp.setDisplacementAllowed
    if f ~= nil then
        f(wp, allowed)
    else
        wp.displacementAllowed = allowed
    end
end

-- Roues d'un véhicule et de ses outils
local function eachWheel(v, fn, seen)
    seen = seen or {}
    if v == nil or seen[v] then return end
    seen[v] = true
    if v.spec_wheels ~= nil and v.spec_wheels.wheels ~= nil then
        for _, wheel in pairs(v.spec_wheels.wheels) do
            if wheel ~= nil and wheel.physics ~= nil then fn(wheel.physics) end
        end
    end
    if v.getAttachedImplements ~= nil then
        for _, impl in ipairs(v:getAttachedImplements() or {}) do
            eachWheel(impl.object, fn, seen)
        end
    end
end

function AS_AiRuts:processRoot(root)
    local ai = AS_AiRuts.isAiDriven(root)
    if not ai then
        root.__asAiRutsOff = nil
        if root.__asAiRutsOn ~= nil then
            root.__asAiRutsOn = nil
            -- fin de l'IA : chaque roue retrouve son réglage d'avant
            eachWheel(root, function(wp)
                local before = self.touched[wp]
                if before ~= nil then
                    self.touched[wp] = nil
                    if wp.wheel ~= nil and wp.wheel.node ~= nil then self.nodeFactor[wp.wheel.node] = nil end
                    if before.scale ~= nil then wp.displacementScale = before.scale end
                    -- le jeu remet la déformation à la fin de l'IA (Wheels:onAIFieldWorkerEnd)
                    self:setAllowed(wp, true)
                end
            end)
        end
        return
    end

    local field = AS_AiRuts.isOnField(root)
    root.__asAiRutsOn = true
    root.__asAiRutsOff = not field
    eachWheel(root, function(wp)
        local fresh = false
        if self.touched[wp] == nil then
            self.touched[wp] = { scale = wp.displacementScale }
            if wp.wheel ~= nil and wp.wheel.node ~= nil then
                self.nodeFactor[wp.wheel.node] = self.AI_FACTOR
            end
            fresh = true
        end
        if field then
            local push = fresh or wp.displacementAllowed ~= true
            if wp.displacementScale == nil or wp.displacementScale < 0.1 then
                wp.displacementScale = self.FIELD_SCALE
                push = true
            end
            -- l'intensité n'arrive au moteur qu'à l'appel de setDisplacementAllowed
            if push then self:setAllowed(wp, true) end
        elseif wp.displacementAllowed == true then
            self:setAllowed(wp, false)
        end
    end)
end

-------------------------------------------------------------------------------
-- Sol sous les roues (hors champ)
-------------------------------------------------------------------------------
local function hasToken(name, list)
    for _, t in ipairs(list) do
        if string.find(name, t, 1, true) ~= nil then return true end
    end
    return false
end

function AS_AiRuts:loadLayers()
    self.layers = {}
    local tn = g_terrainNode
    if tn == nil or getTerrainNumOfLayers == nil or getTerrainLayerName == nil
        or getTerrainLayerAtWorldPos == nil then return end
    for id = 0, getTerrainNumOfLayers(tn) - 1 do
        local name = string.upper(tostring(getTerrainLayerName(tn, id) or ""))
        local kind = "soft"
        if hasToken(name, self.GRAVEL) then kind = "gravel" end
        if hasToken(name, self.HARD) then kind = "hard" end
        self.layers[#self.layers + 1] = { id = id, kind = kind }
    end
end

-- "hard", "gravel" ou "soft" à cette position
function AS_AiRuts:surfaceAt(x, z)
    local tn = g_terrainNode
    local w = { hard = 0, gravel = 0, soft = 0 }
    for _, l in ipairs(self.layers) do
        local v = getTerrainLayerAtWorldPos(tn, l.id, x, 0, z) or 0
        if v > w[l.kind] then w[l.kind] = v end
    end
    if w.hard >= 0.2 or (w.hard > 0 and w.hard >= math.max(w.gravel, w.soft)) then return "hard" end
    if w.gravel >= 0.2 or (w.gravel > 0 and w.gravel >= w.soft) then return "gravel" end
    return "soft"
end

local function isFieldGround(wp)
    if FieldGroundType == nil then return false end
    return wp.densityType ~= nil and wp.densityType ~= FieldGroundType.NONE
end

-- renvoie true si une roue du véhicule est sur un sol dur
function AS_AiRuts:surfaceVehicle(v)
    if v.spec_wheels == nil or v.spec_wheels.wheels == nil then return false end
    local anyHard = false
    for _, wheel in pairs(v.spec_wheels.wheels) do
        local wp = wheel ~= nil and wheel.physics or nil
        local node = wheel ~= nil and wheel.node or nil
        if wp ~= nil and node ~= nil then
            local cap
            if not isFieldGround(wp) then
                local ref = wheel.driveNode or wheel.repr or node
                local x, _, z = getWorldTranslation(ref)
                local cx, cz = math.floor(x / self.CELL), math.floor(z / self.CELL)
                local c = wheel.__asSurf
                if c == nil or c.cx ~= cx or c.cz ~= cz then
                    c = { cx = cx, cz = cz, kind = self:surfaceAt(x, z) }
                    wheel.__asSurf = c
                end
                if c.kind == "hard" then
                    cap = 0
                    anyHard = true
                elseif c.kind == "gravel" then
                    cap = self.GRAVEL_CAP
                else
                    cap = self.SOFT_CAP
                end
            end
            local shape = wp.wheelShape
            local caps = self.nodeCap[node]
            if caps == nil then
                caps = {}
                self.nodeCap[node] = caps
            end
            if shape ~= nil and caps[shape] ~= cap then
                caps[shape] = cap
                -- nouvelle limite envoyée tout de suite au moteur
                if shape ~= 0 and v.isServer and v.isAddedToPhysics then
                    _G.setWheelShapeTerrainDisplacement(node, shape,
                        wp.displacementAllowed and (wp.displacementScale or 1) or 0)
                end
            end
        end
    end
    v.__asOnHard = anyHard
    return anyHard
end

function AS_AiRuts:updateSurfaces()
    if self.layers == nil then
        local ok, err = pcall(self.loadLayers, self)
        if not ok then
            self.layers = {}
            print("[AS_AiRuts] ERREUR couches : " .. tostring(err))
        end
    end
    if #self.layers == 0 then return end
    for _, v in pairs(AS.getVehicles()) do
        if v.spec_wheels ~= nil then
            local moving = true
            if v.getLastSpeed ~= nil then moving = v:getLastSpeed() > 0.3 end
            if moving or v.__asOnHard == nil then
                local ok, err = pcall(self.surfaceVehicle, self, v)
                if not ok and not self.errSurf then
                    self.errSurf = true
                    print("[AS_AiRuts] ERREUR : " .. tostring(err))
                end
            end
        end
    end
end

-- creusement permanent de TTD (setTerrainHeight) : réduit, et jamais sur sol dur
function AS_AiRuts:hookTtdDig()
    if self.ttdHooked then return end
    local td = nil
    local names = { "FS25_TTD_v_3_8", "FS25_TractorTerrainDynamics" }
    if g_modManager ~= nil and g_modManager.getActiveMods ~= nil then
        for _, m in ipairs(g_modManager:getActiveMods() or {}) do
            local n = m.modName
            if n ~= nil and (string.sub(n, 1, 8) == "FS25_TTD" or n == "FS25_TractorTerrainDynamics") then
                table.insert(names, 1, n)
            end
        end
    end
    for _, n in ipairs(names) do
        local env = _G[n]
        if type(env) == "table" then
            td = env.g_TTD_TerrainDeformation or env.TTD_TerrainDeformation
            if td ~= nil then break end
        end
    end
    td = td or _G.g_TTD_TerrainDeformation
    if type(td) ~= "table" or type(td.updateTTDVehicle) ~= "function" then return end
    if type(td.getCFG) == "function" then
        local cfg = td.getCFG()
        if type(cfg) == "table" and type(cfg.DEPTH_PER_PASS) == "number" and not self.ttdCfgDone then
            cfg.DEPTH_PER_PASS = cfg.DEPTH_PER_PASS * self.TTD_DIG_FACTOR
            self.ttdCfgDone = true
        end
    end
    local orig = td.updateTTDVehicle
    td.updateTTDVehicle = function(veh, ...)
        if AS_AiRuts.ENABLED and veh ~= nil and veh.__asOnHard == true then return end
        return orig(veh, ...)
    end
    self.ttdHooked = true
end

function AS_AiRuts:loadMap()
    self:hook()
end

function AS_AiRuts:update(dt)
    if not self.ENABLED or g_currentMission == nil then return end
    if not self.hooked then self:hook() end
    if not self.ttdHooked and (self.ttdTries or 0) < 20 then
        self.ttdTries = (self.ttdTries or 0) + 1
        self:hookTtdDig()
    end
    if g_server ~= nil then
        self.surfTimer = self.surfTimer + (dt or 0)
        if self.surfTimer >= self.SURFACE_INTERVAL then
            self.surfTimer = 0
            self:updateSurfaces()
        end
    end
    self.timer = self.timer + (dt or 0)
    if self.timer < self.INTERVAL then return end
    self.timer = 0
    local done = {}
    for _, v in pairs(AS.getVehicles()) do
        local root = rootOf(v)
        if root ~= nil and not done[root] then
            done[root] = true
            local ok, err = pcall(self.processRoot, self, root)
            if not ok and not self.errShown then
                self.errShown = true
                print("[AS_AiRuts] ERREUR : " .. tostring(err))
            end
        end
    end
end

addModEventListener(AS_AiRuts)
