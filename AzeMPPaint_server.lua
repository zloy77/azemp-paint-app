ac.log('AzeMP Paint: script yukleniyor (v5.0-server)')
-- ============================================================
-- SERVER-SIDE VERSIYA: oyuncular hec nə yuklemir.
-- Server csp_extra_options.ini icinde bu faylin URL-i verilir.
-- Gorsel fayl (logo.png) internetde olmalidir (plate ile eyni logo).
-- Reng deyisikliyi onlayn sinxronlasir: digər oyuncular da sizin masinin rengini gorur.
-- ============================================================
local ASSET_BASE = 'https://raw.githubusercontent.com/zloy77/azemp-plate-app/main/'   -- <-- BUNU DEYIS (sonu '/' ile bitsin)
local TOGGLE_KEY = ui.KeyIndex.N       -- <-- boya penceresini acib-baglayan duymə (plate: M, paint: N)
local function asset(p) return ASSET_BASE .. p end
local LOGO = asset('logo.png')

-- ===================== CONFIG =====================
local TEX_SLOT = 'txDiffuse'
local CFG = {
  -- Yalniz adinda bu sozlerden biri olan materiallar boyanir (kicik herfle yoxlanilir)
  paintMatch = { 'carpaint', 'car_paint' },
  applyInterval = 0.2,    -- boyanin tetbiq tezliyi (sn)
  sendInterval  = 0.3,    -- sürüşdürərkən şəbəkəyə göndərmə tezliyi (sn)
  resendEvery   = 8,      -- sn: yeni qoşulanlar da gorsun deye vaxtaşırı yenidən göndər
  initDelay = 1.0,
  maxScanTries = 20,
}

-- Metalik ve parlaqliqdan material xususiyyetleri. Gorunus xoşa gelmirse YALNIZ bunu deyis.
local PROPS = { 'ksSpecular', 'fresnelMaxLevel', 'ksSpecularEXP', 'ksDiffuse' }
local function computeProps(orig, metal, gloss)
  local r = {}
  r.ksSpecular      = 0.15 + metal * 1.05
  r.fresnelMaxLevel = 0.25 + metal * 0.75
  r.ksSpecularEXP   = 6 + gloss * 294
  if orig.ksDiffuse then r.ksDiffuse = orig.ksDiffuse * (1 - 0.30 * metal) end
  return r
end

-- ===================== RENG YARDIMCILARI =====================
local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end

local function hsv2rgb(h, s, v)
  h = (h % 1) * 6
  local i = math.floor(h)
  local f = h - i
  local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
  i = i % 6
  if i == 0 then return v, t, p
  elseif i == 1 then return q, v, p
  elseif i == 2 then return p, v, t
  elseif i == 3 then return p, q, v
  elseif i == 4 then return t, p, v
  else return v, p, q end
end

