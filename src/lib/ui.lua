-- lib.ui: drawing and tap targets for monitors (and terminals). Every frame
-- is drawn from scratch into an off-screen window and shown at once, so the
-- monitor never flickers. Tap targets are registered while drawing and
-- looked up by tap(x, y).

local util = require("lib.util")

local UI = {}
UI.__index = UI

function UI.new(target)
  local self = setmetatable({ target = target }, UI)
  self.color = target.isColor and target.isColor() or false
  self:resize()
  return self
end

function UI:resize()
  local w, h = self.target.getSize()
  self.w, self.h = w, h
  self.win = window.create(self.target, 1, 1, w, h, false)
  self.hits = {}
end

-- A colour, with a fallback for monochrome screens.
function UI:col(name, mono)
  if self.color then return colors[name] or colors.white end
  return mono or colors.white
end

function UI:begin(bg)
  self.hits = {}
  self.fields = {}
  self.cursorPos = nil
  local win = self.win
  win.setVisible(false)
  win.setBackgroundColor(bg or colors.black)
  win.setTextColor(colors.white)
  win.clear()
end

function UI:finish()
  self.win.setVisible(true)
  self.win.setVisible(false)
  local t = self.target
  if self.cursorPos and t.setCursorBlink then
    t.setCursorPos(self.cursorPos[1], self.cursorPos[2])
    t.setTextColor(self.color and colors.black or colors.white)
    t.setCursorBlink(true)
  elseif t.setCursorBlink then
    t.setCursorBlink(false)
  end
end

