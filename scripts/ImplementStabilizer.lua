-- AutoSwitch : outils stables à l'arrêt (Mud System Physics + MoreRealistic)
-- Fichier chargé par AutoSwitch.lua (après Common.lua).

local vtpInfo, isAutoDriveActive = AS.vtpInfo, AS.isAutoDriveActive

-------------------------------------------------------------------------------
-- v1.0.0.04 : Mud System Physics fait varier le rayon des roues (enfoncement dans
--   la boue et au champ, pression, crevaisons, Use Your Tyres, TTD), tout passe par
--   _G.__MudRadiusCombiner.apply. Sur un outil à l'arrêt, chaque changement de rayon
--   relance la physique (MoreRealistic réécrit aussi la physique des roues) : l'outil
--   se soulève, bouge, son petit mouvement relance l'enfoncement... et il sautille.
--   Ici, le rayon des roues d'un outil est figé tant qu'il ne peut pas rouler :
--     - outil dételé : toujours figé (il ne peut pas avancer seul) ;
--     - outil attelé : figé quand l'attelage est à l'arrêt et que personne ne
--       l'entraîne (pas d'accélérateur, pas de régulateur, ni AutoDrive ni ouvrier).
--   Le rayon reprend ses variations dès que l'attelage repart. Les tracteurs ne
--   sont pas concernés. Aucun fichier de Mud System Physics n'est modifié.
-------------------------------------------------------------------------------
AS_ImplementStabilizer = {}
AS_ImplementStabilizer.STOP_KPH     = 1.5    -- en dessous : attelage considéré à l'arrêt
AS_ImplementStabilizer.SETTLE_MS    = 1500   -- temps d'arrêt avant de figer un outil attelé
AS_ImplementStabilizer.wrapped = nil         -- fonction apply d'origine
AS_ImplementStabilizer.wrapper = nil
AS_ImplementStabilizer.cache = {}            -- [vehicle] = { t = g_time, frozen = bool }
AS_ImplementStabilizer.stillSince = {}       -- [rootVehicle] = g_time du début de l'arrêt

-- L'attelage est-il entraîné (conducteur, régulateur, AutoDrive, ouvrier) ?
local function isDriven(root)
    if root == nil then return false end
    if root.getIsAIActive ~= nil and root:getIsAIActive() then return true end
    if isAutoDriveActive ~= nil and isAutoDriveActive(root) then return true end
    local dr = root.spec_drivable
    if dr ~= nil then
        if math.abs(dr.axisForward or 0) > 0.01 then return true end
        if dr.cruiseControl ~= nil and (dr.cruiseControl.state or 0) ~= 0 then return true end
    end
    return false
end

function AS_ImplementStabilizer:isFrozen(vehicle)
    if vehicle == nil or vehicle.spec_motorized ~= nil then return false end
    local now = g_time or 0
    local c = self.cache[vehicle]
    if c ~= nil and c.t == now then return c.frozen end

    local frozen = false
    local attacher = vehicle.getAttacherVehicle ~= nil and vehicle:getAttacherVehicle() or nil
    if attacher == nil then
        -- outil dételé : ne peut pas avancer seul
        frozen = true
    else
        local root = vehicle.rootVehicle or attacher
        local speed = root.getLastSpeed ~= nil and root:getLastSpeed() or 0
        if speed < self.STOP_KPH and not isDriven(root) then
            local since = self.stillSince[root]
            if since == nil then
                self.stillSince[root] = now
            elseif now - since >= self.SETTLE_MS then
                frozen = true
            end
        else
            self.stillSince[root] = nil
        end
    end
    -- (v1.0.0.83) table réutilisée (plus de table neuve à chaque image et par outil)
    if c == nil then
        c = {}
        self.cache[vehicle] = c
    end
    c.t, c.frozen = now, frozen
    return frozen
end

function AS_ImplementStabilizer:wrap()
    local comb = AS.modGlobal("FS25_MudSystemPhysics", "__MudRadiusCombiner")
    if comb == nil or type(comb.apply) ~= "function" or comb.apply == self.wrapper then return end
    local orig = comb.apply
    self.wrapped = orig
    local mod = self
    self.wrapper = function(wp, eps, ...)
        if wp ~= nil and wp.vehicle ~= nil then
            local ok, frozen = pcall(mod.isFrozen, mod, wp.vehicle)
            if ok and frozen then return end
        end
        return orig(wp, eps, ...)
    end
    comb.apply = self.wrapper
    print("[AS_ImplementStabilizer] rayon des roues figé pour les outils à l'arrêt")
end


-------------------------------------------------------------------------------
-- (07/11) Frein de parking des outils dételés dont les roues n'ont pas de frein
--   Le jeu freine un outil dételé (Attachable : brake(getBrakeForce())), mais seules
--   les roues avec brakeFactor > 0 freinent. Certains mods mettent brakeFactor="0"
--   sur toutes les roues (ex. bêcheuse Imants FSX600H38) : dételé, l'outil roule ou
--   glisse. Ici, pendant l'appel WheelPhysics.updatePhysics d'un outil dételé (sans
--   moteur), une roue sans frein reçoit brakeFactor = 1 ; la valeur d'origine est
--   remise aussitôt après. Outil attelé : rien ne change (il freine comme avant).
-------------------------------------------------------------------------------
AS_ImplementStabilizer.PARK_FACTOR  = 1.0
AS_ImplementStabilizer.PARK_SCAN_MS = 1000   -- vérification des outils dételés
AS_ImplementStabilizer.parkInstalled = false
AS_ImplementStabilizer.parkFrames = 0
AS_ImplementStabilizer.parkTimer = 0
AS_ImplementStabilizer.parked = {}           -- [vehicle] = true : frein de parking posé

