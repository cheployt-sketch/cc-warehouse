-- console: the control panel on the warehouse computer's own screen.
--
-- Pages: Status (what is stored, screens, network, and buttons to reload,
-- compact, rescan or stop), Screens (add, change, remove access points),
-- Storage (what counts as storage, with a button per inventory), Settings
-- (presets, lock time, rescan, hostname, rednet, log level, category
-- overrides, the pairing key) and Log. Everything is clicked; text fields
-- take typing, Tab moves on, Esc backs out.
--
-- Changes are written to the config file and applied to the running
-- service at once. The service shows this panel in its own tab; `warehouse
-- ui` opens it in any tab.

local util = require("lib.util")
local config = require("lib.config")
local category = require("lib.category")
local UI = require("lib.ui")

local Console = {}
Console.__index = Console

local PAGES = { { "status", "Status" }, { "screens", "Screens" }, { "storage", "Storage" }, { "settings", "Settings" }, { "log", "Log" } }
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

function Console:refresh()
  local ping, err = self:ask("ping")
  self.data.ping = ping
  self.data.down = ping == nil
  self.data.err = err
  if ping then
    self.data.stats = self:ask("stats") or self.data.stats
    self.data.access = self:ask("access") or self.data.access
    self.data.peripherals = self:ask("peripherals") or self.data.peripherals
  end
  local cfg = config.load(self.root)
  self.data.cfgBroken = cfg == nil
  self.data.cfg = cfg or self.data.cfg or config.defaultsFor(self.root)
  if not ping then self.data.peripherals = config.peripherals(self.data.cfg) end
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
    end, { bg = active and ui:col("blue", colors.black) or bar, fg = active and colors.white or ui:col("lightGray", colors.white) }) + 1
  end
  self.hint = ""
  local y1, y2 = 3, h - 1
  if self.picker then
    self:drawPicker(y1, y2)
  elseif self.form then
    self:drawForm(y1, y2)
  elseif self.page == "screens" then
    self:drawScreens(y1, y2)
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
    local s = live[ap.name or ap.monitor]
    local state = s and (s.up and (s.locked and "up,locked" or "up") or "DOWN") or "-"
    local name = tostring(ap.name or "?") .. (ap.pin and "*" or "")
    local line = " " .. util.fit(name, 9) .. " " .. util.fit(ap.chest or "", 19) .. " " .. util.fit(ap.monitor or "", 9) .. " " .. state
    ui:text(1, y, util.fit(line, w), (s and not s.up) and ui:col("red") or colors.white)
    ui:region(1, y, w, y, function() self:openScreenForm(i) end)
    y = y + 1
  end
  ui:button(2, y2, "Add screen", function() self:openScreenForm(nil) end, { bg = ui:col("green", colors.black) })
  self.hint = "Click a screen to change or remove it. *: has a PIN"
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
    if fd.cycle then
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
    local x = 13 + fd.w + 1
    if fd.pick then x = ui:button(x, y, "Pick", function() self:openPicker(fd) end) + 1 end
    if fd.hint then ui:text(x, y, util.fit(fd.hint, w - x + 1), ui:col("lightGray", colors.white)) end
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
  self.hint = "Click a field, type. Tab: next. Esc: cancel."
end

function Console:formValue(key)
  for _, fd in ipairs(self.form.fields) do
    if fd.key == key then return fd.cycle and fd.value or trim(fd.f.text) end
  end
end

function Console:saveForm()
  local form = self.form
  local cfg = self.data.cfg
  if form.kind == "screen" then
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

function Console:openPicker(fd)
  local items = {}
  if fd.pick == "inventory" then
    for _, p in ipairs(self.data.peripherals or {}) do
      items[#items + 1] = { label = util.fit(p.name, 28) .. util.rfit(p.size, 5) .. "  " .. p.role .. (p.access and (" " .. p.access) or ""), value = p.name }
    end
  else
    for _, m in ipairs(config.monitors()) do items[#items + 1] = { label = m, value = m } end
  end
  if #items == 0 then
    self:say("Nothing of that kind is on the network", true)
    return
  end
  self.picker = {
    title = "Pick a" .. (fd.pick == "inventory" and "n inventory" or " monitor"),
    items = items,
    offset = 0,
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
    ui:text(2, y, util.fit(it.label, w - 2))
    ui:region(1, y, w, y, function()
      pk.onPick(it.value)
      self.picker = nil
    end)
  end
  ui:button(2, y2, "Cancel", function() self.picker = nil end)
  self.hint = #pk.items > visible and "Scroll with the mouse wheel." or "Click one."
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
          cfg.storage.names = without(cfg.storage.names, p.name)
          self:apply(cfg, p.name .. " no longer storage")
        end
      else
        r.action = "Exclude"
        r.fn = function()
          cfg.storage.exclude = without(cfg.storage.exclude, p.name)
          table.insert(cfg.storage.exclude, p.name)
          self:apply(cfg, p.name .. " excluded")
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

function Console:logLines()
  local path = fs.combine(self.root, "data/log")
  if not fs.exists(path) then return {} end
  local h = fs.open(path, "r")
  local s = h.readAll()
  h.close()
  local lines = {}
  for line in s:gmatch("[^\n]+") do lines[#lines + 1] = line end
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
    if self.form and not self.picker then
      local last = self.form.fields[#self.form.fields]
      if f == last.f then self:saveForm() else self.ui:focusNext() end
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
  elseif self.page == "log" then
    self.logOffset = self.logOffset - dir
  end
end

function Console:run()
  self:refresh()
  local timer = os.startTimer(REFRESH)
  local due = os.clock() + REFRESH
  while self.running do
    self:draw()
    local ev = { os.pullEvent() }
    local e = ev[1]
    if e == "mouse_click" then
      self.ui:tap(ev[3], ev[4])
    elseif e == "mouse_scroll" then
      self:scroll(ev[2])
    elseif e == "key" then
      self:onKey(ev[2])
    elseif e == "char" then
      self:onChar(ev[2])
    elseif e == "term_resize" then
      self.ui:resize()
    elseif e == "timer" and (ev[2] == timer or os.clock() >= due) then
      if self.page ~= "log" and not self.form and not self.picker then self:refresh() end
      timer = os.startTimer(REFRESH)
      due = os.clock() + REFRESH
    end
  end
  self.ui:begin(colors.black)
  self.ui:finish()
  if self.target.setCursorPos then self.target.setCursorPos(1, 1) end
end

return Console
