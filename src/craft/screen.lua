-- craft.screen: the crafter's dashboard on a monitor. The recipes and
-- what each is doing fill the screen; tap one and a panel at the bottom
-- shows its stats with Run, Order (a number pad), Always and Stop.
--
-- It never takes a monitor that is one of the warehouse's access points:
-- the one named in the crafter's setup is refused if it is, and when none
-- is named it uses the first monitor that is not.

local util = require("lib.util")
local UI = require("lib.ui")

local Screen = {}
Screen.__index = Screen

local REFRESH = 2 -- seconds between redraws (times tick)
local MSG_TIME = 6
local ACCESS_EVERY = 30 -- seconds between looks at which monitors the access points use

local STATE_COLORS = { running = "lime", waiting = "orange", learning = "yellow", problem = "red", queued = "lightBlue", idle = "lightGray" }

-- opts: engine, vault, cfg, log(msg)
function Screen.new(opts)
  local self = setmetatable({}, Screen)
  self.engine = opts.engine
  self.vault = opts.vault
  self.cfg = opts.cfg
  self.log = opts.log or function() end
  self.ok = false
  self.selected = nil
  self.dialog = nil
  self.amount = ""
  self.message, self.messageError, self.messageUntil = nil, false, 0
  self.accessMonitors = {}
  self.accessAt = -1000
  self.scroll = 0
  return self
end

function Screen:say(msg, isError)
  self.message, self.messageError, self.messageUntil = msg, isError or false, os.clock() + MSG_TIME
end

-- The monitors the warehouse's access points draw on (asked for now and then).
function Screen:refreshAccess()
  if os.clock() - self.accessAt < ACCESS_EVERY then return end
  self.accessAt = os.clock()
  local ok, cfg = pcall(self.vault.config)
  if ok and type(cfg) == "table" then
    local used = {}
    for _, ap in ipairs(cfg.access or {}) do
      if ap.monitor then used[ap.monitor] = ap.name or ap.monitor end
    end
    self.accessMonitors = used
  end
end

-- Which monitor to draw on: the configured one unless an access point
-- has it, else the first free monitor. Returns the name, or nil and why.
function Screen:pickMonitor()
  self:refreshAccess()
  local want = self.cfg.monitor
  if want and want ~= "" then
    if self.accessMonitors[want] then return nil, "monitor " .. want .. " is the " .. self.accessMonitors[want] .. " access screen; pick another" end
    if not peripheral.isPresent(want) or not peripheral.hasType(want, "monitor") then return nil, "monitor " .. want .. " not found" end
    return want
  end
  local names = peripheral.getNames()
  table.sort(names)
  for _, name in ipairs(names) do
    if peripheral.hasType(name, "monitor") and not self.accessMonitors[name] then return name end
  end
  return nil, "no monitor free (the access points use the ones there are)"
end

function Screen:attach()
  local name, err = self:pickMonitor()
  if not name then return false, err end
  local mon = peripheral.wrap(name)
  local scale = tonumber(self.cfg.scale)
  if not scale then
    mon.setTextScale(1)
    local w, h = mon.getSize()
    scale = (w < 28 or h < 18) and 0.5 or 1
  end
  mon.setTextScale(scale)
  self.monitor = name
  self.mon = mon
  self.ui = UI.new(mon)
  self.ok = true
  return true
end

function Screen:stateColor(s)
  return self.ui:col(STATE_COLORS[s.state] or "white", colors.white)
end

local function ago(epochMs)
  if not epochMs then return "never" end
  local s = math.floor((os.epoch("utc") - epochMs) / 1000)
  if s < 60 then return s .. "s ago" end
  if s < 3600 then return math.floor(s / 60) .. "m ago" end
  return math.floor(s / 3600) .. "h ago"
end

function Screen:draw()
  if not self.ok then return end
  local ui = self.ui
  local ok, err = pcall(function()
    ui:begin(colors.black)
    self:drawAll()
    ui:finish()
  end)
  if not ok then
    self.ok = false
    self.failed = true
    self.log("dashboard: " .. tostring(err))
  end
end

function Screen:drawHeader(w)
  local ui = self.ui
  local bg = ui:col("gray", colors.black)
  if self.message and os.clock() < self.messageUntil then
    ui:text(1, 1, util.fit(" " .. self.message, w), self.messageError and ui:col("red") or ui:col("lime"), bg)
    return
  end
  local st = self.status
  local t = st.turtle
  local turtle
  if t.state == "ready" then turtle = "turtle ok" elseif t.state == "away" then turtle = "turtle away" else turtle = "turtle ?" end
  local s = " Crafter  " .. turtle
  if st.smelter.set then s = s .. "  smelter" end
  ui:text(1, 1, util.fit(s, w), t.state == "ready" and colors.white or ui:col("orange"), bg)
