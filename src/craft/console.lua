-- craft.console: the crafter's control panel on the computer's own screen.
--
-- Pages: Recipes (every recipe with its mode, what it made and what it is
-- doing; click one to change it: name, mode, rate, the steps, with Scan
-- buttons that read a step off the recipe chest, and Run, Order, Stop,
-- Remove), Setup (the turtle, the chests and the monitor, with pickers)
-- and Log. Everything is clicked; text fields take typing, Tab moves on,
-- Esc backs out. Changes apply to the running service at once.

local util = require("lib.util")
local UI = require("lib.ui")
local Recipes = require("craft.recipes")
local Engine = require("craft.engine")

local Console = {}
Console.__index = Console

local PAGES = { { "recipes", "Recipes" }, { "setup", "Setup" }, { "log", "Log" } }
local REFRESH = 2
local MSG_TIME = 8
local MAX_STEP_ROWS = 6

local STATE_COLORS = { running = "lime", waiting = "orange", learning = "yellow", problem = "red", queued = "lightBlue", idle = "white" }

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function ago(epochMs)
  if not epochMs then return "never" end
  local s = math.floor((os.epoch("utc") - epochMs) / 1000)
  if s < 60 then return s .. "s ago" end
  if s < 3600 then return math.floor(s / 60) .. "m ago" end
  return math.floor(s / 3600) .. "h ago"
end

local function copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = copy(v) end
  return out
end

-- opts: engine, vault, root, target (a terminal), standalone (shows Quit),
-- onConfig(cfg) (called when the setup was saved), log(msg)
function Console.new(opts)
  local self = setmetatable({}, Console)
  self.engine = opts.engine
  self.vault = opts.vault
  self.root = opts.root
  self.target = opts.target or term.current()
  self.standalone = opts.standalone
  self.onConfig = opts.onConfig
  self.ui = UI.new(self.target)
  self.page = "recipes"
  self.form, self.picker = nil, nil
  self.message, self.messageError, self.messageUntil = nil, false, 0
  self.hint = ""
  self.listOffset, self.logOffset = 0, 0
  self.running = true
  return self
end

function Console:say(msg, isError)
  self.message, self.messageError, self.messageUntil = msg, isError or false, os.clock() + MSG_TIME
end

function Console:stateColor(state)
  return self.ui:col(STATE_COLORS[state] or "white", colors.white)
end

-- Drawing ----------------------------------------------------------------

