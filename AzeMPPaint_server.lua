ac.log('AzeMP Paint: server-side yuklenir v5.0')

-- ============================================================
-- AzeMP Paint SERVER-SIDE
-- PlateText_server.lua ile ayni calisma modeli:
-- csp_extra_options.ini bu dosyanin URL'sini yukler.
-- Her oyuncunun renk secimi OnlineEvent ile diger istemcilere aktarilir.
-- Her istemci yalnizca kendi gordugu arac mesh'lerini lokal olarak boyar.
-- ============================================================

local CAR_LOCAL = 0
local TEX_SLOT = 'txDiffuse'
local LOGO = './logo.png' -- Optional; falls back to the text logo if unavailable.
local TOGGLE_KEY = ui.KeyIndex.N
local CFG = {
  paintMatch = { 'carpaint', 'car_paint' },
  applyInterval = 0.12,
  initDelay = 1.0,
  resendEvery = 10.0,
  retryInterval = 2.0,
  fontFamily = 'SF Pro Display',
  fontFolder = './fonts',
}

local PROPS = { 'ksSpecular', 'fresnelMaxLevel', 'ksSpecularEXP', 'ksDiffuse' }

local function computeProps(orig, metal, gloss)
  local r = {}
  r.ksSpecular = 0.15 + metal * 1.05
  r.fresnelMaxLevel = 0.25 + metal * 0.75
  r.ksSpecularEXP = 6 + gloss * 294
  if orig.ksDiffuse then r.ksDiffuse = orig.ksDiffuse * (1 - 0.30 * metal) end
  return r
end

local PRESETS = {
  'F4F4F2', 'C0C4CA', '7A7F87', '33363B', '0C0C0E', '7A1020', 'C1121F', 'E4572E',
  'F2B705', 'E9D8A6', '2D6A4F', '52B788', '0B3C5D', '1D6FA5', '3FA7D6', '00A6A6',
  '5E2B97', '9333EA', 'D946EF', 'FF4DA6', '8B5A2B', 'B87333', 'FF6B00', 'A3E635',
}

local function clamp(x, a, b)
  if x < a then return a elseif x > b then return b end
  return x