end

-- The bottom panel for the selected recipe: its stats and the buttons, or
-- the number pad while ordering. Returns how many rows it takes.
function Screen:panelHeight(h)
  if not self.selected then return 0 end
  if self.dialog then return math.min(h - 3, 7) end
  return math.min(h - 3, 6)
end

function Screen:drawPanel(x, y, w, h, s)
  local ui = self.ui
  local gray = ui:col("gray", colors.black)
  ui:fill(x, y, w, h, colors.black)
  ui:text(x, y, util.fit(" " .. s.name, w - 3), colors.white, gray)
  ui:button(x + w - 3, y, "x", function()
    self.selected, self.dialog = nil, nil
  end, { w = 3, bg = ui:col("red", colors.black) })
  if self.dialog then
    local what = self.dialog == "order" and ("Order " .. (s.result or "items")) or "Run how many times?"
    ui:text(x, y + 1, util.fit(" " .. what, w), ui:col("lightGray", colors.white))
    ui:text(x, y + 2, " Amount: ")
    ui:text(x + 9, y + 2, util.fit(self.amount == "" and "_" or self.amount, w - 9), colors.white, ui:col("blue", colors.black))
    local keyW = w >= 30 and 4 or 3
    local padW = ui:numpad(x + 1, y + 3, function(k)
      if k == "clear" then
        self.amount = ""
      elseif k == "back" then
        self.amount = self.amount:sub(1, -2)
      elseif #self.amount < 6 then
        self.amount = (self.amount == "0" and "" or self.amount) .. k
      end
    end, { keyW = keyW, keyH = 1 })
    local bx = x + 1 + padW + 1
    local bw = math.max(4, w - padW - 3)
    ui:button(bx, y + 3, "OK", function() self:confirmDialog(s) end, { w = bw, bg = ui:col("green", colors.black) })
    ui:button(bx, y + 4, "Cancel", function() self.dialog = nil end, { w = bw, bg = ui:col("red", colors.black) })
    return
  end
  local col = self:stateColor(s)
  ui:text(x, y + 1, util.fit(" " .. s.text, w), col)
  ui:text(x, y + 2, util.fit(" makes " .. (s.result or "?"), w), ui:col("lightGray", colors.white))
  ui:text(x, y + 3, util.fit(string.format(" made %s  runs %d  err %d", util.fmtCount(s.made, 7), s.runs, s.errors), w), ui:col("lightGray", colors.white))
  local mode = s.mode == "rate" and string.format("rate %d/%ds", s.rateCount or 1, s.rateSeconds or 600) or s.mode
  ui:text(x, y + 4, util.fit(" " .. mode .. "  last " .. ago(s.lastRun) .. (s.pending > 0 and ("  +" .. s.pending) or ""), w), ui:col("lightGray", colors.white))
  local labels = { "Run", "Order", s.mode == "always" and "Always:on" or "Always", "Stop" }
  local bw = math.floor((w - 3) / 4)
  local bx = x
  local fns = {
    function()
      self.dialog, self.amount = "run", tostring(s.count or 1)
    end,
    function()
      self.dialog, self.amount = "order", ""
    end,
    function()
      local ok, err = pcall(self.engine.setMode, self.engine, s.id, s.mode == "always" and "off" or "always")
      if ok then self:say(s.name .. (s.mode == "always" and ": always off" or ": always on")) else self:say(tostring(err), true) end
    end,
    function()
      local ok, err = pcall(self.engine.stop, self.engine, s.id)
      if ok then self:say(s.name .. " stopped") else self:say(tostring(err), true) end
    end,
  }
  local bgs = { "green", "cyan", s.mode == "always" and "blue" or "gray", "red" }
  for i, label in ipairs(labels) do
    ui:button(bx, y + 5, label, fns[i], { w = bw, bg = ui:col(bgs[i], colors.black) })
    bx = bx + bw + 1
  end
end

function Screen:confirmDialog(s)
  local n = math.floor(tonumber(self.amount) or 0)
  if n < 1 then
    self:say("Pick an amount first", true)
    return
  end
  local ok, err
  if self.dialog == "order" then
    ok, err = pcall(self.engine.order, self.engine, s.id, n)
    if ok then self:say("Ordered " .. n .. " " .. (s.result or "")) end
  else
    ok, err = pcall(self.engine.runTimes, self.engine, s.id, n)
    if ok then self:say("Running " .. s.name .. " " .. n .. "x") end
  end
  if not ok then self:say(tostring(err), true) end
  self.dialog = nil