-- Text fields (for terminals). A field is { text, cursor }; clicking one
-- focuses it, and the owner feeds it key and char events with keyField /
-- charField.
function UI.newField(text, o)
  o = o or {}
  text = tostring(text == nil and "" or text)
  return { text = text, cursor = #text + 1, max = o.max, filter = o.filter }
end

function UI:field(x, y, w, f)
  self.fields[#self.fields + 1] = f
  f.cursor = util.clamp(f.cursor or (#f.text + 1), 1, #f.text + 1)
  local start = math.max(1, f.cursor - w + 1)
  local shown = f.text:sub(start, start + w - 1)
  local focused = self.focus == f
  if self.color then
    self:text(x, y, util.fit(shown, w), colors.black, focused and colors.white or colors.lightGray)
  else
    self:text(x, y, "[" .. util.fit(shown, w - 2) .. "]")
  end
  self:region(x, y, x + w - 1, y, function(cx)
    self.focus = f
    f.cursor = util.clamp(start + cx - 1, 1, #f.text + 1)
  end)
  if focused then self.cursorPos = { x + (f.cursor - start), y } end
end

function UI:focusNext()
  if #self.fields == 0 then return end
  local idx = 0
  for i, f in ipairs(self.fields) do
    if f == self.focus then idx = i end
  end
  self.focus = self.fields[idx % #self.fields + 1]
  self.focus.cursor = #self.focus.text + 1
end

-- Returns true when the key changed or moved within the field.
function UI.keyField(f, code)
  local n = #f.text
  if code == keys.backspace then
    if f.cursor > 1 then
      f.text = f.text:sub(1, f.cursor - 2) .. f.text:sub(f.cursor)
      f.cursor = f.cursor - 1
    end
  elseif code == keys.delete then
    f.text = f.text:sub(1, f.cursor - 1) .. f.text:sub(f.cursor + 1)
  elseif code == keys.left then
    f.cursor = math.max(1, f.cursor - 1)
  elseif code == keys.right then
    f.cursor = math.min(n + 1, f.cursor + 1)
  elseif code == keys.home then
    f.cursor = 1
  elseif code == keys["end"] then
    f.cursor = n + 1
  else
    return false
  end
  return true
end

function UI.charField(f, ch)
  if f.max and #f.text >= f.max then return end
  if f.filter and not ch:match(f.filter) then return end
  f.text = f.text:sub(1, f.cursor - 1) .. ch .. f.text:sub(f.cursor)
  f.cursor = f.cursor + 1
end

function UI:text(x, y, s, fg, bg)
  if y < 1 or y > self.h or x > self.w then return end
  s = tostring(s)
  if x < 1 then
    s = s:sub(2 - x)
    x = 1
  end
  if #s == 0 then return end
  if #s > self.w - x + 1 then s = s:sub(1, self.w - x + 1) end
  local win = self.win
  win.setCursorPos(x, y)
  win.setTextColor(fg or colors.white)
  win.setBackgroundColor(bg or colors.black)
  win.write(s)
end

function UI:fill(x, y, w, h, bg)
  if w <= 0 or h <= 0 then return end
  local line = string.rep(" ", w)
  for yy = y, y + h - 1 do self:text(x, yy, line, colors.white, bg) end
end

function UI:region(x1, y1, x2, y2, fn)
  self.hits[#self.hits + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, fn = fn }
end

-- A tappable label. o: w (width, default #label + 2), h, fg, bg, align
-- ("left", or centred). Returns the x after the button.
function UI:button(x, y, label, fn, o)
  o = o or {}
  local w = o.w or (#label + 2)
  local h = o.h or 1
  local bg = o.bg or self:col("gray", colors.black)
  local fg = o.fg or colors.white
  local s
  if not self.color then
    s = util.center("[" .. label .. "]", w)
  elseif o.align == "left" then
    s = " " .. util.fit(label, w - 1)
  else
    s = util.center(label, w)
  end
  local ty = y + math.floor((h - 1) / 2)
  for yy = y, y + h - 1 do
    self:text(x, yy, yy == ty and s or string.rep(" ", w), fg, bg)
  end
  self:region(x, y, x + w - 1, y + h - 1, fn)
  return x + w
end

-- Runs the handler of the topmost target under (x, y). Returns whether one was hit.
function UI:tap(x, y)
  for i = #self.hits, 1, -1 do
    local h = self.hits[i]
    if x >= h.x1 and x <= h.x2 and y >= h.y1 and y <= h.y2 then
      h.fn(x - h.x1 + 1, y - h.y1 + 1)
      return true
    end
  end
  return false
end

-- A bar filled to `frac`, with a label (default: the percentage) on top.
function UI:bar(x, y, w, frac, fg, bg, label)
  frac = util.clamp(frac or 0, 0, 1)
  label = label or (math.floor(frac * 100 + 0.5) .. "%")
  if self.color then
    local filled = math.floor(w * frac + 0.5)
    local s = util.center(label, w)
    self:text(x, y, s:sub(1, filled), colors.black, fg or colors.green)
    self:text(x + filled, y, s:sub(filled + 1), colors.white, bg or colors.gray)
  else
    local inner = math.max(1, w - #label - 3)
    local filled = math.floor(inner * frac + 0.5)
    self:text(x, y, "[" .. string.rep("#", filled) .. string.rep("-", inner - filled) .. "] " .. label)
  end
end

-- Splits buttons (each #label + 2 wide, 1 apart) into rows that fit width
-- w. Returns a list of rows; each row is a list of { label, w, index }.
function UI.wrap(labels, w)
  local rows, row, used = {}, {}, 0
  for i, label in ipairs(labels) do
    local bw = #label + 2
    if #row > 0 and used + 1 + bw > w then
      rows[#rows + 1] = row
      row, used = {}, 0
    end
    row[#row + 1] = { label = label, w = bw, index = i }
    used = used + bw + (#row > 1 and 1 or 0)
  end
  if #row > 0 then rows[#rows + 1] = row end
  return rows
end

local KEY_ROWS = { "1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm_-:" }

-- The rows a keyboard takes: four rows of keys and one of space, back,
-- clear and OK, each keyH high.
function UI.keyboardHeight(keyH) return 5 * (keyH or 1) end

-- A keyboard inside width w at (x, y). Keys are as wide as the width
-- allows (ten to a row, one column apart; the gap counts as the key on its
-- left when tapped) and o.keyH rows high (default 1), so they are easy to
-- hit on a small text scale. cb gets a character, or "back", "clear" or
-- "ok". Returns the rows used.
function UI:keyboard(x, y, w, cb, o)
  o = o or {}
  local keyH = o.keyH or 1
  local keyW = math.max(1, math.floor((w - 9) / 10))
  local keyBg = self:col("gray", colors.black)
  local labelRow = math.floor((keyH - 1) / 2)
  for r, row in ipairs(KEY_ROWS) do
    local rowW = #row * (keyW + 1) - 1
    local x0 = x + math.max(0, math.floor((w - rowW) / 2))
    local yy = y + (r - 1) * keyH
    for i = 1, #row do
      local ch = row:sub(i, i)
      local kx = x0 + (i - 1) * (keyW + 1)
      for dy = 0, keyH - 1 do
        self:text(kx, yy + dy, dy == labelRow and util.center(ch, keyW) or string.rep(" ", keyW), colors.white, keyBg)
      end
      self:region(kx, yy, kx + keyW, yy + keyH - 1, function() cb(ch) end)
    end
  end
  -- The bottom row spans a ten-key row; space takes what the others leave.
  local fullW = 10 * (keyW + 1) - 1
  local yb = y + 4 * keyH
  local bx = x + math.max(0, math.floor((w - fullW) / 2))
  local spaceW = math.max(7, fullW - (4 + 7 + 6 + 3))
  bx = self:button(bx, yb, "space", function() cb(" ") end, { w = spaceW, h = keyH, bg = keyBg }) + 1
  bx = self:button(bx, yb, "<-", function() cb("back") end, { w = 4, h = keyH, bg = keyBg }) + 1
  bx = self:button(bx, yb, "clear", function() cb("clear") end, { w = 7, h = keyH, bg = keyBg }) + 1
  self:button(bx, yb, "OK", function() cb("ok") end, { w = 6, h = keyH, bg = self:col("green", colors.black) })
  return 5 * keyH
end

-- A 3x4 number pad at (x, y). o: keyW (default 3), keyH (default 1).
-- cb gets a digit, "clear" or "back". Returns its width and height.
function UI:numpad(x, y, cb, o)
  o = o or {}
  local keyW, keyH = o.keyW or 3, o.keyH or 1
  local rows = { { "7", "8", "9" }, { "4", "5", "6" }, { "1", "2", "3" }, { "C", "0", "<" } }
  for r, row in ipairs(rows) do
    for c, ch in ipairs(row) do
      local bg, v = self:col("gray", colors.black), ch
      if ch == "C" then
        bg, v = self:col("red", colors.black), "clear"
      elseif ch == "<" then
        bg, v = self:col("orange", colors.black), "back"
      end
      self:button(x + (c - 1) * (keyW + 1), y + (r - 1) * keyH, ch, function() cb(v) end, { w = keyW, h = keyH, bg = bg })
    end
  end
  return keyW * 3 + 2, keyH * 4
end

-- The text on screen, one string per row (for tests).
function UI:lines()
  local out = {}
  for y = 1, self.h do out[y] = (self.win.getLine(y)) end
  return out
end

return UI
