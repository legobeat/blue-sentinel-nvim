local M = {}

local constants = require("lua/blue_sentinel/constants")
local MAXINT = constants.MAXINT

-- Lexicographic comparison of two PID arrays
function M.isLowerOrEqual(a, b)
  for i, ai in ipairs(a) do
    if i > #b then return false end
    local bi = b[i]
    if ai[1] < bi[1] then return true
    elseif ai[1] > bi[1] then return false
    elseif ai[2] < bi[2] then return true
    elseif ai[2] > bi[2] then return false
    end
  end
  return true
end

-- Generate a random PID between low and high
function M.genPID(low, high, client_id, index)
  local a = (low[index] and low[index][1]) or 0
  local b = (high[index] and high[index][1]) or MAXINT

  if a+1 < b then
    return {{math.random(a+1,b-1), client_id}}
  end

  local g = M.genPID(low, high, client_id, index+1)
  table.insert(g, 1, {
    (low[index] and low[index][1]) or 0,
    (low[index] and low[index][2]) or client_id})
  return g
end

-- Generate count random PIDs between low and high
function M.genPIDSeq(low, high, client_id, index, count)
  local a = (low[index] and low[index][1]) or 0
  local b = (high[index] and high[index][1]) or MAXINT
  local seq = {}

  if a+count < b-1 then
    local step = math.floor((b-1 - (a+1))/count)
    local start = a+1
    for i=1,count do
      table.insert(seq,
        {{math.random(start,start+step-1), client_id}})
      start = start + step
    end
    return seq
  end

  seq = M.genPIDSeq(low, high, client_id, index+1, count)
  for j=1,count do
    table.insert(seq[j], 1, {
      (low[index] and low[index][1]) or 0,
      (low[index] and low[index][2]) or client_id})
  end
  return seq
end

-- Split array a into two arrays left and right at position p
-- For example, splitArray({1,2,3,4,5}, 3) returns {{1,2}, {3,4,5}}
function M.splitArray(a, p)
  local left, right = {}, {}
  for i=1,#a do
    if i < p then left[#left+1] = a[i]
    else right[#right+1] = a[i] end
  end
  return left, right
end

function M.getConfig(varname, default)
  local v, value = pcall(function() return vim.api.nvim_get_var(varname) end)
  if not v then value = default end
  return value
end

return M