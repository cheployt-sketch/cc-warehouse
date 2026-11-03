-- lib.access: one access point, a chest and a monitor on the network.
--
-- Everything you tap sits at the bottom of the screen: the page and sort
-- buttons, the category row, the search box (with its keyboard above it).
-- The list of what is stored fills the space above. When the chest holds
-- something, a chest panel slides in above the controls with a button per
-- stack and one for everything; the list stays visible, so you keep
-- picking. Tapping an item opens the amount panel in the same place, with
-- big preset, stack and number-pad buttons. Wide monitors show the list on
-- the left and, on the right, the stats with the chest panel (or amount
-- panel) at the bottom.
--
-- With a pin in its config the screen locks: after lockAfter seconds
-- without taps, or only when Lock is tapped if lockAfter is 0.

local util = require("lib.util")
local UI = require("lib.ui")
local category = require("lib.category")

local Access = {}
Access.__index = Access

local POLL = 0.3 -- seconds between reads of the chest
local MSG_TIME = 6 -- seconds a status message stays
local WIDE = 57
local CATEGORIES = { "all", "recent", "block", "item", "resource", "unstackable" }

-- cfg: { name, chest, monitor, scale?, pin?, lockAfter? }; global: the
-- service config (presets, lockAfter).
function Access.new(service, cfg, global)
  local self = setmetatable({}, Access)
  self.service = service
  self.index = service.index
  self.cfg = cfg
  self.global = global or {}
  self.name = cfg.name or cfg.monitor
  self.tab = "items"
  self.category = "all"
  self.search = ""
  self.page = 1
  self.sort = "count"
  self.keyboard = false
  self.dialog = nil
  self.chest = {}
  self.chestSig = nil
  self.chestMissing = false
  self.message = nil
  self.messageError = false
  self.messageUntil = 0
  self.drawnVersion = -1
  self.drawnLocked = nil
  self.ok = false
  self.unlockedUntil = 0
  self.pinEntry = ""
  self.pinFailUntil = 0
  return self
end

function Access:hasPin()
  return self.cfg.pin ~= nil and tostring(self.cfg.pin) ~= ""
end

function Access:lockAfter()
  local n = tonumber(self.cfg.lockAfter)
  if n == nil then n = tonumber(self.global.lockAfter) or 120 end
  return n
end

function Access:isLocked()
  return self:hasPin() and os.clock() > self.unlockedUntil
end

-- Activity keeps the screen unlocked (when it relocks by itself at all).
function Access:touch()
  if self:hasPin() and self:lockAfter() > 0 then self.unlockedUntil = os.clock() + self:lockAfter() end
end

function Access:unlock()
  local after = self:lockAfter()
  self.unlockedUntil = after > 0 and (os.clock() + after) or math.huge
end

function Access:say(msg, isError)
  self.message = msg
  self.messageError = isError or false
  self.messageUntil = os.clock() + MSG_TIME
end

function Access:attach()
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

