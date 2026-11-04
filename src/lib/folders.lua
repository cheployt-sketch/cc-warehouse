-- lib.folders: folders for the lists of Parcel tasks and crafter recipes,
-- so that long lists stay easy to go through. An entry is in a folder
-- when its `folder` field names one. A list keeps the folders it declared
-- (so empty ones survive); together with the names its entries use, they
-- are the folders shown.

local F = {}

F.MAX = 16 -- characters in a folder name

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- A cleaned folder name, or nil and why.
function F.clean(name)
  name = trim(name)
  if name == "" then return nil, "Give the folder a name" end
  if #name > F.MAX then return nil, "A folder name is at most " .. F.MAX .. " characters" end
  return name
end

-- Every folder: the declared ones, then those entries name, each once.
function F.names(declared, entries)
  local out, seen = {}, {}
  for _, n in ipairs(declared or {}) do
    if not seen[n] then
      seen[n] = true
      out[#out + 1] = n
    end
  end
  for _, e in ipairs(entries or {}) do
    local n = e.folder
    if type(n) == "string" and n ~= "" and not seen[n] then
      seen[n] = true
      out[#out + 1] = n
    end
  end
  return out
end

-- The folder with this name, spelled as it exists (case does not matter),
-- or the cleaned name for a new one; nil for none.
function F.resolve(declared, entries, name)
  local n = F.clean(name)
  if not n then return nil end
  for _, have in ipairs(F.names(declared, entries)) do
    if have:lower() == n:lower() then return have end
  end
  return n
end

-- What a list shows. At the top level: the folders, each with how many
-- entries it holds, and the entries in no folder. Inside folder `open`:
-- its entries. Entries come with their position in the whole list.
function F.view(declared, entries, open)
  local folders, items = {}, {}
  if open then
    for i, e in ipairs(entries or {}) do
      if e.folder == open then items[#items + 1] = { entry = e, index = i } end
    end
    return { folders = folders, items = items }
  end
  local count = {}
  for _, n in ipairs(F.names(declared, entries)) do
    count[n] = 0
    folders[#folders + 1] = { name = n, count = 0 }
  end
  for i, e in ipairs(entries or {}) do
    if type(e.folder) == "string" and count[e.folder] then
      count[e.folder] = count[e.folder] + 1
    else
      items[#items + 1] = { entry = e, index = i }
    end
  end
  for _, f in ipairs(folders) do f.count = count[f.name] end
  return { folders = folders, items = items }
end

-- Declares a new folder. Returns its name, or nil and why.
function F.add(declared, entries, name)
  local n, err = F.clean(name)
  if not n then return nil, err end
  for _, have in ipairs(F.names(declared, entries)) do
    if have:lower() == n:lower() then return nil, "There is already a folder called " .. have end
  end
  declared[#declared + 1] = n
  return n
end

-- Removes a folder; its entries go back to the top level. Returns how
-- many did.
function F.remove(declared, entries, name)
  for i = #declared, 1, -1 do
    if declared[i] == name then table.remove(declared, i) end
  end
  local moved = 0
  for _, e in ipairs(entries or {}) do
    if e.folder == name then
      e.folder = nil
      moved = moved + 1
    end
  end
  return moved
end

return F
