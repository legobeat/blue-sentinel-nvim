local M = {}

local constants = require("lua/blue_sentinel/constants")
local MAXINT = constants.MAXINT

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

function M.genPID(p, q, s, i)
  local a = (p[i] and p[i][1]) or 0
  local b = (q[i] and q[i][1]) or MAXINT

  if a+1 < b then
    return {{math.random(a+1,b-1), s}}
  end

  local g = M.genPID(p, q, s, i+1)
  table.insert(g, 1, {
    (p[i] and p[i][1]) or 0,
    (p[i] and p[i][2]) or s})
  return g
end

function M.genPIDSeq(p, q, s, i, N)
  local a = (p[i] and p[i][1]) or 0
  local b = (q[i] and q[i][1]) or MAXINT

  if a+N < b-1 then
    local step = math.floor((b-1 - (a+1))/N)
    local start = a+1
    local G = {}
    for i=1,N do
      table.insert(G,
        {{math.random(start,start+step-1), s}})
      start = start + step
    end
    return G
  end

  local G = M.genPIDSeq(p, q, s, i+1, N)
  for j=1,N do
    table.insert(G[j], 1, {
      (p[i] and p[i][1]) or 0,
      (p[i] and p[i][2]) or s})
  end
  return G
end

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