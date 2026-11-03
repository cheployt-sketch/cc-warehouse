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
  local win = self.win
  win.setVisible(false)
  win.setBackgroundColor(bg or colors.black)
  win.setTextColor(colors.white)
  win.clear()
end

function UI:finish()
  self.win.setVisible(true)
  self.win.setVisible(false)
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

-- A five-row keyboard inside width w at (x, y). cb gets a character, or
-- "back", "clear" or "ok".
function UI:keyboard(x, y, w, cb)
  local keyBg = self:col("gray", colors.black)
  for r, row in ipairs(KEY_ROWS) do
    local rowW = #row * 2 - 1
    local x0 = x + math.max(0, math.floor((w - rowW) / 2))
    local yy = y + r - 1
    for i = 1, #row do
      local ch = row:sub(i, i)
      local kx = x0 + (i - 1) * 2
      self:text(kx, yy, ch, colors.white, keyBg)
      self:region(kx, yy, kx + 1, yy, function() cb(ch) end)
    end
  end
  local keys = { { "space", " " }, { "<-", "back" }, { "clear", "clear" }, { "OK", "ok" } }
  local total = -1
  for _, k in ipairs(keys) do total = total + #k[1] + 3 end
  local bx = x + math.max(0, math.floor((w - total) / 2))
  for _, k in ipairs(keys) do
    bx = self:button(bx, y + 4, k[1], function() cb(k[2]) end, { bg = k[2] == "ok" and self:col("green", colors.black) or keyBg }) + 1
  end
  return 5
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