end

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
  return string.format('%02X%02X%02X',
    math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

local function hsvToHex(h, s, v)
  return toHex(hsv2rgb(h, s, v))
end

-- Oyuncu basina ayri state ve ayri material cache.
local sMain = ac.storage('azemppaint_server_main', '0.7500,0.8000,0.7000,0.400,0.600,1.000,0')
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
  sMain:set(string.format('%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%d',
    H, S, V, metallic, gloss, strength, active and 1 or 0))
end

local function currentState()
  return {
    H = clamp(H, 0, 0.9999), S = clamp(S, 0, 1), V = clamp(V, 0, 1),
    metallic = clamp(metallic, 0, 1), gloss = clamp(gloss, 0, 1),
    strength = clamp(strength, 0, 1), active = active and true or false
  }
end

local function encodeState(st)
  return string.format('%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%d',
    st.H, st.S, st.V, st.metallic, st.gloss, st.strength, st.active and 1 or 0)
end

local function decodeState(payload)
  local vals = {}
  for n in tostring(payload or ''):gmatch('[^,]+') do
    vals[#vals + 1] = tonumber(n)
  end
  if #vals ~= 7 then return nil end
  for i = 1, 7 do if vals[i] == nil then return nil end end
  return {
    H = clamp(vals[1], 0, 0.9999), S = clamp(vals[2], 0, 1), V = clamp(vals[3], 0, 1),
    metallic = clamp(vals[4], 0, 1), gloss = clamp(vals[5], 0, 1),
    strength = clamp(vals[6], 0, 1), active = vals[7] == 1
  }
end

local playerStates = {}
local targetsByCar = {}
local handlesByCar = {}
local appliedByCar = {}
local scanStatus = {}
local statusLine = 'Hazırlanır…'
local statusOk = nil
local dirty = false
local clock = 0
local lastApply = -100
local lastSend = -100
local initialized = false
local updateError = false

local function scanCar(carIndex)
  local targets = {}
  local ok, err = pcall(function()
    local root = ac.findNodes('carRoot:' .. tostring(carIndex))
    if not root then return end
    local all = root:findMeshes('?')
    if not all then return end
    local seen = {}
    for i = 1, all:size() do
      local name = all:materialName(i)
      if name and name ~= '' and not seen[name] then
        seen[name] = true
        local low = name:lower()
        for _, kw in ipairs(CFG.paintMatch) do
          if low:find(kw, 1, true) then
            targets[#targets + 1] = name
            break
          end
        end
      end
    end
  end)
  if not ok then
    scanStatus[carIndex] = 'Skan xətası: ' .. tostring(err)
    ac.log('AzeMP Paint SCAN [' .. tostring(carIndex) .. ']: ' .. tostring(err))
  else
    scanStatus[carIndex] = #targets > 0 and ('CarPaint: ' .. #targets) or 'CarPaint tapılmadı'
  end
  targetsByCar[carIndex] = targets
  handlesByCar[carIndex] = handlesByCar[carIndex] or {}
  if carIndex == CAR_LOCAL then
    statusOk = #targets == 0 and false or true
    statusLine = #targets > 0 and ('CarPaint tapıldı (' .. #targets .. ')') or 'CarPaint materialı tapılmadı'
  end
  return #targets > 0
end

local function getHandle(carIndex, name)
  handlesByCar[carIndex] = handlesByCar[carIndex] or {}
  local cache = handlesByCar[carIndex]
  if cache[name] then return cache[name] end

  local root = ac.findNodes('carRoot:' .. tostring(carIndex))
  if not root then return nil end
  local m = root:findMeshes('material:' .. name)
  if not m or m:size() == 0 then return nil end
  pcall(function() m:ensureUniqueMaterials() end)

  local h = { meshes = m, orig = {}, status = '' }
  for _, prop in ipairs(PROPS) do
    pcall(function()
      if m:getMaterialPropertyIndex(prop) then
        local value = m:getMaterialPropertyValue(prop)
        if type(value) == 'number' then h.orig[prop] = value end
      end
    end)
  end
  pcall(function() h.origTex = m:getTextureSlotFilename(TEX_SLOT) end)
  pcall(function()
    local details = m:getTextureSlotDetails(TEX_SLOT)
    if details and details.size then h.size = details.size end
  end)
  h.size = h.size or vec2(1024, 1024)
  cache[name] = h
  return h
end

local function resetCar(carIndex)
  local cache = handlesByCar[carIndex] or {}
  for _, h in pairs(cache) do
    local m = h.meshes
    for prop, value in pairs(h.orig) do
      pcall(function() m:setMaterialProperty(prop, value) end)
    end
    if h.origTex and h.origTex ~= '' then
      pcall(function() m:setMaterialTexture(TEX_SLOT, h.origTex) end)
    end
    h.status = ''
  end
  appliedByCar[carIndex] = 'reset'
end

local function applyHandle(carIndex, name, st)
  local h = getHandle(carIndex, name)
  if not h then return false end
  local m = h.meshes
  local r, g, b = hsv2rgb(st.H, st.S, st.V)

  local okT, errT = pcall(function()
    if st.strength >= 0.995 then
      m:setMaterialTexture(TEX_SLOT, {
        textureSize = h.size,
        background = rgbm(r, g, b, 1),
        callback = function() end
      })
    else
      local size, orig = h.size, h.origTex
      m:setMaterialTexture(TEX_SLOT, {
        textureSize = size,
        callback = function()
          if orig and orig ~= '' then
            pcall(function() display.image{ image = orig, pos = vec2(0, 0), size = size } end)
          end
          display.rect{ pos = vec2(0, 0), size = size, color = rgbm(r, g, b, st.strength) }
        end
      })
    end
  end)

  local props = computeProps(h.orig, st.metallic, st.gloss)
  for _, prop in ipairs(PROPS) do
    if h.orig[prop] ~= nil and props[prop] ~= nil then
      pcall(function() m:setMaterialProperty(prop, props[prop]) end)
    end
  end
  h.status = okT and 'ok' or ('texture error: ' .. tostring(errT))
  return okT
end

local function applyCar(carIndex, st)
  if not st then return end
  if not st.active then
    resetCar(carIndex)
    return
  end
  if not targetsByCar[carIndex] or #targetsByCar[carIndex] == 0 then scanCar(carIndex) end
  local targets = targetsByCar[carIndex] or {}
  local count = 0
  for _, name in ipairs(targets) do
    local ok, result = pcall(applyHandle, carIndex, name, st)
    if ok and result then count = count + 1 end
  end
  appliedByCar[carIndex] = (#targets > 0) and encodeState(st) or nil
  if carIndex == CAR_LOCAL then
    statusLine = 'Tətbiq olundu · ' .. count .. ' material'
    statusOk = #targets > 0
  end
end

-- OnlineEvent: payload kiçik string kimi gonderilir, butun HSV/material parametrləri daxildir.
local paintEvent = ac.OnlineEvent({
  paint = ac.StructItem.string(96)
}, function(sender, data)
  if sender == nil or sender.index == nil then return end
  local st = decodeState(data.paint)
  if not st then return end
  local carIndex = sender.index
  playerStates[carIndex] = st
  appliedByCar[carIndex] = nil
  if st.active then
    applyCar(carIndex, st)
  else
    resetCar(carIndex)
  end
end)

local function broadcastMyState()
  pcall(function() paintEvent({ paint = encodeState(currentState()) }) end)
  lastSend = clock
end

local function markDirty()
  active = true
  dirty = true
end

local function resetAll()
  active = false
  dirty = true
  resetCar(CAR_LOCAL)
  saveMain()
  statusLine = 'Orijinal rəng bərpa olundu'
  statusOk = true
end

local function updateBody(dt)
  clock = clock + dt
  if not initialized and clock > CFG.initDelay then
    initialized = true
    scanCar(CAR_LOCAL)
    if active then dirty = true end
  end

  if dirty and clock - lastApply >= CFG.applyInterval then
    dirty = false
    lastApply = clock
    local st = currentState()
    playerStates[CAR_LOCAL] = st
    applyCar(CAR_LOCAL, st)
    saveMain()
    broadcastMyState()
  end

  if clock - lastSend >= CFG.resendEvery then
    broadcastMyState()
  end

  -- Uzaq avtomobillərin mesh/material-ları gec yuklenirse yeniden yoxla.
  if not updateBody.retry then updateBody.retry = 0 end
  updateBody.retry = updateBody.retry + dt
  if updateBody.retry >= CFG.retryInterval then
    updateBody.retry = 0
    for carIndex, st in pairs(playerStates) do
      if carIndex ~= CAR_LOCAL and st.active then
        local encoded = encodeState(st)
        if appliedByCar[carIndex] ~= encoded then applyCar(carIndex, st) end
      end
    end
    if active and appliedByCar[CAR_LOCAL] ~= encodeState(currentState()) then
      applyCar(CAR_LOCAL, currentState())
    end
  end
end

function script.update(dt)
  local ok, err = pcall(updateBody, dt)
  if not ok and not updateError then
    updateError = true
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

-- ====================== SERVER-SIDE UI WINDOW ======================
local WINDOW_SIZE = vec2(420, 690)
local windowOpen = false
local toggleBtn = nil

pcall(function()
  toggleBtn = ac.ControlButton('__AZEMP_PAINT_TOGGLE', { keyboard = { key = TOGGLE_KEY } })
end)

local function togglePressed()
  if toggleBtn then
    local ok, result = pcall(function() return toggleBtn:pressed() end)
    if ok then return result end
  end
  local ok, result = pcall(ui.keyboardButtonPressed, TOGGLE_KEY, false)
  return ok and result
end

function script.drawUI(dt)
  if togglePressed() then windowOpen = not windowOpen end
  if windowOpen and ui.keyboardButtonPressed(ui.KeyIndex.Escape, false) then
    windowOpen = false
  end
  if not windowOpen then return end

  local scr = ui.windowSize()
  local pos = vec2((scr.x - WINDOW_SIZE.x) / 2, (scr.y - WINDOW_SIZE.y) / 2)
  ui.transparentWindow('AzeMPPaintWindow', pos, WINDOW_SIZE, true, true, function()
    windowMain(dt)
  end)
end