-- outil dételé, sans moteur, que le jeu veut freiner
local function needsParkBrake(vehicle)
    if vehicle == nil or vehicle.spec_motorized ~= nil or vehicle.spec_attachable == nil then return false end
    if vehicle.isDeleted or vehicle.isDeleting then return false end
    if vehicle.getAttacherVehicle == nil or vehicle:getAttacherVehicle() ~= nil then return false end
    return true
end

-- une roue au moins sans frein ?
local function hasUnbrakedWheel(vehicle)
    local spec = vehicle.spec_wheels
    if spec == nil or spec.wheels == nil then return false end
    for _, wheel in ipairs(spec.wheels) do
        local wp = wheel.physics
        if wp ~= nil and (wp.brakeFactor or 0) <= 0 then return true end
    end
    return false
end

local function parkUpdatePhysics(self, superFunc, brakeForce, torque)
    local bf = self.brakeFactor
    if bf ~= nil and bf <= 0 and (brakeForce or 0) > 0 then
        local ok, need = pcall(needsParkBrake, self.vehicle)
        if ok and need then
            self.brakeFactor = AS_ImplementStabilizer.PARK_FACTOR
            local okCall, err = pcall(superFunc, self, brakeForce, torque)
            self.brakeFactor = bf
            if not okCall then error(err) end
            return
        end
    end
    return superFunc(self, brakeForce, torque)
end

-- reprend le freinage des roues (le jeu n'appelle updatePhysics qu'aux changements de frein)
local function refreshWheels(vehicle)
    local spec = vehicle.spec_wheels
    if spec == nil or spec.wheels == nil or not vehicle.isServer or not vehicle.isAddedToPhysics then return end
    local brakeForce = vehicle.getBrakeForce ~= nil and vehicle:getBrakeForce() or 0
    for _, wheel in ipairs(spec.wheels) do
        local wp = wheel.physics
        if wp ~= nil and wp.updatePhysics ~= nil then
            wp:updatePhysics(brakeForce * (wheel.brakePedal or 0), 0)
        end
    end
end

function AS_ImplementStabilizer:installParkBrake()
    if self.parkInstalled then return end
    -- après MudWheelDrag (installé à la 1re image) : ce crochet doit être par-dessus,
    -- sinon MudWheelDrag ne laisserait passer que la résistance de boue
    self.parkFrames = self.parkFrames + 1
    if self.parkFrames < 3 then return end
    self.parkInstalled = true
    if WheelPhysics == nil or WheelPhysics.updatePhysics == nil then return end
    WheelPhysics.updatePhysics = Utils.overwrittenFunction(WheelPhysics.updatePhysics, parkUpdatePhysics)
    print("[AS_ImplementStabilizer] frein de parking des outils dételés aux roues sans frein")
end

function AS_ImplementStabilizer:updateParkBrake(dt)
    self.parkTimer = self.parkTimer + (dt or 0)
    if self.parkTimer < self.PARK_SCAN_MS then return end
    self.parkTimer = 0
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    local seen = {}
    for _, vehicle in pairs(AS.getVehicles()) do
        if type(vehicle) == "table" and vehicle.spec_wheels ~= nil and vehicle.spec_motorized == nil then
            local need = needsParkBrake(vehicle) and hasUnbrakedWheel(vehicle)
            if need then
                seen[vehicle] = true
                if not self.parked[vehicle] then
                    refreshWheels(vehicle)
                    self.parked[vehicle] = true
                    if AS_LOGS ~= nil and AS_LOGS["AS_ImplementStabilizer"] then
                        print(string.format("[AS_ImplementStabilizer] frein de parking posé : %s",
                            tostring(vehicle.getFullName ~= nil and vehicle:getFullName() or vehicle.configFileName)))
                    end
                end
            end
        end
    end
    for vehicle in pairs(self.parked) do
        if not seen[vehicle] then
            self.parked[vehicle] = nil
            if not (vehicle.isDeleted or vehicle.isDeleting) then refreshWheels(vehicle) end
        end
    end
end

function AS_ImplementStabilizer:update(dt)
    -- Mud System Physics peut être chargé après AutoSwitch : on vérifie à chaque image
    self:wrap()
    self:installParkBrake()
    if self.parkInstalled then
        local ok, err = pcall(self.updateParkBrake, self, dt)
        if not ok then print("[AS_ImplementStabilizer] ERREUR frein de parking : " .. tostring(err)) end
    end
    -- nettoyage léger des caches
    if (g_time or 0) % 10000 < (dt or 0) then
        self.cache = {}
        for root in pairs(self.stillSince) do
            if root.isDeleted or root.isDeleting then self.stillSince[root] = nil end
        end
    end
end

function AS_ImplementStabilizer:deleteMap()
    self.cache, self.stillSince = {}, {}
    self.parked, self.parkTimer = {}, 0
end

addModEventListener(AS_ImplementStabilizer)