-- Re-reads the chest. Returns true when its contents changed.
function Access:refreshChest()
  local ok, list = pcall(peripheral.call, self.cfg.chest, "list")
  if not ok or type(list) ~= "table" then
    if not self.chestMissing then
      self.chest, self.chestSig, self.chestMissing = {}, nil, true
      return true
    end
    return false
  end
  self.chestMissing = false
  local slots = {}
  for slot in pairs(list) do slots[#slots + 1] = slot end
  table.sort(slots)
  local items, sig = {}, {}
  for _, slot in ipairs(slots) do
    local it = list[slot]
    local key = util.keyOf(it.name, it.nbt)
    local d = self.index:detail(key)
    items[#items + 1] = { slot = slot, key = key, name = it.name, count = it.count, displayName = d.displayName, category = d.category }
    sig[#sig + 1] = slot .. "=" .. key .. "x" .. it.count
  end
  local s = table.concat(sig, ";")
  if s == self.chestSig then return false end
  self.chest, self.chestSig = items, s
  return true
end

function Access:catColor(cat)
  return self.ui:col(category.COLORS[cat] or "white", colors.white)
end

function Access:draw()
  if not self.ok then return end
  local ui = self.ui
  local locked = self:isLocked()
  local ok, err = pcall(function()
    ui:begin(colors.black)
    self.wide = ui.w >= WIDE
    if locked then
      self:drawLock()
    elseif self.wide then
      self:drawWide()
    else
      self:drawNarrow()
    end
    ui:finish()
  end)
  if not ok then
    self.ok = false
    self.service.log.warn("screen " .. self.name .. ": " .. tostring(err))
  end
  self.drawnVersion = self.index.version
  self.drawnLocked = locked
end

-- Row 1: name, totals and fill, or the current message.
function Access:drawHeader(x, w)
  local ui = self.ui
  local bg = ui:col("gray", colors.black)
  if self.message and os.clock() < self.messageUntil then
    ui:text(x, 1, util.fit(" " .. self.message, w), self.messageError and ui:col("red") or ui:col("lime"), bg)
    return
  end
  local st = self.index.totals
  local pct = st.slots > 0 and math.floor(st.used / st.slots * 100 + 0.5) or 0
  local s = " " .. self.name .. "  " .. util.fmtCount(st.items, 7) .. " items  " .. pct .. "% full"
  ui:text(x, 1, util.fit(s, w), pct >= 90 and ui:col("red") or colors.white, bg)
end

-- The bottom control block: search row, category rows and the pager row.
-- Draws them bottom-up ending at row y2 and returns the first row used.
function Access:drawControls(x, w, y2)
  local ui = self.ui
  local y = y2
  -- pager row: < p/n >  sort  [Stats]  [Lock]
  local items, total = self:listItems()
  local rows = self.listRows or 1
  local pages = math.max(1, math.ceil(total / rows))
  if self.page > pages then self.page = pages end
  local right = x + w
  if self:hasPin() then
    right = right - 6
    ui:button(right, y, "Lock", function() self.unlockedUntil = 0 end)
  end
  if not self.wide then
    local label = self.tab == "stats" and "List" or "Stats"
    right = right - (#label + 2) - 1
    ui:button(right, y, label, function()
      self.tab = self.tab == "stats" and "items" or "stats"
      self.dialog = nil
    end, { bg = self.tab == "stats" and ui:col("blue", colors.black) or nil })
  end
  local sortLabel = self.sort == "count" and "Qty" or "A-Z"
  right = right - (#sortLabel + 2) - 1
  ui:button(right, y, sortLabel, function()
    self.sort = self.sort == "count" and "name" or "count"
    self.page = 1
  end)
  local pageS = " " .. self.page .. "/" .. pages .. " "
  if x + 3 + #pageS + 3 > right then pageS = self.page .. "/" .. pages end
  local bx = ui:button(x, y, "<", function() if self.page > 1 then self.page = self.page - 1 end end, { w = 3 })
  ui:text(bx, y, pageS)
  ui:button(bx + #pageS, y, ">", function() if self.page < pages then self.page = self.page + 1 end end, { w = 3 })
  y = y - 1
  -- category rows
  local labels = {}
  for i, cat in ipairs(CATEGORIES) do labels[i] = category.LABELS[cat] end
  local catRows = UI.wrap(labels, w)
  y = y - #catRows + 1
  for r, row in ipairs(catRows) do
    local used = -1
    for _, b in ipairs(row) do used = used + b.w + 1 end
    local bx2 = x + math.max(0, math.floor((w - used) / 2))
    for _, b in ipairs(row) do
      local cat = CATEGORIES[b.index]
      local active = self.category == cat
      bx2 = ui:button(bx2, y + r - 1, b.label, function()
        self.category = cat
        self.page = 1
        self.tab = "items"
      end, { bg = active and ui:col("blue", colors.black) or nil, fg = active and colors.white or self:catColor(cat) }) + 1
    end
  end
  y = y - 1
  -- search row
  local fieldW = w - 4
  local shown = self.search
  if shown == "" and not self.keyboard then shown = "Search..." end
  if self.keyboard then shown = shown .. "_" end
  local placeholder = self.search == "" and not self.keyboard
  if ui.color then
    ui:text(x, y, util.fit(" " .. shown, fieldW), placeholder and colors.lightGray or colors.white, self.keyboard and colors.blue or colors.gray)
  else
    ui:text(x, y, "[" .. util.fit(shown, fieldW - 2) .. "]")
  end
  ui:region(x, y, x + fieldW - 1, y, function() self.keyboard = not self.keyboard end)
  ui:button(x + fieldW + 1, y, "x", function()
    self.search = ""
    self.page = 1
    self.keyboard = false
  end, { w = 3, bg = ui:col("red", colors.black) })
  if self.keyboard then
    y = y - 5
    ui:keyboard(x, y, w, function(ch) self:onKey(ch) end)
  end
  return y
end

function Access:listItems()
  return self.index:list({ filter = self.search, category = self.category, sort = self.sort })
end

-- How many rows the chest panel wants, given `free` rows above the controls.
function Access:chestHeight(free)
  if self.chestMissing then return 2 end
  if #self.chest == 0 then return self.wide and 3 or 0 end
  local maxRows = math.max(1, math.floor((free - 1) / 3))
  if self.wide then maxRows = math.max(maxRows, math.min(#self.chest, 8)) end
  return 1 + math.min(#self.chest, maxRows)
end

function Access:dialogHeight(free)
  local keyH = (free >= 17) and 2 or 1
  return 5 + 4 * keyH, keyH
end

function Access:drawNarrow()
  local ui = self.ui
  local w, h = ui.w, ui.h
  self:drawHeader(1, w)
  -- bottom-up: controls, keyboard, then the chest or amount panel
  local rows = h - 1 - 4 - (self.keyboard and 5 or 0)
  self.listRows = math.max(1, rows - (self.dialog and 9 or (#self.chest > 0 and 3 or 0)))
  local top = self:drawControls(1, w, h)
  local free = top - 2 -- rows between the header and the controls
  if self.dialog then
    local dh, keyH = self:dialogHeight(free)
    dh = math.min(dh, math.max(1, free - 1))
    self:drawDialog(1, top - dh, w, dh, keyH)
    top = top - dh
  elseif #self.chest > 0 or self.chestMissing then
    local ch = math.min(self:chestHeight(free), math.max(1, free - 1))
    self:drawChest(1, top - ch, w, ch)
    top = top - ch
  end
  local y1, y2 = 2, top - 1
  if y2 < y1 then y2 = y1 end
  if self.tab == "stats" then self:drawStats(1, y1, w, y2) else self:drawItems(1, y1, w, y2) end
end

function Access:drawWide()
  local ui = self.ui
  local w, h = ui.w, ui.h
  local lw = math.floor(w * 0.55)
  local rx, rw = lw + 2, w - lw - 1
  self:drawHeader(1, w)
  for y = 2, h do ui:text(lw + 1, y, " ", colors.white, ui:col("gray", colors.black)) end
  self.listRows = math.max(1, h - 1 - 4 - (self.keyboard and 5 or 0))
  local top = self:drawControls(1, lw, h)
  self:drawItems(1, 2, lw, top - 1)
  -- right column: chest or amount panel at the bottom, stats above
  local free = h - 1
  local bottom
  if self.dialog then
    local dh, keyH = self:dialogHeight(free)
    self:drawDialog(rx, h - dh + 1, rw, dh, keyH)
    bottom = h - dh
  else
    local ch = self:chestHeight(free)
    self:drawChest(rx, h - ch + 1, rw, ch)
    bottom = h - ch
  end
  if bottom - 1 >= 3 then self:drawStats(rx, 2, rw, bottom - 1) end
end

function Access:drawItems(x, y1, w, y2)
  local ui = self.ui
  local rows = y2 - y1 + 1
  if rows < 1 then return end
  self.listRows = rows
  local items, total = self:listItems()
  local pages = math.max(1, math.ceil(total / rows))
  if self.page > pages then self.page = pages end
  local first = (self.page - 1) * rows
  for i = 1, rows do
    local it = items[first + i]
    if it then
      local yy = y1 + i - 1
      local countS = util.fmtCount(it.count, 6)
      local name = it.displayName
      if it.nbt then name = name .. "*" end
      ui:text(x, yy, util.fit(name, w - #countS - 1), self:catColor(it.category))
      ui:text(x + w - #countS, yy, countS, ui:col("lightGray", colors.white))
      ui:region(x, yy, x + w - 1, yy, function() self:openDialog(it) end)
    end
  end
  if total == 0 then
    local msg = "Storage is empty."
    if self.search ~= "" then
      msg = "No item matches."
    elseif self.category == "recent" then
      msg = "Nothing moved yet."
    elseif self.category ~= "all" then
      msg = "No " .. category.LABELS[self.category]:lower() .. " stored."
    end
    ui:text(x, y1, util.fit(msg, w), ui:col("lightGray", colors.white))
  end
end

function Access:onKey(ch)
  if ch == "back" then
    self.search = self.search:sub(1, -2)
  elseif ch == "clear" then
    self.search = ""
  elseif ch == "ok" then
    self.keyboard = false
  elseif #self.search < 24 then
    self.search = self.search .. ch
  end
  self.page = 1
end

function Access:openDialog(it)
  self.dialog = { key = it.key, displayName = it.displayName, max = it.maxCount or 64, amount = "", category = it.category }
  self.keyboard = false
end

-- The amount panel: title, presets, stack multiples, the amount, a number
-- pad on the left and Get / Stack / All / Cancel on the right. The pad and
-- the buttons share the width, so every key is a big target.
function Access:drawDialog(x, y, w, h, keyH)
  local ui = self.ui
  local d = self.dialog
  local avail = self.index:count(d.key)
  local bg = ui:col("black", colors.black)
  ui:fill(x, y, w, h, bg)
  ui:text(x, y, util.fit(" " .. d.displayName, w - 4), self:catColor(d.category), ui:col("gray", colors.black))
  ui:button(x + w - 3, y, "x", function() self.dialog = nil end, { w = 3, bg = ui:col("red", colors.black) })
  ui:text(x, y + 1, util.fit(" In storage: " .. avail .. "  stack " .. d.max, w), ui:col("lightGray", colors.white))
  local function presetRow(yy, values)
    local n = #values
    local bw = math.floor((w - (n - 1)) / n)
    local bx = x
    for i, v in ipairs(values) do
      local label = util.fmtCount(v, bw)
      ui:button(bx, yy, label, function() d.amount = tostring(v) end, { w = bw })
      bx = bx + bw + 1
      if i == n then break end
    end
  end
  presetRow(y + 2, self.global.presets or { 1, 4, 8, 16, 32 })
  if d.max > 1 then
    local stacks = {}
    for _, n in ipairs(self.global.stackPresets or { 1, 2, 4, 8, 16 }) do stacks[#stacks + 1] = n * d.max end
    presetRow(y + 3, stacks)
  end
  ui:text(x, y + 4, " Amount:")
  ui:text(x + 9, y + 4, util.fit(d.amount == "" and "_" or d.amount, w - 9), colors.white, ui:col("blue", colors.black))
  local inner = w - 2
  local numW = math.floor(inner * 0.55)
  local keyW = math.max(1, math.floor((numW - 2) / 3))
  numW = keyW * 3 + 2
  local amount = tonumber(d.amount) or 0
  ui:numpad(x + 1, y + 5, function(k)
    if k == "clear" then
      d.amount = ""
    elseif k == "back" then
      d.amount = d.amount:sub(1, -2)
    elseif #d.amount < 7 then
      d.amount = (d.amount == "0" and "" or d.amount) .. k
    end
  end, { keyW = keyW, keyH = keyH })
  local bx = x + 1 + numW + 1
  local bw = math.max(4, inner - numW - 1)
  ui:button(bx, y + 5, "Get", function() self:doWithdraw(amount) end, { w = bw, h = keyH, bg = ui:col("green", colors.black) })
  ui:button(bx, y + 5 + keyH, "Stack", function() self:doWithdraw(d.max) end, { w = bw, h = keyH })
  ui:button(bx, y + 5 + keyH * 2, "All", function() self:doWithdraw(avail) end, { w = bw, h = keyH, bg = ui:col("cyan", colors.black) })
  ui:button(bx, y + 5 + keyH * 3, "Cancel", function() self.dialog = nil end, { w = bw, h = keyH, bg = ui:col("red", colors.black) })
end

function Access:doWithdraw(n)
  local d = self.dialog
  if not d then return end
  n = math.floor(tonumber(n) or 0)
  if n < 1 then
    self:say("Pick an amount first", true)
    return
  end
  local ok, res = self.service:request("withdraw", { item = d.key, count = n, to = self.cfg.chest })
  if not ok then
    self:say("Error: " .. tostring(res), true)
    return
  end
  if res.moved == 0 then
    self:say("Nothing moved: " .. tostring(res.message or "chest full?"), true)
  elseif res.moved < n then
    self:say("Chest full: got " .. res.moved .. " of " .. n, true)
    self.dialog = nil
  else
    self:say("Got " .. res.moved .. " " .. d.displayName)
    self.dialog = nil
  end
  self:refreshChest()
end

-- The chest panel: a title with the Store-all button, then a row per stack
-- with its own store button.
function Access:drawChest(x, y, w, h)
  local ui = self.ui
  if h < 1 then return end
  local total = 0
  for _, it in ipairs(self.chest) do total = total + it.count end
  local rows = h - 1
  local hidden = #self.chest - rows
  local title
  if self.chestMissing then
    title = " Chest " .. self.cfg.chest .. " not found"
  elseif #self.chest == 0 then
    title = " Chest: empty"
  elseif hidden > 0 then
    title = " Chest: " .. total .. " +" .. hidden .. " more"
  else
    title = " Chest: " .. total .. " items"
  end
  ui:text(x, y, util.fit(title, w), colors.white, ui:col("gray", colors.black))
  if #self.chest > 0 then
    local label = w >= 32 and "Store all" or "Store"
    ui:button(x + w - #label - 2, y, label, function() self:storeAll() end, { bg = ui:col("green", colors.black) })
  elseif not self.chestMissing then
    ui:text(x, y + 1, util.fit(" Put items in the chest", w), ui:col("lightGray", colors.white))
    ui:text(x, y + 2, util.fit(" to store them.", w), ui:col("lightGray", colors.white))
    return
  end
  for i = 1, math.min(#self.chest, rows) do
    local it = self.chest[i]
    local yy = y + i
    ui:text(x, yy, util.rfit(it.count, 4) .. " " .. util.fit(it.displayName, w - 9), self:catColor(it.category))
    ui:button(x + w - 3, yy, ">", function() self:storeSlot(it) end, { w = 3, bg = ui:col("green", colors.black) })
  end
end

local function reportDeposit(self, res, what)
  if res.moved == 0 then
    self:say("Nothing stored: " .. tostring(res.message or "?"), true)
  elseif res.message then
    self:say("Stored " .. res.moved .. " (" .. res.message .. ")", true)
  else
    self:say("Stored " .. res.moved .. " " .. what)
  end
end

function Access:storeAll()
  local ok, res = self.service:request("deposit", { from = self.cfg.chest })
  if ok then reportDeposit(self, res, "items") else self:say("Error: " .. tostring(res), true) end
  self:refreshChest()
end

function Access:storeSlot(it)
  local ok, res = self.service:request("deposit", { from = self.cfg.chest, slot = it.slot })
  if ok then reportDeposit(self, res, it.displayName) else self:say("Error: " .. tostring(res), true) end
  self:refreshChest()
end

function Access:drawStats(x, y1, w, y2)
  local ui = self.ui
  local st = self.index:stats()
  local y = y1
  local frac = st.slots > 0 and st.used / st.slots or 0
  local barCol = ui:col(frac > 0.9 and "red" or frac > 0.7 and "orange" or "green")
  ui:text(x, y, "Fill")
  ui:bar(x + 5, y, w - 5, frac, barCol, ui:col("gray"))
  y = y + 1
  if y > y2 then return end
  ui:text(x, y, util.fit("Slots " .. st.used .. "/" .. st.slots .. "  free " .. st.free, w))
  y = y + 1
  if y > y2 then return end
  ui:text(x, y, util.fit("Items " .. st.items .. "  kinds " .. st.types, w))
  y = y + 2
  if y <= y2 then
    ui:text(x, y, util.fit("Storage (" .. #st.inventories .. ")", w), ui:col("yellow"))
    y = y + 1
    for _, inv in ipairs(st.inventories) do
      if y > y2 then break end
      local f = inv.size > 0 and inv.used / inv.size or 0
      ui:text(x, y, util.fit(util.shortName(inv.name), w - 12))
      ui:bar(x + w - 11, y, 11, f, ui:col(f > 0.9 and "red" or "green"), ui:col("gray"))
      y = y + 1
    end
  end
  y = y + 1
  if y < y2 then
    ui:text(x, y, "Top items", ui:col("yellow"))
    y = y + 1
    local items = self.index:list({ sort = "count", limit = y2 - y + 1 })
    for _, it in ipairs(items) do
      ui:text(x, y, util.rfit(util.fmtCount(it.count, 6), 6) .. " ")
      ui:text(x + 7, y, util.fit(it.displayName, w - 7), self:catColor(it.category))
      y = y + 1
    end
  end
end

-- The lock screen: the pad sits low on the screen, like every other control.
function Access:drawLock()
  local ui = self.ui
  local w, h = ui.w, ui.h
  local keyW = w >= 23 and 5 or 3
  local keyH = h >= 20 and 2 or 1
  local padW, padH = keyW * 3 + 2, keyH * 4
  local y = math.max(5, h - padH - 3)
  ui:text(1, y - 4, util.center(self.name .. " warehouse", w), ui:col("yellow"))
  local failed = os.clock() < self.pinFailUntil
  ui:text(1, y - 3, util.center(failed and "Wrong PIN" or "Enter PIN", w), failed and ui:col("red") or colors.white)
  ui:text(1, y - 2, util.center(string.rep("*", #self.pinEntry) .. "_", w))
  local px = math.max(1, math.floor((w - padW) / 2) + 1)
  ui:numpad(px, y, function(k) self:onPinKey(k) end, { keyW = keyW, keyH = keyH })
  ui:button(px, y + padH + 1, "OK", function() self:tryPin() end, { w = padW, bg = ui:col("green", colors.black) })
end

function Access:onPinKey(k)
  if os.clock() < self.pinFailUntil then return end
  if k == "clear" then
    self.pinEntry = ""
  elseif k == "back" then
    self.pinEntry = self.pinEntry:sub(1, -2)
  elseif #self.pinEntry < 12 then
    self.pinEntry = self.pinEntry .. k
    if #self.pinEntry == #tostring(self.cfg.pin) then self:tryPin() end
  end
end

function Access:tryPin()
  if self.pinEntry == tostring(self.cfg.pin) then
    self.pinEntry = ""
    self:unlock()
    self.service.log.info("screen " .. self.name .. " unlocked")
  else
    self.pinEntry = ""
    self.pinFailUntil = os.clock() + 3
    self.service.log.warn("screen " .. self.name .. ": wrong PIN")
  end
end

function Access:screenLines()
  if not self.ok then return nil end
  return self.ui:lines()
end

function Access:run()
  while true do
    local ok, err = self:attach()
    if ok then
      self:loop()
    else
      self.service.log.warn("screen " .. self.name .. ": " .. tostring(err) .. "; retrying in 5 s")
      sleep(5)
    end
  end
end

function Access:armPoll()
  self.poll = os.startTimer(POLL)
  self.pollDue = os.clock() + POLL
end

-- Reads the chest and redraws when anything changed: the chest, storage,
-- the lock, or a message that ran out.
function Access:tick()
  self:armPoll()
  local changed = self:refreshChest()
  if self.message and os.clock() > self.messageUntil then
    self.message = nil
    changed = true
  end
  if self.pinFailUntil > 0 and os.clock() > self.pinFailUntil then
    self.pinFailUntil = 0
    changed = true
  end
  if changed or self.index.version ~= self.drawnVersion or self:isLocked() ~= self.drawnLocked then self:draw() end
end

-- While this coroutine waits on the service (a tap that moves items) or
-- on an inventory read, events that arrive are not delivered to it, so a
-- poll timer can be lost. The loop arms a fresh timer after every tap and
-- treats any timer event that comes once a poll is overdue as its own.
function Access:loop()
  self:refreshChest()
  self:draw()
  self:armPoll()
  while self.ok do
    local ev = { os.pullEvent() }
    local e = ev[1]
    if e == "monitor_touch" and ev[2] == self.cfg.monitor then
      -- A tap is activity (it keeps the screen unlocked); count it before
      -- the tap runs, so that the Lock button can still lock.
      if not self:isLocked() then self:touch() end
      self.ui:tap(ev[3], ev[4])
      self:draw()
      self:armPoll()
    elseif e == "monitor_resize" and ev[2] == self.cfg.monitor then
      self.ui:resize()
      self:draw()
    elseif e == "timer" and (ev[2] == self.poll or os.clock() >= self.pollDue) then
      self:tick()
    elseif e == "warehouse_event" then
      if not self:isLocked() and self.index.version ~= self.drawnVersion then self:draw() end
    elseif (e == "peripheral_detach" or e == "peripheral") and ev[2] == self.cfg.monitor then
      self.ok = false
    end
  end
end

return Access