local function toHex(r, g, b)
  return string.format('%02X%02X%02X', math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- ===================== MASIN DURUMLARI (her masin ucun ayrica) =====================
-- cars[i] = { st = {H,S,V,metal,gloss,strength,active}, id, targets, handles, scanned, ... }
local cars = {}
local function newState()
  return { H = 0.75, S = 0.8, V = 0.7, metal = 0.4, gloss = 0.6, strength = 1.0, active = false }
end
local function getCar(i)
  local c = cars[i]
  if not c then
    c = { st = newState(), id = nil, targets = {}, handles = {}, scanned = false,
          tries = 0, nextScan = 0, dirty = false, lastApply = -100 }
    cars[i] = c
  end
  return c
end

local function carIdOf(i)
  local id = 'unknown'
  pcall(function() id = ac.getCarID(i) or 'unknown' end)
  return id
end

local clock = 0
local me = getCar(0).st
local myCar = getCar(0)
myCar.id = carIdOf(0)

-- Saxlama (yalniz oz masinimiz ucun)
local sMain = ac.storage('azemppaint_main_' .. myCar.id, '0.7500,0.8000,0.7000,0.400,0.600,1.000,0')
do
  local vals = {}
  for n in tostring(sMain:get()):gmatch('[^,]+') do vals[#vals + 1] = tonumber(n) end
  if #vals >= 7 then
    me.H, me.S, me.V = vals[1], vals[2], vals[3]
    me.metal, me.gloss, me.strength = vals[4], vals[5], vals[6]
    me.active = vals[7] == 1
  end
end
local function saveMain()
  pcall(function()
    sMain:set(string.format('%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%d', me.H, me.S, me.V, me.metal, me.gloss, me.strength, me.active and 1 or 0))
  end)
end

local statusLine = 'Hazırlanır…'
local statusOk = nil    -- nil: gozleyir, true: tapildi, false: tapilmadi

-- ===================== SKAN (yalniz CarPaint) =====================
local function scan(i, c)
  c.targets = {}
  local ok, err = pcall(function()
    local root = ac.findNodes('carRoot:' .. i)
    local all = root:findMeshes('?')
    local n = all:size()
    local seen, names = {}, {}
    for k = 1, n do
      local name = all:materialName(k)
      if name and name ~= '' and not seen[name] then
        seen[name] = true
        names[#names + 1] = name
        local low = name:lower()
        for _, kw in ipairs(CFG.paintMatch) do
          if low:find(kw, 1, true) then c.targets[#c.targets + 1] = name break end
        end
      end
    end
    if i == 0 then ac.log('AzeMP Paint: masin ' .. tostring(c.id) .. ' materiallar: ' .. table.concat(names, ' | ')) end
  end)
  if not ok then
    ac.log('AzeMP Paint SCAN HATA (car ' .. i .. '): ' .. tostring(err))
    if i == 0 then statusOk = false; statusLine = 'Skan xətası: ' .. tostring(err) end
  elseif #c.targets == 0 then
    if i == 0 then statusOk = false; statusLine = 'CarPaint materialı tapılmadı' end
  else
    c.scanned = true
    if i == 0 then statusOk = true; statusLine = 'CarPaint tapıldı (' .. #c.targets .. ')' end
  end
end

-- ===================== TETBIQ =====================
local function getHandle(i, c, name)
  local h = c.handles[name]
  if h then return h end
  local root = ac.findNodes('carRoot:' .. i)
  local m = root:findMeshes('material:' .. name)
  if not m or m:size() == 0 then return nil end
  pcall(function() m:ensureUniqueMaterials() end)   -- eyni model olan diger masinlara tesir etmesin
  h = { meshes = m, orig = {}, status = '' }
  for _, p in ipairs(PROPS) do
    pcall(function()
      if m:getMaterialPropertyIndex(p) then
        local v = m:getMaterialPropertyValue(p)
        if type(v) == 'number' then h.orig[p] = v end
      end
    end)
  end
  pcall(function() h.origTex = m:getTextureSlotFilename(TEX_SLOT) end)
  pcall(function() local d = m:getTextureSlotDetails(TEX_SLOT); if d and d.size then h.size = d.size end end)
  h.size = h.size or vec2(1024, 1024)
  c.handles[name] = h
  return h
end

local function applyHandle(i, c, name)
  local h = getHandle(i, c, name)
  if not h then return false end
  local st = c.st
  local m = h.meshes
  local r, g, b = hsv2rgb(st.H, st.S, st.V)
  local strength = st.strength
  local notes = {}

  local okT, errT = pcall(function()
    if strength >= 0.995 then
      -- ucuz yol: duz reng; desteklenmirse callback-li yola dus
      if not pcall(function() m:setMaterialTexture(TEX_SLOT, rgbm(r, g, b, 1)) end) then
        m:setMaterialTexture(TEX_SLOT, { textureSize = h.size, background = rgbm(r, g, b, 1), callback = function() end })
      end
    else
      local size, orig = h.size, h.origTex
      m:setMaterialTexture(TEX_SLOT, {
        textureSize = size,
        callback = function()
          if orig and orig ~= '' then
            pcall(function() display.image{ image = orig, pos = vec2(0, 0), size = size } end)
          end
          display.rect{ pos = vec2(0, 0), size = size, color = rgbm(r, g, b, strength) }
        end,
      })
    end
  end)
  notes[#notes + 1] = okT and 'diffuse' or ('diffuse XƏTA: ' .. tostring(errT))

  local props = computeProps(h.orig, st.metal, st.gloss)
  for _, p in ipairs(PROPS) do
    if h.orig[p] ~= nil and props[p] ~= nil then
      local ok = pcall(function() m:setMaterialProperty(p, props[p]) end)
      notes[#notes + 1] = p .. (ok and '' or '(xəta)')
    end
  end
  local s = table.concat(notes, ' · ')
  if s ~= h.status then
    h.status = s
    ac.log('AzeMP Paint car ' .. i .. ' [' .. name .. ']: ' .. s)
  end
  return true
end

local function resetHandle(h)
  local m = h.meshes
  for p, v in pairs(h.orig) do pcall(function() m:setMaterialProperty(p, v) end) end
  if h.origTex and h.origTex ~= '' then pcall(function() m:setMaterialTexture(TEX_SLOT, h.origTex) end) end
  h.status = ''
end

local function applyAll(i, c)
  local n = 0
  for _, name in ipairs(c.targets) do
    local ok, res = pcall(applyHandle, i, c, name)
    if ok and res then n = n + 1 end
  end
  if i == 0 and #c.targets > 0 then statusLine = 'Tətbiq olundu · ' .. n .. ' material' end
end

local function resetAllHandles(i, c)
  for _, h in pairs(c.handles) do resetHandle(h) end
  if i == 0 then statusLine = 'Orijinal rəng bərpa olundu' end
end

-- ===================== ONLINE SYNC =====================
local function q(v) return math.floor(clamp(v, 0, 1) * 1000 + 0.5) end
local function encode(st)
  return string.format('%d,%d,%d,%d,%d,%d,%d', q(st.H), q(st.S), q(st.V), q(st.metal), q(st.gloss), q(st.strength), st.active and 1 or 0)
end
local function decode(str, st)
  local v = {}
  for n in tostring(str):gmatch('%d+') do v[#v + 1] = tonumber(n) end
  if #v < 7 then return false end
  st.H = clamp(v[1] / 1000, 0, 0.9999)
  st.S, st.V = clamp(v[2] / 1000, 0, 1), clamp(v[3] / 1000, 0, 1)
  st.metal, st.gloss, st.strength = clamp(v[4] / 1000, 0, 1), clamp(v[5] / 1000, 0, 1), clamp(v[6] / 1000, 0, 1)
  st.active = v[7] == 1
  return true
end

local paintEvent = ac.OnlineEvent({
  data = ac.StructItem.string(32)
}, function(sender, data)
  if sender == nil then return end
  local i = sender.index
  if i == 0 then return end
  local c = getCar(i)
  -- yeni oyuncu eyni slotu tutubsa (masin deyisibse) kesh sifirlanir
  local id = carIdOf(i)
  if c.id ~= id then
    c.id = id
    c.targets, c.handles, c.scanned, c.tries, c.nextScan = {}, {}, false, 0, 0
    c.st = newState()
  end
  local prev = encode(c.st)
  if decode(data.data, c.st) and encode(c.st) ~= prev then
    c.dirty = true
    if c.st.active then c.tries = 0 end   -- tapilmayibsa yeniden axtar
  end
end)

local netDirty, lastSend, resendT = false, -100, 0
local function sendMine()
  lastSend = clock
  netDirty = false
  pcall(function() paintEvent({ data = encode(me) }) end)
end

-- ===================== UPDATE =====================
local updErr = false
local function updateBody(dt)
  clock = clock + dt
  resendT = resendT + dt

  for i, c in pairs(cars) do
    -- skan (oz masinimiz hemise, digerleri yalniz boyali olanda)
    if not c.scanned and (i == 0 or c.st.active) and clock >= CFG.initDelay
       and clock >= c.nextScan and c.tries < CFG.maxScanTries then
      c.tries = c.tries + 1
      c.nextScan = clock + 2
      scan(i, c)
      if c.scanned and c.st.active then c.dirty = true end
    end
    -- tetbiq
    if c.dirty and c.scanned and clock - c.lastApply > CFG.applyInterval then
      c.dirty = false
      c.lastApply = clock
      if c.st.active then applyAll(i, c) else resetAllHandles(i, c) end
      if i == 0 then saveMain() end
    end
  end

  if netDirty and clock - lastSend > CFG.sendInterval then sendMine() end
  if resendT > CFG.resendEvery then
    resendT = 0
    sendMine()
  end
end

function script.update(dt)
  local ok, err = pcall(updateBody, dt)
  if not ok and not updErr then
    updErr = true
    ac.log('AzeMP Paint UPDATE HATA: ' .. tostring(err))
    statusLine = 'Xəta: ' .. tostring(err)
    statusOk = false
  end
end

local function markDirty()
  me.active = true
  myCar.dirty = true
  netDirty = true
end

local function resetMine()
  me.active = false
  myCar.dirty = false
  resetAllHandles(0, myCar)
  saveMain()
  sendMine()
end

-- ===================== ARAYUZ yardimcilari =====================
local C = {   -- reng paleti (r, g, b)
  warn = { 1.000, 0.350, 0.400 },
}
local function W_(a) return rgbm(1, 1, 1, a) end
local function Ca(c, a) return rgbm(c[1], c[2], c[3], a or 1) end

local TEXT, SUB = W_(0.95), W_(0.58)

-- Server versiyada fonts/ qovlugu yoxdur: sistem fontu (Segoe UI) istifade olunur
local fonts = { reg = 'Segoe UI', semi = 'Segoe UI;Weight=SemiBold', bold = 'Segoe UI;Weight=Bold' }

local depth = { var = 0, font = 0, ind = {} }
local function pushVar(a, b) ui.pushStyleVar(a, b); depth.var = depth.var + 1 end
local function popVar(n) n = n or 1; ui.popStyleVar(n); depth.var = depth.var - n end
local function indent(w) ui.indent(w); depth.ind[#depth.ind + 1] = w end
local function unindent(w) ui.unindent(w); depth.ind[#depth.ind] = nil end
local function unwind()
  if depth.var > 0 then pcall(ui.popStyleVar, depth.var) end
  while depth.font > 0 do pcall(ui.popDWriteFont); depth.font = depth.font - 1 end
  for k = #depth.ind, 1, -1 do pcall(ui.unindent, depth.ind[k]) end
  depth.var, depth.font, depth.ind = 0, 0, {}
end

local anim = {}
local function smooth(id, target, dt, speed)
  local v = anim[id]
  if v == nil then v = target end
  v = v + (target - v) * math.min(1, dt * (speed or 14))
  anim[id] = v
  return v
end

local curOffset = vec2(0, 0)
local function rawCursor()
  if ui.getCursor then return ui.getCursor() end
  return vec2(ui.getCursorX(), ui.getCursorY())
end
local function cur() return rawCursor() + curOffset end
local function availX()
  if ui.availableSpaceX then return ui.availableSpaceX() end
  if ui.availableSpace then return ui.availableSpace().x end
  return ui.windowSize().x - 24
end
local function gap(h) ui.dummy(vec2(1, h)) end

local function text(str, size, pos, col, weight)
  ui.pushDWriteFont(fonts[weight or 'reg']); depth.font = depth.font + 1
  ui.dwriteDrawText(str, size, pos, col)
  ui.popDWriteFont(); depth.font = depth.font - 1
end
local function measure(str, size, weight)
  ui.pushDWriteFont(fonts[weight or 'reg']); depth.font = depth.font + 1
  local sz = ui.measureDWriteText(str, size)
  ui.popDWriteFont(); depth.font = depth.font - 1
  return sz
end

-- cur() ekran koordinatidir, ona gore siçan da ekran koordinatinda olmalidir
local function mouseLocal() return ui.mousePos() end

local function multiRect(p1, p2, c1, c2, c3, c4)
  local ok = pcall(ui.drawRectFilledMultiColor, p1, p2, c1, c2, c3, c4)
  if not ok then ui.drawRectFilled(p1, p2, c1) end
end

local function disc(c, rad, col)
  if not pcall(ui.drawCircleFilled, c, rad, col, 32) then
    ui.drawRectFilled(c - vec2(rad, rad), c + vec2(rad, rad), col, rad)
  end
end

local function circleRing(c, rad, col, th)
  if not pcall(ui.drawCircle, c, rad, col, 32, th) then
    ui.drawRect(c - vec2(rad, rad), c + vec2(rad, rad), col, rad, nil, th)
  end
end

-- ===================== ARAYUZ: iOS glass =====================
local uiClock = 0

local function pctText(v) return string.format('%d%%', math.floor(v * 100 + 0.5)) end

-- iOS tipli slider
local function slider(id, name, value, W, dt)
  local p = cur()
  ui.invisibleButton(id, vec2(W, 52))
  local act = ui.itemActive()
  local k = smooth(id .. 'k', act and 1 or 0, dt, 16)
  local tx, tw = p.x + 12, W - 24
  local nv, changed = value, false
  if act then
    nv = clamp((mouseLocal().x - tx) / tw, 0, 1)
    changed = true
  end
  local dv = smooth(id .. 'v', value, dt, 26)
  text(name, 14, p + vec2(2, 4), TEXT, 'semi')
  local pz = measure(pctText(value), 14, 'reg')
  text(pctText(value), 14, p + vec2(W - pz.x - 2, 4), SUB, 'reg')
  local ty = p.y + 38
  local fx = tx + tw * dv
  ui.drawRectFilled(vec2(tx, ty - 2.5), vec2(tx + tw, ty + 2.5), W_(0.18), 2.5)
  if fx > tx + 1 then ui.drawRectFilled(vec2(tx, ty - 2.5), vec2(fx, ty + 2.5), W_(0.95), 2.5) end
  disc(vec2(fx, ty + 1.5), 12 + k, rgbm(0, 0, 0, 0.22))
  disc(vec2(fx, ty), 11 + k, W_(1))
  return nv, changed
end

-- yuvarlaq kunclu duzbucaqli qradiyent: yan kenar inset hesablanir
local function insetFor(d, size, rad)
  local e = math.min(d, size - d)
  if e >= rad then return 0 end
  return rad - math.sqrt(math.max(0, rad * rad - (rad - e) * (rad - e)))
end

local function drawSV(p, w, h, hue, rad)
  local rows = 85
  local rh = h / rows
  for k = 0, rows - 1 do
    local y0 = p.y + k * rh
    local ins = insetFor(k * rh + rh * 0.5, h, rad)
    local x1, x2 = p.x + ins, p.x + w - ins
    local sL, sR = (x1 - p.x) / w, (x2 - p.x) / w
    local vT, vB = 1 - k / rows, 1 - (k + 1) / rows
    local a1, a2, a3 = hsv2rgb(hue, sL, vT)
    local b1, b2, b3 = hsv2rgb(hue, sR, vT)
    local c1, c2, c3 = hsv2rgb(hue, sR, vB)
    local d1, d2, d3 = hsv2rgb(hue, sL, vB)
    multiRect(vec2(x1, y0), vec2(x2, y0 + rh + 0.6),
      rgbm(a1, a2, a3, 1), rgbm(b1, b2, b3, 1), rgbm(c1, c2, c3, 1), rgbm(d1, d2, d3, 1))
  end
end

local function drawHueBar(p, w, h)
  local N = 140
  local sw = w / N
  local rad = h / 2
  for i = 0, N - 1 do
    local x = p.x + i * sw
    local ins = insetFor(i * sw + sw * 0.5, w, rad)
    local cr, cg, cb = hsv2rgb((i + 0.5) / N * 0.9999, 1, 1)
    ui.drawRectFilled(vec2(x, p.y + ins), vec2(x + sw + 0.6, p.y + h - ins), rgbm(cr, cg, cb, 1))
  end
end

local function card(p, w, h)
  ui.drawRectFilled(p, p + vec2(w, h), W_(0.09), 18)
  ui.drawRect(p, p + vec2(w, h), W_(0.13), 18)
end

local function windowMainPro(dt)
  dt = math.min(dt or 0.016, 0.05)
  uiClock = uiClock + dt
  pushVar(ui.StyleVar.ItemSpacing, vec2(0, 0))

  local p0 = rawCursor()
  ui.dummy(vec2(1, 1))
  curOffset = ui.itemRectMin() - p0

  -- Donmus saydam seyse (frosted glass)
  local im = ui.itemRectMin()
  local big = vec2(4000, 4000)
  local okB = pcall(ui.beginBlurredBackground)
  pcall(ui.drawRectFilled, im - big, im + big, rgbm(0.06, 0.07, 0.10, 0.38))
  pcall(ui.drawRectFilled, im - big, im + big, rgbm(1, 1, 1, 0.04))
  if okB then pcall(ui.endBlurredBackground) end

  local H, S, V = me.H, me.S, me.V
  local metallic, gloss, strength = me.metal, me.gloss, me.strength

  local M = 16
  indent(M)
  local W = availX() - M
  local changed = false
  local r, g, b = hsv2rgb(H, S, V)

  -- ===== Logo (sol ust) + cari reng =====
  gap(18)
  do
    local hp = cur()
    local lw = 104
    local lh = lw * 176 / 640
    if not pcall(ui.drawImage, LOGO, hp, hp + vec2(lw, lh), W_(1)) then
      text('azemp', 22, hp, W_(1), 'bold')
    end
    local hx = '#' .. toHex(r, g, b)
    local hz = measure(hx, 12, 'semi')
    local pw, ph = hz.x + 36, 28
    local px, py = hp.x + W - pw, hp.y + (lh - ph) / 2
    ui.drawRectFilled(vec2(px, py), vec2(px + pw, py + ph), W_(0.10), 14)
    ui.drawRect(vec2(px, py), vec2(px + pw, py + ph), W_(0.14), 14)
    disc(vec2(px + 15, py + ph / 2), 7, rgbm(r, g, b, 1))
    circleRing(vec2(px + 15, py + ph / 2), 7, W_(0.35), 1)
    text(hx, 12, vec2(px + 28, py + (ph - hz.y) / 2), TEXT, 'semi')
    ui.dummy(vec2(W, lh))
  end
  gap(16)

  -- ===== Palitra karti =====
  local pad = 12
  local Wc = W - pad * 2
  local svH, hueH = 170, 16
  do
    local cp = cur()
    card(cp, W, pad + svH + 14 + 22 + 10)
    indent(pad)
    gap(pad)

    -- Doygunluq / parlaqliq sahesi
    local sp = cur()
    drawSV(sp, Wc, svH, H, 10)
    ui.drawRect(sp, sp + vec2(Wc, svH), W_(0.16), 10)
    ui.invisibleButton('sv', vec2(Wc, svH))
    local svAct = ui.itemActive()
    if svAct then
      local mp = mouseLocal()
      S = clamp((mp.x - sp.x) / Wc, 0, 1)
      V = 1 - clamp((mp.y - sp.y) / svH, 0, 1)
      changed = true
    end
    r, g, b = hsv2rgb(H, S, V)
    local svk = smooth('svk', svAct and 1 or 0, dt, 18)
    local mk = sp + vec2(S * Wc, (1 - V) * svH)
    disc(mk, 11 + 1.5 * svk, rgbm(0, 0, 0, 0.25))
    circleRing(mk, 9 + 1.5 * svk, W_(1), 2.5)
    disc(mk, 7 + 1.5 * svk, rgbm(r, g, b, 1))
    gap(14)

    -- Ton zolagi
    local hp = cur()
    local bp = hp + vec2(0, 3)
    drawHueBar(bp, Wc, hueH)
    ui.invisibleButton('hue', vec2(Wc, 22))
    local hAct = ui.itemActive()
    if hAct then
      H = clamp((mouseLocal().x - hp.x) / Wc, 0, 0.9999)
      changed = true
    end
    local hk = smooth('hk', hAct and 1 or 0, dt, 18)
    local hr, hg, hb = hsv2rgb(H, 1, 1)
    local kx = clamp(hp.x + Wc * H, hp.x + 11, hp.x + Wc - 11)
    local ky = bp.y + hueH / 2
    disc(vec2(kx, ky + 1), 12 + hk, rgbm(0, 0, 0, 0.22))
    disc(vec2(kx, ky), 11 + hk, W_(1))
    disc(vec2(kx, ky), 8, rgbm(hr, hg, hb, 1))
    gap(10)
    unindent(pad)
  end
  gap(12)

  -- ===== Gorunus karti: parlaqliq / metallik / reng doluluğu =====
  do
    local cp = cur()
    card(cp, W, 3 * 52 + 16)
    indent(pad)
    gap(8)
    local nv, ch = slider('sGloss', 'Parlaqlıq', gloss, Wc, dt)
    if ch then gloss = nv; changed = true end
    local l1 = cur()
    ui.drawRectFilled(l1 + vec2(0, 0), l1 + vec2(Wc, 1), W_(0.08))
    nv, ch = slider('sMetal', 'Metallik', metallic, Wc, dt)
    if ch then metallic = nv; changed = true end
    local l2 = cur()
    ui.drawRectFilled(l2, l2 + vec2(Wc, 1), W_(0.08))
    nv, ch = slider('sStr', 'Rəng doluluğu', strength, Wc, dt)
    if ch then strength = nv; changed = true end
    gap(8)
    unindent(pad)
  end
  gap(12)

  -- ===== Orijinala qayit =====
  local resetClicked = false
  do
    local p = cur()
    local bh = 46
    resetClicked = ui.invisibleButton('reset', vec2(W, bh))
    local k = smooth('resetK', ui.itemHovered() and 1 or 0, dt, 14)
    local pr = smooth('resetP', ui.itemActive() and 1 or 0, dt, 22)
    ui.drawRectFilled(p, p + vec2(W, bh), W_(0.10 + 0.05 * k), 14)
    ui.drawRect(p, p + vec2(W, bh), W_(0.14), 14)
    if pr > 0.01 then ui.drawRectFilled(p, p + vec2(W, bh), rgbm(0, 0, 0, 0.20 * pr), 14) end
    local caption = 'Orijinal rəngə qayıt'
    local tz = measure(caption, 14, 'semi')
    text(caption, 14, p + vec2((W - tz.x) / 2, (bh - tz.y) / 2), rgbm(1, 0.45, 0.42, 1), 'semi')
  end

  if statusOk == false then
    gap(10)
    local wp = cur()
    local wz = measure(statusLine, 12, 'semi')
    text(statusLine, 12, wp + vec2((W - wz.x) / 2, 0), Ca(C.warn, 0.55 + 0.45 * math.sin(uiClock * 3) ^ 2), 'semi')
    ui.dummy(vec2(W, 18))
  end
  gap(16)

  me.H, me.S, me.V = H, S, V
  me.metal, me.gloss, me.strength = metallic, gloss, strength
  if changed then markDirty() end
  if resetClicked then
    me.H, me.S, me.V, me.metal, me.gloss, me.strength = 0.75, 0.8, 0.7, 0.4, 0.6, 1.0
    resetMine()
  end

  unindent(M)
  popVar()
end

local uiError = nil
local function windowMainSimple(dt)
  ui.text('Interfeys xetasi (CSP log fayli):')
  ui.textWrapped(tostring(uiError))
  if ui.button('Yeniden cehd et') then uiError = nil end
end

function windowMain(dt)
  if not uiError then
    local ok, err = pcall(windowMainPro, dt)
    if ok then return end
    uiError = tostring(err)
    ac.log('AzeMP Paint UI HATA: ' .. uiError)
    unwind()
  end
  windowMainSimple(dt)
end

-- ====================== SERVER-SIDE: duyme ile pencere ======================
local WINDOW_SIZE = vec2(340, 620)
local windowOpen = false

local toggleBtn = nil
pcall(function()
  toggleBtn = ac.ControlButton('__AZEMPPAINT_TOGGLE', { keyboard = { key = TOGGLE_KEY } })
end)

local function togglePressed()
  if toggleBtn then
    local ok, r = pcall(function() return toggleBtn:pressed() end)
    if ok then return r end
  end
  local ok, r = pcall(ui.keyboardButtonPressed, TOGGLE_KEY, false)
  return ok and r
end

function script.drawUI(dt)
  if togglePressed() then windowOpen = not windowOpen end
  if windowOpen and ui.keyboardButtonPressed(ui.KeyIndex.Escape, false) then windowOpen = false end
  if not windowOpen then return end

  local scr = ui.windowSize()
  -- Plate penceresi (380 en) ekranin ortasindadir; Paint onun solunda durur, ust uste binmir
  local PLATE_HALF_W, GAP = 190, 20
  local px = scr.x / 2 - PLATE_HALF_W - GAP - WINDOW_SIZE.x
  local pos = vec2(math.max(10, px), math.max(10, (scr.y - WINDOW_SIZE.y) / 2))
  ui.transparentWindow('AzeMPPaintWindow', pos, WINDOW_SIZE, true, true, function()
    windowMain(dt)
  end)
end

-- Acilista: yadda saxlanilmis boya varsa tetbiq et ve digerlerine gonder
if me.active then
  myCar.dirty = true
  netDirty = true
end
ac.log('AzeMP Paint: init bitti, car = ' .. tostring(myCar.id) .. ', active = ' .. tostring(me.active))
