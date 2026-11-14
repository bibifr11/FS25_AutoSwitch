-- AutoSwitch : bloc poids sous le compteur de vitesse (poids total, répartition avant / arrière,
-- masse avant conseillée pour l'outil attelé). Caché si Realistic Mechanical Systems est actif.
-- Fichier chargé par AutoSwitch.lua (après Common.lua).
--
-- Calcul (outil levé, véhicule à l'arrêt), moments pris au pont arrière du tracteur :
--   charge d'un outil sur son porteur : porté 3 points = toute sa masse à son centre de gravité ;
--   semi-porté / traîné = part reprise à l'attelage (bras de levier attelage -> roues de l'outil)
--   règle travail   : porté = tracteur lesté sans outil à 45 % avant ; semi-porté 50 % et traîné 60 %
--                     avec la charge au crochet ; 30 % pour un 2 roues motrices
--   règle transport : outil levé, au moins 30 % du poids sur l'avant (rouge sous 20 %)
--   masse conseillée = la plus exigeante des deux, arrondie à 50 kg au-dessus

local L = AS.L
local shClamp = AS.shClamp
local shGetControlledVehicle = AS.shGetControlledVehicle

AS_Ballast = {}
AS_Ballast.ENABLED = true
AS_Ballast.POS_X = nil           -- coin bas-gauche déplacé à la souris (nil = par défaut)
AS_Ballast.POS_Y = nil
AS_Ballast.DEF_X = 0.80          -- secours si le compteur est introuvable
AS_Ballast.DEF_Y = 0.005
AS_Ballast.UPDATE_MS = 500
AS_Ballast.CIBLE = { porte = 0.45, semiPorte = 0.50, traine = 0.60, remorque = 0.50 }
AS_Ballast.CIBLE_2RM = 0.30
AS_Ballast.TRANSPORT = 0.30
AS_Ballast.MINI_SECU = 0.20
AS_Ballast.TOLERANCE_KG = 300
AS_Ballast.RMS_MOD = "FS25_RealisticMechanicalSystems"
AS_Ballast.state = { t = -10000 }
AS_Ballast.dragging = false
AS_Ballast.box = nil


-------------------------------------------------------------------------------
-- Calcul pur (testé hors jeu)
--   tr = { masse, zG, zAv, zAr, quatreRM }  (t, m dans le repère du tracteur)
--   charges = { { m, z, avant = bool } }      charges reprises par le tracteur
--   zLest   = centre de gravité de la masse avant ; typeOutil = porte / semiPorte / traine / nil
-------------------------------------------------------------------------------
function AS_Ballast.solve(tr, charges, zLest, typeOutil)
    local Lb = tr.zAv - tr.zAr
    if Lb < 0.5 then return nil end
    local function frontOf(m, z) return m * (z - tr.zAr) / Lb end
    local av, tot = frontOf(tr.masse, tr.zG), tr.masse
    local avSeul, totSeul = av, tot                 -- tracteur seul
    local avArr, totArr = av, tot                   -- tracteur + outils arrière (sans masse avant)
    local mAvant = 0
    for _, c in ipairs(charges) do
        local f = frontOf(c.m, c.z)
        av, tot = av + f, tot + c.m
        if c.avant then
            mAvant = mAvant + c.m
        else
            avArr, totArr = avArr + f, totArr + c.m
        end
    end
    local res = { total = tot, avant = av, arriere = tot - av, part = tot > 0 and av / tot or 0, actuelle = mAvant }
    if typeOutil == nil then return res end
    local k = (zLest - tr.zAr) / Lb
    local function lestPour(a0, t0, r)
        if k - r <= 0.05 then return 0 end
        return (r * t0 - a0) / (k - r)
    end
    local r = tr.quatreRM and (AS_Ballast.CIBLE[typeOutil] or 0.45) or AS_Ballast.CIBLE_2RM
    -- outil porté : tracteur seul (l'outil est compté par la règle transport) ;
    -- semi-porté / traîné : tracteur + charge au crochet, l'effort de traction allège l'avant
    local bTravail
    if typeOutil == "porte" then
        bTravail = lestPour(avSeul, totSeul, r)
    else
        bTravail = lestPour(avArr, totArr, r)
    end
    local bTransport = lestPour(avArr, totArr, AS_Ballast.TRANSPORT)
    local b = math.max(bTravail, bTransport, 0)
    res.ideal = math.ceil(b * 1000 / 50 - 1e-6) * 50   -- kg
    res.regle = bTransport > bTravail and "transport" or "travail"
    local partArr = (avArr + mAvant * k) / (totArr + mAvant)  -- outil levé, masse avant actuelle
    res.partOutil = partArr
    if partArr < AS_Ballast.MINI_SECU then
        res.couleur = "red"
    elseif math.abs(mAvant * 1000 - res.ideal) <= AS_Ballast.TOLERANCE_KG then
        res.couleur = "green"
    else
        res.couleur = "orange"
    end
    return res
end

-------------------------------------------------------------------------------
-- Lecture du jeu
-------------------------------------------------------------------------------
local function wheelsOf(v)
    return v ~= nil and v.spec_wheels ~= nil and v.spec_wheels.wheels or nil
end

local function zIn(ref, node, x, y, z)
    local wx, wy, wz = localToWorld(node, x or 0, y or 0, z or 0)
    local _, _, lz = worldToLocal(ref, wx, wy, wz)
    return lz
end

-- masse (t) et somme des moments (t.m) des composants d'un véhicule, repère ref
local function ownMass(v, ref)
    local m, mz = 0, 0
    for _, c in ipairs(v.components or {}) do
        if c.node ~= nil and c.node ~= 0 then
            local cm = (v.getComponentMass ~= nil and v:getComponentMass(c)) or c.mass or 0
            if cm > 0 then
                local cx, cy, cz = getCenterOfMass(c.node)
                m, mz = m + cm, mz + cm * zIn(ref, c.node, cx, cy, cz)
            end
        end
    end
    return m, mz
end

local function jointTypeOf(obj)
    if obj.getActiveInputAttacherJoint == nil then return nil end
    local ij = obj:getActiveInputAttacherJoint()
    return ij ~= nil and ij.jointType or nil
end

local function isMounted(jt)
    return jt ~= nil and AttacherJoints ~= nil and jt == AttacherJoints.JOINTTYPE_IMPLEMENT
end

local function isSemiMounted(jt)
    return jt ~= nil and AttacherJoints ~= nil and AttacherJoints.JOINTTYPE_SEMIMOUNTED ~= nil
        and jt == AttacherJoints.JOINTTYPE_SEMIMOUNTED
end

-- nœuds des roues de l'outil qui touchent le sol
local function groundWheels(obj)
    local list = {}
    for _, w in ipairs(wheelsOf(obj) or {}) do
        local node = w.repr or w.driveNode or w.node
        local onGround = w.physics == nil or w.physics.hasGroundContact ~= false
        if node ~= nil and node ~= 0 and onGround then list[#list + 1] = node end
    end
    return list
end

local function isLowered(obj)
    if obj.getIsLowered == nil then return false end
    local ok, low = pcall(obj.getIsLowered, obj, false)
    return ok and low == true
end

local bodyLoad

-- charge (t) qu'un outil met sur son porteur et sa position z ; masse totale de la branche
local function transferred(parent, impl, ref, depth)
    local obj = impl.object
    local m, mz, mAll = bodyLoad(obj, ref, depth + 1)
    if m <= 0 then return 0, 0, mAll end
    local zG = mz / m
    local jt = jointTypeOf(obj)
    -- roues de l'outil posées au sol ; un outil porté baissé (au travail) est compté levé
    local ground = groundWheels(obj)
    if #ground == 0 or (isMounted(jt) and isLowered(obj)) then
        return m, zG, mAll, "porte"                -- porté (outil levé) ou sans roues au sol
    end
    local kind = isSemiMounted(jt) and "semiPorte" or "traine"
    if obj.spec_trailer ~= nil then kind = "remorque" end   -- benne / plateau : pas d'effort de traction au sol
    local zH = zG
    local jd = parent.getAttacherJointByJointDescIndex ~= nil and parent:getAttacherJointByJointDescIndex(impl.jointDescIndex) or nil
    if jd ~= nil and jd.jointTransform ~= nil then zH = zIn(ref, jd.jointTransform) end
    local sz = 0
    for _, node in ipairs(ground) do sz = sz + zIn(ref, node) end
    local zW = sz / #ground
    local bras = zW - zH
    if math.abs(bras) < 0.05 then return 0, zH, mAll, kind end
    local part = shClamp((zW - zG) / bras, 0, 1)
    return m * part, zH, mAll, kind
end

-- masse portée par la caisse d'un véhicule : la sienne + ce que ses outils lui mettent dessus
bodyLoad = function(v, ref, depth)
    local m, mz = ownMass(v, ref)
    local mAll = m
    if depth < 4 and v.getAttachedImplements ~= nil then
        for _, impl in ipairs(v:getAttachedImplements() or {}) do
            if impl.object ~= nil then
                local cm, cz, ca = transferred(v, impl, ref, depth)
                m, mz, mAll = m + cm, mz + cm * cz, mAll + ca
            end
        end
    end
    return m, mz, mAll
end

local function frontHitchZ(v, ref, zAv)
    local spec = v.spec_attacherJoints
    for _, jd in ipairs(spec ~= nil and spec.attacherJoints or {}) do
        if jd.jointTransform ~= nil then
            local z = zIn(ref, jd.jointTransform)
            if z > zAv then return z end
        end
    end
    return nil
end

function AS_Ballast:compute(v)
    local ref = v.rootNode
    local wheels = wheelsOf(v)
    if ref == nil or wheels == nil or #wheels < 2 then return nil end
    local zAv, zAr = -math.huge, math.huge
    for _, w in ipairs(wheels) do
        local node = w.repr or w.driveNode or w.node
        if node ~= nil and node ~= 0 then
            local z = zIn(ref, node)
            zAv, zAr = math.max(zAv, z), math.min(zAr, z)
        end
    end
    if zAv - zAr < 0.5 then return nil end
    local m, mz = ownMass(v, ref)
    if m <= 0 then return nil end
    local tr = { masse = m, zG = mz / m, zAv = zAv, zAr = zAr,
        quatreRM = AS.is4wd == nil or AS.is4wd(v) ~= false }
    local charges, total = {}, m
    local typeOutil, mOutil = nil, 0
    local zLest, mFront, mzFront = nil, 0, 0
    for _, impl in ipairs(v.getAttachedImplements ~= nil and v:getAttachedImplements() or {}) do
        local obj = impl.object
        if obj ~= nil then
            local cm, cz, ca, kind = transferred(v, impl, ref, 0)
            total = total + ca
            -- avant / arrière selon le point d'attelage (chargeur frontal compris à l'avant)
            local avant = cz > zAv
            local jd = v.getAttacherJointByJointDescIndex ~= nil and v:getAttacherJointByJointDescIndex(impl.jointDescIndex) or nil
            if jd ~= nil and jd.jointTransform ~= nil then
                avant = zIn(ref, jd.jointTransform) > (zAv + zAr) * 0.5
            end
            charges[#charges + 1] = { m = cm, z = cz, avant = avant }
            if avant then
                mFront, mzFront = mFront + cm, mzFront + cm * cz
            elseif ca > mOutil then
                mOutil = ca
                typeOutil = kind
            end
        end
    end
    if mFront > 0 then
        zLest = mzFront / mFront
    else
        local zh = frontHitchZ(v, ref, zAv)
        zLest = zh ~= nil and (zh + 0.4) or (zAv + 1.2)
    end
    if AS.isHarvester ~= nil and AS.isHarvester(v) then typeOutil = nil end
    local res = AS_Ballast.solve(tr, charges, zLest, typeOutil)
    if res == nil then return nil end
    res.poids = total
    res.typeOutil = typeOutil
    return res
end

function AS_Ballast:update(dt)
    if not self.ENABLED or g_currentMission == nil then return end
    if g_modIsLoaded ~= nil and g_modIsLoaded[self.RMS_MOD] == true then return end
    local st = self.state
    if g_time - st.t < self.UPDATE_MS and g_time >= st.t then return end
    st.t = g_time
    local v = shGetControlledVehicle()
    local res = nil
    if v ~= nil then
        local ok, r = pcall(self.compute, self, v)
        if ok then
            res = r
        elseif not self.loggedError then
            self.loggedError = true
            print("[AS_Ballast] erreur : " .. tostring(r))
        end
    end
    st.vehicle, st.res = v, res
    if res ~= nil then
        local key = string.format("%s|%s|%d|%d", tostring(v), tostring(res.typeOutil), res.ideal or -1, math.floor(res.actuelle * 1000 + 0.5))
        if key ~= st.logKey then
            st.logKey = key
            print(string.format("[AS_Ballast] %s : poids %.2f t, av %.2f t / ar %.2f t (%d %%), outil %s, masse avant actuelle %d kg, conseillée %s kg (règle %s), outil levé %d %% avant",
                tostring(v.getName ~= nil and v:getName() or "?"), res.poids, res.avant, res.arriere, math.floor(res.part * 100 + 0.5),
                tostring(res.typeOutil), math.floor(res.actuelle * 1000 + 0.5), tostring(res.ideal), tostring(res.regle),
                math.floor((res.partOutil or res.part) * 100 + 0.5)))
        end
    end
end

-------------------------------------------------------------------------------
-- Affichage
-------------------------------------------------------------------------------
local COLORS = {
    white  = { 1, 1, 1, 1 },
    grey   = { 0.75, 0.75, 0.75, 1 },
    green  = { 0.45, 0.90, 0.35, 1 },
    orange = { 1.00, 0.60, 0.10, 1 },
    red    = { 1.00, 0.25, 0.20, 1 },
}

local function fmtT(t)
    return (string.format("%.1f", t):gsub("%.", ","))
end

local function fmtKg(kg)
    local s = tostring(math.floor(kg + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
    return (out:gsub("^ ", ""))
end

function AS_Ballast:draw()
    self.box = nil
    if not self.ENABLED or g_currentMission == nil then return end
    if g_modIsLoaded ~= nil and g_modIsLoaded[self.RMS_MOD] == true then return end
    local st = self.state
    local res = st.res
    if res == nil or st.vehicle ~= shGetControlledVehicle() then return end
    local hud = g_currentMission.hud
    if hud == nil or (hud.getIsVisible ~= nil and not hud:getIsVisible()) then return end
    local sm = hud.speedMeter
    local function py(px)
        if sm ~= nil and sm.scalePixelToScreenHeight ~= nil then return sm:scalePixelToScreenHeight(px) end
        return px / 1080
    end
    local function pxw(px)
        if sm ~= nil and sm.scalePixelToScreenWidth ~= nil then return sm:scalePixelToScreenWidth(px) end
        return px / 1920
    end

    -- avant négatif = le tracteur se cabre : affiché 0 (la masse conseillée est alors en rouge)
    local av = math.max(0, res.avant)
    local part = res.total > 0 and av / res.total or 0
    -- tout sur une ligne : « Poids 8,8 t  Av 17 %  Masse avant 600 / 1 000 kg » + jauge en petits carrés
    local parts = {
        { text = string.format(L("as_ballast_weight"), fmtT(res.poids)), color = "white", bold = true },
        { text = string.format(L("as_ballast_split"), math.floor(part * 100 + 0.5)), color = "grey" },
    }
    if res.ideal ~= nil then
        parts[#parts + 1] = { text = string.format(L("as_ballast_line"), fmtKg(res.actuelle * 1000), fmtKg(res.ideal)),
            color = res.couleur, bold = true }
    end
    local size = py(13)
    local sep = pxw(10)
    local padX, padY = pxw(8), py(4)
    local sq, sqH, sqGap, mark = 3, 8, 1, 1     -- jauge : barres verticales 3 x 8 px, 1 px d'écart, trait de 1 px
    local gaugeW = res.ideal ~= nil and (pxw(sq * 10 + sqGap * 10 + mark + sqGap)) or 0
    local w = 0
    for i, pt in ipairs(parts) do
        setTextBold(pt.bold == true)
        pt.w = getTextWidth(size, pt.text)
        w = w + pt.w + (i > 1 and sep or 0)
    end
    if gaugeW > 0 then w = w + sep * 0.6 + gaugeW end
    local boxW, boxH = w + padX * 2, size + padY * 2
    -- par défaut : sous le compteur de vitesse, calé sur son bord droit
    local x, y = self.DEF_X, self.DEF_Y
    local bg, bgR = sm ~= nil and sm.speedBg or nil, sm ~= nil and sm.speedBgRight or nil
    if bg ~= nil and bg.x ~= nil and bg.y ~= nil then
        local right = (bgR ~= nil and bgR.x ~= nil and bgR.width ~= nil) and (bgR.x + bgR.width) or (bg.x + (bg.width or 0))
        x = right - boxW
        y = bg.y - py(6) - boxH
    end
    if self.POS_X ~= nil and self.POS_Y ~= nil then x, y = self.POS_X, self.POS_Y end
    x = shClamp(x, 0, math.max(0, 1 - boxW))
    y = shClamp(y, 0, math.max(0, 1 - boxH))
    self.box = { x = x, y = y, w = boxW, h = boxH }
    if drawFilledRect ~= nil then drawFilledRect(x, y, boxW, boxH, 0, 0, 0, 0.6) end
    setTextAlignment(RenderText.ALIGN_LEFT)
    local cx = x + padX
    for i, pt in ipairs(parts) do
        if i > 1 then cx = cx + sep end
        local c = COLORS[pt.color] or COLORS.white
        setTextBold(pt.bold == true)
        setTextColor(c[1], c[2], c[3], c[4])
        renderText(cx, y + padY + size * 0.15, size, pt.text)
        cx = cx + pt.w
    end
    if gaugeW > 0 then
        self:drawGauge(res, cx + sep * 0.6, y + boxH * 0.5 - py(sqH) * 0.5, sq, sqH, sqGap, mark, pxw, py)
    end
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
end

-- Jauge de la masse avant : 10 cases, la 8e = masse conseillée (trait blanc juste après) ;
-- 1 à 8 du rouge au vert, 9 et 10 = trop lourd (orange puis rouge)
local GAUGE_COLORS = {
    { 0.86, 0.18, 0.14 }, { 0.93, 0.33, 0.11 }, { 1.00, 0.48, 0.08 }, { 1.00, 0.62, 0.10 },
    { 1.00, 0.76, 0.14 }, { 0.86, 0.84, 0.20 }, { 0.58, 0.85, 0.26 }, { 0.30, 0.86, 0.32 },
    { 1.00, 0.62, 0.10 }, { 0.93, 0.30, 0.12 },
}
AS_Ballast.GAUGE_IDEAL = 8

function AS_Ballast:drawGauge(res, gx, gy, sq, sqH, sqGap, mark, pxw, py)
    if drawFilledRect == nil then return end
    local ideal = (res.ideal or 0) / 1000
    local cur = res.actuelle or 0
    local k = self.GAUGE_IDEAL
    -- remplissage continu (0..10 cases) : conseillée = 8 cases, 10 cases = 25 % de trop
    local target
    if ideal > 0 then
        target = cur / ideal * k
    else
        target = k + math.min(2, cur / 0.5)   -- rien de conseillé : chaque 250 kg de plus = une case
    end
    target = math.max(0, math.min(10, target))
    -- la jauge glisse en douceur quand la masse, le remplissage du semoir ou de la remorque changent
    local now = g_time or 0
    local shown = self.gaugeShown
    if shown == nil or self.gaugeVehicle ~= self.state.vehicle then
        shown = target
    else
        local dt = math.max(0, math.min(200, now - (self.gaugeTime or now)))
        shown = shown + (target - shown) * math.min(1, dt / 250)
        if math.abs(target - shown) < 0.01 then shown = target end
    end
    self.gaugeShown, self.gaugeTime, self.gaugeVehicle = shown, now, self.state.vehicle
    -- 10 barres verticales ; trait blanc après la 8e (= masse conseillée)
    local w, h, g = pxw(sq), py(sqH), pxw(sqGap)
    local sx = gx
    for i = 1, 10 do
        local col = GAUGE_COLORS[i]
        local fill = math.max(0, math.min(1, shown - (i - 1)))
        if fill < 1 then drawFilledRect(sx, gy, w, h, col[1], col[2], col[3], 0.22) end
        if fill > 0 then drawFilledRect(sx, gy, w, h * fill, col[1], col[2], col[3], 1) end   -- se remplit par le bas
        sx = sx + w + g
        if i == k then
            drawFilledRect(sx, gy - py(2), pxw(mark), h + py(4), 1, 1, 1, 0.9)
            sx = sx + pxw(mark) + g
        end
    end
end

-- déplacement à la souris, comme les blocs de SpeedHint.lua
function AS_Ballast:mouseEvent(posX, posY, isDown, isUp, button)
    local canDrag = self.ENABLED and g_inputBinding ~= nil and g_inputBinding.getShowMouseCursor ~= nil
        and g_inputBinding:getShowMouseCursor() == true
    if not canDrag then
        self.dragging = false
        return
    end
    local b = self.box
    if isDown and button == Input.MOUSE_BUTTON_LEFT then
        if b ~= nil and posX >= b.x and posX <= b.x + b.w and posY >= b.y and posY <= b.y + b.h then
            self.dragging = true
            self.dragDX, self.dragDY = posX - b.x, posY - b.y
        end
        return
    end
    if self.dragging then
        local nx, ny = posX - (self.dragDX or 0), posY - (self.dragDY or 0)
        if b ~= nil then
            nx = shClamp(nx, 0, math.max(0, 1 - b.w))
            ny = shClamp(ny, 0, math.max(0, 1 - b.h))
        end
        self.POS_X, self.POS_Y = nx, ny
        if isUp then
            self.dragging = false
            if AS_Settings ~= nil then
                AS_Settings.ballastPosX, AS_Settings.ballastPosY = nx, ny
                AS_Settings:save()
            end
        end
    end
end

function AS_Ballast:delete()
    self.state = { t = -10000 }
    self.box = nil
end

addModEventListener(AS_Ballast)
