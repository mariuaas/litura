-- Lua: long strings and comments with levels, metatables, varargs, goto. Ünïcode ✓
--[==[ a long comment
  with ]] inside, closed only by its own level ]==]
local M = {}
local mt = { __index = function(t, k) return rawget(t, "_" .. k) end }

local text = [[
a long string ]=] that spans lines — ünïcode
]]
local nested = [=[ contains ]] and [[ freely ]=]

function M.sum(...)
  local total = 0
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if type(v) == "number" then total = total + v
    elseif type(v) == "table" then total = total + M.sum(table.unpack(v))
    end
  end
  return total
end

function M:greet(name)
  local s = ("hello, %s"):format(name or "world")
  return s .. "\n" .. #text
end

local function walk(t, depth)
  depth = depth or 0
  for k, v in pairs(t) do
    if type(v) == "table" and depth < 3 then
      walk(v, depth + 1)
    else
      goto continue
    end
    ::continue::
  end
end

local co = coroutine.wrap(function(a, b)
  local c = coroutine.yield(a + b)
  return c * 2, 0x1F, 3.5e-2, 1 // 2, 7 % 3, ~5, 1 << 4
end)

setmetatable(M, mt)
walk({ { 1, { 2, { 3 } } }, x = nested })
return M, co(1, 2), M.sum(1, { 2, 3 }), not nil and true or false
