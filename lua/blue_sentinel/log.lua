local log_filename
if vim.g.debug_blue_sentinel then
  log_filename = vim.fn.stdpath('data') .. "/blue_sentinel.log"
end

local log

function log(...)
  if log_filename then
    local elems = { ... }
    vim.schedule(function()
      for i=1,#elems do
        elems[i] = tostring(elems[i])
      end

      local line table.concat(elems, " ")
      local f = io.open(log_filename, "a")
      if f then
        f:write(line .. "\n")
        f:close()
      end
    end)
  end
end

return log

