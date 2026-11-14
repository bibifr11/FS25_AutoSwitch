-- AutoSwitch : location de champs (onglet « Location » du menu Échap)
-- Fichier chargé par AutoSwitch.lua (après CoopPay.lua). Module à part : réglage
-- « Location de champs » dans l'onglet AUTOSWITCH des Paramètres.

-------------------------------------------------------------------------------
-- v1.0.4.0 :
--   Prendre en location : un champ d'un voisin (parcelle sans propriétaire) proposé
--     ce mois-ci. Il passe à la ferme pendant le bail (travail, récolte) mais ne
--     peut pas être vendu. Loyer payé chaque mois.
--   Mettre en location : un champ de la ferme passe au voisin pendant le bail, la
--     ferme n'y travaille plus et touche le loyer chaque mois.
--   Bail : durée minimale 6, 12, 24 ou 36 mois. Résilier avant la fin coûte 50 %
--     des loyers restants. Un mois avant l'échéance, l'autre partie dit si elle
--     renouvelle (probabilité réglable, 70 % par défaut) ; loyer révisé de ±5 %.
--     Champ pris en location avec une culture en place à l'échéance : bail prolongé
--     de mois en mois jusqu'à la récolte (12 mois au plus).
--   Loyer mensuel = prix de la parcelle x taux annuel (4 % par défaut) / 12, ±15 %
--     selon le champ. Ligne « Fermages » dans Finances.
--   Sauvegarde : AutoSwitch_lease.xml dans la partie.
-- (v1.0.4.0) mettre en location = annonce ; un locataire signe après 1 à 3 mois, le champ
--   reste à la ferme d'ici là (« Retirer l'annonce » possible). Bail fini sans
--   renouvellement : le champ revient et repasse en annonce. Encadré en haut à droite
--   de l'onglet : champs possédés, pris en location, loués.
-- (v1.0.4.0) durée des baux aléatoire (6, 12, 24 ou 36 mois) : chaque offre a la sienne,
--   le locataire fixe celle d'une annonce à la signature, nouvelle durée à chaque renouvellement.
-- v1.0.4.2 : onglet en trois listes (Mes champs | Locations | Annonces des voisins), mini-carte
--   en haut à gauche, icône maison €/$.
--   Reprise des baux de FS25_RentYourField (rentYourFieldAgreements.xml) une seule
--     fois, quand ce mod n'est plus chargé : loyer et durée gardés. Tant qu'il est
--     chargé, ses champs sont affichés « géré par RentYourField » et pas touchés.
--   Multijoueur : tout se décide sur le serveur ; les clients envoient leurs demandes
--     et reçoivent la liste des baux.
-------------------------------------------------------------------------------
AS_FieldLease = {}

