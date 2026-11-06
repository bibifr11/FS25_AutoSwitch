-- AutoSwitch : touches Ctrl droit réservées à AutoSwitch (01/11, demande de Fabien)
--
-- 1) Lecture directe du clavier : nos combinaisons (Ctrl droit + I, Flèche haut, M, R, C) marchent
--    toujours, même si le jeu a écarté notre touche à cause d'un doublon avec un autre mod.
-- 2) Les autres MODS qui déclarent la même combinaison dans leur modDesc la perdent : leur action ne
--    réagit plus quand Ctrl droit + cette touche est enfoncé (log + message au joueur). Le jeu de base
--    n'est pas touché.
-- Un seul déclenchement par appui : la lecture directe et la touche du jeu ne s'ajoutent pas.

AS_KeyLock = {}
AS_KeyLock.ENABLED = true
AS_KeyLock.MIN_GAP = 350           -- ms : un appui = une action, quel que soit le chemin
AS_KeyLock.MOD_NAME = g_currentModName or "FS25_AutoSwitch"

-- action, touche (avec Ctrl droit), où elle marche
AS_KeyLock.KEYS = {
    { "AS_DUAL_SWITCH",    "KEY_i",  "foot" },
    { "AS_DRIVE_MODE",     "KEY_up", "vehicle" },
    { "AS_WEATHER",        "KEY_m",  "both" },
    { "AS_REGISTER",       "KEY_r",  "both" },
    { "AS_FIELDS",         "KEY_c",  "both" },
}

AS_KeyLock.ours = {}         -- nom d'action -> { key, where }
AS_KeyLock.byCombo = {}      -- "KEY_rctrl KEY_t" -> nom de notre action
for _, k in ipairs(AS_KeyLock.KEYS) do
    AS_KeyLock.ours[k[1]] = { key = k[2], where = k[3] }
    AS_KeyLock.byCombo["KEY_rctrl " .. k[2]:lower()] = k[1]
end
AS_KeyLock.cb = {}           -- notre action -> { target, callback } (dernier enregistrement)
AS_KeyLock.lastFire = {}     -- notre action -> g_time du dernier déclenchement
AS_KeyLock.wasDown = {}
AS_KeyLock.blocked = {}      -- action d'un autre mod -> { ours = notre action, mod = nom du mod }
AS_KeyLock.blockLogged = {}

local function log(fmt, ...)
    print("[AS_KeyLock] " .. string.format(fmt, ...))
end

local function now() return g_time or 0 end

local function keyDown(name)
    local id = Input ~= nil and Input[name] or nil
    if id == nil or Input.isKeyPressed == nil then return false end
    local ok, r = pcall(Input.isKeyPressed, id)
    return ok and r == true
end

