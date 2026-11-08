-- AutoSwitch : calendrier des cultures (carte ou Climate Profiles)
-- Fichier chargé par AutoSwitch.lua (avant Settings.lua).

-------------------------------------------------------------------------------
-- 08/11 : FS25_ClimateProfiles 1.0.0.1 remplace les dates de semis et de récolte
--   du jeu (FruitTypeDesc.getIsPlantableInPeriod / getIsHarvestableInPeriod).
--   Sur Le Mechet (profil « morvan »), le blé, l'orge et l'avoine de printemps
--   prennent les dates des céréales d'hiver.
--   Réglage AutoSwitch « Calendrier des cultures » :
--     Carte (défaut)    : dates de la carte pour toutes les cultures, la météo de
--                         Climate Profiles reste active.
--     Climate Profiles  : dates du mod Climate Profiles.
--   Les fonctions d'origine du jeu sont gardées dès le chargement d'AutoSwitch
--   (Climate Profiles ne pose ses crochets qu'au chargement de la carte).
--   Notre crochet est reposé par-dessus à chaque partie (premier update).
-------------------------------------------------------------------------------
AS_CropCalendar = {}
AS_CropCalendar.USE_MAP = true
AS_CropCalendar.wrappedP = nil
AS_CropCalendar.wrappedH = nil
AS_CropCalendar.logged = false

local ORIG_P = FruitTypeDesc ~= nil and FruitTypeDesc.getIsPlantableInPeriod or nil
local ORIG_H = FruitTypeDesc ~= nil and FruitTypeDesc.getIsHarvestableInPeriod or nil

local function otherModActive()
    return g_modIsLoaded ~= nil and g_modIsLoaded["FS25_ClimateProfiles"] == true
end

function AS_CropCalendar.plantable(fruitType, superFunc, growthMode, period)
    if AS_CropCalendar.USE_MAP and ORIG_P ~= nil then
        return ORIG_P(fruitType, growthMode, period)
    end
    return superFunc(fruitType, growthMode, period)
end

function AS_CropCalendar.harvestable(fruitType, superFunc, growthMode, period)
    if AS_CropCalendar.USE_MAP and ORIG_H ~= nil then
        return ORIG_H(fruitType, growthMode, period)
    end
    return superFunc(fruitType, growthMode, period)
end

function AS_CropCalendar:install()
    if FruitTypeDesc == nil or ORIG_P == nil or ORIG_H == nil then return end
    if FruitTypeDesc.getIsPlantableInPeriod ~= self.wrappedP then
        self.wrappedP = Utils.overwrittenFunction(FruitTypeDesc.getIsPlantableInPeriod, AS_CropCalendar.plantable)
        FruitTypeDesc.getIsPlantableInPeriod = self.wrappedP
    end
    if FruitTypeDesc.getIsHarvestableInPeriod ~= self.wrappedH then
        self.wrappedH = Utils.overwrittenFunction(FruitTypeDesc.getIsHarvestableInPeriod, AS_CropCalendar.harvestable)
        FruitTypeDesc.getIsHarvestableInPeriod = self.wrappedH
    end
    if not self.logged then
        self.logged = true
        print(string.format("[AS_CropCalendar] calendrier des cultures : %s", self.USE_MAP and "carte" or "Climate Profiles"))
    end
end

function AS_CropCalendar:loadMap(name)
    self.logged = false
end

-- seulement si Climate Profiles est chargé ; comparaison de deux fonctions par image
function AS_CropCalendar:update(dt)
    if g_currentMission == nil or not otherModActive() then return end
    if FruitTypeDesc ~= nil and (FruitTypeDesc.getIsPlantableInPeriod ~= self.wrappedP
        or FruitTypeDesc.getIsHarvestableInPeriod ~= self.wrappedH) then
        self:install()
    end
end

function AS_CropCalendar:setUseMap(useMap)
    self.USE_MAP = useMap ~= false
    if g_currentMission ~= nil and otherModActive() then
        print(string.format("[AS_CropCalendar] calendrier des cultures : %s", self.USE_MAP and "carte" or "Climate Profiles"))
    end
end

addModEventListener(AS_CropCalendar)
