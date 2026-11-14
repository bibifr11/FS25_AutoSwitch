-- AutoSwitch : largeur réelle des rouleaux (MoreRealistic + Mud System Physics)
-- Fichier chargé par AutoSwitch.lua (après Duals.lua).

-------------------------------------------------------------------------------
-- (11/11) Rouleaux trop lourds à tirer
--   Dans la plupart des mods de rouleaux, les cylindres sont de petites roues
--   physiques sans pneu, très étroites (ex. Özdöken RC 950 : 9,5 m de rouleau
--   portés par 4 roues de 20 cm). MoreRealistic calcule alors une pression au sol
--   énorme (résistance au roulement) et Mud System Physics les enfonce comme des
--   pneus étroits : un 100 ch ne tire plus le rouleau, même sur sol sec.
--   Ici, chaque roue sans pneu d'un rouleau reçoit sa part de la largeur de
--   travail (largeur de travail / nombre de cylindres) dans wp.mrTotalWidth :
--     - MoreRealistic lit directement cette largeur pour la pression au sol ;
--     - Mud System Physics la reçoit pendant ses calculs par AS_Duals (même
--       échange que pour les roues jumelées), puis la largeur d'origine revient.
--   wp.width ne change pas : le jeu de base (forme physique, traces, dégâts aux
--   cultures) ne voit aucune différence. Une roue déjà plus large est gardée.
-------------------------------------------------------------------------------
AS_RollerWidth = {}
AS_RollerWidth.SCAN_MS = 1000
AS_RollerWidth.timer = 0
AS_RollerWidth.done = setmetatable({}, { __mode = "k" })   -- [vehicle] = true : déjà traité

-- roue avec un vrai pneu (même règle que TireLife) : les cylindres n'en ont pas
local function hasTire(wheel)
    for _, vw in ipairs(wheel.visualWheels or {}) do
        for _, part in ipairs(vw.visualParts or {}) do
            if type(part.tireNodes) == "table" and #part.tireNodes > 0 then return true end
        end
    end
    return false
end

local function isRoller(vehicle)
    if vehicle.spec_roller ~= nil then return true end
    local item = g_storeManager ~= nil and vehicle.configFileName ~= nil
        and g_storeManager:getItemByXMLFilename(vehicle.configFileName) or nil
    return item ~= nil and string.find(string.lower(tostring(item.categoryName or "")), "roller", 1, true) ~= nil
end

-- largeur de travail : fiche magasin, sinon zones de travail
local function getWorkWidth(vehicle)
    local item = g_storeManager ~= nil and vehicle.configFileName ~= nil
        and g_storeManager:getItemByXMLFilename(vehicle.configFileName) or nil
    -- les fiches ne sont lues qu'à l'ouverture du magasin : on les lit si besoin
    if item ~= nil and item.specs == nil and StoreItemUtil ~= nil and StoreItemUtil.loadSpecsFromXML ~= nil then
        pcall(StoreItemUtil.loadSpecsFromXML, item)
    end
    local ww = item ~= nil and item.specs ~= nil and tonumber(item.specs.workingWidth) or nil
    if ww ~= nil and ww > 0 then return ww end
    local spec = vehicle.spec_workArea
    if spec ~= nil and spec.workAreas ~= nil then
        local best = 0
        for _, area in ipairs(spec.workAreas) do
            if area.start ~= nil and area.width ~= nil then
                local x1, _, _ = localToLocal(area.start, vehicle.rootNode, 0, 0, 0)
                local x2, _, _ = localToLocal(area.width, vehicle.rootNode, 0, 0, 0)
                best = best + math.abs(x1 - x2)
            end
        end
        if best > 0 then return best end
    end
    return nil
end

-- renvoie le nombre de cylindres élargis (0 si rien à faire), nil si pas encore prêt
function AS_RollerWidth.apply(vehicle)
    local spec = vehicle.spec_wheels
    if spec == nil or spec.wheels == nil or #spec.wheels == 0 then return nil end
    local drums = {}
    for _, wheel in ipairs(spec.wheels) do
        local wp = wheel.physics
        if wp ~= nil and type(wp.width) == "number" and wp.width > 0 and not hasTire(wheel) then
            drums[#drums + 1] = wp
        end
    end
    if #drums == 0 then return 0 end
    local ww = getWorkWidth(vehicle)
    if ww == nil then return 0 end
    local share = ww / #drums
    local n = 0
    for _, wp in ipairs(drums) do
        local base = tonumber(wp.mrTotalWidth) or wp.width
        if share > base then
            wp.__asRollerBaseWidth = wp.__asRollerBaseWidth or base
            wp.mrTotalWidth = share
            n = n + 1
        end
    end
    if n > 0 then
        print(string.format("[AS_RollerWidth] %s : %d cylindres, largeur %.2f m chacun (au lieu de %.2f m, travail %.1f m)",
            tostring(vehicle.getFullName ~= nil and vehicle:getFullName() or vehicle.configFileName),
            n, share, drums[1].__asRollerBaseWidth or drums[1].width, ww))
    end
    return n
end

function AS_RollerWidth:update(dt)
    self.timer = self.timer + (dt or 0)
    if self.timer < self.SCAN_MS then return end
    self.timer = 0
    for _, vehicle in pairs(AS.getVehicles()) do
        if type(vehicle) == "table" and not self.done[vehicle] and vehicle.spec_motorized == nil
            and vehicle.spec_wheels ~= nil and not (vehicle.isDeleted or vehicle.isDeleting) then
            local okR, roller = pcall(isRoller, vehicle)
            if okR and not roller then
                self.done[vehicle] = true
            elseif okR then
                local ok, n = pcall(AS_RollerWidth.apply, vehicle)
                if not ok then
                    self.done[vehicle] = true
                    print("[AS_RollerWidth] ERREUR : " .. tostring(n))
                elseif n ~= nil then
                    self.done[vehicle] = true
                end
            end
        end
    end
end

function AS_RollerWidth:deleteMap()
    self.done = setmetatable({}, { __mode = "k" })
    self.timer = 0
end

addModEventListener(AS_RollerWidth)