end

function Screen:drawAll()
  local ui = self.ui
  local w, h = ui.w, ui.h
  self.status = self.engine:status()
  self:drawHeader(w)
  local list = self.status.recipes
  local selected
  for _, s in ipairs(list) do
    if s.id == self.selected then selected = s end
  end
  if self.selected and not selected then
    self.selected, self.dialog = nil, nil
  end
  local panelH = selected and self:panelHeight(h) or 0
  local rows = h - 1 - panelH
  if #list == 0 then
    ui:text(1, 2, util.fit(" No recipes yet. Lay one out", w), ui:col("lightGray", colors.white))
    ui:text(1, 3, util.fit(" in the recipe chest and", w), ui:col("lightGray", colors.white))
    ui:text(1, 4, util.fit(" scan it on the computer.", w), ui:col("lightGray", colors.white))
  end
  local pages = math.max(1, math.ceil(#list / math.max(1, rows - (#list > rows and 1 or 0))))
  local perPage = rows
  if #list > rows then perPage = rows - 1 end
  perPage = math.max(1, perPage)
  self.scroll = util.clamp(self.scroll, 0, math.max(0, pages - 1))
  local first = self.scroll * perPage
  for i = 1, perPage do
    local s = list[first + i]
    if not s then break end
    local y = 1 + i
    local isSel = s.id == self.selected
    local stateW = math.min(#s.text, math.floor(w / 2))
    local name = util.fit(s.name, w - stateW - 2)
    ui:text(1, y, " " .. name, isSel and colors.black or colors.white, isSel and ui:col("lightGray", colors.black) or colors.black)
    ui:text(w - stateW + 1, y, s.text:sub(1, stateW), isSel and colors.black or self:stateColor(s), isSel and ui:col("lightGray", colors.black) or colors.black)
    ui:region(1, y, w, y, function()
      if self.selected == s.id then
        self.selected, self.dialog = nil, nil
      else
        self.selected, self.dialog = s.id, nil
      end
    end)
  end
  if #list > rows then
    local y = 1 + perPage + 1
    local bx = ui:button(1, y, "<", function() self.scroll = self.scroll - 1 end, { w = 3 })
    ui:text(bx + 1, y, (self.scroll + 1) .. "/" .. pages)
    ui:button(bx + 1 + #((self.scroll + 1) .. "/" .. pages) + 1, y, ">", function() self.scroll = self.scroll + 1 end, { w = 3 })
  end
  if selected then self:drawPanel(1, h - panelH + 1, w, panelH, selected) end
end

function Screen:screenLines()
  if not self.ok then return nil end
  return self.ui:lines()
end

-- New settings: another monitor or scale makes the loop attach again.
function Screen:reconfigure(cfg)
  local old = self.cfg
  self.cfg = cfg
  if cfg.monitor ~= old.monitor or tonumber(cfg.scale) ~= tonumber(old.scale) then
    if self.mon then pcall(self.mon.clear) end
    self.ok = false
    self.accessAt = -1000
  end
end

function Screen:run()
  while true do
    if self.failed then
      self.failed = false
      sleep(2)
    end
    local ok, err = self:attach()
    if ok then
      self.log("dashboard on " .. self.monitor)
      self:loop()
    else
      if err ~= self.lastErr then
        self.log("dashboard: " .. tostring(err) .. "; trying again in 10 s")
        self.lastErr = err
      end
      sleep(10)
    end
  end
end

function Screen:loop()
  self:draw()
  local timer = os.startTimer(REFRESH)
  local due = os.clock() + REFRESH
  while self.ok do
    local ev = { os.pullEvent() }
    local e = ev[1]
    if e == "monitor_touch" and ev[2] == self.monitor then
      self.ui:tap(ev[3], ev[4])
      self:draw()
    elseif e == "monitor_resize" and ev[2] == self.monitor then
      self.ui:resize()
      self:draw()
    elseif e == "crafter_changed" or e == "crafter_touch" then
      if e == "crafter_touch" and ev[2] == self.monitor then self.ui:tap(ev[3], ev[4]) end
      self:draw()
    elseif e == "timer" and (ev[2] == timer or os.clock() >= due) then
      timer = os.startTimer(REFRESH)
      due = os.clock() + REFRESH
      if self.message and os.clock() > self.messageUntil then self.message = nil end
      self:draw()
    elseif e == "peripheral_detach" and ev[2] == self.monitor then
      self.ok = false
    end
  end
end

return Screen
