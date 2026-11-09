ac.log('AzeMP Paint: yuklenir v4.0')

-- ============================================================
-- AzeMP Paint: masinin CarPaint rengi + metalik + parlaqliq
-- Single player TEST versiyasi (Lua app).
-- Quraşdırma: apps/lua/AzeMPPaint/ (manifest.ini, AzeMPPaint.lua, logo.png, fonts/)
-- ============================================================

local CAR = 0
local TEX_SLOT = 'txDiffuse'
local LOGO = './logo.png'

-- ===================== CONFIG =====================
local CFG = {
  -- Yalniz adinda bu sozlerden biri olan materiallar boyanir (kicik herfle yoxlanilir)
  paintMatch = { 'carpaint', 'car_paint' },
  applyInterval = 0.12,
  initDelay = 1.0,
  rgbSpeed = 0.10,        -- logo RGB glow suretu (hue/sn)
  fontFamily = 'SF Pro Display',   -- fonts/ qovluguna SF Pro fayllarini qoysan istifade olunur
  fontFolder = './fonts',
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

local PRESETS = {
  'F4F4F2', 'C0C4CA', '7A7F87', '33363B', '0C0C0E', '7A1020', 'C1121F', 'E4572E',
  'F2B705', 'E9D8A6', '2D6A4F', '52B788', '0B3C5D', '1D6FA5', '3FA7D6', '00A6A6',
  '5E2B97', '9333EA', 'D946EF', 'FF4DA6', '8B5A2B', 'B87333', 'FF6B00', 'A3E635',
}

-- ===================== RENG YARDIMCILARI =====================
local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end
local function lerp(a, b, t) return a + (b - a) * t end

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

local function rgb2hsv(r, g, b)
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  local d = mx - mn
  local h = 0
  if d > 0 then
    if mx == r then h = ((g - b) / d) % 6
    elseif mx == g then h = (b - r) / d + 2
    else h = (r - g) / d + 4 end
    h = h / 6
  end
  return h, (mx == 0) and 0 or d / mx, mx
end

local function toHex(r, g, b)
  return string.format('%02X%02X%02X', math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

local function parseHex(str)
  str = (str or ''):gsub('#', ''):gsub('%s', '')
  if #str ~= 6 or not str:match('^%x+$') then return nil end
  return tonumber(str:sub(1, 2), 16) / 255, tonumber(str:sub(3, 4), 16) / 255, tonumber(str:sub(5, 6), 16) / 255
end

-- ===================== DURUM + SAXLAMA =====================
local carId = 'unknown'
pcall(function() carId = ac.getCarID(CAR) or 'unknown' end)

local sMain = ac.storage('azemppaint_main', '0.7500,0.8000,0.7000,0.400,0.600,1.000,0')

local H, S, V, metallic, gloss, strength, active = 0.75, 0.8, 0.7, 0.4, 0.6, 1.0, false
do
  local vals = {}
  for n in tostring(sMain:get()):gmatch('[^,]+') do vals[#vals + 1] = tonumber(n) end
  if #vals >= 7 then
    H, S, V = vals[1], vals[2], vals[3]
    metallic, gloss, strength = vals[4], vals[5], vals[6]
    active = vals[7] == 1
  end
end

local function saveMain()
  sMain:set(string.format('%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%d', H, S, V, metallic, gloss, strength, active and 1 or 0))
end

local targets = {}      -- CarPaint material adlari
local handles = {}      -- [ad] = { meshes, orig, origTex, size, status }
local statusLine = 'Hazırlanır…'
local statusOk = nil    -- nil: gozleyir, true: tapildi, false: tapilmadi
local hexText = toHex(hsv2rgb(H, S, V))

-- ===================== SKAN (yalniz CarPaint) =====================
local function scan()
  targets = {}
  local ok, err = pcall(function()
    local root = ac.findNodes('carRoot:' .. CAR)
    local all = root:findMeshes('?')
    local n = all:size()
    local seen, names = {}, {}
    for i = 1, n do
      local name = all:materialName(i)
      if name and name ~= '' and not seen[name] then
        seen[name] = true
        names[#names + 1] = name
        local low = name:lower()
        for _, kw in ipairs(CFG.paintMatch) do
          if low:find(kw, 1, true) then targets[#targets + 1] = name break end
        end
      end
    end
    ac.log('AzeMP Paint: masin ' .. carId .. ' materiallar: ' .. table.concat(names, ' | '))
  end)
  if not ok then
    statusOk = false
    statusLine = 'Skan xətası: ' .. tostring(err)
    ac.log('AzeMP Paint SCAN HATA: ' .. tostring(err))
  elseif #targets == 0 then
    statusOk = false
    statusLine = 'CarPaint materialı tapılmadı'
  else
    statusOk = true
    statusLine = 'CarPaint tapıldı (' .. #targets .. ')'
  end
end

-- ===================== TETBIQ =====================
local function getHandle(name)
  local h = handles[name]
  if h then return h end
  local root = ac.findNodes('carRoot:' .. CAR)
  local m = root:findMeshes('material:' .. name)
  if not m or m:size() == 0 then return nil end
  pcall(function() m:ensureUniqueMaterials() end)
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
  handles[name] = h
  return h
end

local function applyHandle(name)
  local h = getHandle(name)
  if not h then return false end
  local m = h.meshes
  local r, g, b = hsv2rgb(H, S, V)
  local notes = {}

  local okT, errT = pcall(function()
    if strength >= 0.995 then
      m:setMaterialTexture(TEX_SLOT, { textureSize = h.size, background = rgbm(r, g, b, 1), callback = function() end })
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

  local props = computeProps(h.orig, metallic, gloss)
  for _, p in ipairs(PROPS) do
    if h.orig[p] ~= nil and props[p] ~= nil then
      local ok = pcall(function() m:setMaterialProperty(p, props[p]) end)
      notes[#notes + 1] = p .. (ok and '' or '(xəta)')
    end
  end
  h.status = table.concat(notes, ' · ')
  return true
end

local function resetHandle(name)
  local h = handles[name]
  if not h then return end
  local m = h.meshes
  for p, v in pairs(h.orig) do pcall(function() m:setMaterialProperty(p, v) end) end
  if h.origTex and h.origTex ~= '' then pcall(function() m:setMaterialTexture(TEX_SLOT, h.origTex) end) end
  h.status = ''
end

local function applyAll()
  local n = 0
  for _, name in ipairs(targets) do
    local ok, res = pcall(applyHandle, name)
    if ok and res then n = n + 1 end
  end
  if #targets > 0 then statusLine = 'Tətbiq olundu · ' .. n .. ' material' end
end

local function resetAll()
  for name in pairs(handles) do resetHandle(name) end
  active = false
  saveMain()
  statusLine = 'Orijinal rəng bərpa olundu'
end

local clock, lastApply, dirty, inited = 0, -100, false, false
local updErr = false

local function markDirty()
  dirty = true
  active = true
end

function script.update(dt)
  local ok, err = pcall(function()
    clock = clock + dt
    if not inited and clock > CFG.initDelay then
      inited = true
      scan()
      if active then dirty = true end
    end
    if dirty and clock - lastApply > CFG.applyInterval then
      dirty = false
      lastApply = clock
      applyAll()
      saveMain()
    end
  end)
  if not ok and not updErr then
    updErr = true
    ac.log('AzeMP Paint UPDATE HATA: ' .. tostring(err))
    statusLine = 'Xəta: ' .. tostring(err)
    statusOk = false
  end
end

-- ===================== ARAYUZ v4 yardimcilari =====================

local SWATCHES = {
  'F4F4F2', 'C0C4CA', '33363B', '0C0C0E', 'C1121F', 'FF6B00', 'F2B705', 'A3E635',
  '2D6A4F', '00A6A6', '3FA7D6', '1D6FA5', '0B3C5D', '9333EA', 'D946EF', 'FF4DA6',
}

local C = {   -- reng paleti (r, g, b)
  accent  = { 0.576, 0.200, 0.918 },   -- mor
  accent2 = { 0.851, 0.275, 0.937 },   -- magenta
  warn    = { 1.000, 0.350, 0.400 },
}
local function W_(a) return rgbm(1, 1, 1, a) end
local function Ca(c, a) return rgbm(c[1], c[2], c[3], a or 1) end

local TEXT, SUB = W_(0.95), rgbm(0.68, 0.64, 0.78, 1)


-- ===================== FONT (SF Pro -> Segoe UI) =====================
local fonts = nil
local fontLabel = 'Segoe UI'

local function measureFont(f)
  local ok, w = pcall(function()
    ui.pushDWriteFont(f)
    local x = ui.measureDWriteText('Hamburgefonstiv 0123', 100).x
    ui.popDWriteFont()
    return x
  end)
  return ok and w or nil
end

local function weighted(base, enumName, strName)
  if type(base) == 'string' then return base .. ';Weight=' .. strName end
  local ok, f = pcall(function() return base:weight(ui.DWriteFont.Weight[enumName]) end)
  return (ok and f) and f or base
end

local function resolveFonts()
  if fonts then return end
  local ref = measureFont('NoSuchFontXYZ')
  local fam, folder = CFG.fontFamily, CFG.fontFolder
  local cands = {
    function() return ui.DWriteFont(fam, folder) end,
    function() return fam .. ':' .. folder end,
    function() return fam end,
    function() return 'SF Pro Text' end,
  }
  local base
  for i, c in ipairs(cands) do
    local ok, f = pcall(c)
    if ok and f then
      local w = measureFont(f)
      if w and ref and math.abs(w - ref) > 0.5 then
        base = f
        fontLabel = 'SF Pro (#' .. i .. ')'
        break
      end
    end
  end
  if not base then base = 'Segoe UI' end
  fonts = { reg = base, semi = weighted(base, 'SemiBold', 'SemiBold'), bold = weighted(base, 'Bold', 'Bold') }
  ac.log('AzeMP Paint: font = ' .. fontLabel)
end

-- ===================== ALT FUNKSIYALAR =====================
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

local function mouseLocal()
  local ok, v = pcall(ui.mouseLocalPos)
  if ok and v then return v end
  return ui.mousePos() - ui.windowPos()
end

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

-- Yumsaq glow (merkezden kenara solan qatlar)
local function glowRect(p1, p2, r, g, b, rounding, spread, strength)
  if strength <= 0.003 then return end
  for i = 8, 1, -1 do
    local t = i / 8
    local e = spread * t
    ui.drawRectFilled(p1 - vec2(e, e), p2 + vec2(e, e),
      rgbm(r, g, b, strength * 0.075 * (1 - t) ^ 1.4 + strength * 0.006), rounding + e)
  end
end

local function glowDisc(c, rad, r, g, b, spread, strength)
  if strength <= 0.003 then return end
  for i = 8, 1, -1 do
    local t = i / 8
    pcall(ui.drawCircleFilled, c, rad + spread * t,
      rgbm(r, g, b, strength * 0.10 * (1 - t) ^ 1.4 + strength * 0.008), 32)
  end
end

local function label(str, W)
  local p = cur()
  text(str, 11, p + vec2(2, 0), SUB, 'semi')
  ui.dummy(vec2(W, 20))
end

-- ===================== ARAYUZ v4: iOS glass =====================
SUB = W_(0.58)
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
  -- d: kenardan mesafe (0..size), qaytarir: kunc yuvarlaqligi ucun daxile cekilme
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
  resolveFonts()
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
  do
    local p = cur()
    local bh = 46
    local clicked = ui.invisibleButton('reset', vec2(W, bh))
    local k = smooth('resetK', ui.itemHovered() and 1 or 0, dt, 14)
    local pr = smooth('resetP', ui.itemActive() and 1 or 0, dt, 22)
    ui.drawRectFilled(p, p + vec2(W, bh), W_(0.10 + 0.05 * k), 14)
    ui.drawRect(p, p + vec2(W, bh), W_(0.14), 14)
    if pr > 0.01 then ui.drawRectFilled(p, p + vec2(W, bh), rgbm(0, 0, 0, 0.20 * pr), 14) end
    local label = 'Orijinal rəngə qayıt'
    local tz = measure(label, 14, 'semi')
    text(label, 14, p + vec2((W - tz.x) / 2, (bh - tz.y) / 2), rgbm(1, 0.45, 0.42, 1), 'semi')
    if clicked then resetAll() end
  end

  if statusOk == false then
    gap(10)
    local wp = cur()
    local wz = measure(statusLine, 12, 'semi')
    text(statusLine, 12, wp + vec2((W - wz.x) / 2, 0), Ca(C.warn, 0.55 + 0.45 * math.sin(uiClock * 3) ^ 2), 'semi')
    ui.dummy(vec2(W, 18))
  end
  gap(16)

  if changed then markDirty() end
  unindent(M)
  popVar()
end

local uiError = nil
function windowMain(dt)
  if not uiError then
    local ok, err = pcall(windowMainPro, dt)
    if ok then return end
    uiError = tostring(err)
    ac.log('AzeMP Paint UI HATA: ' .. uiError)
    unwind()
  end
  ui.text('Interfeys xetasi (CSP log fayli):')
  ui.textWrapped(uiError)
  if ui.button('Yeniden cehd et') then uiError = nil end
end