function Console:draw()
  local ui = self.ui
  local w, h = ui.w, ui.h
  ui:begin(colors.black)
  local bar = ui:col("gray", colors.black)
  local st = self.engine:status()
  self.status = st
  local t = st.turtle
  local turtle = t.state == "ready" and ("turtle #" .. tostring(t.id) .. " ok") or ("turtle " .. tostring(t.state))
  local right = turtle .. "  " .. st.active .. " active "
  ui:text(1, 1, util.fit(" Crafter", w), colors.white, bar)
  ui:text(w - #right + 1, 1, right, t.state == "ready" and colors.white or ui:col("orange"), bar)
  local x = 1
  for _, pg in ipairs(PAGES) do
    local active = self.page == pg[1]
    x = ui:button(x, 2, pg[2], function()
      self.page = pg[1]
      self.form, self.picker, self.ui.focus = nil, nil, nil
      if pg[1] == "log" then self.logOffset = 0 end
    end, { bg = active and ui:col("blue", colors.black) or bar, fg = active and colors.white or ui:col("lightGray", colors.white) })
  end
  self.hint = ""
  local y1, y2 = 3, h - 1
  if self.picker then
    self:drawPicker(y1, y2)
  elseif self.form then
    self:drawForm(y1, y2)
  elseif self.page == "setup" then
    self:drawSetup(y1, y2)
  elseif self.page == "log" then
    self:drawLog(y1, y2)
  else
    self:drawRecipes(y1, y2)
  end
  local showMsg = self.message and os.clock() < self.messageUntil
  ui:text(1, h, util.fit(" " .. (showMsg and self.message or self.hint), w), (showMsg and self.messageError) and ui:col("red") or colors.white, bar)
  ui:finish()
end

function Console:drawRecipes(y1, y2)
  local ui, w = self.ui, self.ui.w
  local list = self.status.recipes
  ui:text(1, y1, util.fit(" Name             Mode    Made    State", w), ui:col("yellow"))
  local visible = y2 - y1 - 1
  self.listOffset = util.clamp(self.listOffset, 0, math.max(0, #list - visible))
  if #list == 0 then
    ui:text(2, y1 + 1, "No recipes yet. Lay one out in the recipe chest,", ui:col("lightGray", colors.white))
    ui:text(2, y1 + 2, "then click 'New recipe' and 'Scan craft'.", ui:col("lightGray", colors.white))
  end
  for i = 1, visible do
    local s = list[i + self.listOffset]
    if not s then break end
    local y = y1 + i
    local mode = s.mode == "rate" and (tostring(s.rateCount) .. "/" .. tostring(s.rateSeconds) .. "s") or s.mode
    local line = " " .. util.fit(s.name, 16) .. " " .. util.fit(mode, 7) .. " " .. util.rfit(util.fmtCount(s.made, 6), 6) .. "  " .. s.text
    ui:text(1, y, util.fit(line, w), self:stateColor(s.state))
    ui:region(1, y, w, y, function() self:openRecipeForm(s.id) end)
  end
  local x = ui:button(2, y2, "New recipe", function() self:openRecipeForm(nil) end, { bg = ui:col("green", colors.black) }) + 1
  if self.standalone then ui:button(x, y2, "Quit", function() self.running = false end) end
  self.hint = "Click a recipe to change, run or stop it. Wheel scrolls."
end

-- The recipe form works on a copy; Save hands it to the engine.
function Console:openRecipeForm(id)
  local rec = id and self.engine:find(id)
  local r = rec and copy(rec) or { name = "", mode = "off", count = 1, steps = {} }
  self.form = {
    kind = "recipe",
    id = rec and rec.id or nil,
    rec = r,
    name = UI.newField(r.name, { max = 20 }),
    count = UI.newField(r.count or 1, { max = 5, filter = "%d" }),
    rateCount = UI.newField(r.rateCount or 64, { max = 6, filter = "%d" }),
    rateSeconds = UI.newField(r.rateSeconds or 600, { max = 6, filter = "%d" }),
    order = UI.newField("", { max = 6, filter = "%d" }),
    mode = r.mode or "off",
  }
  self.ui.focus = self.form.name
end

function Console:formRecipe()
  local f = self.form
  local r = f.rec
  r.name = trim(f.name.text)
  r.mode = f.mode
  r.count = tonumber(f.count.text) or 1
  r.rateCount = tonumber(f.rateCount.text) or 64
  r.rateSeconds = tonumber(f.rateSeconds.text) or 600
  return r
end

function Console:saveRecipe()
  local f = self.form
  local r = self:formRecipe()
  if r.name == "" then
    self:say("Give the recipe a name", true)
    return nil
  end
  local other = self.engine:find(r.name)
  if other and other.id ~= f.id then
    self:say("There is already a recipe called " .. r.name, true)
    return nil
  end
  local ok, res
  if f.id then
    ok, res = pcall(self.engine.update, self.engine, f.id, r)
  else
    ok, res = pcall(self.engine.add, self.engine, r)
  end
  if not ok then
    self:say(tostring(res), true)
    return nil
  end
  f.id = res.id
  f.rec = copy(res)
  self:say("Saved " .. res.name .. (Recipes.unlearned(res) and "; learning what it makes" or ""))
  return res
end

function Console:scanStep(kind)
  local step, err = self.engine:scan(kind)
  if not step then
    self:say(tostring(err), true)
    return
  end
  local steps = self.form.rec.steps
  steps[#steps + 1] = step
  self:say("Step " .. #steps .. ": " .. Recipes.describe(step) .. ". Save to keep it.")
end

function Console:drawForm(y1, y2)
  local ui, w = self.ui, self.ui.w
  local f = self.form
  local r = f.rec
  ui:text(1, y1, util.fit(" " .. (f.id and ("Recipe " .. r.name) or "New recipe"), w), ui:col("yellow"))
  local y = y1 + 1
  ui:text(2, y, "Name")
  ui:field(7, y, 18, f.name)
  ui:text(27, y, "Mode")
  ui:button(32, y, f.mode, function()
    local i = 1
    for k, m in ipairs(Recipes.MODES) do
      if m == f.mode then i = k end
    end
    f.mode = Recipes.MODES[i % #Recipes.MODES + 1]
  end, { w = 8 })
  ui:text(41, y, "Run x")
  ui:field(47, y, 4, f.count)
  y = y + 1
  ui:text(2, y, "Rate")
  ui:field(7, y, 7, f.rateCount)
  ui:text(15, y, "items every")
  ui:field(27, y, 7, f.rateSeconds)
  ui:text(35, y, "s  (mode rate)", ui:col("lightGray", colors.white))
  y = y + 1
  ui:text(2, y, "Steps", ui:col("yellow"))
  local x = ui:button(9, y, "Scan craft", function() self:scanStep("craft") end) + 1
  x = ui:button(x, y, "Scan smelt", function() self:scanStep("smelt") end) + 1
  ui:text(x, y, util.fit("adds what the recipe chest holds", w - x + 1), ui:col("lightGray", colors.white))
  y = y + 1
  if #r.steps == 0 then
    ui:text(3, y, "none yet: lay the first step out in the recipe chest and scan it", ui:col("lightGray", colors.white))
    y = y + 1
  end
  for i, step in ipairs(r.steps) do
    if i > MAX_STEP_ROWS then
      ui:text(3, y, "+" .. (#r.steps - MAX_STEP_ROWS) .. " more", ui:col("lightGray", colors.white))
      y = y + 1
      break
    end
    ui:text(2, y, util.fit(i .. ". " .. Recipes.describe(step), w - 15), step.result and colors.white or ui:col("orange"))
    local bx = w - 12
    bx = ui:button(bx, y, "^", function()
      if i > 1 then r.steps[i], r.steps[i - 1] = r.steps[i - 1], r.steps[i] end
    end, { w = 3 }) + 1
    bx = ui:button(bx, y, "v", function()
      if i < #r.steps then r.steps[i], r.steps[i + 1] = r.steps[i + 1], r.steps[i] end
    end, { w = 3 }) + 1
    ui:button(bx, y, "x", function() table.remove(r.steps, i) end, { w = 3, bg = ui:col("red", colors.black) })
    y = y + 1
  end
  if f.id then
    local s
    for _, e in ipairs(self.status.recipes) do
      if e.id == f.id then s = e end
    end
    if s then
      y = y + 1
      ui:text(2, y, util.fit("State: " .. s.text, w - 1), self:stateColor(s.state))
      y = y + 1
      ui:text(2, y, util.fit(string.format("Made %d, %d runs, %d crafts, %d smelted, %d errors, last run %s", s.made, s.runs, s.crafts, s.smelted, s.errors, ago(s.lastRun)), w - 1), ui:col("lightGray", colors.white))
      if s.lastMessage and s.state ~= "problem" then
        y = y + 1
        ui:text(2, y, util.fit("Last: " .. s.lastMessage, w - 1), ui:col("lightGray", colors.white))
      end
    end
  end
  -- Actions on the saved recipe.
  local ya = y2 - 1
  local bx = 2
  bx = ui:button(bx, ya, "Run", function()
    if not f.id then return self:say("Save the recipe first", true) end
    local ok, err = pcall(self.engine.runTimes, self.engine, f.id, tonumber(f.count.text) or 1)
    if ok then self:say("Running " .. r.name .. " " .. (tonumber(f.count.text) or 1) .. "x") else self:say(tostring(err), true) end
  end, { bg = ui:col("green", colors.black) }) + 1
  ui:text(bx, ya, "Order")
  ui:field(bx + 6, ya, 7, f.order)
  bx = ui:button(bx + 14, ya, "Go", function()
    if not f.id then return self:say("Save the recipe first", true) end
    local n = tonumber(f.order.text) or 0
    if n < 1 then return self:say("Type how many items to order", true) end
    local ok, err = pcall(self.engine.order, self.engine, f.id, n)
    if ok then
      self:say("Ordered " .. n)
      f.order.text, f.order.cursor = "", 1
    else
      self:say(tostring(err), true)
    end
  end, { bg = ui:col("cyan", colors.black) }) + 1
  bx = ui:button(bx, ya, "Stop", function()
    if not f.id then return self:say("Save the recipe first", true) end
    local ok, err = pcall(self.engine.stop, self.engine, f.id)
    if ok then
      f.mode = "off"
      self:say(r.name .. " stopped")
    else
      self:say(tostring(err), true)
    end
  end, { bg = ui:col("red", colors.black) }) + 1
  bx = 2
  bx = ui:button(bx, y2, "Save", function()
    if self:saveRecipe() then self.form, self.ui.focus = nil, nil end
  end, { bg = ui:col("green", colors.black) }) + 1
  bx = ui:button(bx, y2, "Cancel", function() self.form, self.ui.focus = nil, nil end) + 1
  if f.id then
    if self.confirmRemove and os.clock() < self.confirmRemove then
      ui:button(bx, y2, "Really remove", function()
        local ok, err = pcall(self.engine.remove, self.engine, f.id)
        self.confirmRemove = nil
        if ok then
          self.form, self.ui.focus = nil, nil
          self:say("Removed " .. r.name)
        else
          self:say(tostring(err), true)
        end
      end, { bg = ui:col("red", colors.black) })
    else
      ui:button(bx, y2, "Remove", function()
        self.confirmRemove = os.clock() + 5
        self:say("Click 'Really remove' to remove " .. r.name, true)
      end, { bg = ui:col("red", colors.black) })
    end
  end
  self.hint = "Scan reads the recipe chest's top left 3x3 (result in slot 9). Esc: back."
end

-- Setup ------------------------------------------------------------------

local SETUP = {
  { key = "turtle", label = "Turtle", pick = "turtle", hint = "the crafty turtle on the network" },
  { key = "input", label = "Input chest", pick = "inventory", hint = "the turtle takes from it" },
  { key = "output", label = "Output chest", pick = "inventory", hint = "the turtle drops into it (blank: input)" },
  { key = "recipeChest", label = "Recipe chest", pick = "inventory", hint = "where you lay recipes out" },
  { key = "smeltIn", label = "Smelter in", pick = "inventory", hint = "hoppers take from it" },
  { key = "smeltOut", label = "Smelter out", pick = "inventory", hint = "hoppers fill it" },
  { key = "monitor", label = "Monitor", pick = "monitor", hint = "blank: first free one" },
  { key = "scale", label = "Text scale", hint = "0.5 or 1, blank: auto", w = 5 },
  { key = "smeltStall", label = "Smelt stall", hint = "s without output = stalled", w = 5 },
}

function Console:setupFields()
  if self.setup then return self.setup end
  local cfg = self.engine.cfg
  local fields = {}
  for _, s in ipairs(SETUP) do
    fields[s.key] = UI.newField(cfg[s.key], { max = 40, filter = (s.key == "scale" and "[%d%.]") or (s.key == "smeltStall" and "%d") or nil })
  end
  self.setup = fields
  return fields
end

function Console:drawSetup(y1, y2)
  local ui, w = self.ui, self.ui.w
  local fields = self:setupFields()
  local y = y1
  for _, s in ipairs(SETUP) do
    ui:text(2, y, util.fit(s.label, 13))
    local fw = s.w or 24
    ui:field(15, y, fw, fields[s.key])
    local x = 15 + fw + 1
    if s.pick then x = ui:button(x, y, "Pick", function() self:openPicker(fields[s.key], s.pick) end) + 1 end
    ui:text(x, y, util.fit(s.hint, w - x + 1), ui:col("lightGray", colors.white))
    y = y + 1
  end
  y = y + 1
  local t = self.status.turtle
  local line = "Turtle: " .. tostring(t.state)
  if t.id then line = line .. " (#" .. tostring(t.id) .. (t.label and (" " .. t.label) or "") .. ")" end
  if t.msg then line = line .. ": " .. tostring(t.msg) end
  ui:text(2, y, util.fit(line, w - 1), t.state == "ready" and ui:col("lime") or ui:col("orange"))
  y = y + 1
  local sm = self.status.smelter
  ui:text(2, y, util.fit("Smelter: " .. (sm.set and (sm.items .. " items caught" .. (sm.lastAt and (", last " .. ago(sm.lastAt)) or "")) or "not set up"), w - 1), ui:col("lightGray", colors.white))
  ui:button(2, y2, "Save setup", function()
    local cfg = {}
    for _, s in ipairs(SETUP) do
      local v = trim(fields[s.key].text)
      if v == "" then
        cfg[s.key] = nil
      elseif s.key == "turtle" then
        cfg[s.key] = tonumber(v) or v
      elseif s.key == "scale" or s.key == "smeltStall" then
        cfg[s.key] = tonumber(v)
      else
        cfg[s.key] = v
      end
    end
    cfg.smeltStall = cfg.smeltStall or 300
    if cfg.output == cfg.input then cfg.output = nil end
    if not Engine.saveConfig(self.root, cfg) then return self:say("Could not write the config", true) end
    local full = Engine.loadConfig(self.root)
    self.engine:reconfigure(full)
    if self.onConfig then self.onConfig(full) end
    self:say("Setup saved and applied")
  end, { bg = ui:col("green", colors.black) })
  self.hint = "Pick inventories from the network. Save applies at once."
end

function Console:openPicker(field, kind)
  local items = {}
  if kind == "inventory" then
    local ok, list = pcall(self.vault.peripherals)
    for _, p in ipairs(ok and list or {}) do
      items[#items + 1] = { label = util.fit(p.name, 28) .. util.rfit(p.size, 5) .. "  " .. p.role .. (p.access and (" " .. p.access) or ""), value = p.name }
    end
  elseif kind == "monitor" then
    local used = {}
    local ok, cfg = pcall(self.vault.config)
    for _, ap in ipairs(ok and cfg.access or {}) do used[ap.monitor] = ap.name or ap.monitor end
    local names = peripheral.getNames()
    table.sort(names)
    for _, n in ipairs(names) do
      if peripheral.hasType(n, "monitor") then
        if used[n] then
          items[#items + 1] = { label = util.fit(n, 20) .. "  access screen " .. used[n] .. " (not available)", value = nil }
        else
          items[#items + 1] = { label = n, value = n }
        end
      end
    end
  else
    for _, n in ipairs(peripheral.getNames()) do
      if peripheral.hasType(n, "turtle") then
        local ok, id = pcall(peripheral.call, n, "getID")
        local ok2, label = pcall(peripheral.call, n, "getLabel")
        items[#items + 1] = { label = util.fit(n, 16) .. "  #" .. tostring(ok and id or "?") .. "  " .. tostring(ok2 and label or ""), value = n }
      end
    end
  end
  if #items == 0 then
    self:say("Nothing of that kind is on the network", true)
    return
  end
  self.picker = {
    title = "Pick a " .. kind .. " (Esc: back)",
    items = items,
    offset = 0,
    onPick = function(v)
      if v == nil then return self:say("That monitor belongs to an access point", true) end
      field.text, field.cursor = v, #v + 1
    end,
  }
end

function Console:drawPicker(y1, y2)
  local ui, w = self.ui, self.ui.w
  local pk = self.picker
  ui:text(1, y1, util.fit(" " .. pk.title, w), ui:col("yellow"))
  local visible = y2 - y1 - 1
  pk.offset = util.clamp(pk.offset, 0, math.max(0, #pk.items - visible))
  for i = 1, visible do
    local it = pk.items[i + pk.offset]
    if not it then break end
    local y = y1 + i
    ui:text(2, y, util.fit(it.label, w - 2), it.value == nil and ui:col("lightGray", colors.white) or colors.white)
    ui:region(1, y, w, y, function()
      pk.onPick(it.value)
      if it.value ~= nil then self.picker = nil end
    end)
  end
  ui:button(2, y2, "Cancel", function() self.picker = nil end)
  self.hint = #pk.items > visible and "Scroll with the mouse wheel." or "Click one."
end

-- Log ----------------------------------------------------------------------

function Console:logLines()
  local path = fs.combine(self.root, "data/crafter/log")
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
    if line then ui:text(1, y1 + i - 1, util.fit(line, w)) end
  end
  self.hint = "Wheel scrolls. " .. #lines .. " lines."
end

-- Input --------------------------------------------------------------------

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
    if f then self.ui:focusNext() end
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
  elseif self.page == "recipes" and not self.form then
    self.listOffset = self.listOffset + dir
  elseif self.page == "log" then
    self.logOffset = self.logOffset - dir
  end
end

function Console:screenLines() return self.ui:lines() end

function Console:run()
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
    elseif e == "crafter_click" then
      -- a test hook: a click handed over by the service
      self.ui:tap(ev[2], ev[3])
      dirty = true
    elseif e == "crafter_changed" then
      dirty = true
    elseif e == "timer" and (ev[2] == timer or os.clock() >= due) then
      timer = os.startTimer(REFRESH)
      due = os.clock() + REFRESH
      dirty = true
    end
  end
  self.ui:begin(colors.black)
  self.ui:finish()
  if self.target.setCursorPos then self.target.setCursorPos(1, 1) end
end

return Console
