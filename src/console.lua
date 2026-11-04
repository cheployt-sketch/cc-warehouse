-- console: the control panel on the warehouse computer's own screen.
--
-- Pages: Status (what is stored, screens, network, and buttons to reload,
-- compact, rescan or stop), Screens (add, change, remove access points),
-- Storage (what counts as storage, with a button per inventory), Parcels
-- (the Parcel tasks, in folders), Settings (presets, lock time, rescan,
-- hostname, rednet, log level, category overrides, the pairing key) and
-- Log. The chest and monitor pickers say what each one is used for (a
-- screen, a Parcel task, the crafter) and list the free ones first. Everything is clicked; text fields
-- take typing, Tab moves on, Esc backs out.
--
-- Changes are written to the config file and applied to the running
-- service at once. The service shows this panel in its own tab; `warehouse
-- ui` opens it in any tab.

local util = require("lib.util")
local config = require("lib.config")
local category = require("lib.category")
local UI = require("lib.ui")
local Uses = require("lib.uses")
local Folders = require("lib.folders")
local Stats = require("lib.stats")
local Parcel = require("parcel")

local Console = {}
Console.__index = Console

local PAGES = { { "status", "Status" }, { "screens", "Screens" }, { "storage", "Storage" }, { "parcels", "Parcels" }, { "settings", "Settings" }, { "log", "Log" } }
local KINDS = { "deposit", "withdraw" }
local ONOFF = { "on", "off" }
local REFRESH = 2
local MSG_TIME = 8
local CATS = { "block", "item", "resource", "unstackable" }
local LEVELS = { "debug", "info", "warn", "error" }

local function setOf(list)
  local s = {}
  for _, v in ipairs(list or {}) do s[v] = true end
  return s
end