-- « KEY_t KEY_rctrl » -> « KEY_rctrl KEY_t » (ordre et casse sans importance)
local function normCombo(s)
    local parts = {}
    for w in tostring(s or ""):gmatch("%S+") do parts[#parts + 1] = w:lower() end
    table.sort(parts, function(a, b)
        if a == "key_rctrl" then return true end
        if b == "key_rctrl" then return false end
        return a < b
    end)
    for i, p in ipairs(parts) do parts[i] = p == "key_rctrl" and "KEY_rctrl" or p end
    return table.concat(parts, " ")
end

-------------------------------------------------------------------------------
-- Enregistrement des actions : nos rappels sont gardés, ceux des mods en doublon sont filtrés
-------------------------------------------------------------------------------
function AS_KeyLock:comboHeld(ours)
    local o = self.ours[ours]
    return o ~= nil and keyDown("KEY_rctrl") and keyDown(o.key)
end

if InputBinding ~= nil and InputBinding.registerActionEvent ~= nil then
    InputBinding.registerActionEvent = Utils.overwrittenFunction(InputBinding.registerActionEvent,
        function(self, superFunc, actionName, target, callback, ...)
            local name = type(actionName) == "string" and actionName or nil
            if name ~= nil and type(callback) == "function" and AS_KeyLock.ENABLED then
                if AS_KeyLock.ours[name] ~= nil then
                    AS_KeyLock.cb[name] = { target = target, callback = callback }
                    local orig = callback
                    callback = function(t, ...)
                        -- déjà fait par la lecture directe (ou l'inverse) : un appui = une action
                        if now() - (AS_KeyLock.lastFire[name] or -100000) < AS_KeyLock.MIN_GAP then return end
                        AS_KeyLock.lastFire[name] = now()
                        return orig(t, ...)
                    end
                elseif AS_KeyLock.blocked[name] ~= nil then
                    local b = AS_KeyLock.blocked[name]
                    local orig = callback
                    callback = function(t, ...)
                        if AS_KeyLock:comboHeld(b.ours) then
                            if not AS_KeyLock.blockLogged[name] then
                                AS_KeyLock.blockLogged[name] = true
                                log("touche Ctrl droit + %s gardée pour AutoSwitch : action %s du mod %s ignorée",
                                    AS_KeyLock.ours[b.ours].key:sub(5):upper(), name, tostring(b.mod))
                            end
                            return
                        end
                        return orig(t, ...)
                    end
                end
            end
            return superFunc(self, actionName, target, callback, ...)
        end)
end

-------------------------------------------------------------------------------
-- Mods en doublon : lus dans leur modDesc (touches clavier par défaut)
-------------------------------------------------------------------------------
function AS_KeyLock:scanMods()
    if g_modManager == nil then return end
    local mods = nil
    if g_modManager.getActiveMods ~= nil then
        local ok, m = pcall(g_modManager.getActiveMods, g_modManager)
        if ok and type(m) == "table" then mods = m end
    end
    mods = mods or g_modManager.mods
    if type(mods) ~= "table" then return end
    local found = {}
    for _, m in ipairs(mods) do
        local mn = type(m) == "table" and m.modName or nil
        local file = type(m) == "table" and m.modFile or nil
        if mn ~= nil and mn ~= self.MOD_NAME and type(file) == "string" and fileExists(file) then
            local xml = loadXMLFile("asKeyLock", file)
            if xml ~= nil and xml ~= 0 then
                local i = 0
                while i < 500 do
                    local key = string.format("modDesc.inputBinding.actionBinding(%d)", i)
                    if not hasXMLProperty(xml, key) then break end
                    local action = getXMLString(xml, key .. "#action")
                    local j = 0
                    while j < 20 do
                        local bk = string.format("%s.binding(%d)", key, j)
                        if not hasXMLProperty(xml, bk) then break end
                        local dev = getXMLString(xml, bk .. "#device") or ""
                        local input = getXMLString(xml, bk .. "#input")
                        if action ~= nil and input ~= nil and (dev == "" or dev:find("KB_MOUSE", 1, true)) then
                            local ours = self.byCombo[normCombo(input)]
                            if ours ~= nil and self.ours[action] == nil then
                                self.blocked[action] = { ours = ours, mod = mn }
                                found[#found + 1] = string.format("Ctrl droit + %s (%s, %s)", self.ours[ours].key:sub(5):upper(), action, mn)
                            end
                        end
                        j = j + 1
                    end
                    i = i + 1
                end
                delete(xml)
            end
        end
    end
    if #found > 0 then
        log("touches reprises aux autres mods : %s", table.concat(found, " ; "))
        self.pendingNotice = string.format(AS.L("vtpas_keyLock_taken"), table.concat(found, ", "))
    else
        log("aucun autre mod ne prend nos touches Ctrl droit")
    end
end

-------------------------------------------------------------------------------
-- Lecture directe du clavier
-------------------------------------------------------------------------------
function AS_KeyLock:canFire(where)
    if g_gui ~= nil and g_gui.getIsGuiVisible ~= nil and g_gui:getIsGuiVisible() then return false end
    local v = AS.shGetControlledVehicle ~= nil and AS.shGetControlledVehicle() or nil
    if where == "vehicle" then return v ~= nil end
    if where == "foot" then return v == nil end
    return true
end

function AS_KeyLock:update(dt)
    if not self.ENABLED then return end
    if self.pendingNotice ~= nil and g_currentMission ~= nil and (g_time or 0) > 15000 then
        local text = self.pendingNotice
        self.pendingNotice = nil
        if AS.showTimedNotification ~= nil then
            pcall(AS.showTimedNotification, "alert", FSBaseMission ~= nil and FSBaseMission.INGAME_NOTIFICATION_INFO or nil, text)
        end
    end
    local ctrl = keyDown("KEY_rctrl")
    for _, k in ipairs(self.KEYS) do
        local name = k[1]
        local down = ctrl and keyDown(k[2])
        if down and not self.wasDown[name] then
            local c = self.cb[name]
            if c ~= nil and self:canFire(k[3]) and now() - (self.lastFire[name] or -100000) >= self.MIN_GAP then
                self.lastFire[name] = now()
                local ok, err = pcall(c.callback, c.target, name, 1, nil, nil, false)
                if not ok then log("ERREUR touche %s : %s", name, tostring(err)) end
            end
        end
        self.wasDown[name] = down
    end
end

function AS_KeyLock:loadMap()
    local ok, err = pcall(self.scanMods, self)
    if not ok then log("ERREUR lecture des touches des mods : %s", tostring(err)) end
end

addModEventListener(AS_KeyLock)
