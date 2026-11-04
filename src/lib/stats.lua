-- lib.stats: stat screens. A stat screen is a monitor that shows what the
-- warehouse is doing as gauges, bars and charts rather than as a list:
-- the storage fill, the item total in big digits, items over time, what
-- came in and went out, the biggest stocks, the split by kind, the Parcel
-- Service, the crafter, the screens and the service itself. Each screen
-- shows the panels its config names (`show`), in that order, or all of
-- them; what does not fit goes on further pages, and a tap turns the
-- page. Monitors of any size work; wide ones (57 columns and up) get two
-- columns.
--
-- Config, in /warehouse/config (the panel's Screens page edits it):
--   stats = { { name = "Stats", monitor = "monitor_3", scale = 0.5,
--               show = { "fill", "items", "flow", "moves", "top", "kinds",
--                        "parcels", "crafter", "screens", "service" } } }
--
-- The Collector keeps the numbers the screens draw from: a point a minute
-- (items, used slots, what moved in and out, what the Parcel Service
-- moved and the crafter made so far), kept for a few hours in
-- /warehouse/data/history, and the crafter's state, asked for every few
-- seconds over its local API. The service runs one while a stat screen
-- is configured.

local util = require("lib.util")
local UI = require("lib.ui")
local category = require("lib.category")

local M = {}

M.SAMPLE = 60 -- seconds between history points
M.KEEP = 180 -- points kept (three hours)
M.SAVE_EVERY = 10 -- points between saves of the history
M.CRAFTER_EVERY = 5 -- seconds between looks at the crafter
M.REFRESH = 5 -- seconds between redraws
M.WIDE = 57 -- columns from which a screen gets two columns of panels

M.ORDER = { "fill", "items", "flow", "moves", "top", "kinds", "parcels", "crafter", "screens", "service" }
M.SHORT = { fill = "Fill", items = "Items", flow = "Flow", moves = "Moves", top = "Top", kinds = "Kinds", parcels = "Parcels", crafter = "Crafter", screens = "Screens", service = "Service" }

-- The collector ----------------------------------------------------------

local Collector = {}
Collector.__index = Collector
M.Collector = Collector

-- opts: index, root, parcel() (the hosted Parcel object, or nil), log(msg)
function Collector.new(opts)
  local self = setmetatable({}, Collector)
  self.index = opts.index
  self.root = opts.root
  self.getParcel = opts.parcel or function() return nil end
  self.log = opts.log or function() end
  self.path = fs.combine(opts.root, "data/history")
  local saved = util.readTable(self.path)
  self.points = saved and saved.points or {}
  self.inn, self.out = 0, 0 -- moved since the last point
  self.crafter = nil -- the crafter's last status
  self.crafterUp = false
  self.unsaved = 0
  return self
end

-- Every change the index reports comes through here.
function Collector:onChange(changes)
  for _, c in ipairs(changes or {}) do
    local d = tonumber(c.delta) or 0
    if d > 0 then self.inn = self.inn + d else self.out = self.out - d end
  end
end

-- What the Parcel Service has moved in all, and the crafter made in all;
-- the difference between two points is a rate.
function Collector:parcelMoved()
  local p = self.getParcel()
  if not p then return nil end
  local n = 0
  for _, s in pairs(p.stats or {}) do n = n + (s.moved or 0) end
  return n
end

function Collector:crafterMade()
  if not self.crafter then return nil end
  local n = 0
  for _, r in ipairs(self.crafter.recipes or {}) do n = n + (r.made or 0) end
  return n
end

-- Adds a point: storage now, and what moved since the last point.
function Collector:sample()
  local t = self.index.totals
  self.points[#self.points + 1] = { t = os.epoch("utc"), items = t.items, used = t.used, slots = t.slots, inn = self.inn, out = self.out, pm = self:parcelMoved(), cm = self:crafterMade() }
  self.inn, self.out = 0, 0
  while #self.points > M.KEEP do table.remove(self.points, 1) end
  self.unsaved = self.unsaved + 1
  if self.unsaved >= M.SAVE_EVERY then self:save() end
end

function Collector:save()
  self.unsaved = 0
  util.writeTable(self.path, { points = self.points })
end

-- Runs as a task of the service: a point every SAMPLE seconds, and the
-- crafter's state every CRAFTER_EVERY seconds over its local API (no
-- answer within two seconds means it is not running).
function Collector:run()
  local sampleTimer = os.startTimer(M.SAMPLE)
  local askTimer = os.startTimer(1)
  local pending, timeout, n = nil, nil, 0
  while true do
    local ev, a = os.pullEvent()
    if ev == "timer" and a == sampleTimer then
      sampleTimer = os.startTimer(M.SAMPLE)
      self:sample()
    elseif ev == "timer" and a == askTimer then
      askTimer = os.startTimer(M.CRAFTER_EVERY)
      n = n + 1
      pending = "stats-" .. n
      os.queueEvent("crafter_request", { id = pending, op = "status", args = {} })
      timeout = os.startTimer(2)
    elseif ev == "crafter_reply" and type(a) == "table" and a.id == pending then
      pending = nil
      if a.ok and type(a.result) == "table" then
        self.crafter, self.crafterUp = a.result, true
      else
        self.crafterUp = false
      end
    elseif ev == "timer" and a == timeout and pending then
      pending = nil
      self.crafterUp = false
    end
  end
end

-- Series ------------------------------------------------------------------

-- Up to `cols` values of a point field, newest last, each standing for
-- the same number of points: the last value of its points ("last", for
-- levels such as items) or their sum ("sum", for what moved). Returns the
-- values and the seconds each one covers.
function M.series(points, field, cols, how)
  local n = #points
  if n == 0 or cols < 1 then return {}, M.SAMPLE end
  local per = math.max(1, math.ceil(n / cols))
  local vals, i = {}, n
  while i >= 1 and #vals < cols do
    local from = math.max(1, i - per + 1)
    local v
    if how == "sum" then
      v = 0
      for j = from, i do v = v + (points[j][field] or 0) end
    else
      v = points[i][field] or 0
    end
    table.insert(vals, 1, v)
    i = from - 1
  end
  return vals, per * M.SAMPLE
end

-- How much a cumulative field (pm, cm) grew over the last `seconds`.
function M.grew(points, field, seconds)
  local n = #points
  if n == 0 or points[n][field] == nil then return nil end
  local last = points[n][field]
  local want = n - math.floor(seconds / M.SAMPLE)
  for i = n - 1, 1, -1 do
    if points[i][field] == nil then return last - (points[i + 1][field] or last) end
    if i <= want then return last - points[i][field] end
  end
  return last - points[1][field]
end

function M.spanText(seconds)
  if seconds < 3600 then return math.floor(seconds / 60 + 0.5) .. " min" end
  local h = seconds / 3600
  if h == math.floor(h) then return math.floor(h) .. " h" end
  return string.format("%.1f h", h)
end

-- Drawing ----------------------------------------------------------------

-- Digits (and a few letters) as 3x5 blocks, for the big numbers.
local GLYPHS = {
  ["0"] = { "111", "101", "101", "101", "111" }, ["1"] = { "010", "110", "010", "010", "111" }, ["2"] = { "111", "001", "111", "100", "111" },
  ["3"] = { "111", "001", "111", "001", "111" }, ["4"] = { "101", "101", "111", "001", "001" }, ["5"] = { "111", "100", "111", "001", "111" },
  ["6"] = { "111", "100", "111", "101", "111" }, ["7"] = { "111", "001", "001", "001", "001" }, ["8"] = { "111", "101", "111", "101", "111" },
  ["9"] = { "111", "101", "111", "001", "111" }, ["."] = { "000", "000", "000", "000", "010" }, ["k"] = { "100", "101", "110", "101", "101" },
  ["M"] = { "101", "111", "111", "101", "101" }, ["%"] = { "101", "001", "010", "100", "101" },
}

-- Draws s in big digits (3 columns by 5 rows each, a column apart) in
-- `color` at (x, y). Returns the width used.
function M.bigText(ui, x, y, s, color)
  local cx = x
  for i = 1, #s do
    local g = GLYPHS[s:sub(i, i)]
    if g then
      for r = 1, 5 do
        for c = 1, 3 do
          if g[r]:sub(c, c) == "1" then ui:text(cx + c - 1, y + r - 1, " ", colors.white, color) end
        end
      end
      cx = cx + 4
    else
      cx = cx + 2
    end
  end
  return cx - x - 1
end

-- CC's block characters: drawn in black on the column colour, 143 leaves
-- the bottom third of a cell coloured and 131 the bottom two thirds;
-- drawn in the colour on black, 131 colours the top third and 143 the
-- top two thirds.
local UP = { "\143", "\131" }
local DOWN = { "\131", "\143" }

-- A column chart in the rect: values left to right (the newest at the
-- right edge), scaled to lo..hi, one cell wide, filled from the bottom
-- (or from the top with `down`) to a third of a cell.
function M.columns(ui, x, y, w, h, values, lo, hi, color, down)
  local n = #values
  if n == 0 or h < 1 then return end
  if hi <= lo then hi = lo + 1 end
  local x0 = x + w - n
  for i, v in ipairs(values) do
    local cx = x0 + i - 1
    if cx >= x then
      local frac = util.clamp((v - lo) / (hi - lo), 0, 1)
      local thirds = math.floor(frac * h * 3 + 0.5)
      local full = math.floor(thirds / 3)
      local rest = thirds - full * 3
      for r = 1, full do
        ui:text(cx, down and (y + r - 1) or (y + h - r), " ", colors.white, color)
      end
      if rest > 0 and full < h then
        if down then
          ui:text(cx, y + full, DOWN[rest], color, colors.black)
        else
          ui:text(cx, y + h - full - 1, UP[rest], colors.black, color)
        end
      end
    end
  end
end

local function gray(ui) return ui:col("lightGray", colors.white) end
local function catColor(ui, cat) return ui:col(category.COLORS[cat] or "white", colors.white) end

-- The panels ---------------------------------------------------------------
-- Each: title(d, w), height(d, w) (rows below the title) and draw(ui, x,
-- y, w, h, d), with d from Screen:data().

local P = {}
M.PANELS = P

P.fill = {
  title = function(d)
    local st = d.stats
    local pct = st.slots > 0 and math.floor(st.used / st.slots * 100 + 0.5) or 0
    return "Storage " .. pct .. "% full"
  end,
  height = function(d) return 2 + math.min(#d.stats.inventories, 6) end,
  draw = function(ui, x, y, w, h, d)
    local st = d.stats
    local frac = st.slots > 0 and st.used / st.slots or 0
    ui:bar(x, y, w, frac, ui:col(frac > 0.9 and "red" or frac > 0.7 and "orange" or "green"), ui:col("gray"))
    ui:text(x, y + 1, util.fit(" " .. st.used .. "/" .. st.slots .. " slots, " .. st.free .. " free", w), gray(ui))
    for i, inv in ipairs(st.inventories) do
      local yy = y + 1 + i
      if yy > y + h - 1 then break end
      local f = inv.size > 0 and inv.used / inv.size or 0
      ui:text(x, yy, util.fit(" " .. util.shortName(inv.name), w - 12))
      ui:bar(x + w - 11, yy, 11, f, ui:col(f > 0.9 and "red" or "green"), ui:col("gray"))
    end
  end,
}

P.items = {
  title = function() return "Items in storage" end,
  height = function() return 6 end,
  draw = function(ui, x, y, w, h, d)
    local st = d.stats
    local s = util.fmtCount(st.items, math.max(1, math.floor((w - 1) / 4)))
    M.bigText(ui, x + 1, y, s, ui:col("lightBlue", colors.white))
    ui:text(x, y + 5, util.fit(" " .. st.types .. " kinds, " .. st.free .. " free slots", w), gray(ui))
  end,
}

local function range(vals)
  local lo, hi = math.huge, -math.huge
  for _, v in ipairs(vals) do
    lo = math.min(lo, v)
    hi = math.max(hi, v)
  end
  return lo, hi
end

P.flow = {
  title = function() return "Items over time" end,
  height = function(d, w, h) return (h or 0) >= 40 and 10 or 7 end,
  draw = function(ui, x, y, w, h, d)
    local vals, per = M.series(d.points, "items", w, "last")
    if #vals < 2 then
      ui:text(x, y, util.fit(" a point a minute: give it a while", w), gray(ui))
      return
    end
    local lo, hi = range(vals)
    local pad = math.max(1, math.floor((hi - lo) * 0.15))
    lo, hi = math.max(0, lo - pad), hi + pad
    M.columns(ui, x, y, w, h - 1, vals, lo, hi, ui:col("lightBlue", colors.white))
    ui:text(x, y + h - 1, util.fit(" " .. util.fmtCount(lo, 7) .. " to " .. util.fmtCount(hi, 7) .. " over " .. M.spanText(per * #vals), w), gray(ui))
  end,
}

P.moves = {
  title = function() return "In and out" end,
  height = function(d, w, h) return (h or 0) >= 40 and 10 or 7 end,
  draw = function(ui, x, y, w, h, d)
    local inn, per = M.series(d.points, "inn", w, "sum")
    local out = M.series(d.points, "out", w, "sum")
    if #inn < 1 then
      ui:text(x, y, util.fit(" a point a minute: give it a while", w), gray(ui))
      return
    end
    local half = math.floor((h - 1) / 2)
    local _, hiIn = range(inn)
    local _, hiOut = range(out)
    local hi = math.max(hiIn, hiOut, 1)
    local totalIn, totalOut = 0, 0
    for _, v in ipairs(inn) do totalIn = totalIn + v end
    for _, v in ipairs(out) do totalOut = totalOut + v end
    M.columns(ui, x, y, w, half, inn, 0, hi, ui:col("green", colors.white))
    M.columns(ui, x, y + half, w, h - 1 - half, out, 0, hi, ui:col("red", colors.white), true)
    ui:text(x, y + h - 1, util.fit(" in " .. util.fmtCount(totalIn, 6) .. "  out " .. util.fmtCount(totalOut, 6) .. " over " .. M.spanText(per * #inn), w), gray(ui))
  end,
}

P.top = {
  title = function() return "Top items" end,
  height = function(d) return math.max(1, math.min(8, d.stats.types)) end,
  draw = function(ui, x, y, w, h, d)
    local items = d.index:list({ sort = "count", limit = h })
    if #items == 0 then
      ui:text(x, y, " nothing stored", gray(ui))
      return
    end
    local max = math.max(1, items[1].count)
    local nameW = math.max(6, math.floor(w * 0.45))
    for i, it in ipairs(items) do
      local yy = y + i - 1
      local countS = util.fmtCount(it.count, 6)
      ui:text(x, yy, util.fit(" " .. it.displayName, nameW), catColor(ui, it.category))
      local bw = w - nameW - #countS - 1
      local filled = math.floor(bw * it.count / max + 0.5)
      if filled > 0 then ui:text(x + nameW, yy, string.rep(" ", filled), colors.white, catColor(ui, it.category)) end
      ui:text(x + w - #countS, yy, countS, gray(ui))
    end
  end,
}

local KINDS = { "block", "item", "resource", "unstackable" }

P.kinds = {
  title = function() return "By kind" end,
  height = function() return 3 end,
  draw = function(ui, x, y, w, h, d)
    local counts, total = {}, 0
    for key, it in pairs(d.index.items) do
      if it.count > 0 then
        local c = d.index:detail(key).category or "item"
        counts[c] = (counts[c] or 0) + it.count
        total = total + it.count
      end
    end
    if total == 0 then
      ui:text(x, y, " nothing stored", gray(ui))
      return
    end
    local bx, left = x, w
    local last
    for _, c in ipairs(KINDS) do
      if (counts[c] or 0) > 0 then last = c end
    end
    for _, c in ipairs(KINDS) do
      local n = counts[c] or 0
      if n > 0 then
        local seg = c == last and left or math.min(left, math.max(1, math.floor(w * n / total + 0.5)))
        ui:text(bx, y, string.rep(" ", seg), colors.white, catColor(ui, c))
        bx, left = bx + seg, left - seg
      end
    end
    local legend = {}
    for _, c in ipairs(KINDS) do
      local n = counts[c] or 0
      if n > 0 then legend[#legend + 1] = { c, category.LABELS[c] .. " " .. math.floor(n / total * 100 + 0.5) .. "%" } end
    end
    local lx, ly = x + 1, y + 1
    for _, l in ipairs(legend) do
      if lx + #l[2] > x + w and ly < y + h then
        lx, ly = x + 1, ly + 1
      end
      if ly < y + h then ui:text(lx, ly, l[2], catColor(ui, l[1])) end
      lx = lx + #l[2] + 2
    end
  end,
}

local function ago(epochMs)
  if not epochMs then return "never" end
  local s = math.floor((os.epoch("utc") - epochMs) / 1000)
  if s < 60 then return s .. "s ago" end
  if s < 3600 then return math.floor(s / 60) .. "m ago" end
  return math.floor(s / 3600) .. "h ago"
end

P.parcels = {
  title = function(d)
    local p = d.parcel
    if not p then return "Parcel Service: off" end
    return "Parcel Service: " .. #p.tasks .. (#p.tasks == 1 and " task" or " tasks")
  end,
  height = function(d) return 1 + (d.parcel and math.min(#d.parcel.tasks, 6) or 0) end,
  draw = function(ui, x, y, w, h, d)
    local p = d.parcel
    if not p then
      ui:text(x, y, " not running", gray(ui))
      return
    end
    local on, moved = 0, 0
    for _, t in ipairs(p.tasks) do
      if t.enabled ~= false then on = on + 1 end
      local s = p.stats[t.id]
      if s then moved = moved + (s.moved or 0) end
    end
    local hour = M.grew(d.points, "pm", 3600)
    ui:text(x, y, util.fit(" " .. on .. " on, moved " .. util.fmtCount(moved, 7) .. (hour and (", " .. util.fmtCount(hour, 6) .. " in 1 h") or ""), w), gray(ui))
    for i, t in ipairs(p.tasks) do
      local yy = y + i
      if yy > y + h - 1 then break end
      local s = p.stats[t.id] or {}
      local right = (t.enabled == false) and "off" or (ago(s.lastRun) .. (s.lastMoved and (" +" .. s.lastMoved) or ""))
      local col = colors.white
      if t.enabled == false then col = gray(ui) elseif (s.errors or 0) > 0 and s.lastMoved == 0 and s.lastMessage then col = ui:col("orange", colors.white) end
      ui:text(x, yy, util.fit(" " .. tostring(t.name or t.id), w - #right - 1), col)
      ui:text(x + w - #right, yy, right, col)
    end
  end,
}

local STATE_COLORS = { running = "lime", waiting = "orange", learning = "yellow", problem = "red", queued = "lightBlue", idle = "lightGray" }

P.crafter = {
  title = function(d)
    if not d.crafterUp then return "Crafter: not running" end
    local made = M.grew(d.points, "cm", 3600)
    return "Crafter: turtle " .. tostring(d.crafter.turtle.state) .. (made and (", made " .. util.fmtCount(made, 6) .. " in 1 h") or "")
  end,
  height = function(d) return 1 + (d.crafterUp and math.min(#d.crafter.recipes, 6) or 0) end,
  draw = function(ui, x, y, w, h, d)
    if not d.crafterUp then
      ui:text(x, y, " start it with 'crafter'", gray(ui))
      return
    end
    local counts = {}
    for _, r in ipairs(d.crafter.recipes) do counts[r.state] = (counts[r.state] or 0) + 1 end
    local lx = x + 1
    for _, s in ipairs({ "running", "waiting", "queued", "learning", "problem", "idle" }) do
      if counts[s] then
        local t = counts[s] .. " " .. s
        if lx + #t <= x + w then ui:text(lx, y, t, ui:col(STATE_COLORS[s], colors.white)) end
        lx = lx + #t + 2
      end
    end
    if #d.crafter.recipes == 0 then ui:text(x, y, " no recipes", gray(ui)) end
    for i, r in ipairs(d.crafter.recipes) do
      local yy = y + i
      if yy > y + h - 1 then break end
      local stateW = math.min(#r.text, math.floor(w / 2))
      ui:text(x, yy, util.fit(" " .. r.name, w - stateW - 1), colors.white)
      ui:text(x + w - stateW, yy, r.text:sub(1, stateW), ui:col(STATE_COLORS[r.state] or "white", colors.white))
    end
  end,
}

P.screens = {
  title = function(d) return "Screens" end,
  height = function(d) return math.max(1, #(d.cfg.access or {})) end,
  draw = function(ui, x, y, w, h, d)
    local list = d.cfg.access or {}
    if #list == 0 then
      ui:text(x, y, " none", gray(ui))
      return
    end
    for i, ap in ipairs(list) do
      local yy = y + i - 1
      if yy > y + h - 1 then break end
      local live = d.access[i]
      local state = live and (live.ok and (live:isLocked() and "up, locked" or "up") or "DOWN") or "-"
      ui:text(x, yy, util.fit(" " .. tostring(ap.name or ap.monitor), w - #state - 1), live and live.ok and colors.white or ui:col("red"))
      ui:text(x + w - #state, yy, state, live and live.ok and ui:col("lime") or ui:col("red"))
    end
  end,
}

local function uptime(seconds)
  seconds = math.floor(seconds or 0)
  if seconds < 90 then return seconds .. " s" end
  local m = math.floor(seconds / 60)
  if m < 120 then return m .. " min" end
  return math.floor(m / 60) .. " h " .. (m % 60) .. " min"
end

P.service = {
  title = function() return "Service" end,
  height = function() return 2 end,
  draw = function(ui, x, y, w, h, d)
    local cfg = d.cfg
    ui:text(x, y, util.fit(" up " .. uptime(os.clock() - d.started) .. ", rednet " .. (cfg.rednet ~= false and "on" or "off") .. ", " .. tostring(cfg.hostname), w), gray(ui))
    ui:text(x, y + 1, util.fit(" v" .. tostring(d.version) .. ", log " .. tostring(cfg.logLevel or "info") .. ", " .. #d.points .. " points kept", w), gray(ui))
  end,
}

-- The screen --------------------------------------------------------------

local Screen = {}
Screen.__index = Screen
M.Screen = Screen

-- cfg: { name, monitor, scale?, show? }
function Screen.new(service, cfg, collector)
  local self = setmetatable({}, Screen)
  self.service = service
  self.cfg = cfg
  self.collector = collector
  self.name = cfg.name or cfg.monitor
  self.page = 1
  self.ok = false
  self.stopped = false
  self.drawnAt = -1000
  return self
end

function Screen:attach()
  local mon = peripheral.wrap(self.cfg.monitor)
  if not mon or not mon.setTextScale then return false, "monitor " .. tostring(self.cfg.monitor) .. " not found" end
  local scale = tonumber(self.cfg.scale)
  if not scale then
    mon.setTextScale(1)
    local w, h = mon.getSize()
    scale = (w < 28 or h < 18) and 0.5 or 1
  end
  mon.setTextScale(scale)
  self.mon = mon
  self.ui = UI.new(mon)
  self.ok = true
  return true
end

-- The panels this screen shows, in order.
function Screen:panelNames()
  local show = self.cfg.show
  local out = {}
  if type(show) == "table" then
    for _, n in ipairs(show) do
      if P[n] then out[#out + 1] = n end
    end
  end
  if #out == 0 then return M.ORDER end
  return out
end

function Screen:data()
  local s = self.service
  return {
    stats = s.index:stats(), index = s.index, points = self.collector.points, collector = self.collector,
    parcel = self.collector.getParcel(), crafter = self.collector.crafter, crafterUp = self.collector.crafterUp,
    access = s.access or {}, cfg = s.cfg, started = s.started or 0, version = s.version,
  }
end

-- Where each panel goes: top to bottom, column by column, page by page;
-- a panel that does not fit in the rows left starts the next column.
function Screen:layout(d, h)
  local w = self.ui.w
  local cols = w >= M.WIDE and 2 or 1
  local colW = cols == 2 and math.floor((w - 1) / 2) or w
  local pages = { {} }
  local page, col, y = pages[1], 1, 1
  for _, name in ipairs(self:panelNames()) do
    local ph = math.min(1 + P[name].height(d, colW, h), h)
    if y + ph - 1 > h then
      col, y = col + 1, 1
      if col > cols then
        col, page = 1, {}
        pages[#pages + 1] = page
      end
    end
    page[#page + 1] = { name = name, x = (col - 1) * (colW + 1) + 1, y = y, w = colW, h = ph }
    y = y + ph + 1
  end
  return pages
end

function Screen:draw()
  if not self.ok then return end
  local ui = self.ui
  local ok, err = pcall(function()
    ui:begin(colors.black)
    local d = self:data()
    local h = ui.h
    local pages = self:layout(d, h)
    if #pages > 1 then pages = self:layout(d, h - 1) end
    if self.page > #pages then self.page = 1 end
    for _, pl in ipairs(pages[self.page]) do
      local p = P[pl.name]
      ui:text(pl.x, pl.y, util.fit(" " .. p.title(d, pl.w), pl.w), colors.white, ui:col("gray", colors.black))
      if pl.h > 1 then p.draw(ui, pl.x, pl.y + 1, pl.w, pl.h - 1, d) end
    end
    if #pages > 1 then
      local pageS = self.page .. "/" .. #pages .. " "
      ui:text(1, h, util.fit(" tap for more", ui.w - #pageS), gray(ui), ui:col("gray", colors.black))
      ui:text(ui.w - #pageS + 1, h, pageS, colors.white, ui:col("gray", colors.black))
    end
    ui:finish()
  end)
  self.drawnAt = os.clock()
  if not ok then
    self.ok = false
    self.failed = true
    self.service.log.warn("stat screen " .. self.name .. ": " .. tostring(err))
  end
end

function Screen:screenLines()
  if not self.ok then return nil end
  return self.ui:lines()
end

-- New settings: another monitor or scale makes the loop attach again.
-- Returns true when anything changed.
function Screen:reconfigure(cfg)
  local old = self.cfg
  self.cfg = cfg
  self.name = cfg.name or cfg.monitor
  local changed = textutils.serialise(cfg) ~= textutils.serialise(old)
  if cfg.monitor ~= old.monitor or tonumber(cfg.scale) ~= tonumber(old.scale) then
    if self.mon then pcall(self.mon.clear) end
    self.mon, self.ui = nil, nil
    self.ok = false
  end
  self.page = 1
  os.queueEvent("warehouse_reload")
  return changed
end

function Screen:stop()
  self.stopped = true
  self.ok = false
  if self.mon then
    pcall(self.mon.setBackgroundColor, colors.black)
    pcall(self.mon.clear)
  end
end

function Screen:run()
  while not self.stopped do
    if self.failed then
      self.failed = false
      sleep(2)
    end
    local ok, err = self:attach()
    if ok then
      self:loop()
    else
      self.service.log.warn("stat screen " .. self.name .. ": " .. tostring(err) .. "; retrying in 5 s")
      sleep(5)
    end
  end
end

-- Redraws every REFRESH seconds and, at most once a second, when storage
-- changed; a tap turns the page.
function Screen:loop()
  self:draw()
  local timer = os.startTimer(M.REFRESH)
  while self.ok and not self.stopped do
    local ev = { os.pullEvent() }
    local e = ev[1]
    if e == "monitor_touch" and ev[2] == self.cfg.monitor then
      self.page = self.page + 1
      self:draw()
    elseif e == "monitor_resize" and ev[2] == self.cfg.monitor then
      self.ui:resize()
      self:draw()
    elseif e == "timer" and ev[2] == timer then
      timer = os.startTimer(M.REFRESH)
      self:draw()
    elseif e == "warehouse_event" and os.clock() - self.drawnAt >= 1 then
      self:draw()
    elseif (e == "peripheral_detach" or e == "peripheral") and ev[2] == self.cfg.monitor then
      self.ok = false
    end
  end
end

return M