local function join(list)
  local out = {}
  for _, v in ipairs(list or {}) do out[#out + 1] = tostring(v) end
  return table.concat(out, ",")
end

local function numbers(text)
  local out = {}
  for s in tostring(text):gmatch("[^,%s]+") do
    local n = tonumber(s)
    if n then out[#out + 1] = n end
  end
  return out
end

local function words(text)
  local out = {}
  for s in tostring(text):gmatch("[^,%s]+") do out[#out + 1] = s end
  return out
end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function uptime(seconds)
  seconds = math.floor(seconds or 0)
  if seconds < 90 then return seconds .. " s" end
  local m = math.floor(seconds / 60)
  if m < 120 then return m .. " min" end
  return math.floor(m / 60) .. " h " .. (m % 60) .. " min"
end

-- opts: vault (the client library, connected locally), root (the warehouse
-- folder), target (a terminal; default the current one), standalone (shows
-- a Quit button and returns when it is clicked).
function Console.new(opts)
  local self = setmetatable({}, Console)
  self.vault = opts.vault
  self.root = opts.root
  self.target = opts.target or term.current()
  self.standalone = opts.standalone
  self.ui = UI.new(self.target)
  self.page = "status"
  self.form = nil
  self.picker = nil
  self.message, self.messageError, self.messageUntil = nil, false, 0
  self.hint = ""
  self.data = {}
  self.storageOffset = 0
  self.parcelOffset = 0
  self.parcelFolder = nil -- the open folder on the Parcels page
  self.logOffset = 0
  self.running = true
  return self
end

function Console:say(msg, isError)
  self.message = msg
  self.messageError = isError or false
  self.messageUntil = os.clock() + MSG_TIME
end

-- Asks the service; nil (and a reason) when it does not answer.
function Console:ask(op, args)
  if not self.vault then return nil, "no connection to the service" end
  local ok, res = self.vault.try(op, args or {})
  if ok then return res end
  return nil, res
end

-- The inventories on the network, with sizes. Asked for only where they
-- are shown (the Storage page, pickers, Fill), since every size is a
-- peripheral call.
function Console:refreshPeripherals()
  local list = self:ask("peripherals")
  if not list then list = config.peripherals(self.data.cfg or config.defaultsFor(self.root)) end
  self.data.peripherals = list
  return list
end

function Console:refresh()
  local ping, err = self:ask("ping")
  self.data.ping = ping
  self.data.down = ping == nil
  self.data.err = err
  if ping then
    self.data.stats = self:ask("stats") or self.data.stats
    self.data.access = self:ask("access") or self.data.access
    self.data.statscreens = self:ask("statscreens") or self.data.statscreens
  end
  local cfg = config.load(self.root)
  self.data.cfgBroken = cfg == nil
  self.data.cfg = cfg or self.data.cfg or config.defaultsFor(self.root)
  if self.page == "storage" or not self.data.peripherals then self:refreshPeripherals() end
  if self.page == "parcels" or not self.data.parcels then
    self.data.parcels = Parcel.loadConfig(self.root)
    self.data.pstats = Parcel.loadStats(self.root)
  end
end

-- Saves the config and has the service apply it.
function Console:apply(cfg, what)
  if not config.save(cfg) then
    self:say("Could not write " .. cfg.path, true)
    return false
  end
  local res, err = self:ask("reload")
  if res then
    local parts = {}
    for _, n in ipairs(res.screens.added) do parts[#parts + 1] = "screen " .. tostring(n) .. " added" end
    for _, n in ipairs(res.screens.updated) do parts[#parts + 1] = "screen " .. tostring(n) .. " changed" end
    for _, n in ipairs(res.screens.removed) do parts[#parts + 1] = "screen " .. tostring(n) .. " removed" end
    for _, n in ipairs(res.storage.added) do parts[#parts + 1] = "+" .. n end
    for _, n in ipairs(res.storage.removed) do parts[#parts + 1] = "-" .. n end
    local st = res.stats or {}
    for _, n in ipairs(st.added or {}) do parts[#parts + 1] = "stat screen " .. tostring(n) .. " added" end
    for _, n in ipairs(st.updated or {}) do parts[#parts + 1] = "stat screen " .. tostring(n) .. " changed" end
    for _, n in ipairs(st.removed or {}) do parts[#parts + 1] = "stat screen " .. tostring(n) .. " removed" end
    for _, n in ipairs(res.notes) do parts[#parts + 1] = n end
    self:say((what or "Saved") .. ": " .. (#parts > 0 and table.concat(parts, ", ") or "applied"))
  elseif self.data.down then
    self:say((what or "Saved") .. "; applies when the service starts")
  else
    self:say("Saved, but not applied: " .. tostring(err), true)
  end
  self:refresh()
  return true
end

-- Drawing ----------------------------------------------------------------

function Console:draw()
  local ui = self.ui
  local w, h = ui.w, ui.h
  ui:begin(colors.black)
  local bar = ui:col("gray", colors.black)
  local p, st = self.data.ping, self.data.stats
  local title = " Warehouse"
  if p then title = title .. "  " .. tostring(p.hostname) .. "  #" .. tostring(p.id) end
  local right
  if self.data.down then
    right = "service not running "
  elseif st then
    right = util.fmtCount(st.items, 7) .. " items  " .. math.floor((st.slots > 0 and st.used / st.slots or 0) * 100 + 0.5) .. "% full "
  else
    right = ""
  end
  ui:text(1, 1, util.fit(title, w), colors.white, bar)
  ui:text(w - #right + 1, 1, right, self.data.down and ui:col("red") or colors.white, bar)
  local x = 1
  for _, pg in ipairs(PAGES) do
    local active = self.page == pg[1]
    x = ui:button(x, 2, pg[2], function()
      self.page = pg[1]
      self.form, self.picker = nil, nil
      self.ui.focus = nil
      if pg[1] == "log" then self.logOffset = 0 end
    end, { bg = active and ui:col("blue", colors.black) or bar, fg = active and colors.white or ui:col("lightGray", colors.white) })
  end
  self.hint = ""
  local y1, y2 = 3, h - 1
  if self.picker then
    self:drawPicker(y1, y2)
  elseif self.form and self.form.kind == "confirm" then
    self:drawConfirm(y1, y2)
  elseif self.form then
    self:drawForm(y1, y2)
  elseif self.page == "screens" then
    self:drawScreens(y1, y2)
  elseif self.page == "parcels" then
    self:drawParcels(y1, y2)
  elseif self.page == "storage" then
    self:drawStorage(y1, y2)
  elseif self.page == "settings" then
    self:drawSettings(y1, y2)
  elseif self.page == "log" then
    self:drawLog(y1, y2)
  else
    self:drawStatus(y1, y2)
  end
  local msg = (self.message and os.clock() < self.messageUntil) and self.message or self.hint
  ui:text(1, h, util.fit(" " .. msg, w), (self.message and os.clock() < self.messageUntil and self.messageError) and ui:col("red") or colors.white, bar)
  ui:finish()
end

function Console:drawStatus(y1, y2)
  local ui, w = self.ui, self.ui.w
  local st, p, cfg = self.data.stats, self.data.ping, self.data.cfg
  local y = y1
  if self.data.down then
    ui:text(2, y, util.fit("The service is not running on this computer.", w - 1), ui:col("red"))
    ui:text(2, y + 1, util.fit("Start it with 'warehouse'. Settings you change here apply when it starts.", w - 1), ui:col("lightGray", colors.white))
    y = y + 3
  elseif st then
    ui:text(2, y, util.fit("Items " .. st.items .. " in " .. st.types .. " kinds    Slots " .. st.used .. "/" .. st.slots, w - 1))
    y = y + 1
    ui:text(2, y, "Storage", ui:col("yellow"))
    y = y + 1
    local shown = 0
    for _, inv in ipairs(st.inventories) do
      if shown >= 4 then
        ui:text(3, y, "+" .. (#st.inventories - shown) .. " more", ui:col("lightGray", colors.white))
        y = y + 1
        break
      end
      local f = inv.size > 0 and inv.used / inv.size or 0
      ui:text(3, y, util.fit(util.shortName(inv.name), 22) .. util.rfit(inv.used .. "/" .. inv.size, 9) .. " ")
      ui:bar(36, y, w - 36, f, ui:col(f > 0.9 and "red" or "green"), ui:col("gray"))
      y = y + 1
      shown = shown + 1
    end
    if shown == 0 then
      ui:text(3, y, "none: check the Storage page", ui:col("red"))
      y = y + 1
    end
  end
  ui:text(2, y, "Screens", ui:col("yellow"))
  y = y + 1
  local access = self.data.access or {}
  if #access == 0 then
    ui:text(3, y, (#(cfg.access or {}) == 0) and "none: add one on the Screens page" or "(starting)", ui:col("lightGray", colors.white))
    y = y + 1
  end
  for i, s in ipairs(access) do
    if i > 3 then
      ui:text(3, y, "+" .. (#access - 3) .. " more", ui:col("lightGray", colors.white))
      y = y + 1
      break
    end
    local state = s.up and (s.locked and "up, locked" or "up") or "DOWN"
    ui:text(3, y, util.fit(tostring(s.name), 10) .. util.fit(tostring(s.monitor), 12) .. util.fit(tostring(s.chest), 20) .. state, s.up and colors.white or ui:col("red"))
    y = y + 1
  end
  if p then
    ui:text(2, y, util.fit("Network  rednet " .. (cfg.rednet ~= false and "on" or "off") .. ", hostname " .. tostring(p.hostname), w - 1), ui:col("lightGray", colors.white))
    y = y + 1
    ui:text(2, y, util.fit("Service  up " .. uptime(p.uptime) .. (self.data.cfgBroken and ", CONFIG FILE BROKEN" or ", config ok"), w - 1), self.data.cfgBroken and ui:col("red") or ui:col("lightGray", colors.white))
    y = y + 1
  end
  local bx = 2
  bx = ui:button(bx, y2, "Reload config", function()
    local res, err = self:ask("reload")
    if res then self:say("Config applied") else self:say("Reload failed: " .. tostring(err), true) end
    self:refresh()
  end) + 1
  bx = ui:button(bx, y2, "Compact", function()
    local res, err = self:ask("compact")
    if res then self:say("Compacted: " .. res.moves .. " moves") else self:say(tostring(err), true) end
  end) + 1
  bx = ui:button(bx, y2, "Rescan", function()
    local res, err = self:ask("rescan")
    if res then self:say("Rescanned: " .. res.items .. " items in " .. res.used .. " slots") else self:say(tostring(err), true) end
    self:refresh()
  end) + 1
  if self.stopArmed and os.clock() < self.stopArmed then
    bx = ui:button(bx, y2, "Really stop", function()
      self:ask("shutdown")
      self.stopArmed = nil
      self:say("Stopping the service")
      if self.standalone then self.running = false end
    end, { bg = ui:col("red", colors.black) }) + 1
  else
    bx = ui:button(bx, y2, "Stop", function()
      self.stopArmed = os.clock() + 5
      self:say("Click 'Really stop' to stop the service", true)
    end, { bg = ui:col("red", colors.black) }) + 1
  end
  if self.standalone then ui:button(bx, y2, "Quit", function() self.running = false end) end
  self.hint = "Click a page above. Changes apply at once."
end

function Console:drawScreens(y1, y2)
  local ui, w = self.ui, self.ui.w
  local cfg = self.data.cfg
  local live = {}
  for _, s in ipairs(self.data.access or {}) do live[s.name or s.monitor] = s end
  ui:text(1, y1, util.fit(" Name      Chest               Monitor   State", w), ui:col("yellow"))
  local y = y1 + 1
  if #(cfg.access or {}) == 0 then
    ui:text(2, y, "No screens yet. Add one below.", ui:col("lightGray", colors.white))
  end
  for i, ap in ipairs(cfg.access or {}) do
    if y >= y2 - 1 then break end
    if i > 6 then
      ui:text(2, y, "+" .. (#cfg.access - 6) .. " more", ui:col("lightGray", colors.white))
      y = y + 1
      break
    end
    local s = live[ap.name or ap.monitor]
    local state = s and (s.up and (s.locked and "up,locked" or "up") or "DOWN") or "-"
    local name = tostring(ap.name or "?") .. (ap.pin and "*" or "")
    local line = " " .. util.fit(name, 9) .. " " .. util.fit(ap.chest or "", 19) .. " " .. util.fit(ap.monitor or "", 9) .. " " .. state
    ui:text(1, y, util.fit(line, w), (s and not s.up) and ui:col("red") or colors.white)
    ui:region(1, y, w, y, function() self:openScreenForm(i) end)
    y = y + 1
  end
  -- Stat screens: monitors with charts (lib.stats).
  y = y + 1
  if y < y2 - 1 then
    ui:text(1, y, util.fit(" Stat screen       Monitor    Shows", w), ui:col("yellow"))
    y = y + 1
    local sLive = {}
    for _, s in ipairs(self.data.statscreens or {}) do sLive[s.name or s.monitor] = s end
    if #(cfg.stats or {}) == 0 then
      ui:text(2, y, "none: a monitor with charts of what the warehouse does.", ui:col("lightGray", colors.white))
    end
    for i, sc in ipairs(cfg.stats or {}) do
      if y >= y2 - 1 then break end
      local s = sLive[sc.name or sc.monitor]
      local state = s and (s.up and "up" or "DOWN") or "-"
      local shows = (type(sc.show) == "table" and #sc.show > 0) and table.concat(sc.show, ",") or "everything"
      local line = " " .. util.fit(tostring(sc.name or sc.monitor), 17) .. " " .. util.fit(sc.monitor or "", 10) .. " " .. util.fit(shows, w - 36) .. " " .. state
      ui:text(1, y, util.fit(line, w), (s and not s.up) and ui:col("red") or colors.white)
      ui:region(1, y, w, y, function() self:openStatForm(i) end)
      y = y + 1
    end
  end
  local x = ui:button(2, y2, "Add screen", function() self:openScreenForm(nil) end, { bg = ui:col("green", colors.black) }) + 1
  ui:button(x, y2, "Add stat screen", function() self:openStatForm(nil) end, { bg = ui:col("green", colors.black) })
  self.hint = "Click a screen to change or remove it. *: has a PIN. Stat screens show charts."
end

-- A stat screen's form: name, monitor, text scale and which panels it
-- shows (none ticked: everything).
function Console:openStatForm(index)
  local cfg = self.data.cfg
  cfg.stats = cfg.stats or {}
  local sc = index and cfg.stats[index] or {}
  self.form = {
    kind = "stats",
    index = index,
    title = index and ("Stat screen " .. tostring(sc.name or sc.monitor)) or "New stat screen",
    fields = {
      { label = "Name", key = "name", f = UI.newField(sc.name or ("Stats" .. (#cfg.stats + 1)), { max = 16 }), w = 18 },
      { label = "Monitor", key = "monitor", f = UI.newField(sc.monitor, { max = 40 }), w = 26, pick = "monitor" },
      { label = "Text scale", key = "scale", f = UI.newField(sc.scale, { max = 4, filter = "[%d%.]" }), w = 6, hint = "0.5 or 1, blank: auto" },
      { label = "Show", key = "show", toggles = Stats.ORDER, labels = Stats.SHORT, value = setOf(sc.show), hint = "nothing ticked: everything, in this order" },
    },
    notes = { "Charts of the fill, the item total, items over time, in and out, the top items,", "the kinds, the Parcel Service, the crafter, the screens and the service." },
  }
  if index then
    self.form.extra = {
      { "Remove stat screen", function()
        table.remove(cfg.stats, index)
        self.form, self.ui.focus = nil, nil
        self:apply(cfg, "Stat screen " .. tostring(sc.name or sc.monitor) .. " removed")
      end, "red" },
    }
  end
  self.ui.focus = self.form.fields[1].f
end

function Console:saveStatForm()
  local form, cfg = self.form, self.data.cfg
  local name, monitor, scale = self:formValue("name"), self:formValue("monitor"), self:formValue("scale")
  if monitor == "" then
    self:say("Pick the monitor the charts go on", true)
    return
  end
  if name == "" then name = monitor end
  for i, sc in ipairs(cfg.stats or {}) do
    if i ~= form.index and (sc.name == name or sc.monitor == monitor) then
      self:say("There is already a stat screen " .. tostring(sc.name) .. " on " .. tostring(sc.monitor), true)
      return
    end
  end
  for _, ap in ipairs(cfg.access or {}) do
    if ap.monitor == monitor then
      self:say("Monitor " .. monitor .. " belongs to the screen " .. tostring(ap.name), true)
      return
    end
  end
  local sc = { name = name, monitor = monitor }
  if scale ~= "" then sc.scale = tonumber(scale) end
  local show = self:formValue("show")
  if #show > 0 then sc.show = show end
  cfg.stats = cfg.stats or {}
  if form.index then cfg.stats[form.index] = sc else cfg.stats[#cfg.stats + 1] = sc end
  self.form, self.ui.focus = nil, nil
  self:apply(cfg, "Stat screen " .. name)
end

function Console:openScreenForm(index)
  local cfg = self.data.cfg
  local ap = index and cfg.access[index] or {}
  self.form = {
    kind = "screen",
    index = index,
    title = index and ("Screen " .. tostring(ap.name)) or "New screen",
    fields = {
      { label = "Name", key = "name", f = UI.newField(ap.name or ((#(cfg.access or {}) == 0) and "Main" or ""), { max = 16 }), w = 18 },
      { label = "Chest", key = "chest", f = UI.newField(ap.chest, { max = 40 }), w = 26, pick = "inventory" },
      { label = "Monitor", key = "monitor", f = UI.newField(ap.monitor, { max = 40 }), w = 26, pick = "monitor" },
      { label = "PIN", key = "pin", f = UI.newField(ap.pin, { max = 12, filter = "%d" }), w = 12, hint = "blank: never locks" },
      { label = "Lock after", key = "lockAfter", f = UI.newField(ap.lockAfter, { max = 6, filter = "%d" }), w = 6, hint = "s, 0: Lock button only" },
      { label = "Text scale", key = "scale", f = UI.newField(ap.scale, { max = 4, filter = "[%d%.]" }), w = 6, hint = "0.5 or 1, blank: auto" },
    },
  }
  self.ui.focus = self.form.fields[1].f
end

function Console:drawForm(y1, y2)
  local ui, w = self.ui, self.ui.w
  local form = self.form
  ui:text(1, y1, util.fit(" " .. form.title, w), ui:col("yellow"))
  local y = y1 + 1
  for _, fd in ipairs(form.fields) do
    ui:text(2, y, util.fit(fd.label, 11))
    if fd.toggles then
      -- a row (or rows) of on/off buttons
      local labels = {}
      for i, key in ipairs(fd.toggles) do labels[i] = fd.labels and fd.labels[key] or key end
      local rows = UI.wrap(labels, w - 13)
      for r, row in ipairs(rows) do
        local bx = 13
        for _, b in ipairs(row) do
          local key = fd.toggles[b.index]
          local on = fd.value[key] == true
          bx = ui:button(bx, y, b.label, function()
            if fd.value[key] then fd.value[key] = nil else fd.value[key] = true end
          end, { bg = on and ui:col("blue", colors.black) or nil, fg = on and colors.white or ui:col("lightGray", colors.white) }) + 1
        end
        if r < #rows then y = y + 1 end
      end
      if fd.hint then
        y = y + 1
        ui:text(13, y, util.fit(fd.hint, w - 13), ui:col("lightGray", colors.white))
      end
    elseif fd.cycle then
      ui:button(13, y, fd.value, function()
        local i = 1
        for k, v in ipairs(fd.cycle) do
          if v == fd.value then i = k end
        end
        fd.value = fd.cycle[i % #fd.cycle + 1]
      end, { w = fd.w })
    else
      ui:field(13, y, fd.w, fd.f)
    end
    if not fd.toggles then
      local x = 13 + fd.w + 1
      if fd.pick then x = ui:button(x, y, "Pick", function() self:openPicker(fd) end) + 1 end
      if fd.fill then x = ui:button(x, y, "Fill", function() self:fillItems(fd) end) + 1 end
      if fd.hint then ui:text(x, y, util.fit(fd.hint, w - x + 1), ui:col("lightGray", colors.white)) end
    end
    y = y + 1
  end
  for _, note in ipairs(form.notes or {}) do
    ui:text(2, y, util.fit(note, w - 1), ui:col("lightGray", colors.white))
    y = y + 1
  end
  y = y + 1
  local x = ui:button(2, y, "Save", function() self:saveForm() end, { bg = ui:col("green", colors.black) }) + 1
  x = ui:button(x, y, "Cancel", function()
    self.form = nil
    self.ui.focus = nil
  end) + 1
  if form.kind == "screen" and form.index then
    ui:button(x, y, "Remove screen", function() self:removeScreen(form.index) end, { bg = ui:col("red", colors.black) })
  end
  for _, b in ipairs(form.extra or {}) do
    x = ui:button(x, y, b[1], b[2], { bg = b[3] and ui:col(b[3], colors.black) or nil }) + 1
  end
  self.hint = form.hint or "Click a field, type. Tab: next. Esc: cancel."
end

-- Parcel Service --------------------------------------------------------

local function ago(epochMs)
  if not epochMs then return "never" end
  local s = math.floor((os.epoch("utc") - epochMs) / 1000)
  if s < 60 then return s .. "s ago" end
  if s < 3600 then return math.floor(s / 60) .. "m ago" end
  return math.floor(s / 3600) .. "h ago"
end

-- The Parcels page: the folders (lib.folders) and the tasks in none, or
-- the tasks of the open folder. Tasks go into a folder from their form.
function Console:drawParcels(y1, y2)
  local ui, w = self.ui, self.ui.w
  local cfg = self.data.parcels or { tasks = {} }
  cfg.tasks = cfg.tasks or {}
  cfg.folders = cfg.folders or {}
  local stats = self.data.pstats or {}
  local open = self.parcelFolder
  local view = Folders.view(cfg.folders, cfg.tasks, open)
  local rows = {}
  for _, f in ipairs(view.folders) do rows[#rows + 1] = { folder = f } end
  for _, it in ipairs(view.items) do rows[#rows + 1] = { task = it.entry, index = it.index } end
  local head = open and util.fit(open .. "/", 11) or "Name       "
  ui:text(1, y1, util.fit(" " .. head .. " Kind     Inventory           Last run", w), ui:col("yellow"))
  local visible = y2 - y1 - 1
  self.parcelOffset = util.clamp(self.parcelOffset, 0, math.max(0, #rows - visible))
  if #rows == 0 then
    ui:text(2, y1 + 1, open and "No tasks in this folder yet. Add one below." or "No tasks yet. Add one below.", ui:col("lightGray", colors.white))
  end
  for i = 1, visible do
    local r = rows[i + self.parcelOffset]
    if not r then break end
    local y = y1 + i
    if r.folder then
      local f = r.folder
      ui:text(1, y, util.fit(" + " .. f.name .. "  (" .. f.count .. (f.count == 1 and " task)" or " tasks)"), w), ui:col("lightBlue", colors.white))
      ui:region(1, y, w, y, function()
        self.parcelFolder = f.name
        self.parcelOffset = 0
      end)
    else
      local t, s = r.task, stats[r.task.id] or {}
      local last = (t.enabled == false) and "off" or (ago(s.lastRun) .. (s.lastMoved and (" +" .. s.lastMoved) or ""))
      local line = " " .. util.fit(tostring(t.name or t.id), 11) .. " " .. util.fit(t.kind or "?", 8) .. " " .. util.fit(tostring(t.inventory or ""), 19) .. " " .. last
      local col = colors.white
      if t.enabled == false then col = ui:col("lightGray", colors.white) elseif (s.errors or 0) > 0 and s.lastMoved == 0 and s.lastMessage then col = ui:col("orange", colors.white) end
      ui:text(1, y, util.fit(line, w), col)
      local index = r.index
      ui:region(1, y, w, y, function() self:openParcelForm(index) end)
    end
  end
  local x = ui:button(2, y2, "Add task", function() self:openParcelForm(nil, open) end, { bg = ui:col("green", colors.black) }) + 1
  if open then
    x = ui:button(x, y2, "Back", function()
      self.parcelFolder = nil
      self.parcelOffset = 0
    end) + 1
    if self.confirmFolder and os.clock() < self.confirmFolder then
      ui:button(x, y2, "Really remove", function()
        self.confirmFolder = nil
        local moved = Folders.remove(cfg.folders, cfg.tasks, open)
        Parcel.saveConfig(self.root, cfg)
        self.parcelFolder, self.parcelOffset = nil, 0
        self:say("Folder " .. open .. " removed" .. (moved > 0 and ("; " .. moved .. " task(s) are back at the top level") or ""))
        self:refresh()
      end, { bg = ui:col("red", colors.black) })
    else
      ui:button(x, y2, "Remove folder", function()
        self.confirmFolder = os.clock() + 5
        self:say("Click 'Really remove' to remove the folder " .. open .. " (its tasks stay, at the top level)", true)
      end, { bg = ui:col("red", colors.black) })
    end
    self.hint = "Folder " .. open .. ": click a task to change, run or remove it. Wheel scrolls."
  else
    ui:button(x, y2, "New folder", function() self:openFolderForm() end)
    self.hint = "Click a task to change it, a folder to open it. Wheel scrolls."
  end
end

function Console:openFolderForm()
  self.form = {
    kind = "folder",
    title = "New folder",
    fields = { { label = "Name", key = "name", f = UI.newField("", { max = Folders.MAX }), w = 18, hint = "tasks join it from their form" } },
    hint = "Type a name and click Save. Esc: cancel.",
  }
  self.ui.focus = self.form.fields[1].f
end

function Console:saveFolderForm()
  local cfg = self.data.parcels
  cfg.folders = cfg.folders or {}
  local name, err = Folders.add(cfg.folders, cfg.tasks or {}, self:formValue("name"))
  if not name then
    self:say(err, true)
    return
  end
  if Parcel.saveConfig(self.root, cfg) then
    self.parcelFolder, self.parcelOffset = name, 0
    self:say("Folder " .. name .. " made: add tasks to it, or move tasks in from their form")
  else
    self:say("Could not write " .. Parcel.configPath(self.root), true)
  end
  self.form, self.ui.focus = nil, nil
  self:refresh()
end

-- folder: the folder a new task starts in (the open one).
function Console:openParcelForm(index, folder)
  local cfg = self.data.parcels
  cfg.tasks = cfg.tasks or {}
  local t = index and cfg.tasks[index] or { kind = "deposit", interval = 5, items = {}, folder = folder }
  local s = (self.data.pstats or {})[t.id or ""] or {}
  local form = {
    kind = "parcel",
    index = index,
    title = index and ("Task " .. tostring(t.name or t.id)) or "New task",
    fields = {
      { label = "Name", key = "name", f = UI.newField(t.name, { max = 20 }), w = 18 },
      { label = "Kind", key = "kind", cycle = KINDS, value = t.kind or "deposit", w = 10, hint = "into the vault / out of it" },
      { label = "Inventory", key = "inventory", f = UI.newField(t.inventory, { max = 40 }), w = 26, pick = "inventory" },
      { label = "Folder", key = "folder", f = UI.newField(t.folder, { max = Folders.MAX }), w = 18, pick = "folder", hint = "blank: top level" },
      { label = "Items", key = "items", f = UI.newField(Parcel.formatItems(t.kind or "deposit", t.items), { max = 400 }), w = 30, fill = true },
      { label = "Every", key = "interval", f = UI.newField(t.interval or 5, { max = 6, filter = "%d" }), w = 6, hint = "seconds" },
      { label = "Max/run", key = "maxPerRun", f = UI.newField(t.maxPerRun, { max = 7, filter = "%d" }), w = 7, hint = "items, blank: no cap" },
      { label = "Total", key = "totalLimit", f = UI.newField(t.totalLimit, { max = 8, filter = "%d" }), w = 8, hint = "lifetime budget, blank: none" },
      { label = "Enabled", key = "enabled", cycle = ONOFF, value = (t.enabled == false) and "off" or "on", w = 5 },
    },
    notes = {
      "Items: deposit  oak_planks<64   (all = everything)",
      "       withdraw minecraft:coal=64/32#1000",
    },
  }
  if index then
    form.notes[#form.notes + 1] = string.format("Stats: %d runs, %d moved, %d errors, last %s%s", s.runs or 0, s.moved or 0, s.errors or 0, ago(s.lastRun), s.lastMessage and (": " .. s.lastMessage) or "")
    form.extra = {
      { "Remove", function()
        table.remove(cfg.tasks, index)
        Parcel.saveConfig(self.root, cfg)
        self.form, self.ui.focus = nil, nil
        self:say("Task removed")
        self:refresh()
      end, "red" },
      { "Run now", function()
        os.queueEvent("parcel_run", t.id)
        self:say("Running " .. tostring(t.name or t.id))
      end },
      { "Reset stats", function()
        os.queueEvent("parcel_reset", t.id)
        self:say("Stats reset")
      end },
    }
  end
  self.form = form
  self.ui.focus = form.fields[1].f
end

-- Fill: puts what the chosen inventory holds on the Items line (deposit:
-- the names; withdraw: name=count, keeping what is there now).
function Console:fillItems(fd)
  local inventory = self:formValue("inventory")
  if inventory == "" then
    self:say("Pick the inventory first", true)
    return
  end
  local kind = self:formValue("kind")
  local inv, err = self:ask("inventory", { name = inventory })
  if not inv then
    local ok, list = pcall(peripheral.call, inventory, "list")
    if not ok or type(list) ~= "table" then
      self:say("Cannot read " .. inventory .. ": " .. tostring(err or list), true)
      return
    end
    inv = { items = {} }
    for slot, it in pairs(list) do inv.items[#inv.items + 1] = { name = it.name, count = it.count, slot = slot } end
  end
  local counts, order = {}, {}
  for _, it in ipairs(inv.items) do
    if not counts[it.name] then order[#order + 1] = it.name end
    counts[it.name] = (counts[it.name] or 0) + it.count
  end
  local present = {}
  for _, spec in ipairs(Parcel.parseItems(kind, fd.f.text) or {}) do present[util.shortName(spec.item):lower()] = true end
  local added = {}
  for _, name in ipairs(order) do
    if not present[util.shortName(name):lower()] then
      added[#added + 1] = kind == "withdraw" and (name .. "=" .. counts[name]) or name
    end
  end
  if #added == 0 then
    self:say(#order == 0 and (inventory .. " is empty") or "Everything in it is already on the line")
    return
  end
  local text = trim(fd.f.text)
  if text == "all" or text == "*" then text = "" end
  fd.f.text = (text ~= "" and (text .. ",") or "") .. table.concat(added, ",")
  fd.f.cursor = #fd.f.text + 1
  self.ui.focus = fd.f
  self:say("Added " .. #added .. " item(s) from " .. inventory)
end

function Console:saveParcelForm()
  local form = self.form
  local cfg = self.data.parcels
  local name, kind, inventory = self:formValue("name"), self:formValue("kind"), self:formValue("inventory")
  if inventory == "" then
    self:say("Pick the inventory the task works on", true)
    return
  end
  local items, err = Parcel.parseItems(kind, self:formValue("items"))
  if not items then
    self:say(err, true)
    return
  end
  if kind == "withdraw" and #items == 0 then
    self:say("A withdraw task needs items: name=keep or name/perRun", true)
    return
  end
  local old = form.index and cfg.tasks[form.index] or {}
  local t = { id = old.id or Parcel.newId(cfg), name = name ~= "" and name or nil, kind = kind, inventory = inventory, items = items }
  cfg.folders = cfg.folders or {}
  t.folder = Folders.resolve(cfg.folders, cfg.tasks, self:formValue("folder"))
  if t.folder then Folders.add(cfg.folders, {}, t.folder) end -- a folder typed here is declared too
  t.interval = tonumber(self:formValue("interval")) or 5
  t.maxPerRun = tonumber(self:formValue("maxPerRun"))
  t.totalLimit = tonumber(self:formValue("totalLimit"))
  t.enabled = self:formValue("enabled") ~= "off"
  if form.index then cfg.tasks[form.index] = t else cfg.tasks[#cfg.tasks + 1] = t end
  if Parcel.saveConfig(self.root, cfg) then
    self:say("Task " .. tostring(t.name or t.id) .. " saved and running")
  else
    self:say("Could not write " .. Parcel.configPath(self.root), true)
  end
  self.form, self.ui.focus = nil, nil
  self:refresh()
end

function Console:formValue(key)
  for _, fd in ipairs(self.form.fields) do
    if fd.key == key then
      if fd.toggles then
        local out = {}
        for _, k in ipairs(fd.toggles) do
          if fd.value[k] then out[#out + 1] = k end
        end
        return out
      end
      return fd.cycle and fd.value or trim(fd.f.text)
    end
  end
end

function Console:saveForm()
  local form = self.form
  local cfg = self.data.cfg
  if form.kind == "parcel" then
    self:saveParcelForm()
  elseif form.kind == "folder" then
    self:saveFolderForm()
  elseif form.kind == "stats" then
    self:saveStatForm()
  elseif form.kind == "screen" then
    local name, chest, monitor = self:formValue("name"), self:formValue("chest"), self:formValue("monitor")
    if name == "" or chest == "" or monitor == "" then
      self:say("A screen needs a name, a chest and a monitor", true)
      return
    end
    local other = config.findAccess(cfg, name)
    if other and other ~= cfg.access[form.index or -1] then
      self:say("There is already a screen called " .. name, true)
      return
    end
    local pin, lockAfter, scale = self:formValue("pin"), self:formValue("lockAfter"), self:formValue("scale")
    local ap = { name = name, chest = chest, monitor = monitor }
    if pin ~= "" then ap.pin = pin end
    if lockAfter ~= "" then ap.lockAfter = tonumber(lockAfter) end
    if scale ~= "" then ap.scale = tonumber(scale) end
    cfg.access = cfg.access or {}
    if form.index then cfg.access[form.index] = ap else cfg.access[#cfg.access + 1] = ap end
    self.form, self.ui.focus = nil, nil
    self:apply(cfg, "Screen " .. name)
  elseif form.kind == "override" then
    local item, cat = self:formValue("item"), self:formValue("category")
    if item == "" then
      self:say("Type the item name, like create:iron_sheet", true)
      return
    end
    cfg.categories = cfg.categories or {}
    cfg.categories[item] = cat
    self.form, self.ui.focus = nil, nil
    self:apply(cfg, item .. " = " .. cat)
  end
end

function Console:removeScreen(index)
  local cfg = self.data.cfg
  local ap = cfg.access[index]
  table.remove(cfg.access, index)
  self.form, self.ui.focus = nil, nil
  self:apply(cfg, "Screen " .. tostring(ap and ap.name) .. " removed")
end

-- Pickers: inventories and monitors with what each is used for (lib.uses),
-- free ones first; folders for a task.
function Console:openPicker(fd)
  local items, title, hint = {}, "Pick one", "Click one."
  if fd.pick == "inventory" then
    for _, r in ipairs(Uses.inventories(self.root, self.data.cfg, self:refreshPeripherals())) do
      items[#items + 1] = { label = Uses.line(r), value = r.name, busy = r.busy }
    end
    title, hint = "Pick an inventory", "Free ones first; gray: used by a screen, a task or the crafter."
  elseif fd.pick == "monitor" then
    for _, r in ipairs(Uses.monitors(self.root, self.data.cfg)) do
      items[#items + 1] = { label = Uses.line(r), value = r.name, busy = r.busy }
    end
    title, hint = "Pick a monitor", "Free ones first; gray: used by a screen or the crafter."
  else
    local cfg = self.data.parcels or {}
    items[#items + 1] = { label = "(top level: no folder)", value = "" }
    for _, n in ipairs(Folders.names(cfg.folders, cfg.tasks)) do items[#items + 1] = { label = n, value = n } end
    title = "Pick a folder"
  end
  if #items == 0 then
    self:say("Nothing of that kind is on the network", true)
    return
  end
  self.picker = {
    title = title,
    items = items,
    offset = 0,
    hint = hint,
    onPick = function(v)
      fd.f.text = v
      fd.f.cursor = #v + 1
    end,
  }
end

function Console:drawPicker(y1, y2)
  local ui, w = self.ui, self.ui.w
  local pk = self.picker
  ui:text(1, y1, util.fit(" " .. pk.title .. " (Esc: back)", w), ui:col("yellow"))
  local visible = y2 - y1 - 1
  pk.offset = util.clamp(pk.offset, 0, math.max(0, #pk.items - visible))
  for i = 1, visible do
    local it = pk.items[i + pk.offset]
    if not it then break end
    local y = y1 + i
    ui:text(2, y, util.fit(it.label, w - 2), it.busy and ui:col("lightGray", colors.white) or colors.white)
    ui:region(1, y, w, y, function()
      pk.onPick(it.value)
      self.picker = nil
    end)
  end
  ui:button(2, y2, "Cancel", function() self.picker = nil end)
  self.hint = (#pk.items > visible and "Wheel scrolls. " or "") .. (pk.hint or "Click one.")
end

function Console:storageRows()
  local cfg = self.data.cfg
  local fills = {}
  for _, inv in ipairs(self.data.stats and self.data.stats.inventories or {}) do
    fills[inv.name] = inv.size > 0 and inv.used / inv.size or 0
  end
  local names, excluded = setOf(cfg.storage.names), setOf(cfg.storage.exclude)
  local rows = {}
  local function without(list, name)
    local out = {}
    for _, n in ipairs(list or {}) do
      if n ~= name then out[#out + 1] = n end
    end
    return out
  end
  for _, p in ipairs(self.data.peripherals or {}) do
    local r = { name = p.name, size = p.size, color = colors.white }
    if p.role == "storage" then
      r.role = "storage"
      r.fill = fills[p.name]
      r.color = self.ui:col("lightBlue", colors.white)
      if names[p.name] then
        r.action = "Remove"
        r.fn = function()
          self:confirmExclude(p.name, "remove", function()
            cfg.storage.names = without(cfg.storage.names, p.name)
            self:apply(cfg, p.name .. " no longer storage")
          end)
        end
      else
        r.action = "Exclude"
        r.fn = function()
          self:confirmExclude(p.name, "exclude", function()
            cfg.storage.exclude = without(cfg.storage.exclude, p.name)
            table.insert(cfg.storage.exclude, p.name)
            self:apply(cfg, p.name .. " excluded")
          end)
        end
      end
    elseif p.role == "excluded" then
      r.role = "excluded"
      r.color = self.ui:col("lightGray", colors.white)
      r.action = "Include"
      r.fn = function()
        cfg.storage.exclude = without(cfg.storage.exclude, p.name)
        self:apply(cfg, p.name .. " included")
      end
    elseif p.role == "access" then
      r.role = "screen " .. tostring(p.access)
      r.color = self.ui:col("yellow", colors.white)
    else
      r.role = "free"
      r.action = "Add"
      r.fn = function()
        cfg.storage.names = without(cfg.storage.names, p.name)
        table.insert(cfg.storage.names, p.name)
        cfg.storage.exclude = without(cfg.storage.exclude, p.name)
        self:apply(cfg, p.name .. " is storage")
      end
    end
    rows[#rows + 1] = r
  end
  return rows
end

-- Taking a storage inventory out of the vault while it still holds items:
-- asks whether to move them into the rest of the vault first. change()
-- makes the config change; what is "exclude" or "remove".
function Console:confirmExclude(name, what, change)
  local inv = self:ask("inventory", { name = name })
  if not inv or inv.total == 0 then return change() end
  local Cap = what:sub(1, 1):upper() .. what:sub(2)
  self.form = {
    kind = "confirm",
    title = name .. " holds " .. inv.total .. " items in " .. #inv.items .. " slots",
    notes = {
      "Move them into the rest of the vault first, or leave them where they are?",
      "(Moving needs room in the other storage inventories.)",
    },
    buttons = {
      { "Move, then " .. what, function()
        change()
        local res, err = self:ask("deposit", { from = name, recent = false })
        if res then
          self:say(string.format("Moved %d of %d items out of %s%s", res.moved, inv.total, name, res.message and ("; " .. res.message) or ""), res.message ~= nil)
        else
          self:say("Could not move the items: " .. tostring(err), true)
        end
        self:refresh()
      end, "green" },
      { Cap .. " as is", change, "orange" },
      { "Cancel", function() end },
    },
  }
end

function Console:drawConfirm(y1, y2)
  local ui, w = self.ui, self.ui.w
  local form = self.form
  ui:text(1, y1, util.fit(" " .. form.title, w), ui:col("yellow"))
  local y = y1 + 1
  for _, note in ipairs(form.notes or {}) do
    ui:text(2, y, util.fit(note, w - 1), ui:col("lightGray", colors.white))
    y = y + 1
  end
  y = y + 1
  local x = 2
  for _, b in ipairs(form.buttons) do
    x = ui:button(x, y, b[1], function()
      self.form, self.ui.focus = nil, nil
      b[2]()
    end, { bg = b[3] and ui:col(b[3], colors.black) or nil }) + 1
  end
  self.hint = "Click one. Esc: cancel."
end

function Console:drawStorage(y1, y2)
  local ui, w = self.ui, self.ui.w
  local cfg = self.data.cfg
  if not self.typesField then self.typesField = UI.newField(join(cfg.storage.types), { max = 120 }) end
  ui:text(2, y1, "Storage types")
  ui:field(16, y1, w - 16 - 7, self.typesField)
  ui:button(w - 5, y1, "Save", function()
    cfg.storage.types = words(self.typesField.text)
    self:apply(cfg, "Storage types")
  end, { bg = ui:col("green", colors.black) })
  ui:text(1, y1 + 1, util.fit(" Inventory            Size Role      Fill", w), ui:col("yellow"))
  local rows = self:storageRows()
  local visible = y2 - (y1 + 2) + 1
  self.storageOffset = util.clamp(self.storageOffset, 0, math.max(0, #rows - visible))
  if #rows == 0 then ui:text(2, y1 + 2, "No inventories on the network.", ui:col("lightGray", colors.white)) end
  for i = 1, visible do
    local r = rows[i + self.storageOffset]
    if not r then break end
    local y = y1 + 1 + i
    local fill = r.fill and (math.floor(r.fill * 100 + 0.5) .. "%") or ""
    ui:text(1, y, util.fit(" " .. util.fit(r.name, 20) .. util.rfit(r.size, 5) .. " " .. util.fit(r.role, 9) .. " " .. fill, w - 10), r.color)
    if r.action then ui:button(w - 8, y, r.action, r.fn, { w = 9, bg = r.action == "Exclude" and ui:col("orange", colors.black) or ui:col("gray", colors.black) }) end
  end
  self.hint = "Storage = listed types + added ones. Wheel scrolls."
end

function Console:drawSettings(y1, y2)
  local ui, w = self.ui, self.ui.w
  local cfg = self.data.cfg
  local s = self.settings
  if not s then
    s = {
      presets = UI.newField(join(cfg.presets), { max = 40 }),
      stackPresets = UI.newField(join(cfg.stackPresets), { max = 40 }),
      lockAfter = UI.newField(cfg.lockAfter, { max = 6, filter = "%d" }),
      rescanSeconds = UI.newField(cfg.rescanSeconds, { max = 6, filter = "%d" }),
      hostname = UI.newField(cfg.hostname, { max = 24 }),
      rednet = cfg.rednet ~= false,
      logLevel = cfg.logLevel or "info",
    }
    self.settings = s
  end
  local y = y1
  ui:text(2, y, "Presets")
  ui:field(10, y, 16, s.presets)
  ui:text(28, y, "Stacks")
  ui:field(35, y, 14, s.stackPresets)
  y = y + 1
  ui:text(2, y, "Lock after")
  ui:field(13, y, 5, s.lockAfter)
  ui:text(19, y, "s   Rescan every")
  ui:field(36, y, 5, s.rescanSeconds)
  ui:text(42, y, "s")
  y = y + 1
  ui:text(2, y, "Hostname")
  ui:field(11, y, 12, s.hostname)
  ui:text(25, y, "Rednet")
  ui:button(32, y, s.rednet and "on" or "off", function() s.rednet = not s.rednet end, { w = 5, bg = ui:col(s.rednet and "green" or "gray", colors.black) })
  ui:text(38, y, "Log")
  ui:button(42, y, s.logLevel, function()
    local i = 1
    for k, v in ipairs(LEVELS) do
      if v == s.logLevel then i = k end
    end
    s.logLevel = LEVELS[i % #LEVELS + 1]
  end, { w = 7 })
  y = y + 1
  ui:button(2, y, "Save settings", function()
    cfg.presets = numbers(s.presets.text)
    cfg.stackPresets = numbers(s.stackPresets.text)
    cfg.lockAfter = tonumber(s.lockAfter.text) or 0
    cfg.rescanSeconds = tonumber(s.rescanSeconds.text) or 0
    cfg.hostname = trim(s.hostname.text) ~= "" and trim(s.hostname.text) or "vault"
    cfg.rednet = s.rednet
    cfg.logLevel = s.logLevel
    if #cfg.presets == 0 then cfg.presets = { 1, 4, 8, 16, 32 } end
    if #cfg.stackPresets == 0 then cfg.stackPresets = { 1, 2, 4, 8, 16 } end
    self:apply(cfg, "Settings")
  end, { bg = ui:col("green", colors.black) })
  y = y + 2
  ui:text(2, y, "Item categories you set yourself", ui:col("yellow"))
  y = y + 1
  local keys = {}
  for item in pairs(cfg.categories or {}) do keys[#keys + 1] = item end
  table.sort(keys)
  if #keys == 0 then
    ui:text(3, y, "none; add one if the screens guess wrong", ui:col("lightGray", colors.white))
    y = y + 1
  end
  for _, item in ipairs(keys) do
    if y >= y2 then break end
    ui:text(3, y, util.fit(item .. " = " .. tostring(cfg.categories[item]), w - 8))
    ui:button(w - 4, y, "x", function()
      cfg.categories[item] = nil
      self:apply(cfg, item .. " back to automatic")
    end, { w = 3, bg = ui:col("red", colors.black) })
    y = y + 1
  end
  local x = ui:button(2, y2, "Add category", function()
    self.form = {
      kind = "override",
      title = "Item category",
      fields = {
        { label = "Item", key = "item", f = UI.newField("", { max = 60 }), w = 30, hint = "e.g. create:iron_sheet" },
        { label = "Category", key = "category", cycle = CATS, value = "resource", w = 13 },
      },
    }
    self.ui.focus = self.form.fields[1].f
  end) + 1
  ui:button(x, y2, "Show key", function()
    local secure = require("lib.secure")
    local key = secure.loadKey(fs.combine(self.root, "data/secret"))
    if key then self:say("Key " .. secure.encodeKey(key)) else self:say("No key yet (the service makes one)", true) end
  end)
  self.hint = "Presets: comma separated. Save applies at once."
end

-- The log, re-read only when the file has grown or shrunk.
function Console:logLines()
  local path = fs.combine(self.root, "data/log")
  if not fs.exists(path) then return {} end
  local size = fs.getSize(path)
  if self.logCache and self.logCache.size == size then return self.logCache.lines end
  local h = fs.open(path, "r")
  local s = h.readAll()
  h.close()
  local lines = {}
  for line in s:gmatch("[^\n]+") do lines[#lines + 1] = line end
  self.logCache = { size = size, lines = lines }
  return lines
end

function Console:drawLog(y1, y2)
  local ui, w = self.ui, self.ui.w
  local lines = self:logLines()
  local visible = y2 - y1 + 1
  self.logOffset = util.clamp(self.logOffset, 0, math.max(0, #lines - visible))
  local last = #lines - self.logOffset
  for i = 1, visible do
    local line = lines[last - visible + i]
    if line then
      local col = colors.white
      if line:find(" WARN ", 1, true) then col = ui:col("orange", colors.white) elseif line:find(" ERROR ", 1, true) then col = ui:col("red", colors.white) end
      ui:text(1, y1 + i - 1, util.fit(line, w), col)
    end
  end
  self.hint = "Wheel scrolls. " .. #lines .. " lines in " .. fs.combine(self.root, "data/log")
end

-- Input -------------------------------------------------------------------

function Console:onKey(code)
  local f = self.ui.focus
  if code == keys.escape then
    if self.picker then
      self.picker = nil
    elseif self.form then
      self.form, self.ui.focus = nil, nil
    elseif self.standalone and not f then
      self.running = false
    else
      self.ui.focus = nil
    end
  elseif code == keys.tab then
    self.ui:focusNext()
  elseif code == keys.enter then
    if self.form and self.form.fields and not self.picker then
      local last = self.form.fields[#self.form.fields]
      if f and last.f and f == last.f then self:saveForm() else self.ui:focusNext() end
    elseif f then
      self.ui.focus = nil
    end
  elseif f then
    UI.keyField(f, code)
  end
end

function Console:onChar(ch)
  if self.ui.focus then UI.charField(self.ui.focus, ch) end
end

function Console:scroll(dir)
  if self.picker then
    self.picker.offset = self.picker.offset + dir
  elseif self.page == "storage" then
    self.storageOffset = self.storageOffset + dir
  elseif self.page == "parcels" and not self.form then
    self.parcelOffset = self.parcelOffset + dir
  elseif self.page == "log" then
    self.logOffset = self.logOffset - dir
  end
end

-- Draws only after something that can change the picture: input, the
-- refresh timer, or a change in storage. Every other event on the computer
-- (the screens' chest polls, for one) passes through untouched.
function Console:run()
  self:refresh()
  local timer = os.startTimer(REFRESH)
  local due = os.clock() + REFRESH
  local dirty = true
  while self.running do
    if dirty then
      self:draw()
      dirty = false
    end
    local ev = { os.pullEvent() }
    local e = ev[1]
    if e == "mouse_click" then
      self.ui:tap(ev[3], ev[4])
      dirty = true
    elseif e == "mouse_scroll" then
      self:scroll(ev[2])
      dirty = true
    elseif e == "key" then
      self:onKey(ev[2])
      dirty = true
    elseif e == "char" then
      self:onChar(ev[2])
      dirty = true
    elseif e == "term_resize" then
      self.ui:resize()
      dirty = true
    elseif e == "warehouse_click" then
      -- a test hook: a click handed over by the service (debug.click),
      -- which reaches this tab even when it is not the focused one
      self.ui:tap(ev[2], ev[3])
      dirty = true
    elseif e == "timer" and (ev[2] == timer or os.clock() >= due) then
      if not self.form and not self.picker then self:refresh() end
      timer = os.startTimer(REFRESH)
      due = os.clock() + REFRESH
      dirty = true
    elseif e == "warehouse_event" and self.page == "status" then
      dirty = true
    end
  end
  self.ui:begin(colors.black)
  self.ui:finish()
  if self.target.setCursorPos then self.target.setCursorPos(1, 1) end
end

return Console