-- (13/11) contour d'un champ (points de son polygone), gardé en cache
local borderCache = {}
local function fieldBorder(field)
    if field == nil then return nil end
    local b = borderCache[field]
    if b ~= nil then return b or nil end
    b = false
    local nodes = nil
    if type(field.getPolygonPoints) == "function" then
        local ok, r = pcall(field.getPolygonPoints, field)
        if ok then nodes = r end
    end
    nodes = nodes or field.polygonPoints
    if type(nodes) == "table" and #nodes >= 3 then
        b = {}
        for _, n in ipairs(nodes) do
            local ok, x, _, z = pcall(getWorldTranslation, n)
            if ok and x ~= nil then b[#b + 1] = { x, z } end
        end
        if #b < 3 then b = false end
    end
    borderCache[field] = b
    return b or nil
end

AS_FieldLease.ENABLED     = true    -- réglage « Location de champs » (onglet + nouveaux baux)
AS_FieldLease.RATE        = 4       -- taux annuel du loyer (% du prix de la parcelle)
AS_FieldLease.RENEW       = 70      -- probabilité de renouvellement (%)
AS_FieldLease.PENALTY     = 0.5     -- résiliation anticipée : part des loyers restants
AS_FieldLease.REVISION    = 0.05    -- révision du loyer au renouvellement (±)
AS_FieldLease.SPREAD      = 0.15    -- écart du loyer selon le champ (±)
AS_FieldLease.OFFER_SHARE = 0.40    -- part des champs des voisins proposés chaque mois
AS_FieldLease.MAX_EXTRA   = 12      -- prolongation jusqu'à la récolte : mois au plus
AS_FieldLease.WAIT_MIN    = 1       -- annonce : mois avant qu'un locataire signe (1 à 3)
AS_FieldLease.WAIT_MAX    = 3
AS_FieldLease.TERMS       = { 6, 12, 24, 36 }
AS_FieldLease.FILE_NAME   = "AutoSwitch_lease.xml"
AS_FieldLease.RYF_MOD     = "FS25_RentYourField"
AS_FieldLease.RYF_FILE    = "rentYourFieldAgreements.xml"

AS_FieldLease.contracts   = {}      -- [farmlandId] = bail
AS_FieldLease.lastMonth   = nil     -- dernier mois traité (année * 12 + mois - 1)
AS_FieldLease.ryfImported = false
AS_FieldLease.ownerChanges = {}     -- changements de propriétaire à envoyer aux clients
AS_FieldLease.dirty       = false   -- liste à renvoyer aux clients
AS_FieldLease.started     = false

local STAT_NAME = "asFieldLease"
local MOD_NAME  = g_currentModName or "FS25_AutoSwitch"
local MOD_DIR   = g_currentModDirectory or ""

local function log(fmt, ...)
    print("[AS_Location] " .. string.format(fmt, ...))
end

local function L(key)
    if AS ~= nil and AS.L ~= nil then return AS.L(key) end
    return key
end

local function money(v)
    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        local ok, s = pcall(g_i18n.formatMoney, g_i18n, v, 0, true, true)
        if ok then return s end
    end
    return tostring(math.floor(v + 0.5))
end

-------------------------------------------------------------------------------
-- Ligne « Fermages » dans Finances (même méthode que les coopératives)
-------------------------------------------------------------------------------
if FinanceStats ~= nil and FinanceStats.statNames ~= nil and FinanceStats.statNameToIndex ~= nil
    and FinanceStats.statNameToIndex[STAT_NAME] == nil then
    table.insert(FinanceStats.statNames, STAT_NAME)
    FinanceStats.statNameToIndex[STAT_NAME] = #FinanceStats.statNames
end

if I18N ~= nil and I18N.getText ~= nil then
    I18N.getText = Utils.overwrittenFunction(I18N.getText, function(i18n, superFunc, text, modEnv, ...)
        if modEnv == nil and text == "finance_" .. STAT_NAME then
            return superFunc(i18n, text, MOD_NAME, ...)
        end
        return superFunc(i18n, text, modEnv, ...)
    end)
end

local function getMoneyType()
    if AS_FieldLease.moneyType == nil and MoneyType ~= nil and MoneyType.register ~= nil then
        local ok, mt = pcall(MoneyType.register, STAT_NAME, "finance_" .. STAT_NAME)
        if ok and mt ~= nil then AS_FieldLease.moneyType = mt end
    end
    return AS_FieldLease.moneyType or (MoneyType ~= nil and MoneyType.OTHER) or nil
end

-------------------------------------------------------------------------------
-- Outils
-------------------------------------------------------------------------------
local function isServer()
    return g_currentMission ~= nil and g_currentMission.getIsServer ~= nil and g_currentMission:getIsServer()
end

local function isMultiplayer()
    local mi = g_currentMission ~= nil and g_currentMission.missionDynamicInfo or nil
    return mi ~= nil and mi.isMultiplayer == true
end

local function localFarmId()
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        local ok, id = pcall(g_currentMission.getFarmId, g_currentMission)
        if ok and id ~= nil then return id end
    end
    return 1
end

local function noOwner()
    return (FarmlandManager ~= nil and FarmlandManager.NO_OWNER_FARM_ID) or 0
end

-- mois courant : année * 12 + mois - 1 (nil avant le début de la partie)
local function currentMonth()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    if env == nil or env.currentPeriod == nil then return nil end
    return (env.currentYear or 1) * 12 + (env.currentPeriod - 1)
end

-- nombre pseudo-aléatoire 0..1 fixe pour (a, b, c) : offres stables pendant le mois
local function hash01(a, b, c)
    local x = math.sin(a * 12.9898 + b * 78.233 + (c or 0) * 37.719) * 43758.5453
    return x - math.floor(x)
end

local function getOwner(farmlandId)
    if g_farmlandManager == nil or g_farmlandManager.getFarmlandOwner == nil then return nil end
    local ok, o = pcall(g_farmlandManager.getFarmlandOwner, g_farmlandManager, farmlandId)
    if ok then return o end
    return nil
end

local function setOwner(farmlandId, farmId)
    if g_farmlandManager == nil then return end
    local ok, err = pcall(g_farmlandManager.setLandOwnership, g_farmlandManager, farmlandId, farmId)
    if not ok then log("ERREUR propriétaire parcelle %d : %s", farmlandId, tostring(err)) end
    if g_messageCenter ~= nil and MessageType ~= nil and MessageType.FARM_PROPERTY_CHANGED ~= nil then
        pcall(g_messageCenter.publish, g_messageCenter, MessageType.FARM_PROPERTY_CHANGED, farmId)
    end
end

-------------------------------------------------------------------------------
-- Champs regroupés par parcelle (une parcelle = un bail)
-------------------------------------------------------------------------------
local function fieldNumber(field)
    if field.getId ~= nil then
        local ok, id = pcall(field.getId, field)
        if ok and type(id) == "number" then return id end
    end
    return field.fieldId
end

-- [farmlandId] = { fields = {...}, ids = {12, 13}, ha = 4.2 } ; recalculé au plus toutes les 5 s
function AS_FieldLease:getParcels()
    local now = g_time or 0
    if self.parcels ~= nil and now - (self.parcelsTime or -10000) < 5000 and now >= (self.parcelsTime or 0) then
        return self.parcels
    end
    local parcels = {}
    local fm = g_fieldManager
    local list = {}
    if fm ~= nil then
        if fm.getFields ~= nil then
            local ok, l = pcall(fm.getFields, fm)
            if ok and type(l) == "table" then list = l end
        elseif type(fm.fields) == "table" then
            list = fm.fields
        end
    end
    for _, field in pairs(list) do
        local fl = type(field) == "table" and field.farmland or nil
        if fl ~= nil and type(fl.id) == "number" then
            local p = parcels[fl.id]
            if p == nil then
                p = { farmland = fl, fields = {}, ids = {}, ha = 0 }
                parcels[fl.id] = p
            end
            table.insert(p.fields, field)
            local n = fieldNumber(field)
            if n ~= nil then table.insert(p.ids, n) end
            p.ha = p.ha + (tonumber(field.areaHa) or 0)
        end
    end
    for _, p in pairs(parcels) do table.sort(p.ids) end
    self.parcels, self.parcelsTime = parcels, now
    return parcels
end

function AS_FieldLease:parcelName(farmlandId)
    local p = self:getParcels()[farmlandId]
    if p == nil or #p.ids == 0 then
        return string.format(L("vtpas_fl_parcel"), farmlandId)
    end
    local s = string.format(L("vtpas_fl_field"), p.ids[1])
    if #p.ids > 1 then
        local rest = {}
        for i = 2, #p.ids do rest[#rest + 1] = "+" .. p.ids[i] end
        s = s .. " (" .. table.concat(rest, " ") .. ")"
    end
    return s
end

local function farmlandPrice(farmlandId)
    local fl = g_farmlandManager ~= nil and g_farmlandManager:getFarmlandById(farmlandId) or nil
    return fl ~= nil and tonumber(fl.price) or 0
end

-- durée aléatoire d'un bail
local function randomTerm()
    return AS_FieldLease.TERMS[math.random(1, #AS_FieldLease.TERMS)]
end

-- durée du bail proposé pour une parcelle ce mois-ci (fixe pendant le mois)
function AS_FieldLease:offerTerm(farmlandId, month)
    local i = math.floor(hash01(farmlandId, month or 0, 11) * #self.TERMS) + 1
    return self.TERMS[math.min(i, #self.TERMS)]
end

-- loyer mensuel proposé pour une parcelle ce mois-ci
function AS_FieldLease:offerRent(farmlandId, month)
    local factor = 1 + self.SPREAD * (2 * hash01(farmlandId, month or 0, 7) - 1)
    return farmlandPrice(farmlandId) * self.RATE / 100 / 12 * factor
end

-- culture en place, pas encore récoltée, sur un des champs de la parcelle
local probe = nil
function AS_FieldLease:hasGrowingCrop(farmlandId)
    local p = self:getParcels()[farmlandId]
    if p == nil or FieldState == nil or FieldState.new == nil then return false end
    if probe == nil then probe = FieldState.new() end
    for _, field in ipairs(p.fields) do
        local x, z = field.posX, field.posZ
        if x ~= nil and z ~= nil and pcall(probe.update, probe, x, z) then
            local fruit, growth = probe.fruitTypeIndex, probe.growthState or 0
            if probe.isValid and fruit ~= nil and fruit > 0 and growth > 0 then
                local desc = g_fruitTypeManager ~= nil and g_fruitTypeManager:getFruitTypeByIndex(fruit) or nil
                local cut = desc ~= nil and desc.cutState or nil
                local withered = desc ~= nil and desc.witheredState or nil
                if growth ~= cut and growth ~= withered then return true end
            end
        end
    end
    return false
end

-------------------------------------------------------------------------------
-- FS25_RentYourField : baux affichés tant qu'il est chargé, repris quand il n'y est plus
-------------------------------------------------------------------------------
function AS_FieldLease:ryfManager()
    if g_modIsLoaded == nil or g_modIsLoaded[self.RYF_MOD] ~= true then return nil end
    if AS ~= nil and AS.modGlobal ~= nil then
        return AS.modGlobal(self.RYF_MOD, "g_rentYourFieldManager")
    end
    return nil
end

function AS_FieldLease:ryfAgreement(farmlandId)
    local m = self:ryfManager()
    if m == nil or type(m.rentAgreements) ~= "table" then return nil end
    return m.rentAgreements[farmlandId]
end

local function ryfDifficulty()
    local d = g_currentMission ~= nil and g_currentMission.missionInfo ~= nil
        and g_currentMission.missionInfo.economicDifficulty or 2
    if d == 1 then return 1.2 elseif d == 3 then return 0.8 end
    return 1.0
end

function AS_FieldLease:importRyf()
    if self.ryfImported then return end
    if g_modIsLoaded ~= nil and g_modIsLoaded[self.RYF_MOD] == true then return end
    local mi = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local dir = mi ~= nil and mi.savegameDirectory or nil
    if dir == nil or dir == "" then return end
    local path = dir .. "/" .. self.RYF_FILE
    self.ryfImported = true
    if not fileExists(path) then return end
    local xml = loadXMLFile("asRyf", path)
    if xml == nil or xml == 0 then return end
    local root = "rentYourFieldAgreements"
    local pct = getXMLFloat(xml, root .. "#monthlyIncomePercent") or 2
    local term = getXMLInt(xml, root .. "#minDuration") or 12
    if term < 1 then term = 12 end
    local now = currentMonth() or 0
    local n = 0
    local i = 0
    while true do
        local key = string.format("%s.rentAgreement(%d)", root, i)
        local id = getXMLInt(xml, key .. "#farmlandId")
        if id == nil then break end
        local farmId = getXMLInt(xml, key .. "#farmId") or 1
        local done = getXMLInt(xml, key .. "#duration") or 0
        if self.contracts[id] == nil and getOwner(id) == noOwner() then
            local start = now - done
            local k = math.max(1, math.ceil((done + 1) / term))
            self.contracts[id] = { id = id, dir = "out", farmId = farmId, start = start,
                term = term, endM = start + k * term, rent = farmlandPrice(id) * pct / 100 * ryfDifficulty(),
                renew = true, extra = 0, src = "ryf" }
            n = n + 1
        end
        i = i + 1
    end
    delete(xml)
    if n > 0 then
        self.dirty = true
        log("%d baux repris de RentYourField", n)
    end
end

-------------------------------------------------------------------------------
-- Listes
-------------------------------------------------------------------------------
-- parcelle libre et proposée à la location ce mois-ci
function AS_FieldLease:isOffered(farmlandId, month)
    if self.contracts[farmlandId] ~= nil or self:ryfAgreement(farmlandId) ~= nil then return false end
    if getOwner(farmlandId) ~= noOwner() then return false end
    if farmlandPrice(farmlandId) <= 0 then return false end
    return hash01(farmlandId, month or 0, 3) < self.OFFER_SHARE
end

local function missionRunning(farmlandId)
    local fl = g_farmlandManager ~= nil and g_farmlandManager:getFarmlandById(farmlandId) or nil
    if fl == nil or g_missionManager == nil or g_missionManager.getIsMissionRunningOnFarmland == nil then return false end
    local ok, r = pcall(g_missionManager.getIsMissionRunningOnFarmland, g_missionManager, fl)
    return ok and r == true
end

-- lignes de l'onglet : liste 1 = mes champs (libres, en annonce), 2 = mes locations (prises),
-- 3 = annonces des voisins, 4 = champs loués à des voisins
AS_FieldLease.LIST_OWN, AS_FieldLease.LIST_LEASE, AS_FieldLease.LIST_OFFER, AS_FieldLease.LIST_OUT = 1, 2, 3, 4
function AS_FieldLease:buildRows(list, farmId)
    local rows = {}
    local month = currentMonth() or 0
    for id, p in pairs(self:getParcels()) do
        local c = self.contracts[id]
        local mine = c ~= nil and c.farmId == farmId
        local ryf = self:ryfAgreement(id)
        local row = nil
        if list == self.LIST_OFFER then
            if self:isOffered(id, month) then
                row = { id = id, kind = "offer", rent = self:offerRent(id, month), term = self:offerTerm(id, month) }
            end
        elseif list == self.LIST_LEASE then
            if mine and c.dir == "in" then
                row = { id = id, kind = c.dir, c = c, rent = c.rent }
            end
        elseif list == self.LIST_OUT then
            if mine and c.dir == "out" then
                row = { id = id, kind = c.dir, c = c, rent = c.rent }
            elseif ryf ~= nil and ryf.farmId == farmId then
                local m = self:ryfManager()
                local ok, r = pcall(m.getMonthlyIncome, m, id)
                row = { id = id, kind = "ryf", rent = ok and r or 0, done = ryf.duration or 0 }
            end
        else
            if mine and c.dir == "wait" then
                row = { id = id, kind = "wait", c = c, rent = c.rent, done = math.max(0, month - c.start) }
            elseif c == nil and ryf == nil and getOwner(id) == farmId then
                row = { id = id, kind = "own", rent = self:offerRent(id, month) }
            end
        end
        if row ~= nil then
            row.name = self:parcelName(id)
            row.ha = p.ha
            row.field = p.fields[1]
            row.firstField = p.ids[1] or (10000 + id)
            rows[#rows + 1] = row
        end
    end
    table.sort(rows, function(x, y) return x.firstField < y.firstField end)
    return rows
end

-- mois restants d'un bail
function AS_FieldLease:monthsLeft(c)
    return math.max(0, c.endM - (currentMonth() or c.endM))
end

function AS_FieldLease:penalty(c)
    if c.dir == "wait" then return 0 end
    return c.rent * self:monthsLeft(c) * self.PENALTY
end

-- totaux du mois pour la ferme : reçus, payés
function AS_FieldLease:totals(farmId)
    local inc, out = 0, 0
    for _, c in pairs(self.contracts) do
        if c.farmId == farmId then
            if c.dir == "out" then inc = inc + c.rent elseif c.dir == "in" then out = out + c.rent end
        end
    end
    return inc, out
end

-- encadré de l'onglet : champs possédés (dont en annonce), pris en location, loués
function AS_FieldLease:counts(farmId)
    local owned, wait, taken, leased = 0, 0, 0, 0
    for id in pairs(self:getParcels()) do
        local c = self.contracts[id]
        if c ~= nil and c.farmId == farmId then
            if c.dir == "in" then taken = taken + 1
            elseif c.dir == "out" then leased = leased + 1
            else owned, wait = owned + 1, wait + 1 end
        elseif self:ryfAgreement(id) ~= nil and self:ryfAgreement(id).farmId == farmId then
            leased = leased + 1
        elseif c == nil and getOwner(id) == farmId then
            owned = owned + 1
        end
    end
    return owned, wait, taken, leased
end

-- pour le découvert : parcelle prise en location (pas un bien) / mise en location (reste un bien)
function AS_FieldLease:isLeasedIn(farmlandId, farmId)
    local c = self.contracts[farmlandId]
    return c ~= nil and c.dir == "in" and (farmId == nil or c.farmId == farmId)
end

function AS_FieldLease:leasedOutValue(farmId)
    local total = 0
    for id, c in pairs(self.contracts) do
        if c.dir == "out" and c.farmId == farmId then total = total + farmlandPrice(id) end
    end
    return total
end

-------------------------------------------------------------------------------
-- Actions (sur le serveur)
-------------------------------------------------------------------------------
AS_FieldLease.ACTION_TAKE      = 1
AS_FieldLease.ACTION_LEASE_OUT = 2
AS_FieldLease.ACTION_TERMINATE = 3
AS_FieldLease.ACTION_RENEW     = 4   -- arg = 1 : renouveler, 0 : ne pas renouveler
AS_FieldLease.ACTION_HELLO     = 5   -- client qui demande la liste

local function notifyFarm(farmId, text)
    if g_currentMission == nil or farmId ~= localFarmId() then return end
    if AS ~= nil and AS.showTimedNotification ~= nil and FSBaseMission ~= nil then
        AS.showTimedNotification("alert", FSBaseMission.INGAME_NOTIFICATION_INFO, text)
    end
end

-- renvoie true si l'action est faite
function AS_FieldLease:doAction(action, farmlandId, farmId, arg)
    local month = currentMonth()
    if month == nil then return false end
    local c = self.contracts[farmlandId]
    if action == self.ACTION_TAKE then
        if not self.ENABLED or not self:isOffered(farmlandId, month) or missionRunning(farmlandId) then return false end
        local term = self:offerTerm(farmlandId, month)
        self.contracts[farmlandId] = { id = farmlandId, dir = "in", farmId = farmId, start = month,
            term = term, endM = month + term, rent = self:offerRent(farmlandId, month), renew = true, extra = 0 }
        setOwner(farmlandId, farmId)
        self.ownerChanges[#self.ownerChanges + 1] = { farmlandId, farmId }
        log("ferme %d prend en location la parcelle %d (%d mois, %d par mois)", farmId, farmlandId, term,
            math.floor(self.contracts[farmlandId].rent))
    elseif action == self.ACTION_LEASE_OUT then
        if not self.ENABLED or c ~= nil or self:ryfAgreement(farmlandId) ~= nil then return false end
        if getOwner(farmlandId) ~= farmId or missionRunning(farmlandId) then return false end
        local c2 = self:list(farmlandId, farmId, month)
        log("ferme %d met en annonce la parcelle %d (%d par mois, signature dans %d mois)", farmId,
            farmlandId, math.floor(c2.rent), c2.endM - month)
    elseif action == self.ACTION_TERMINATE then
        if c == nil or c.farmId ~= farmId then return false end
        if c.dir == "out" and missionRunning(farmlandId) then return false end
        local pen = self:penalty(c)
        if pen > 0 and g_currentMission.addMoney ~= nil then
            g_currentMission:addMoney(-pen, farmId, getMoneyType(), true, true)
        end
        log("ferme %d résilie le bail de la parcelle %d (pénalité %d)", farmId, farmlandId, math.floor(pen))
        self:finish(c, false)
    elseif action == self.ACTION_RENEW then
        if c == nil or c.farmId ~= farmId then return false end
        c.renew = (arg == 1)
        if not c.renew then c.decided = nil end
    else
        return false
    end
    self.dirty = true
    return true
end

-- annonce : la parcelle reste à la ferme, un locataire signe dans 1 à 3 mois (endM = mois de la signature)
function AS_FieldLease:list(farmlandId, farmId, month)
    local c = { id = farmlandId, dir = "wait", farmId = farmId, start = month, term = 0,
        endM = month + math.random(self.WAIT_MIN, self.WAIT_MAX), rent = self:offerRent(farmlandId, month),
        renew = true, extra = 0 }
    self.contracts[farmlandId] = c
    self.dirty = true
    return c
end

-- fin du bail : la parcelle revient ; relist = champ loué remis en annonce
function AS_FieldLease:finish(c, relist)
    self.contracts[c.id] = nil
    local owner = (c.dir == "in") and noOwner() or c.farmId
    if getOwner(c.id) ~= owner then
        setOwner(c.id, owner)
        self.ownerChanges[#self.ownerChanges + 1] = { c.id, owner }
    end
    if relist and c.dir == "out" and self.ENABLED then
        local m = currentMonth() or c.endM
        self:list(c.id, c.farmId, m)
    end
    self.dirty = true
end

-- demande depuis l'onglet (client ou serveur)
function AS_FieldLease:request(action, farmlandId, arg)
    local farmId = localFarmId()
    if isServer() then
        local ok = self:doAction(action, farmlandId, farmId, arg)
        self:broadcast()
        return ok
    end
    if g_client ~= nil and AS_FieldLeaseActionEvent ~= nil then
        g_client:getServerConnection():sendEvent(AS_FieldLeaseActionEvent.new(action, farmlandId, farmId, arg or 0))
    end
    return true
end

-------------------------------------------------------------------------------
-- Changement de mois : loyers, préavis, renouvellement, fin
-------------------------------------------------------------------------------
function AS_FieldLease:processMonth(m)
    local byFarm = {}
    local ended = {}
    local signed = {}
    for _, c in pairs(self.contracts) do
        if c.dir == "wait" then
            if m >= c.endM then
                if missionRunning(c.id) then c.endM = m + 1 else signed[#signed + 1] = c end
            end
        else
            self:processContract(c, m, byFarm, ended)
        end
    end
    -- annonces : un locataire signe, la parcelle passe au voisin
    for _, c in ipairs(signed) do
        c.term = randomTerm()
        c.dir, c.start, c.endM, c.decided, c.extra = "out", m, m + c.term, nil, 0
        if getOwner(c.id) ~= noOwner() then
            setOwner(c.id, noOwner())
            self.ownerChanges[#self.ownerChanges + 1] = { c.id, noOwner() }
        end
        notifyFarm(c.farmId, string.format(L("vtpas_fl_signed"), self:parcelName(c.id), c.term, money(c.rent)))
        log("bail signé : parcelle %d louée %d mois, %d par mois", c.id, c.term, math.floor(c.rent))
    end
    for _, c in ipairs(ended) do
        notifyFarm(c.farmId, string.format(L(c.dir == "out" and self.ENABLED and "vtpas_fl_endedRelist" or "vtpas_fl_ended"),
            self:parcelName(c.id)))
        log("bail terminé : parcelle %d", c.id)
        self:finish(c, true)
    end
    for farmId, sum in pairs(byFarm) do
        if sum ~= 0 and g_currentMission.addMoney ~= nil then
            g_currentMission:addMoney(sum, farmId, getMoneyType(), true, true)
        end
    end
    self.dirty = true
end

-- un bail en cours : loyer du mois, préavis, renouvellement ou fin
function AS_FieldLease:processContract(c, m, byFarm, ended)
    local sign = (c.dir == "out") and 1 or -1
    byFarm[c.farmId] = (byFarm[c.farmId] or 0) + sign * c.rent
    local name = self:parcelName(c.id)
    local left = c.endM - m
    -- préavis : l'autre partie dit un mois avant si elle renouvelle
    if left == 1 and c.decided == nil and c.renew then
        c.decided = math.random() * 100 < self.RENEW
        notifyFarm(c.farmId, string.format(L(c.decided and "vtpas_fl_noticeYes" or "vtpas_fl_noticeNo"), name))
    end
    if left <= 0 then
        if c.renew and c.decided == nil then c.decided = math.random() * 100 < self.RENEW end
        if c.renew and c.decided then
            c.term = randomTerm()
            c.endM = c.endM + c.term
            c.rent = c.rent * (1 + self.REVISION * (2 * math.random() - 1))
            c.decided, c.extra = nil, 0
            notifyFarm(c.farmId, string.format(L("vtpas_fl_renewed"), name, c.term, money(c.rent)))
            log("bail renouvelé : parcelle %d, %d par mois", c.id, math.floor(c.rent))
        elseif c.dir == "in" and (c.extra or 0) < self.MAX_EXTRA and self:hasGrowingCrop(c.id) then
            c.endM = c.endM + 1
            c.extra = (c.extra or 0) + 1
            if c.extra == 1 then notifyFarm(c.farmId, string.format(L("vtpas_fl_extended"), name)) end
        else
            ended[#ended + 1] = c
        end
    end
end

-------------------------------------------------------------------------------
-- Sauvegarde / chargement
-------------------------------------------------------------------------------
local function savegamePath()
    local mi = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local dir = mi ~= nil and mi.savegameDirectory or nil
    if dir == nil or dir == "" then return nil end
    return dir .. "/" .. AS_FieldLease.FILE_NAME
end

function AS_FieldLease:save()
    local path = savegamePath()
    if path == nil then return end
    local xml = createXMLFile("asLease", path, "lease")
    if xml == nil or xml == 0 then return end
    if self.lastMonth ~= nil then setXMLInt(xml, "lease#lastMonth", self.lastMonth) end
    setXMLBool(xml, "lease#ryfImported", self.ryfImported)
    local i = 0
    for _, c in pairs(self.contracts) do
        local key = string.format("lease.contract(%d)", i)
        setXMLInt(xml, key .. "#farmland", c.id)
        setXMLString(xml, key .. "#dir", c.dir)
        setXMLInt(xml, key .. "#farmId", c.farmId)
        setXMLInt(xml, key .. "#start", c.start)
        setXMLInt(xml, key .. "#term", c.term)
        setXMLInt(xml, key .. "#end", c.endM)
        setXMLFloat(xml, key .. "#rent", c.rent)
        setXMLBool(xml, key .. "#renew", c.renew)
        if c.decided ~= nil then setXMLBool(xml, key .. "#decided", c.decided) end
        setXMLInt(xml, key .. "#extra", c.extra or 0)
        if c.src ~= nil then setXMLString(xml, key .. "#src", c.src) end
        i = i + 1
    end
    saveXMLFile(xml)
    delete(xml)
end

function AS_FieldLease:load()
    self.contracts, self.lastMonth, self.ryfImported = {}, nil, false
    local path = savegamePath()
    if path == nil or not fileExists(path) then return end
    local xml = loadXMLFile("asLease", path)
    if xml == nil or xml == 0 then return end
    self.lastMonth = getXMLInt(xml, "lease#lastMonth")
    self.ryfImported = getXMLBool(xml, "lease#ryfImported") == true
    local i = 0
    while true do
        local key = string.format("lease.contract(%d)", i)
        local id = getXMLInt(xml, key .. "#farmland")
        if id == nil then break end
        local dir = getXMLString(xml, key .. "#dir")
        if dir == "in" or dir == "out" or dir == "wait" then
            self.contracts[id] = { id = id, dir = dir, farmId = getXMLInt(xml, key .. "#farmId") or 1,
                start = getXMLInt(xml, key .. "#start") or 0, term = getXMLInt(xml, key .. "#term") or 12,
                endM = getXMLInt(xml, key .. "#end") or 0, rent = getXMLFloat(xml, key .. "#rent") or 0,
                renew = getXMLBool(xml, key .. "#renew") ~= false, decided = getXMLBool(xml, key .. "#decided"),
                extra = getXMLInt(xml, key .. "#extra") or 0, src = getXMLString(xml, key .. "#src") }
        end
        i = i + 1
    end
    delete(xml)
    local n = 0
    for _ in pairs(self.contracts) do n = n + 1 end
    log("%d baux chargés", n)
end

if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, function()
        if not isServer() then return end
        local ok, err = pcall(AS_FieldLease.save, AS_FieldLease)
        if not ok then log("ERREUR sauvegarde : %s", tostring(err)) end
    end)
end

-------------------------------------------------------------------------------
-- Multijoueur : demande d'un client (client -> serveur) et liste des baux (serveur -> clients)
-------------------------------------------------------------------------------
AS_FieldLeaseActionEvent = {}
local AS_FieldLeaseActionEvent_mt = Class(AS_FieldLeaseActionEvent, Event)
InitEventClass(AS_FieldLeaseActionEvent, "AS_FieldLeaseActionEvent")

function AS_FieldLeaseActionEvent.emptyNew()
    return Event.new(AS_FieldLeaseActionEvent_mt)
end

function AS_FieldLeaseActionEvent.new(action, farmlandId, farmId, arg)
    local self = AS_FieldLeaseActionEvent.emptyNew()
    self.action, self.farmlandId, self.farmId, self.arg = action, farmlandId, farmId, arg or 0
    return self
end

function AS_FieldLeaseActionEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.action)
    streamWriteInt32(streamId, self.farmlandId)
    streamWriteUInt8(streamId, self.farmId)
    streamWriteInt32(streamId, self.arg)
end

function AS_FieldLeaseActionEvent:readStream(streamId, connection)
    self.action = streamReadUInt8(streamId)
    self.farmlandId = streamReadInt32(streamId)
    self.farmId = streamReadUInt8(streamId)
    self.arg = streamReadInt32(streamId)
    self:run(connection)
end

function AS_FieldLeaseActionEvent:run(connection)
    if connection:getIsServer() then return end   -- seulement sur le serveur
    if self.action == AS_FieldLease.ACTION_HELLO then
        connection:sendEvent(AS_FieldLeaseSyncEvent.new(AS_FieldLease.contracts, {}))
        return
    end
    local ok, err = pcall(AS_FieldLease.doAction, AS_FieldLease, self.action, self.farmlandId, self.farmId, self.arg)
    if not ok then log("ERREUR demande client : %s", tostring(err)) end
    AS_FieldLease:broadcast()
end

AS_FieldLeaseSyncEvent = {}
local AS_FieldLeaseSyncEvent_mt = Class(AS_FieldLeaseSyncEvent, Event)
InitEventClass(AS_FieldLeaseSyncEvent, "AS_FieldLeaseSyncEvent")

function AS_FieldLeaseSyncEvent.emptyNew()
    return Event.new(AS_FieldLeaseSyncEvent_mt)
end

function AS_FieldLeaseSyncEvent.new(contracts, ownerChanges)
    local self = AS_FieldLeaseSyncEvent.emptyNew()
    self.contracts, self.ownerChanges = contracts, ownerChanges
    return self
end

function AS_FieldLeaseSyncEvent:writeStream(streamId, connection)
    local list = {}
    for _, c in pairs(self.contracts) do list[#list + 1] = c end
    streamWriteFloat32(streamId, AS_FieldLease.RATE)
    streamWriteInt32(streamId, #list)
    for _, c in ipairs(list) do
        streamWriteInt32(streamId, c.id)
        streamWriteUInt8(streamId, c.dir == "in" and 1 or (c.dir == "wait" and 3 or 2))
        streamWriteUInt8(streamId, c.farmId)
        streamWriteInt32(streamId, c.start)
        streamWriteInt32(streamId, c.term)
        streamWriteInt32(streamId, c.endM)
        streamWriteFloat32(streamId, c.rent)
        streamWriteBool(streamId, c.renew)
        streamWriteUInt8(streamId, c.decided == nil and 0 or (c.decided and 1 or 2))
    end
    streamWriteInt32(streamId, #self.ownerChanges)
    for _, o in ipairs(self.ownerChanges) do
        streamWriteInt32(streamId, o[1])
        streamWriteUInt8(streamId, o[2])
    end
end

function AS_FieldLeaseSyncEvent:readStream(streamId, connection)
    self.rate = streamReadFloat32(streamId)
    self.contracts = {}
    local n = streamReadInt32(streamId)
    for _ = 1, n do
        local c = {}
        c.id = streamReadInt32(streamId)
        local dir = streamReadUInt8(streamId)
        c.dir = dir == 1 and "in" or (dir == 3 and "wait" or "out")
        c.farmId = streamReadUInt8(streamId)
        c.start = streamReadInt32(streamId)
        c.term = streamReadInt32(streamId)
        c.endM = streamReadInt32(streamId)
        c.rent = streamReadFloat32(streamId)
        c.renew = streamReadBool(streamId)
        local d = streamReadUInt8(streamId)
        if d == 1 then c.decided = true elseif d == 2 then c.decided = false end
        c.extra = 0
        self.contracts[c.id] = c
    end
    self.ownerChanges = {}
    local m = streamReadInt32(streamId)
    for _ = 1, m do
        local id = streamReadInt32(streamId)
        local owner = streamReadUInt8(streamId)
        self.ownerChanges[#self.ownerChanges + 1] = { id, owner }
    end
    self:run(connection)
end

function AS_FieldLeaseSyncEvent:run(connection)
    if not connection:getIsServer() then return end   -- seulement sur les clients
    AS_FieldLease.contracts = self.contracts
    if self.rate ~= nil then AS_FieldLease.RATE = self.rate end
    for _, o in ipairs(self.ownerChanges) do
        if getOwner(o[1]) ~= o[2] then setOwner(o[1], o[2]) end
    end
    if AS_LeaseFrame ~= nil and AS_LeaseFrame.instance ~= nil then
        pcall(AS_LeaseFrame.instance.updateContent, AS_LeaseFrame.instance)
    end
end

-- serveur : liste des baux envoyée aux clients après un changement
function AS_FieldLease:broadcast()
    if not self.dirty then return end
    self.dirty = false
    local changes = self.ownerChanges
    self.ownerChanges = {}
    if AS_LeaseFrame ~= nil and AS_LeaseFrame.instance ~= nil then
        pcall(AS_LeaseFrame.instance.updateContent, AS_LeaseFrame.instance)
    end
    if not isMultiplayer() or g_server == nil then return end
    g_server:broadcastEvent(AS_FieldLeaseSyncEvent.new(self.contracts, changes), false)
end

-------------------------------------------------------------------------------
-- Carte (menu Échap) : achat / vente impossibles sur une parcelle en bail
-------------------------------------------------------------------------------
if InGameMenuMapFrame ~= nil and InGameMenuMapFrame.setMapInputContext ~= nil then
    InGameMenuMapFrame.setMapInputContext = Utils.overwrittenFunction(InGameMenuMapFrame.setMapInputContext,
        function(frame, superFunc, a1, a2, a3, a4, a5, a6, buyFarmlandActive, sellFarmlandActive, ...)
            local fl = frame.selectedFarmland
            if fl ~= nil and fl.id ~= nil and AS_FieldLease.contracts[fl.id] ~= nil then
                buyFarmlandActive, sellFarmlandActive = false, false
            end
            return superFunc(frame, a1, a2, a3, a4, a5, a6, buyFarmlandActive, sellFarmlandActive, ...)
        end)
end

-- RentYourField refuse les parcelles d'un autre mod de location (il cherche g_fieldLeasingManager)
local function exposeToRyf()
    local ok, G0 = pcall(getfenv, 0)
    if not ok or type(G0) ~= "table" or G0.g_fieldLeasingManager ~= nil then return end
    G0.g_fieldLeasingManager = {
        getLeaseAgreement = function(_, farmlandId)
            return AS_FieldLease.contracts[farmlandId]
        end,
    }
end

-------------------------------------------------------------------------------
-- Boucle
-------------------------------------------------------------------------------
function AS_FieldLease:loadMap()
    getMoneyType()
    pcall(exposeToRyf)
    if isServer() then
        local ok, err = pcall(self.load, self)
        if not ok then log("ERREUR chargement : %s", tostring(err)) end
    end
    if AS_LeaseFrame ~= nil then
        local ok, err = pcall(AS_LeaseFrame.setup)
        if not ok then log("ERREUR onglet : %s", tostring(err)) end
    end
end

function AS_FieldLease:update(dt)
    local mission = g_currentMission
    if mission == nil then return end
    if not isServer() then
        if not self.started and g_client ~= nil and AS_FieldLeaseActionEvent ~= nil then
            self.started = true
            g_client:getServerConnection():sendEvent(AS_FieldLeaseActionEvent.new(self.ACTION_HELLO, 0, localFarmId(), 0))
        end
        return
    end
    local m = currentMonth()
    if m == nil then return end
    if not self.started then
        self.started = true
        local ok, err = pcall(self.importRyf, self)
        if not ok then log("ERREUR reprise RentYourField : %s", tostring(err)) end
        if self.lastMonth == nil or self.lastMonth > m then self.lastMonth = m end
    end
    -- plusieurs mois d'un coup (sommeil) : traités un par un, 24 au plus
    local steps = 0
    while self.lastMonth < m and steps < 24 do
        self.lastMonth = self.lastMonth + 1
        steps = steps + 1
        local ok, err = pcall(self.processMonth, self, self.lastMonth)
        if not ok then log("ERREUR changement de mois : %s", tostring(err)) end
    end
    if self.lastMonth < m then self.lastMonth = m end
    if self.dirty then self:broadcast() end
end

function AS_FieldLease:deleteMap()
    self.contracts, self.ownerChanges = {}, {}
    self.lastMonth, self.started, self.ryfImported, self.dirty = nil, false, false, false
    self.parcels = nil
    -- image de la mini-carte : refaite à la prochaine partie
    local fr = AS_LeaseFrame ~= nil and AS_LeaseFrame.frame or nil
    if fr ~= nil and fr.mapInfo ~= nil then
        if fr.mapInfo.ov ~= nil and delete ~= nil then pcall(delete, fr.mapInfo.ov) end
        fr.mapInfo = nil
    end
    if fr ~= nil and fr.houseOv then
        if delete ~= nil then pcall(delete, fr.houseOv) end
        fr.houseOv = nil
        if fr.headerIcon ~= nil and fr.headerIcon.setVisible ~= nil then fr.headerIcon:setVisible(true) end
    end
end

addModEventListener(AS_FieldLease)

-------------------------------------------------------------------------------
-- Onglet « Location » du menu Échap (v1.0.4.2) : en haut à gauche la mini-carte et le champ
-- choisi, en haut à droite l'encadré des compteurs ; en bas trois listes côte à côte :
-- Mes champs | Locations | Annonces des voisins
-------------------------------------------------------------------------------
AS_LeaseFrame = {}
local AS_LeaseFrame_mt = Class(AS_LeaseFrame, TabbedMenuFrameElement)

function AS_LeaseFrame.new()
    local self = AS_LeaseFrame:superClass().new(nil, AS_LeaseFrame_mt)
    self.name = "asLeaseFrame"
    self.rows = { {}, {}, {}, {} }
    self.selList, self.selIndex = nil, -1
    self.btnBack = { inputAction = InputAction.MENU_BACK }
    self.btnOption = { text = "", inputAction = InputAction.MENU_EXTRA_2,
        callback = function() self:onOption() end }
    self.btnAction = { text = "", inputAction = InputAction.MENU_ACCEPT, disabled = true,
        callback = function() self:onAction() end }
    self:setMenuButtonInfo({ self.btnBack, self.btnAction })
    return self
end

function AS_LeaseFrame:copyAttributes(src)
    AS_LeaseFrame:superClass().copyAttributes(self, src)
end

-- numéro de liste (1 à 4) d'un élément SmoothList
function AS_LeaseFrame:lists()
    return { self.listOwn, self.listLease, self.listOffer, self.listOut }
end

function AS_LeaseFrame:listNr(list)
    for i, l in ipairs(self:lists()) do
        if l ~= nil and l == list then return i end
    end
    return nil
end

function AS_LeaseFrame:onGuiSetupFinished()
    AS_LeaseFrame:superClass().onGuiSetupFinished(self)
    for _, l in ipairs(self:lists()) do
        l:setDataSource(self)
        l:setDelegate(self)
    end
end

function AS_LeaseFrame:onFrameOpen()
    AS_LeaseFrame:superClass().onFrameOpen(self)
    AS_LeaseFrame.instance = self
    if g_messageCenter ~= nil and MessageType ~= nil and MessageType.FARM_PROPERTY_CHANGED ~= nil then
        g_messageCenter:subscribe(MessageType.FARM_PROPERTY_CHANGED, function() self:updateContent() end, self)
    end
    self:updateContent()
end

function AS_LeaseFrame:onFrameClose()
    AS_LeaseFrame:superClass().onFrameClose(self)
    AS_LeaseFrame.instance = nil
    if g_messageCenter ~= nil then g_messageCenter:unsubscribeAll(self) end
end

local function setText(el, s)
    if el ~= nil and el.setText ~= nil then el:setText(s) end
end

function AS_LeaseFrame:updateContent()
    local fl = AS_FieldLease
    local farmId = localFarmId()
    fl.parcels = nil
    local selId = self:selectedRow() ~= nil and self:selectedRow().id or nil
    for i = 1, 4 do self.rows[i] = self:sortRows(i, fl:buildRows(i, farmId)) end
    setText(self.headerText, L("vtpas_fl_title"))
    setText(self.groupMine, L("vtpas_fl_groupMine"))
    setText(self.groupNeighbours, L("vtpas_fl_groupNeighbours"))
    setText(self.countTitle, L("vtpas_fl_boxTitle"))
    setText(self.titleOwn, L("vtpas_fl_listOwn") .. " (" .. #self.rows[1] .. ")")
    setText(self.titleLease, L("vtpas_fl_listIn") .. " (" .. #self.rows[2] .. ")")
    setText(self.titleOffer, L("vtpas_fl_listOffer") .. " (" .. #self.rows[3] .. ")")
    setText(self.titleOut, L("vtpas_fl_listOut") .. " (" .. #self.rows[4] .. ")")
    for _, k in ipairs({ "1", "2", "3", "4" }) do
        setText(self["colField" .. k], L("vtpas_fl_colField"))
        setText(self["colArea" .. k], L("vtpas_fl_colAreaShort"))
        setText(self["colRent" .. k], L("vtpas_fl_colRent"))
    end
    setText(self.colInfo1, L("vtpas_fl_colState"))
    setText(self.colInfo2, L("vtpas_fl_colTerm"))
    setText(self.colInfo3, L("vtpas_fl_colTermOffer"))
    setText(self.colInfo4, L("vtpas_fl_colTerm"))
    local inc, out = fl:totals(farmId)
    setText(self.summaryText, string.format(L("vtpas_fl_summary"), money(inc), money(out)))
    local owned, wait, taken, leased = fl:counts(farmId)
    local ownedText = string.format(L("vtpas_fl_cntOwned"), owned)
    if wait > 0 then ownedText = ownedText .. " " .. string.format(L("vtpas_fl_cntWait"), wait) end
    setText(self.countOwned, ownedText)
    setText(self.countTaken, string.format(L("vtpas_fl_cntTaken"), taken))
    setText(self.countLeased, string.format(L("vtpas_fl_cntLeased"), leased))
    for _, l in ipairs(self:lists()) do l:reloadData() end
    -- même champ gardé choisi s'il est encore dans sa liste
    self.selIndex = -1
    if selId ~= nil and self.selList ~= nil then
        for i, r in ipairs(self.rows[self.selList]) do if r.id == selId then self.selIndex = i end end
    end
    -- rien de choisi : la ligne surlignée de la première liste non vide
    if self.selIndex < 1 then
        for n, l in ipairs(self:lists()) do
            if #self.rows[n] > 0 then
                local i = l ~= nil and l.selectedIndex or 1
                if i == nil or i < 1 or i > #self.rows[n] then i = 1 end
                self.selList, self.selIndex = n, i
                break
            end
        end
    end
    self:updateDetails()
    self:updateButtons()
end

function AS_LeaseFrame:getNumberOfSections() return 1 end
function AS_LeaseFrame:getTitleForSectionHeader() return "" end
function AS_LeaseFrame:getNumberOfItemsInSection(list, section)
    local n = self:listNr(list)
    return n ~= nil and #self.rows[n] or 0
end

-- texte court (colonne) et texte complet (détail) d'une ligne
function AS_LeaseFrame:rowTexts(r)
    local fl = AS_FieldLease
    if r.kind == "offer" then
        local t = string.format(L("vtpas_fl_months"), r.term)
        return t, L("vtpas_fl_stOffer") .. " - " .. string.format(L("vtpas_fl_leaseOf"), r.term)
    elseif r.kind == "own" then
        return L("vtpas_fl_stFree"), L("vtpas_fl_stOwn")
    elseif r.kind == "wait" then
        return L("vtpas_fl_stListed"), L("vtpas_fl_stWait") .. " - " .. string.format(L("vtpas_fl_listedSince"), r.done)
    elseif r.kind == "ryf" then
        return L("vtpas_fl_stRyfShort"), L("vtpas_fl_stRyf") .. " - " .. string.format(L("vtpas_fl_since"), r.done)
    end
    local c = r.c
    local left = string.format(L("vtpas_fl_left"), fl:monthsLeft(c))
    local state
    if not c.renew then
        state = L("vtpas_fl_stNoRenew")
    elseif c.decided == true then
        state = L("vtpas_fl_stRenewYes")
    elseif c.decided == false then
        state = L("vtpas_fl_stRenewNo")
    elseif (c.extra or 0) > 0 then
        state = L("vtpas_fl_stHarvest")
    else
        state = string.format(L("vtpas_fl_stRunning"), c.term)
    end
    local dir = L(r.kind == "in" and "vtpas_fl_dirIn" or "vtpas_fl_dirOut")
    return left, dir .. " - " .. left .. " - " .. state
end

function AS_LeaseFrame:populateCellForItemInSection(list, section, index, cell)
    local n = self:listNr(list)
    local r = n ~= nil and self.rows[n][index] or nil
    if r == nil then return end
    local short = self:rowTexts(r)
    local rent = money(r.rent or 0)
    if r.kind == "in" then rent = "- " .. rent elseif r.kind == "out" or r.kind == "ryf" then rent = "+ " .. rent end
    setText(cell:getAttribute("field"), r.name)
    setText(cell:getAttribute("area"), string.format("%.2f", r.ha or 0))
    setText(cell:getAttribute("rent"), rent)
    setText(cell:getAttribute("info"), short)
end

-- tri d'une liste par un clic sur l'en-tête de colonne (Champ, ha, Loyer, 4e colonne) ;
-- deuxième clic sur la même colonne = ordre inverse
local SORT_COLS = { colField = "field", colArea = "area", colRent = "rent", colInfo = "info" }

local function sortValue(r, key)
    if key == "area" then return r.ha or 0 end
    if key == "rent" then return r.rent or 0 end
    if key == "info" then
        if r.kind == "offer" then return r.term or 0 end
        if r.kind == "own" then return -1 end
        if r.kind == "wait" or r.kind == "ryf" then return r.done or 0 end
        if r.c ~= nil then return AS_FieldLease:monthsLeft(r.c) end
        return 0
    end
    return r.firstField or 0
end

function AS_LeaseFrame:sortRows(n, rows)
    local st = self.sort ~= nil and self.sort[n] or nil
    if st == nil then return rows end
    table.sort(rows, function(a, b)
        local va, vb = sortValue(a, st.key), sortValue(b, st.key)
        if va == vb then return (a.firstField or 0) < (b.firstField or 0) end
        if st.asc then return va < vb end
        return va > vb
    end)
    return rows
end

function AS_LeaseFrame:onSortClick(button)
    local id = button ~= nil and button.id or nil
    if id == nil then return end
    local col, n = string.match(id, "^(col%a+)(%d)$")
    local key = col ~= nil and SORT_COLS[col] or nil
    n = tonumber(n)
    if key == nil or n == nil then return end
    self.sort = self.sort or {}
    local st = self.sort[n]
    if st ~= nil and st.key == key then
        st.asc = not st.asc
    else
        -- surface, loyer et durée : du plus grand au plus petit d'abord
        self.sort[n] = { key = key, asc = key == "field" }
    end
    self:updateContent()
end

-- clic sur une ligne, même déjà surlignée : elle devient le champ choisi
function AS_LeaseFrame:onListClick(list, section, index)
    self:onListSelectionChanged(list, section, index)
end

function AS_LeaseFrame:onListSelectionChanged(list, section, index)
    local n = self:listNr(list)
    if n == nil then return end
    self.selList, self.selIndex = n, index
    self.manual = nil   -- champ choisi dans une liste : la carte reprend le zoom automatique
    self:updateDetails()
    self:updateButtons()
end

local function canManage()
    if g_currentMission == nil then return false end
    if g_currentMission:getIsServer() or g_currentMission.isMasterUser == true then return true end
    if Farm ~= nil and Farm.PERMISSION ~= nil and g_currentMission.getHasPlayerPermission ~= nil then
        local ok, r = pcall(g_currentMission.getHasPlayerPermission, g_currentMission, Farm.PERMISSION.MANAGE_RIGHTS)
        return ok and r == true
    end
    return false
end

function AS_LeaseFrame:selectedRow()
    if self.selList == nil or self.selIndex == nil or self.selIndex < 1 then return nil end
    return self.rows[self.selList][self.selIndex]
end

-- détail du champ choisi, à droite de la mini-carte
function AS_LeaseFrame:updateDetails()
    local r = self:selectedRow()
    if r == nil then
        setText(self.infoName, L("vtpas_fl_pick"))
        setText(self.infoArea, "")
        setText(self.infoRent, "")
        setText(self.infoState, "")
        return
    end
    local _, long = self:rowTexts(r)
    setText(self.infoName, r.name)
    setText(self.infoArea, string.format(L("vtpas_fl_infoArea"), r.ha or 0))
    setText(self.infoRent, string.format(L("vtpas_fl_infoRent"), money(r.rent or 0)))
    setText(self.infoState, long)
end

function AS_LeaseFrame:updateButtons()
    local r = self:selectedRow()
    self.btnAction.disabled = true
    -- bouton Renouveler Oui / Non seulement sur un bail en cours
    if r ~= nil and (r.kind == "in" or r.kind == "out") then
        self.btnOption.text = L(r.c.renew and "vtpas_fl_btnRenewOn" or "vtpas_fl_btnRenewOff")
        self.btnOption.disabled = false
        self:setMenuButtonInfo({ self.btnBack, self.btnOption, self.btnAction })
    else
        self:setMenuButtonInfo({ self.btnBack, self.btnAction })
    end
    self.btnAction.text = L("vtpas_fl_btnPick")
    if r ~= nil then
        local manage = canManage()
        if r.kind == "offer" then
            self.btnAction.text = L("vtpas_fl_btnTake")
            self.btnAction.disabled = not (manage and AS_FieldLease.ENABLED)
        elseif r.kind == "own" then
            self.btnAction.text = L("vtpas_fl_btnLeaseOut")
            self.btnAction.disabled = not (manage and AS_FieldLease.ENABLED)
        elseif r.kind == "in" or r.kind == "out" then
            self.btnAction.text = L("vtpas_fl_btnTerminate")
            self.btnAction.disabled = not manage
        elseif r.kind == "wait" then
            self.btnAction.text = L("vtpas_fl_btnUnlist")
            self.btnAction.disabled = not manage
        else
            self.btnAction.text = L("vtpas_fl_btnTerminate")
        end
    end
    self:setMenuButtonInfoDirty()
end

function AS_LeaseFrame:onOption()
    local r = self:selectedRow()
    if r == nil or (r.kind ~= "in" and r.kind ~= "out") or not canManage() then return end
    AS_FieldLease:request(AS_FieldLease.ACTION_RENEW, r.id, r.c.renew and 0 or 1)
    self:updateContent()
end

function AS_LeaseFrame:onAction()
    local r = self:selectedRow()
    if r == nil or not canManage() then return end
    local fl = AS_FieldLease
    local text, action
    if r.kind == "offer" then
        text = string.format(L("vtpas_fl_askTake"), r.name, money(r.rent), r.term)
        action = fl.ACTION_TAKE
    elseif r.kind == "own" then
        text = string.format(L("vtpas_fl_askLeaseOut"), r.name, money(r.rent))
        action = fl.ACTION_LEASE_OUT
    elseif r.kind == "wait" then
        text = string.format(L("vtpas_fl_askUnlist"), r.name)
        action = fl.ACTION_TERMINATE
    elseif r.kind == "in" or r.kind == "out" then
        local pen = fl:penalty(r.c)
        if pen > 0 then
            text = string.format(L("vtpas_fl_askTerminatePen"), r.name, money(pen))
        else
            text = string.format(L("vtpas_fl_askTerminate"), r.name)
        end
        action = fl.ACTION_TERMINATE
    else
        return
    end
    YesNoDialog.show(function(target, yes)
        if yes then
            fl:request(action, r.id, 0)
            target.selIndex = -1
            target:updateContent()
        end
    end, self, text, L("vtpas_fl_title"))
end

-------------------------------------------------------------------------------
-- Carte (en haut à gauche, étirée vers la droite) : une partie de la carte du jeu autour de
-- mes propriétés, champs des quatre listes en couleur ; un champ choisi dans une liste fait
-- zoomer la carte dessus (rouge, avec son contour)
-------------------------------------------------------------------------------
local MAP_COL = {
    [1] = { 0.30, 0.85, 0.30, 1 },   -- mes champs : vert
    [2] = { 0.25, 0.60, 1.00, 1 },   -- mes locations : bleu
    [3] = { 1.00, 0.85, 0.20, 1 },   -- annonces des voisins : jaune
    [4] = { 0.95, 0.45, 0.95, 1 },   -- champs loués à des voisins : violet
    sel = { 1.00, 0.15, 0.15, 1 },
}
AS_LeaseFrame.ZOOM_FIELD = 180      -- m de chaque côté du champ choisi (au minimum)
AS_LeaseFrame.ZOOM_MINE = 450       -- m de chaque côté au minimum pour la vue de mes propriétés
AS_LeaseFrame.ZOOM_SPEED = 0.18     -- part du chemin faite à chaque image (zoom progressif)
AS_LeaseFrame.ZOOM_MIN = 80         -- m de chaque côté au plus près (molette)
AS_LeaseFrame.ZOOM_STEP = 1.25      -- un cran de molette

function AS_LeaseFrame:getMapImage()
    if self.mapInfo ~= nil then return self.mapInfo end
    local info = { ov = nil, wx = 2048, wz = 2048, es = 0.5, ex = 0.25, ez = 0.25 }
    local m = g_currentMission
    local hud = m ~= nil and m.hud or nil
    local im = nil
    if hud ~= nil then
        if hud.getIngameMap ~= nil then
            local ok, r = pcall(hud.getIngameMap, hud)
            if ok then im = r end
        end
        im = im or hud.ingameMap
    end
    local file
    if im ~= nil and im.mapOverlay ~= nil then file = im.mapOverlay.filename end
    if file == nil and m ~= nil and m.missionInfo ~= nil and m.missionInfo.map ~= nil then
        file = m.missionInfo.map.mapImageFilename
    end
    info.wx = (im ~= nil and im.worldSizeX) or (m ~= nil and m.terrainSize) or 2048
    info.wz = (im ~= nil and im.worldSizeZ) or (m ~= nil and m.terrainSize) or 2048
    info.es = (im ~= nil and im.mapExtensionScaleFactor) or 0.5
    info.ex = (im ~= nil and im.mapExtensionOffsetX) or 0.25
    info.ez = (im ~= nil and im.mapExtensionOffsetZ) or 0.25
    if file ~= nil and createImageOverlay ~= nil then
        local ok, ov = pcall(createImageOverlay, file)
        if ok and ov ~= nil and ov ~= 0 then info.ov = ov end
    end
    self.mapInfo = info
    return info
end

-- vue voulue : centre (x, z) et demi-largeur en mètres
function AS_LeaseFrame:targetView(info)
    local minX, maxX, minZ, maxZ
    local function add(x, z, m)
        minX = math.min(minX or x, x - m); maxX = math.max(maxX or x, x + m)
        minZ = math.min(minZ or z, z - m); maxZ = math.max(maxZ or z, z + m)
    end
    local r = self:selectedRow()
    local zoom = self.ZOOM_MINE
    if r ~= nil then
        zoom = self.ZOOM_FIELD
        local p = AS_FieldLease:getParcels()[r.id]
        for _, f in ipairs(p ~= nil and p.fields or {}) do
            local border = fieldBorder(f)
            for _, b in ipairs(border or {}) do add(b[1], b[2], 0) end
            if f.posX ~= nil then add(f.posX, f.posZ, 0) end
        end
    else
        for _, n in ipairs({ 1, 2, 4 }) do
            for _, row in ipairs(self.rows[n]) do
                if row.field ~= nil and row.field.posX ~= nil then add(row.field.posX, row.field.posZ, 0) end
            end
        end
    end
    if minX == nil then return 0, 0, info.wx * 0.5 end
    local half = math.max(zoom, (maxX - minX) * 0.5 * 1.3, (maxZ - minZ) * 0.5 * 1.3 * (self.mapAspect or 1))
    return (minX + maxX) * 0.5, (minZ + maxZ) * 0.5, half
end

function AS_LeaseFrame:drawMiniMap()
    local el = self.miniMap
    if el == nil or el.absPosition == nil or el.absSize == nil or drawFilledRect == nil then return end
    local x0, y0, w, h = el.absPosition[1], el.absPosition[2], el.absSize[1], el.absSize[2]
    local info = self:getMapImage()
    -- rapport largeur / hauteur réel de la carte à l'écran
    local aspect = (w * (g_screenWidth or 1920)) / math.max(1e-6, h * (g_screenHeight or 1080))
    self.mapAspect = aspect
    local tx, tz, th = self:targetView(info)
    th = math.min(th, info.wx * 0.5)
    local v = self.view
    if self.manual ~= nil then
        -- carte déplacée / zoomée à la souris : elle reste où le joueur l'a mise
        local m = self.manual
        m.hw = math.max(self.ZOOM_MIN, math.min(info.wx * 0.5, m.hw))
        m.x = math.max(-info.wx * 0.5 + m.hw, math.min(info.wx * 0.5 - m.hw, m.x))
        local mh = m.hw / aspect
        m.z = math.max(-info.wz * 0.5 + mh, math.min(info.wz * 0.5 - mh, m.z))
        v = { x = m.x, z = m.z, hw = m.hw }
        self.view = v
    elseif v == nil then
        v = { x = tx, z = tz, hw = th }
        self.view = v
    else
        local k = self.ZOOM_SPEED
        v.x, v.z, v.hw = v.x + (tx - v.x) * k, v.z + (tz - v.z) * k, v.hw + (th - v.hw) * k
    end
    local hw = v.hw
    local hh = hw / aspect
    -- la vue reste dans la carte
    local cx = math.max(-info.wx * 0.5 + hw, math.min(info.wx * 0.5 - hw, v.x))
    local cz = math.max(-info.wz * 0.5 + hh, math.min(info.wz * 0.5 - hh, v.z))
    if hw >= info.wx * 0.5 then cx = 0 end
    if hh >= info.wz * 0.5 then cz = 0 end
    local left, top = cx - hw, cz - hh
    self.mapView = { x0 = x0, y0 = y0, w = w, h = h, left = left, top = top, hw = hw, hh = hh }
    drawFilledRect(x0, y0, w, h, 0.05, 0.06, 0.05, 1)
    if info.ov ~= nil and setOverlayUVs ~= nil then
        local nx0, nx1 = left / info.wx + 0.5, (cx + hw) / info.wx + 0.5
        local nz0, nz1 = top / info.wz + 0.5, (cz + hh) / info.wz + 0.5
        local u0, u1 = info.ex + info.es * nx0, info.ex + info.es * nx1
        local vTop, vBot = 1 - info.ez - info.es * nz0, 1 - info.ez - info.es * nz1
        setOverlayUVs(info.ov, u0, vBot, u0, vTop, u1, vBot, u1, vTop)
        setOverlayColor(info.ov, 1, 1, 1, 1)
        AS.renderOverlay(info.ov, x0, y0, w, h)
    end
    local function toScreen(x, z)
        return x0 + (x - left) / (2 * hw) * w, y0 + h - (z - top) / (2 * hh) * h
    end
    local function inside(sx, sy, m)
        return sx >= x0 + m and sx <= x0 + w - m and sy >= y0 + m and sy <= y0 + h - m
    end
    -- marques de couleur avec le numéro du champ dessus
    local dot = h * 0.03
    local textSize = h * 0.055
    local hasText = renderText ~= nil and getTextWidth ~= nil and setTextAlignment ~= nil and RenderText ~= nil
    local marks = {}
    for n = 1, 4 do
        local c = MAP_COL[n]
        for i, r in ipairs(self.rows[n]) do
            local f = r.field
            if f ~= nil and f.posX ~= nil then
                local sx, sy = toScreen(f.posX, f.posZ)
                local num = tostring(r.firstField ~= nil and r.firstField < 10000 and r.firstField or r.id)
                local mw, mh = dot * 1.6, dot
                if hasText then
                    mw = getTextWidth(textSize, num) + textSize * 0.5
                    mh = textSize * 1.1
                end
                if inside(sx, sy, mh * 0.5) then
                    drawFilledRect(sx - mw * 0.5, sy - mh * 0.5, mw, mh, c[1], c[2], c[3], 0.95)
                    marks[#marks + 1] = { n = n, i = i, x = sx, y = sy, w = mw, h = mh, num = num }
                end
            end
        end
    end
    if hasText then
        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextBold(true)
        setTextColor(0, 0, 0, 1)
        for _, m in ipairs(marks) do
            renderText(m.x, m.y - textSize * 0.35, textSize, m.num)
        end
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextBold(false)
        setTextColor(1, 1, 1, 1)
    end
    self.mapMarks = marks
    local r = self:selectedRow()
    if r ~= nil then
        local p = AS_FieldLease:getParcels()[r.id]
        local c = MAP_COL.sel
        local px = h * 0.008
        for _, f in ipairs(p ~= nil and p.fields or {}) do
            local border = fieldBorder(f)
            if border ~= nil then
                -- contour : points le long des bords
                for i = 1, #border do
                    local a, b = border[i], border[i % #border + 1]
                    local ax, ay = toScreen(a[1], a[2])
                    local bx, by = toScreen(b[1], b[2])
                    local steps = math.min(400, math.max(1, math.floor(math.max(math.abs(bx - ax), math.abs(by - ay)) / px)))
                    for k = 0, steps - 1 do
                        local t = k / steps
                        local sx, sy = ax + (bx - ax) * t, ay + (by - ay) * t
                        if inside(sx, sy, px) then
                            drawFilledRect(sx - px * 0.5, sy - px * 0.5, px, px, c[1], c[2], c[3], 1)
                        end
                    end
                end
            elseif f.posX ~= nil then
                local sx, sy = toScreen(f.posX, f.posZ)
                local big = dot * 1.6
                if inside(sx, sy, big * 0.5) then
                    drawFilledRect(sx - big * 0.5, sy - big * 0.5, big, big, c[1], c[2], c[3], 1)
                end
            end
        end
    end
end

-- clic sur la carte : la marque la plus proche du clic devient le champ choisi
function AS_LeaseFrame:pickOnMap(posX, posY)
    local v = self.mapView
    if v == nil or posX < v.x0 or posX > v.x0 + v.w or posY < v.y0 or posY > v.y0 + v.h then return false end
    local best, bestD
    for _, m in ipairs(self.mapMarks or {}) do
        -- dans la marque (ou tout près) ; la plus proche de son centre gagne
        local dx = math.max(0, math.abs(posX - m.x) - m.w * 0.5)
        local dy = math.max(0, math.abs(posY - m.y) - m.h * 0.5)
        if dx * dx + dy * dy <= (v.h * 0.05) ^ 2 then
            local d = (posX - m.x) ^ 2 + (posY - m.y) ^ 2
            if bestD == nil or d < bestD then best, bestD = m, d end
        end
    end
    if best == nil then return true end
    self.selList, self.selIndex = best.n, best.i
    local list = self:lists()[best.n]
    if list ~= nil and list.setSelectedItem ~= nil then pcall(list.setSelectedItem, list, 1, best.i, true) end
    self.selList, self.selIndex = best.n, best.i
    self:updateDetails()
    self:updateButtons()
    return true
end

-- souris sur la carte : clic simple = choisir le champ, clic maintenu = faire glisser la carte,
-- molette = zoomer / dézoomer autour du pointeur
function AS_LeaseFrame:mapMouse(posX, posY, isDown, isUp, button)
    local v = self.mapView
    if v == nil or Input == nil then return false end
    local over = posX >= v.x0 and posX <= v.x0 + v.w and posY >= v.y0 and posY <= v.y0 + v.h
    local d = self.drag
    if d ~= nil then
        if isUp and button == Input.MOUSE_BUTTON_LEFT then
            self.drag = nil
            if not d.moved then self:pickOnMap(d.sx, d.sy) end
            return true
        end
        local dx, dy = posX - d.sx, posY - d.sy
        if not d.moved and (math.abs(dx) > v.w * 0.01 or math.abs(dy) > v.h * 0.02) then d.moved = true end
        if d.moved then
            self.manual = { x = d.cx - dx / v.w * 2 * v.hw, z = d.cz + dy / v.h * 2 * v.hh, hw = d.hw }
        end
        return true
    end
    if not over or not isDown then return false end
    if button == Input.MOUSE_BUTTON_LEFT then
        self.drag = { sx = posX, sy = posY, cx = v.left + v.hw, cz = v.top + v.hh, hw = v.hw, moved = false }
        return true
    end
    local wheelIn = button == Input.MOUSE_BUTTON_WHEEL_UP
    local wheelOut = button == Input.MOUSE_BUTTON_WHEEL_DOWN
    if wheelIn or wheelOut then
        -- le point sous le pointeur reste sous le pointeur
        local wx = v.left + (posX - v.x0) / v.w * 2 * v.hw
        local wz = v.top + (v.y0 + v.h - posY) / v.h * 2 * v.hh
        local f = wheelIn and (1 / self.ZOOM_STEP) or self.ZOOM_STEP
        local hw, hh = v.hw * f, v.hh * f
        local cx = wx - ((posX - v.x0) / v.w * 2 - 1) * hw
        local cz = wz - ((v.y0 + v.h - posY) / v.h * 2 - 1) * hh
        self.manual = { x = cx, z = cz, hw = hw }
        return true
    end
    return false
end

function AS_LeaseFrame:mouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    if self.drag == nil then
        eventUsed = AS_LeaseFrame:superClass().mouseEvent(self, posX, posY, isDown, isUp, button, eventUsed)
    end
    if not eventUsed or self.drag ~= nil then
        local ok, used = pcall(self.mapMouse, self, posX, posY, isDown, isUp, button)
        if ok and used then eventUsed = true end
    end
    return eventUsed
end

-- icône du titre : la maison €/$ (même image que l'onglet) dessinée à la place de l'icône du jeu
function AS_LeaseFrame:drawHeaderIcon()
    local el = self.headerIcon
    if el == nil or el.absPosition == nil or el.absSize == nil or createImageOverlay == nil then return end
    if self.houseOv == nil then
        self.houseOv = false
        local ok, ov = pcall(createImageOverlay, Utils.getFilename("hud/as_lease_icon.dds", MOD_DIR))
        if ok and ov ~= nil and ov ~= 0 then self.houseOv = ov end
        if self.houseOv and el.setVisible ~= nil then el:setVisible(false) end
    end
    if not self.houseOv then return end
    setOverlayColor(self.houseOv, 0.02, 0.02, 0.02, 1)
    AS.renderOverlay(self.houseOv, el.absPosition[1], el.absPosition[2], el.absSize[1], el.absSize[2])
end

function AS_LeaseFrame:draw()
    AS_LeaseFrame:superClass().draw(self)
    pcall(self.drawHeaderIcon, self)
    local ok, err = pcall(self.drawMiniMap, self)
    if not ok and not self.mapErr then
        self.mapErr = true
        log("ERREUR mini-carte : %s", tostring(err))
    end
end

-- création de l'onglet (même méthode que les autres mods qui ajoutent une page au menu Échap)
function AS_LeaseFrame.setup()
    if g_inGameMenu == nil or g_gui == nil or AS_LeaseFrame.frame ~= nil then return end
    g_gui:loadProfiles(Utils.getFilename("gui/AS_LeaseProfiles.xml", MOD_DIR))
    local frame = AS_LeaseFrame.new()
    g_gui:loadGui(Utils.getFilename("gui/AS_LeasePage.xml", MOD_DIR), "asLeaseFrame", frame, true)
    AS_LeaseFrame.frame = frame
    local menu = g_inGameMenu
    local pageName = "asLeaseFrame"
    menu.controlIDs[pageName] = nil
    -- après l'onglet Finances (sinon à la fin)
    local target = 0
    local after = menu.pageFinances or menu.pageStatistics
    for i, child in ipairs(menu.pagingElement.elements) do
        if child == after then target = i + 1 break end
    end
    menu[pageName] = frame
    menu.pagingElement:addElement(frame)
    menu:exposeControlsAsFields(pageName)
    if target > 0 then
        for i, child in ipairs(menu.pagingElement.elements) do
            if child == frame then
                table.remove(menu.pagingElement.elements, i)
                table.insert(menu.pagingElement.elements, target, child)
                break
            end
        end
        for i, child in ipairs(menu.pagingElement.pages) do
            if child.element == frame then
                table.remove(menu.pagingElement.pages, i)
                table.insert(menu.pagingElement.pages, target, child)
                break
            end
        end
    end
    menu.pagingElement:updateAbsolutePosition()
    menu.pagingElement:updatePageMapping()
    menu:registerPage(frame, nil, function() return AS_FieldLease.ENABLED end)
    menu:addPageTab(frame, Utils.getFilename("hud/as_lease_icon.dds", MOD_DIR), GuiUtils.getUVs({ 0, 0, 1024, 1024 }))
    if target > 0 then
        for i, child in ipairs(menu.pageFrames) do
            if child == frame then
                table.remove(menu.pageFrames, i)
                table.insert(menu.pageFrames, target, child)
                break
            end
        end
    end
    menu:rebuildTabList()
end
