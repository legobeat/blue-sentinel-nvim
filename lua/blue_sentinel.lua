local vim = vim
local websocket_client = require("blue_sentinel.websocket_client")
local log = require("blue_sentinel.log")
local api_attach = {}
local api_attach_id = 1
local attached = {}
local detach = {}
local allprev = {}
local prev = { "" }
local vtextGroup
local old_namespace
local cursors = {}
local cursorGroup
local follow = false
local follow_aut
local loc2rem = {}
local rem2loc = {}
local only_share_cwd
local received = {}
local ws_client
local singlebuf
local sessionshare = false
local disable_undo = false
local undostack = {}
local undosp = {}
local undoslice = {}
local hl_group = {}
local client_hl_group = {}
local autocmd_init = false
local marks = {}
local id2author = {}
-- pos = [(num, site)]
local MAXINT = 1e10 -- can be adjusted
local startpos, endpos = {{0, 0}}, {{MAXINT, 0}}
-- line = [pos]
-- pids = [line]
local allpids = {}
local pids = {}
local agent = 0
local author = vim.api.nvim_get_var("blue_sentinel_username")
local ignores = {}

local utf8 = require("blue_sentinel.utf8")
local constants = require("blue_sentinel.constants")

local MSG_TYPE = constants.MSG_TYPE
local OP_TYPE = constants.OP_TYPE

local util = require("blue_sentinel.util")
local isLowerOrEqual = util.isLowerOrEqual
local genPID = util.genPID
local genPIDSeq = util.genPIDSeq
local splitArray = util.splitArray
local getConfig = util.getConfig

-- HELPERS {{{
local function afterPID(x, y)
  if x == #pids[y] then return pids[y+1][1]
  else return pids[y][x+1] end
end

local function findCharPositionBefore(opid)
  local y1, y2 = 1, #pids
  while true do
    local ym = math.floor((y2 + y1)/2)
    if ym == y1 then break end
    if isLowerOrEqual(pids[ym][1], opid) then
      y1 = ym
    else
      y2 = ym
    end
  end

  local px, py = 1, 1
  for y=y1,#pids do
    for x,pid in ipairs(pids[y]) do
      if not isLowerOrEqual(pid, opid) then
        return px, py
      end
      px, py = x, y
    end
  end
end

local function findPIDBefore(opid)
  local x, y = findCharPositionBefore(opid)
  if x == 1 then
    return pids[y-1][#pids[y-1]]
  elseif x then
    return pids[y][x-1]
  end
end

-- }}}

function SendOp(buf, op)
  if not disable_undo then
    table.insert(undoslice[buf], op)
  end

  local rem = loc2rem[buf]

  local obj = {
    MSG_TYPE.TEXT,
    op,
    rem,
    agent,
  }

  local encoded = vim.api.nvim_call_function("json_encode", { obj })

  log(string.format("send[%d] : %s", agent, vim.inspect(encoded)))
  ws_client:send_text(encoded)
end

local function on_lines(_, buf, changedtick, firstline, lastline, new_lastline, bytecount)
  if detach[buf] then
    detach[buf] = nil
    return true
  end

  if ignores[buf][changedtick] then
    ignores[buf][changedtick] = nil
    return
  end

  prev = allprev[buf]
  pids = allpids[buf]

  local cur_lines = vim.api.nvim_buf_get_lines(buf, firstline, new_lastline, true)

  local add_range = {
    start_char = -1,
    start_line = firstline,
    end_char = -1,       -- at position there is \n
    end_line = new_lastline
  }

  local del_range = {
    start_char = -1,
    start_line = firstline,
    end_char = -1,
    end_line = lastline,
  }

  while (add_range.end_line > add_range.start_line or (add_range.end_line == add_range.start_line and add_range.end_char >= add_range.start_char)) and
    (del_range.end_line > del_range.start_line or (del_range.end_line == del_range.start_line and del_range.end_char >= del_range.start_char)) do
    local c1, c2
    if add_range.end_char == -1 then
      c1 = "\n"
    else
      c1 = utf8.char(cur_lines[add_range.end_line - firstline + 1] or "", add_range.end_char)
    end

    if del_range.end_char == -1 then
      c2 = "\n"
    else
      c2 = utf8.char(prev[del_range.end_line + 1] or "", del_range.end_char)
    end

    if c1 ~= c2 then
      break
    end

    local add_prev, del_prev
    if add_range.end_char == -1 then
      add_prev = { end_line = add_range.end_line - 1, end_char = utf8.len(cur_lines[add_range.end_line - firstline] or "") - 1 }
    else
      add_prev = { end_char = add_range.end_char - 1, end_line = add_range.end_line }
    end

    if del_range.end_char == -1 then
      del_prev = { end_line = del_range.end_line - 1, end_char = utf8.len(prev[del_range.end_line] or "") - 1 }
    else
      del_prev = { end_char = del_range.end_char - 1, end_line = del_range.end_line }
    end

    add_range.end_char, add_range.end_line = add_prev.end_char, add_prev.end_line
    del_range.end_char, del_range.end_line = del_prev.end_char, del_prev.end_line
  end

  while (add_range.start_line < add_range.end_line or (add_range.start_line == add_range.end_line and add_range.start_char <= add_range.end_char)) and
    (del_range.start_line < del_range.end_line or (del_range.start_line == del_range.end_line and del_range.start_char <= del_range.end_char)) do
    local c1, c2
    if add_range.start_char == -1 then
      c1 = "\n"
    else
      c1 = utf8.char(cur_lines[add_range.start_line - firstline + 1] or "", add_range.start_char)
    end

    if del_range.start_char == -1 then
      c2 = "\n"
    else
      c2 = utf8.char(prev[del_range.start_line + 1] or "", del_range.start_char)
    end

    if c1 ~= c2 then
      break
    end
    add_range.start_char = add_range.start_char + 1
    del_range.start_char = del_range.start_char + 1

    if add_range.start_char == utf8.len(cur_lines[add_range.start_line - firstline + 1] or "") then
      add_range.start_char = -1
      add_range.start_line = add_range.start_line + 1
    end

    if del_range.start_char == utf8.len(prev[del_range.start_line + 1] or "") then
      del_range.start_char = -1
      del_range.start_line = del_range.start_line + 1
    end
  end


  local endx = del_range.end_char
  for y = del_range.end_line, del_range.start_line, -1 do
    local startx = -1
    if y == del_range.start_line then
      startx = del_range.start_char
    end

    for x = endx, startx, -1 do
      if x == -1 then
        if #prev > 1 then
          if y > 0 then
            prev[y] = prev[y] .. (prev[y + 1] or "")
          end
          table.remove(prev, y + 1)

          local del_pid = pids[y + 2][1]
          for i, pid in ipairs(pids[y + 2]) do
            if i > 1 then
              table.insert(pids[y + 1], pid)
            end
          end
          table.remove(pids, y + 2)

          SendOp(buf, { OP_TYPE.DEL, "\n", del_pid })
        end
      else
        local c = utf8.char(prev[y + 1], x)

        prev[y + 1] = utf8.remove(prev[y + 1], x)

        local del_pid = pids[y + 2][x + 2]
        table.remove(pids[y + 2], x + 2)

        SendOp(buf, { OP_TYPE.DEL, c, del_pid })
      end
    end
    endx = utf8.len(prev[y] or "") - 1
  end

  local len_insert = 0
  local startx = add_range.start_char
  for y = add_range.start_line, add_range.end_line do
    local endx
    if y == add_range.end_line then
      endx = add_range.end_char
    else
      endx = utf8.len(cur_lines[y - firstline + 1]) - 1
    end

    for x = startx, endx do
      len_insert = len_insert + 1
    end
    startx = -1
  end

  local before_pid, after_pid
  if add_range.start_char == -1 then
    local pidx
    local x, y = add_range.start_char, add_range.start_line
    if cur_lines[y - firstline] then
      pidx = utf8.len(cur_lines[y - firstline]) + 1
    else
      pidx = #pids[y + 1]
    end
    before_pid = pids[y + 1][pidx]
    after_pid = afterPID(pidx, y + 1)
  else
    local x, y = add_range.start_char, add_range.start_line
    before_pid = pids[y + 2][x + 1]
    after_pid = afterPID(x + 1, y + 2)
  end

  local newpidindex = 1
  local newpids = genPIDSeq(before_pid, after_pid, agent, 1, len_insert)

  local startx = add_range.start_char
  for y = add_range.start_line, add_range.end_line do
    local endx
    if y == add_range.end_line then
      endx = add_range.end_char
    else
      endx = utf8.len(cur_lines[y - firstline + 1]) - 1
    end

    for x = startx, endx do
      if x == -1 then
        if cur_lines[y - firstline] then
          local l, r = utf8.split(prev[y], utf8.len(cur_lines[y - firstline]))
          prev[y] = l
          table.insert(prev, y + 1, r)
        else
          table.insert(prev, y + 1, "")
        end

        local pidx
        if cur_lines[y - firstline] then
          pidx = utf8.len(cur_lines[y - firstline]) + 1
        else
          pidx = #pids[y + 1]
        end

        local new_pid = newpids[newpidindex]
        newpidindex = newpidindex + 1

        local l, r = splitArray(pids[y + 1], pidx + 1)
        pids[y + 1] = l
        table.insert(r, 1, new_pid)
        table.insert(pids, y + 2, r)

        SendOp(buf, { OP_TYPE.INS, "\n", new_pid })
      else
        local c = utf8.char(cur_lines[y - firstline + 1], x)
        prev[y + 1] = utf8.insert(prev[y + 1], x, c)

        local new_pid = newpids[newpidindex]
        newpidindex = newpidindex + 1

        table.insert(pids[y + 2], x + 2, new_pid)

        SendOp(buf, { OP_TYPE.INS, c, new_pid })
      end
    end
    startx = -1
  end

  allprev[buf] = prev
  allpids[buf] = pids

  local mode = vim.api.nvim_call_function("mode", {})
  local insert_mode = mode == "i"

  if not insert_mode then
    if #undoslice[buf] > 0 then
      while undosp[buf] < #undostack[buf] do
        table.remove(undostack[buf])       -- remove last element
      end
      table.insert(undostack[buf], undoslice[buf])
      undosp[buf] = undosp[buf] + 1
      undoslice[buf] = {}
    end
  end
end

local function attach_to_current_buffer(buf)
  attached[buf] = nil

  detach[buf] = nil

  undostack[buf] = {}
  undosp[buf] = 0

  undoslice[buf] = {}

  ignores[buf] = {}

  if not attached[buf] then
    local attach_success = vim.api.nvim_buf_attach(buf, false, {
      on_lines = on_lines,
      on_detach = function(_, buf)
        attached[buf] = nil
      end
    })

    -- Commented until I understand how the undo engine works
    -- vim.api.nvim_buf_set_keymap(buf, 'n', 'u', '<cmd>lua require("blue_sentinel").undo(' .. buf .. ')<CR>', {noremap = true})
    -- vim.api.nvim_buf_set_keymap(buf, 'n', '<C-r>', '<cmd>lua require("blue_sentinel").redo(' .. buf .. ')<CR>', {noremap = true})


    if attach_success then
      attached[buf] = true
    end
  else
    detach[buf] = nil
  end
end

function BlueSentinelOpenOrCreateBuffer(buf)
  if (sessionshare and not received[buf]) then
    local fullname = vim.api.nvim_buf_get_name(buf)
    local cwdname = vim.api.nvim_call_function("fnamemodify",
      { fullname, ":." })
    local bufname = cwdname
    if bufname == fullname then
      bufname = vim.api.nvim_call_function("fnamemodify",
      { fullname, ":t" })
    end


    if cwdname ~= fullname or not only_share_cwd then
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)

      local middlepos = genPID(startpos, endpos, agent, 1)
      pids = {
        { startpos },
        { middlepos },
        { endpos },
      }

      local numgen = 0
      for i=1,#lines do
        local line = lines[i]
        if i > 1 then
          numgen = numgen + 1
        end

        for j=1,string.len(line) do
          numgen = numgen + 1
        end
      end

      local newpidindex = 1
      local newpids = genPIDSeq(middlepos, endpos, agent, 1, numgen)

      for i=1,#lines do
        local line = lines[i]
        if i > 1 then
          local newpid = newpids[newpidindex]
          newpidindex = newpidindex + 1

          table.insert(pids, i+1, { newpid })

        end

        for j=1,string.len(line) do
          local newpid = newpids[newpidindex]
          newpidindex = newpidindex + 1

          table.insert(pids[i+1], newpid)

        end
      end

      prev = lines

      allprev[buf] = prev
      allpids[buf] = pids

      if not rem2loc[agent] then
        rem2loc[agent] = {}
      end

      rem2loc[agent][buf] = buf
      loc2rem[buf] = { agent, buf }

      local rem = loc2rem[buf]

      local pidslist = {}
      for _,lpid in ipairs(allpids[buf]) do
        for _,pid in ipairs(lpid) do
          table.insert(pidslist, pid[1][1])
        end
      end

      local obj = {
        MSG_TYPE.INITIAL,
        bufname,
        rem,
        pidslist,
        allprev[buf]
      }

      local encoded = vim.api.nvim_call_function("json_encode", {  obj  })

      ws_client:send_text(encoded)

      attach_to_current_buffer(buf)
    end
  end
end

function LeaveInsert()
  for buf,_ in pairs(undoslice) do
    if #undoslice[buf] > 0 then
      while undosp[buf] < #undostack[buf] do
        table.remove(undostack[buf]) -- remove last element
      end
      table.insert(undostack[buf], undoslice[buf])
      undosp[buf] = undosp[buf] + 1
      undoslice[buf] = {}
    end

  end
end

local function MarkRange()
  local _, snum, scol, _ = unpack(vim.api.nvim_call_function("getpos", { "'<" }))
  local _, enum, ecol, _ = unpack(vim.api.nvim_call_function("getpos", { "'>" }))

  local curbuf = vim.api.nvim_get_current_buf()
  local pids = allpids[curbuf]
  local prev = allprev[curbuf]

  ecol = math.min(ecol, string.len(prev[enum])+1)

  local bscol = vim.str_utfindex(prev[snum], scol-1)
  local becol = vim.str_utfindex(prev[enum], ecol-1)

  local spid = pids[snum+1][bscol+1]
  local epid
  if #pids[enum+1] < becol+1 then
    epid = pids[enum+2][1]
  else
    epid = pids[enum+1][becol+1]
  end

  if marks[agent] then
    vim.api.nvim_buf_clear_namespace(marks[agent].buf, marks[agent].ns_id, 0, -1)
    marks[agent] = nil
  end

  marks[agent] = {}
  marks[agent].buf = curbuf
  marks[agent].ns_id = vim.api.nvim_create_namespace("")
  for y=snum-1,enum-1 do
    local lscol
    if y == snum-1 then lscol = scol-1
    else lscol = 0 end

    local lecol
    if y == enum-1 then lecol = ecol-1
    else lecol = -1 end

    vim.api.nvim_buf_add_highlight(
      marks[agent].buf,
      marks[agent].ns_id,
      "TermCursor",
      y, lscol, lecol)
  end

  local rem = loc2rem[curbuf]
  local obj = {
    MSG_TYPE.MARK,
    agent,
    rem,
    spid, epid,
  }

  local encoded = vim.api.nvim_call_function("json_encode", { obj })
  ws_client:send_text(encoded)


end

local function MarkClear()
  for _, mark in pairs(marks) do
    vim.api.nvim_buf_clear_namespace(mark.buf, mark.ns_id, 0, -1)
  end

  marks = {}

end

local function isPIDEqual(a, b)
  if #a ~= #b then return false end
  for i=1,#a do
    if a[i][1] ~= b[i][1] then return false end
    if a[i][2] ~= b[i][2] then return false end
  end
  return true
end

local function findCharPositionExact(opid)
  local y1, y2 = 1, #pids
  while true do
    local ym = math.floor((y2 + y1)/2)
    if ym == y1 then break end
    if isLowerOrEqual(pids[ym][1], opid) then
      y1 = ym
    else
      y2 = ym
    end
  end

  local y = y1
  for x,pid in ipairs(pids[y]) do
    if isPIDEqual(pid, opid) then
      return x, y
    end

    if not isLowerOrEqual(pid, opid) then
      return nil
    end
  end
end

local function StartClient(first, appuri, port)
  local v, username = pcall(function() return vim.api.nvim_get_var("blue_sentinel_username") end)
  if not v then
    error("Please specify a username in g:blue_sentinel_username")
  end

  detach = {}

  vtextGroup = {
    getConfig("blue_sentinel_name_hl_group_user1", "CursorLineNr"),
    getConfig("blue_sentinel_name_hl_group_user2", "CursorLineNr"),
    getConfig("blue_sentinel_name_hl_group_user3", "CursorLineNr"),
    getConfig("blue_sentinel_name_hl_group_user4", "CursorLineNr"),
    getConfig("blue_sentinel_name_hl_group_default", "CursorLineNr")
  }

  old_namespace = {}

  cursorGroup = {
    getConfig("blue_sentinel_cursor_hl_group_user1", "Cursor"),
    getConfig("blue_sentinel_cursor_hl_group_user2", "Cursor"),
    getConfig("blue_sentinel_cursor_hl_group_user3", "Cursor"),
    getConfig("blue_sentinel_cursor_hl_group_user4", "Cursor"),
    getConfig("blue_sentinel_cursor_hl_group_default", "Cursor")
  }

  cursors = {}

  loc2rem = {}
  rem2loc = {}

  only_share_cwd = getConfig("g:blue_sentinel_only_cwd", true)

  ws_client = websocket_client { uri = appuri, port = port }
  if not ws_client then
    error("Could not connect to server")
    return
  end

  ws_client:connect {
    on_connect = function()
      local obj = {
        MSG_TYPE.INFO,
        sessionshare,
        author,
        agent,
      }
      local encoded = vim.api.nvim_call_function("json_encode", { obj })
      ws_client:send_text(encoded)


      for _, o in pairs(api_attach) do
        if o.on_connect then
          o.on_connect()
        end
      end

      vim.schedule(function() print("Connected!") end)
    end,
    on_text = function(wsdata)
      local decoded = vim.api.nvim_call_function("json_decode", {  wsdata })

      if decoded then
        log(string.format("rec[%d] : %s", agent, vim.inspect(decoded)))
        if decoded[1] == MSG_TYPE.TEXT then
          local _, op, other_rem, other_agent = unpack(decoded)
          local lastPID

          local ag, bufid = unpack(other_rem)
          local buf = rem2loc[ag][bufid]

          prev = allprev[buf]
          pids = allpids[buf]

          local tick = vim.api.nvim_buf_get_changedtick(buf)+1
          ignores[buf][tick] = true

          if op[1] == OP_TYPE.INS then
            lastPID = op[3]

            local x, y = findCharPositionBefore(op[3])

            if op[2] == "\n" then
              local py, py1 = splitArray(pids[y], x+1)
              pids[y] = py
              table.insert(py1, 1, op[3])
              table.insert(pids, y+1, py1)
            else table.insert(pids[y], x+1, op[3] ) end

            if op[2] == "\n" then
              if y-2 >= 0 then
                local curline = vim.api.nvim_buf_get_lines(buf, y-2, y-1, true)[1]
                local l, r = utf8.split(curline, x-1)
                vim.api.nvim_buf_set_lines(buf, y-2, y-1, true, { l, r })
              else
                vim.api.nvim_buf_set_lines(buf, 0, 0, true, { "" })
              end
            else
              local curline = vim.api.nvim_buf_get_lines(buf, y-2, y-1, true)[1]
              curline = utf8.insert(curline, x-1, op[2])
              vim.api.nvim_buf_set_lines(buf, y-2, y-1, true, { curline })
            end

            if op[2] == "\n" then
              if y-1 >= 1 then
                local l, r = utf8.split(prev[y-1], x-1)
                prev[y-1] = l
                table.insert(prev, y, r)
              else
                table.insert(prev, y, "")
              end
            else
              prev[y-1] = utf8.insert(prev[y-1], x-1, op[2])
            end


          elseif op[1] == OP_TYPE.DEL then
            lastPID = findPIDBefore(op[3])

            local sx, sy = findCharPositionExact(op[3])

            if sx then
              if sx == 1 then
                if sy-3 >= 0 then
                  local prevline = vim.api.nvim_buf_get_lines(buf, sy-3, sy-2, true)[1]
                  local curline = vim.api.nvim_buf_get_lines(buf, sy-2, sy-1, true)[1]
                  vim.api.nvim_buf_set_lines(buf, sy-3, sy-1, true, { prevline .. curline })
                else
                  vim.api.nvim_buf_set_lines(buf, sy-2, sy-1, true, {})
                end
              else
                if sy > 1 then
                  local curline = vim.api.nvim_buf_get_lines(buf, sy-2, sy-1, true)[1]
                  curline = utf8.remove(curline, sx-2)
                  vim.api.nvim_buf_set_lines(buf, sy-2, sy-1, true, { curline })
                end
              end

              if sx == 1 then
                if sy-2 >= 1 then
                  prev[sy-2] = prev[sy-2] .. string.sub(prev[sy-1], 1)
                end
                table.remove(prev, sy-1)
              else
                if sy > 1 then
                  local curline = prev[sy-1]
                  curline = utf8.remove(curline, sx-2)
                  prev[sy-1] = curline
                end
              end

              if sx == 1 then
                for i,pid in ipairs(pids[sy]) do
                  if i > 1 then
                    table.insert(pids[sy-1], pid)
                  end
                end
                table.remove(pids, sy)
              else
                table.remove(pids[sy], sx)
              end

            end

          end
          allprev[buf] = prev
          allpids[buf] = pids
          local aut = id2author[other_agent]

          if lastPID and other_agent ~= agent then
            local x, y = findCharPositionExact(lastPID)

            if old_namespace[aut] then
              if attached[old_namespace[aut].buf] then
                vim.api.nvim_buf_clear_namespace(
                  old_namespace[aut].buf, old_namespace[aut].id,
                  0, -1)
              end
              old_namespace[aut] = nil
            end

            if cursors[aut] then
              if attached[cursors[aut].buf] then
                vim.api.nvim_buf_clear_namespace(
                  cursors[aut].buf, cursors[aut].id,
                  0, -1)
              end
              cursors[aut] = nil
            end

            if x then
              if x == 1 then x = 2 end
              old_namespace[aut] = {
                id = vim.api.nvim_create_namespace(aut),
                buf = buf,
              }
              vim.api.nvim_buf_set_extmark(
                buf,
                old_namespace[aut].id,
                math.max(y - 2, 0),
                0,
                {
                  virt_text = {{  aut, vtextGroup[client_hl_group[other_agent]] } },
                  virt_text_pos = "right_align"
                }
              )

              if prev[y-1] and x-2 >= 0 and x-2 <= utf8.len(prev[y-1]) then
                local bx = vim.str_byteindex(prev[y-1], x-2)
                cursors[aut] = {
                  id = vim.api.nvim_buf_add_highlight(buf,
                    0, cursorGroup[client_hl_group[other_agent]], y-2, bx, bx+1),
                  buf = buf,
                  line = y-2,
                }
                if vim.api.nvim_buf_set_extmark then
                  cursors[aut].ext_id =
                    vim.api.nvim_buf_set_extmark(
                      buf, cursors[aut].id, y-2, bx, {})
                end

              end

            end
            if follow and follow_aut == aut then
              local curbuf = vim.api.nvim_get_current_buf()
              if curbuf ~= buf then
                vim.api.nvim_set_current_buf(buf)
              end

              vim.api.nvim_command("normal " .. (y-1) .. "gg")
            end


            for _, o in pairs(api_attach) do
              if o.on_change then
                o.on_change(aut, buf, y-2)
              end
            end

          end
          -- @check_if_pid_match_with_prev

        end

        if decoded[1] == MSG_TYPE.REQUEST then
          local encoded

          local function pidslist(b)
            local ps = {}
            for _,lpid in ipairs(allpids[b]) do
              for _,pid in ipairs(lpid) do
                table.insert(ps, pid)
              end
            end
            return ps
          end

          local function send_initial_for_buffer(buf)
            local rem
            if loc2rem[buf] then
              rem = loc2rem[buf]
            else
              rem = { agent, buf }
            end
            local fullname = vim.api.nvim_buf_get_name(buf)
            local cwdname = vim.api.nvim_call_function("fnamemodify",
              { fullname, ":." })
            local bufname = cwdname
            if bufname == fullname then
              bufname = vim.api.nvim_call_function("fnamemodify",
              { fullname, ":t" })
            end

            local obj = {
              MSG_TYPE.INITIAL,
              bufname,
              rem,
              pidslist(buf),
              allprev[buf]
            }

            encoded = vim.api.nvim_call_function("json_encode", {  obj  })

            ws_client:send_text(encoded)
          end

          if not sessionshare then
            send_initial_for_buffer(singlebuf)
          else
            local allbufs = vim.api.nvim_list_bufs()
            local bufs = {}
            -- skip terminal, help, ... buffers
            for _,buf in ipairs(allbufs) do
              local buftype = vim.api.nvim_buf_get_option(buf, "buftype")
              if buftype == "" then
                table.insert(bufs, buf)
              end
            end

            for _,buf in ipairs(bufs) do
              send_initial_for_buffer(buf)
            end
          end
        end


        if decoded[1] == MSG_TYPE.INITIAL then
          local _, bufname, bufid, pidslist, content = unpack(decoded)

          local ag, bufid = unpack(bufid)
          if not rem2loc[ag] or not rem2loc[ag][bufid] then
            local buf
            if not sessionshare then
              buf = singlebuf
              vim.api.nvim_buf_set_name(buf, bufname)

              if vim.api.nvim_buf_call then
                vim.api.nvim_buf_call(buf, function()
                  vim.api.nvim_command("doautocmd BufRead " .. vim.api.nvim_buf_get_name(buf))
                end)
              end

            else
              buf = vim.api.nvim_create_buf(true, true)

              received[buf] = true

              attach_to_current_buffer(buf)

              vim.api.nvim_buf_set_name(buf, bufname)

              if vim.api.nvim_buf_call then
                vim.api.nvim_buf_call(buf, function()
                  vim.api.nvim_command("doautocmd BufRead " .. vim.api.nvim_buf_get_name(buf))
                end)
              end

              vim.api.nvim_buf_set_option(buf, "buftype", "")

            end

            if not rem2loc[ag] then
              rem2loc[ag] = {}
            end

            rem2loc[ag][bufid] = buf
            loc2rem[buf] = { ag, bufid }


            prev = content

            local pidindex = 1
            pids = {}

            table.insert(pids, { pidslist[pidindex] })
            pidindex = pidindex + 1

            for _, line in ipairs(content) do
              local lpid = {}
              for i=0,utf8.len(line) do
                table.insert(lpid, pidslist[pidindex])
                pidindex = pidindex + 1
              end
              table.insert(pids, lpid)
            end

            table.insert(pids, { pidslist[pidindex] })


            local tick = vim.api.nvim_buf_get_changedtick(buf)+1
            ignores[buf][tick] = true

            vim.api.nvim_buf_set_lines(
              buf,
              0, -1, false, prev)

            allprev[buf] = prev
            allpids[buf] = pids
          else
            local buf = rem2loc[ag][bufid]

            prev = content

            local pidindex = 1
            pids = {}

            table.insert(pids, { pidslist[pidindex] })
            pidindex = pidindex + 1

            for _, line in ipairs(content) do
              local lpid = {}
              for i=0,utf8.len(line) do
                table.insert(lpid, pidslist[pidindex])
                pidindex = pidindex + 1
              end
              table.insert(pids, lpid)
            end

            table.insert(pids, { pidslist[pidindex] })


            local tick = vim.api.nvim_buf_get_changedtick(buf)+1
            ignores[buf][tick] = true

            vim.api.nvim_buf_set_lines(
              buf,
              0, -1, false, prev)

            allprev[buf] = prev
            allpids[buf] = pids

            vim.api.nvim_buf_set_name(buf, bufname)

            if vim.api.nvim_buf_call then
              vim.api.nvim_buf_call(buf, function()
                vim.api.nvim_command("doautocmd BufRead " .. vim.api.nvim_buf_get_name(buf))
              end)
            end

          end
        end

        if decoded[1] == MSG_TYPE.AVAILABLE then
          local _, is_first, client_id, is_sessionshare  = unpack(decoded)
          if is_first and first then
            agent = client_id


            if sessionshare then
              local allbufs = vim.api.nvim_list_bufs()
              local bufs = {}
              -- skip terminal, help, ... buffers
              for _,buf in ipairs(allbufs) do
                local buftype = vim.api.nvim_buf_get_option(buf, "buftype")
                if buftype == "" then
                  table.insert(bufs, buf)
                end
              end

              for _, buf in ipairs(bufs) do
                attach_to_current_buffer(buf)
              end

              for _, buf in ipairs(bufs) do
                local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)

                local middlepos = genPID(startpos, endpos, agent, 1)
                pids = {
                  { startpos },
                  { middlepos },
                  { endpos },
                }

                local numgen = 0
                for i=1,#lines do
                  local line = lines[i]
                  if i > 1 then
                    numgen = numgen + 1
                  end

                  for j=1,string.len(line) do
                    numgen = numgen + 1
                  end
                end

                local newpidindex = 1
                local newpids = genPIDSeq(middlepos, endpos, agent, 1, numgen)

                for i=1,#lines do
                  local line = lines[i]
                  if i > 1 then
                    local newpid = newpids[newpidindex]
                    newpidindex = newpidindex + 1

                    table.insert(pids, i+1, { newpid })

                  end

                  for j=1,string.len(line) do
                    local newpid = newpids[newpidindex]
                    newpidindex = newpidindex + 1

                    table.insert(pids[i+1], newpid)

                  end
                end

                prev = lines

                allprev[buf] = prev
                allpids[buf] = pids
                if not rem2loc[agent] then
                  rem2loc[agent] = {}
                end

                rem2loc[agent][buf] = buf
                loc2rem[buf] = { agent, buf }

              end

            else
              local buf = singlebuf

              attach_to_current_buffer(buf)

              if not rem2loc[agent] then
                rem2loc[agent] = {}
              end

              rem2loc[agent][buf] = buf
              loc2rem[buf] = { agent, buf }

              local rem = loc2rem[buf]


              local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)

              local middlepos = genPID(startpos, endpos, agent, 1)
              pids = {
                { startpos },
                { middlepos },
                { endpos },
              }

              local numgen = 0
              for i=1,#lines do
                local line = lines[i]
                if i > 1 then
                  numgen = numgen + 1
                end

                for j=1,string.len(line) do
                  numgen = numgen + 1
                end
              end

              local newpidindex = 1
              local newpids = genPIDSeq(middlepos, endpos, agent, 1, numgen)

              for i=1,#lines do
                local line = lines[i]
                if i > 1 then
                  local newpid = newpids[newpidindex]
                  newpidindex = newpidindex + 1

                  table.insert(pids, i+1, { newpid })

                end

                for j=1,string.len(line) do
                  local newpid = newpids[newpidindex]
                  newpidindex = newpidindex + 1

                  table.insert(pids[i+1], newpid)

                end
              end

              prev = lines

              allprev[buf] = prev
              allpids[buf] = pids

            end

            vim.api.nvim_command("augroup blueSentinelSession")
            vim.api.nvim_command("autocmd!")
            -- this is kind of messy
            -- a better way to write this
            -- would be great
            vim.api.nvim_command("autocmd BufNewFile,BufRead * call execute('lua BlueSentinelOpenOrCreateBuffer(' . expand('<abuf>') . ')', '')")
            vim.api.nvim_command("augroup end")

          elseif not is_first and not first then
            if is_sessionshare ~= sessionshare then
              print("ERROR: Share mode client server mismatch (session mode, single buffer mode)")
              for aut,_ in pairs(cursors) do
                if cursors[aut] then
                  if attached[cursors[aut].buf] then
                    vim.api.nvim_buf_clear_namespace(
                      cursors[aut].buf, cursors[aut].id,
                      0, -1)
                  end
                  cursors[aut] = nil
                end

                if old_namespace[aut] then
                  if attached[old_namespace[aut].buf] then
                    vim.api.nvim_buf_clear_namespace(
                      old_namespace[aut].buf, old_namespace[aut].id,
                      0, -1)
                  end
                  old_namespace[aut] = nil
                end

              end
              cursors = {}
              vim.api.nvim_command("augroup blueSentinelSession")
              vim.api.nvim_command("autocmd!")
              vim.api.nvim_command("augroup end")


              for bufhandle,_ in pairs(allprev) do
                if vim.api.nvim_buf_is_loaded(bufhandle) then
                  DetachFromBuffer(bufhandle)
                end
              end

              agent = 0
            else
              agent = client_id


              if not sessionshare then
                local buf = singlebuf
                attach_to_current_buffer(buf)
              end
              local obj = {
                MSG_TYPE.REQUEST,
              }
              local encoded = vim.api.nvim_call_function("json_encode", {  obj  })
              ws_client:send_text(encoded)


              vim.api.nvim_command("augroup blueSentinelSession")
              vim.api.nvim_command("autocmd!")
              -- this is kind of messy
              -- a better way to write this
              -- would be great
              vim.api.nvim_command("autocmd BufNewFile,BufRead * call execute('lua BlueSentinelOpenOrCreateBuffer(' . expand('<abuf>') . ')', '')")
              vim.api.nvim_command("augroup end")

            end
          elseif is_first and not first then
            print("ERROR: Tried to join an empty server")
            for aut,_ in pairs(cursors) do
              if cursors[aut] then
                if attached[cursors[aut].buf] then
                  vim.api.nvim_buf_clear_namespace(
                    cursors[aut].buf, cursors[aut].id,
                    0, -1)
                end
                cursors[aut] = nil
              end

              if old_namespace[aut] then
                if attached[old_namespace[aut].buf] then
                  vim.api.nvim_buf_clear_namespace(
                    old_namespace[aut].buf, old_namespace[aut].id,
                    0, -1)
                end
                old_namespace[aut] = nil
              end

            end
            cursors = {}
            vim.api.nvim_command("augroup blueSentinelSession")
            vim.api.nvim_command("autocmd!")
            vim.api.nvim_command("augroup end")


            for bufhandle,_ in pairs(allprev) do
              if vim.api.nvim_buf_is_loaded(bufhandle) then
                DetachFromBuffer(bufhandle)
              end
            end

            agent = 0
          elseif not is_first and first then
            print("ERROR: Tried to start a server which is already busy")
            for aut,_ in pairs(cursors) do
              if cursors[aut] then
                if attached[cursors[aut].buf] then
                  vim.api.nvim_buf_clear_namespace(
                    cursors[aut].buf, cursors[aut].id,
                    0, -1)
                end
                cursors[aut] = nil
              end

              if old_namespace[aut] then
                if attached[old_namespace[aut].buf] then
                  vim.api.nvim_buf_clear_namespace(
                    old_namespace[aut].buf, old_namespace[aut].id,
                    0, -1)
                end
                old_namespace[aut] = nil
              end

            end
            cursors = {}
            vim.api.nvim_command("augroup blueSentinelSession")
            vim.api.nvim_command("autocmd!")
            vim.api.nvim_command("augroup end")


            for bufhandle,_ in pairs(allprev) do
              if vim.api.nvim_buf_is_loaded(bufhandle) then
                DetachFromBuffer(bufhandle)
              end
            end

            agent = 0
          end
        end

        if decoded[1] == MSG_TYPE.CONNECT then
          local _, new_id, new_aut = unpack(decoded)
          id2author[new_id] = new_aut
          local user_hl_group = 5
          for i=1,4 do
            if not hl_group[i] then
              hl_group[i] = true
              user_hl_group = i
              break
            end
          end

          client_hl_group[new_id] = user_hl_group

          for _, o in pairs(api_attach) do
            if o.on_clientconnected then
              o.on_clientconnected(new_aut)
            end
          end

        end

        if decoded[1] == MSG_TYPE.DISCONNECT then
          local _, remove_id = unpack(decoded)
          local aut = id2author[remove_id]
          if aut then
            id2author[remove_id] = nil
            if client_hl_group[remove_id] ~= 5 then -- 5 means default hl group (there are four predefined)
              hl_group[client_hl_group[remove_id]] = nil
            end
            client_hl_group[remove_id] = nil

            for _, o in pairs(api_attach) do
              if o.on_clientdisconnected then
                o.on_clientdisconnected(aut)
              end
            end

          end
        end
        if decoded[1] == MSG_TYPE.DATA then
          local _, data = unpack(decoded)
          for _, o in pairs(api_attach) do
            if o.on_data then
              o.on_data(data)
            end
          end

        end

        if decoded[1] == MSG_TYPE.MARK then
          local _, other_agent, rem, spid, epid = unpack(decoded)
          local ag, rembuf = unpack(rem)
          local buf = rem2loc[ag][rembuf]

          local sx, sy = findCharPositionExact(spid)
          local ex, ey = findCharPositionExact(epid)

          if marks[other_agent] then
            vim.api.nvim_buf_clear_namespace(marks[other_agent].buf, marks[other_agent].ns_id, 0, -1)
            marks[other_agent] = nil
          end

          marks[other_agent] = {}
          marks[other_agent].buf = buf
          marks[other_agent].ns_id = vim.api.nvim_create_namespace("")
          local scol = vim.str_byteindex(prev[sy-1], sx-1)
          local ecol = vim.str_byteindex(prev[ey-1], ex-1)

          for y=sy-1,ey-1 do
            local lscol
            if y == sy-1 then lscol = scol
            else lscol = 0 end

            local lecol
            if y == ey-1 then lecol = ecol
            else lecol = -1 end

            vim.api.nvim_buf_add_highlight(
              marks[other_agent].buf,
              marks[other_agent].ns_id,
              cursorGroup[client_hl_group[other_agent]],
              y-1, lscol, lecol)
          end

          local aut = id2author[other_agent]

          old_namespace[aut] = {
            id = vim.api.nvim_create_namespace(aut),
            buf = buf,
          }

          vim.api.nvim_buf_set_extmark(
            buf,
            marks[other_agent].ns_id,
            sy - 2,
            0,
            {
              virt_text = {{  aut, vtextGroup[client_hl_group[other_agent]] } },
              virt_text_pos = "right_align"
            }
          )

          if follow and follow_aut == aut then
            local curbuf = vim.api.nvim_get_current_buf()
            if curbuf ~= buf then
              vim.api.nvim_set_current_buf(buf)
            end

            local y = sy
            vim.api.nvim_command("normal " .. (y-1) .. "gg")
          end
        end

      else
        error("Could not decode json " .. wsdata)
      end

    end,
    on_disconnect = function()
      for aut,_ in pairs(cursors) do
        if cursors[aut] then
          if attached[cursors[aut].buf] then
            vim.api.nvim_buf_clear_namespace(
              cursors[aut].buf, cursors[aut].id,
              0, -1)
          end
          cursors[aut] = nil
        end

        if old_namespace[aut] then
          if attached[old_namespace[aut].buf] then
            vim.api.nvim_buf_clear_namespace(
              old_namespace[aut].buf, old_namespace[aut].id,
              0, -1)
          end
          old_namespace[aut] = nil
        end

      end
      cursors = {}
      vim.api.nvim_command("augroup blueSentinelSession")
      vim.api.nvim_command("autocmd!")
      vim.api.nvim_command("augroup end")


      for bufhandle,_ in pairs(allprev) do
        if vim.api.nvim_buf_is_loaded(bufhandle) then
          DetachFromBuffer(bufhandle)
        end
      end

      agent = 0
      for _, o in pairs(api_attach) do
        if o.on_disconnect then
          o.on_disconnect()
        end
      end

      vim.schedule(function() print("Disconnected.") end)
    end
  }
end


function DetachFromBuffer(bufnr)
  detach[bufnr] = true
end


local function Start(host, port)
  if ws_client and ws_client:is_active() then
    error("Client is already connected. Use BlueSentinelStop first to disconnect.")
  end

  if not autocmd_init then
    vim.api.nvim_command("augroup blueSentinelUndo")
    vim.api.nvim_command("autocmd!")
    vim.api.nvim_command([[autocmd InsertLeave * lua require"blue_sentinel".LeaveInsert()]])
    vim.api.nvim_command("augroup end")
    autocmd_init = true
  end


  local buf = vim.api.nvim_get_current_buf()
  singlebuf = buf
  local first = true
  sessionshare = false
  StartClient(first, host, port)


end

local function Join(host, port)
  if ws_client and ws_client:is_active() then
    error("Client is already connected. Use BlueSentinelStop first to disconnect.")
  end

  if not autocmd_init then
    vim.api.nvim_command("augroup blueSentinelUndo")
    vim.api.nvim_command("autocmd!")
    vim.api.nvim_command([[autocmd InsertLeave * lua require"blue_sentinel".LeaveInsert()]])
    vim.api.nvim_command("augroup end")
    autocmd_init = true
  end


  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, buf)

  singlebuf = buf
  local first = false
  sessionshare = false
  StartClient(first, host, port)

end

local function Stop()
  ws_client:disconnect()
  ws_client = nil

end


local function StartSession(host, port)
  if ws_client and ws_client:is_active() then
    error("Client is already connected. Use BlueSentinelStop first to disconnect.")
  end

  if not autocmd_init then
    vim.api.nvim_command("augroup blueSentinelUndo")
    vim.api.nvim_command("autocmd!")
    vim.api.nvim_command([[autocmd InsertLeave * lua require"blue_sentinel".LeaveInsert()]])
    vim.api.nvim_command("augroup end")
    autocmd_init = true
  end


  local first = true
  sessionshare = true
  StartClient(first, host, port)

end

local function JoinSession(host, port)
  if ws_client and ws_client:is_active() then
    error("Client is already connected. Use BlueSentinelStop first to disconnect.")
  end

  if not autocmd_init then
    vim.api.nvim_command("augroup blueSentinelUndo")
    vim.api.nvim_command("autocmd!")
    vim.api.nvim_command([[autocmd InsertLeave * lua require"blue_sentinel".LeaveInsert()]])
    vim.api.nvim_command("augroup end")
    autocmd_init = true
  end


  local first = false
  sessionshare = true
  StartClient(first, host, port)

end


local function Status()
  if ws_client and ws_client:is_active() then
    local positions = {}
    for _, aut in pairs(id2author) do
      local c = cursors[aut]
      if c then
        local buf = c.buf
        local fullname = vim.api.nvim_buf_get_name(buf)
        local cwdname = vim.api.nvim_call_function("fnamemodify",
          { fullname, ":." })
        local bufname = cwdname
        if bufname == fullname then
          bufname = vim.api.nvim_call_function("fnamemodify",
          { fullname, ":t" })
        end

        local line
        if c.ext_id then
          line,_ = unpack(vim.api.nvim_buf_get_extmark_by_id(
              buf, c.id, c.ext_id, {}))
        else
          line= c.y
        end

        table.insert(positions , {aut, bufname, line+1})
      else
        table.insert(positions , {aut, "", ""})
      end
    end

    local info_str = {}
    for _,pos in ipairs(positions) do
      table.insert(info_str, table.concat(pos, " "))
    end
    print("Connected. " .. #info_str .. " other client(s)\n\n" .. table.concat(info_str, "\n"))

  else
    print("Disconnected.")
  end
end

local function StartFollow(aut)
  follow = true
  follow_aut = aut
  print("Following " .. aut)
end

local function StopFollow()
  follow = false
  print("Following Stopped.")
end

local function SaveBuffers(force)
  local allbufs = vim.api.nvim_list_bufs()
  local bufs = {}
  -- skip terminal, help, ... buffers
  for _,buf in ipairs(allbufs) do
    local buftype = vim.api.nvim_buf_get_option(buf, "buftype")
    if buftype == "" then
      table.insert(bufs, buf)
    end
  end

  local i = 1
  while i < #bufs do
    local buf = bufs[i]
    local fullname = vim.api.nvim_buf_get_name(buf)

    if string.len(fullname) == 0 then
      table.remove(bufs, i)
    else
      i = i + 1
    end
  end

  for _,buf in ipairs(bufs) do
    local fullname = vim.api.nvim_buf_get_name(buf)

    local parentdir = vim.api.nvim_call_function("fnamemodify", { fullname, ":h" })
    local isdir = vim.api.nvim_call_function("isdirectory", { parentdir })
    if isdir == 0 then
      vim.api.nvim_call_function("mkdir", { parentdir, "p" } )
    end

    vim.api.nvim_command("b " .. buf)
    if force then
      vim.api.nvim_command("w!") -- write all
    else
      vim.api.nvim_command("w") -- write all
    end

  end
end

function OpenBuffers()
  local all = vim.api.nvim_call_function("glob", { "**" })
  local files = {}
  if string.len(all) > 0 then
    for path in vim.gsplit(all, "\n") do
      local isdir = vim.api.nvim_call_function("isdirectory", { path })
      if isdir == 0 then
        table.insert(files, path)
      end
    end
  end
  local num_files = 0
  for _,file in ipairs(files) do
    vim.api.nvim_command("args " .. file)
    num_files = num_files + 1
  end
  print("Opened " .. num_files .. " files.")
end


local function undo(buf)
  if undosp[buf] == 0 then
    print("Already at oldest change.")
    return
  end
  local ops = undostack[buf][undosp[buf]]
  local rev_ops = {}
  for i=#ops,1,-1 do
    table.insert(rev_ops, ops[i])
  end
  ops = rev_ops

  -- quick hack to avoid bug when first line is
  -- restored. The newlines are stored at
  -- the beginning. Because the undo will reverse
  -- the inserted character, it can happen that
  -- character are entered before any newline
  -- which will error. To avoid the last op is
  -- swapped with first
  local lowest = nil
  local firstpid = allpids[buf][2][1]
  for i,op in ipairs(ops) do
    if op[1] == OP_TYPE.INS and isLowerOrEqual(op[3], firstpid) then
      lowest = i
      break
    end
  end

  if lowest then
    ops[lowest], ops[1] = ops[1], ops[lowest]
  end

  undosp[buf] = undosp[buf] - 1


  disable_undo = true
  local other_rem, other_agent = loc2rem[buf], agent
  local lastPID
  for _, op in ipairs(ops) do
    if op[1] == OP_TYPE.INS then
      op = { OP_TYPE.DEL, op[3], op[2] }

    elseif op[1] == OP_TYPE.DEL then
      op = { OP_TYPE.INS, op[3], op[2] }
    end

    local ag, bufid = unpack(other_rem)
    buf = rem2loc[ag][bufid]

    prev = allprev[buf]
    pids = allpids[buf]

    local tick = vim.api.nvim_buf_get_changedtick(buf)+1
    ignores[buf][tick] = true

    if op[1] == OP_TYPE.INS then
      lastPID = op[3]

      local x, y = findCharPositionBefore(op[3])

      if op[2] == "\n" then
        local py, py1 = splitArray(pids[y], x+1)
        pids[y] = py
        table.insert(py1, 1, op[3])
        table.insert(pids, y+1, py1)
      else table.insert(pids[y], x+1, op[3] ) end

      if op[2] == "\n" then
        if y-2 >= 0 then
          local curline = vim.api.nvim_buf_get_lines(buf, y-2, y-1, true)[1]
          local l, r = utf8.split(curline, x-1)
          vim.api.nvim_buf_set_lines(buf, y-2, y-1, true, { l, r })
        else
          vim.api.nvim_buf_set_lines(buf, 0, 0, true, { "" })
        end
      else
        local curline = vim.api.nvim_buf_get_lines(buf, y-2, y-1, true)[1]
        curline = utf8.insert(curline, x-1, op[2])
        vim.api.nvim_buf_set_lines(buf, y-2, y-1, true, { curline })
      end

      if op[2] == "\n" then
        if y-1 >= 1 then
          local l, r = utf8.split(prev[y-1], x-1)
          prev[y-1] = l
          table.insert(prev, y, r)
        else
          table.insert(prev, y, "")
        end
      else
        prev[y-1] = utf8.insert(prev[y-1], x-1, op[2])
      end


    elseif op[1] == OP_TYPE.DEL then
      lastPID = findPIDBefore(op[3])

      local sx, sy = findCharPositionExact(op[3])

      if sx then
        if sx == 1 then
          if sy-3 >= 0 then
            local prevline = vim.api.nvim_buf_get_lines(buf, sy-3, sy-2, true)[1]
            local curline = vim.api.nvim_buf_get_lines(buf, sy-2, sy-1, true)[1]
            vim.api.nvim_buf_set_lines(buf, sy-3, sy-1, true, { prevline .. curline })
          else
            vim.api.nvim_buf_set_lines(buf, sy-2, sy-1, true, {})
          end
        else
          if sy > 1 then
            local curline = vim.api.nvim_buf_get_lines(buf, sy-2, sy-1, true)[1]
            curline = utf8.remove(curline, sx-2)
            vim.api.nvim_buf_set_lines(buf, sy-2, sy-1, true, { curline })
          end
        end

        if sx == 1 then
          if sy-2 >= 1 then
            prev[sy-2] = prev[sy-2] .. string.sub(prev[sy-1], 1)
          end
          table.remove(prev, sy-1)
        else
          if sy > 1 then
            local curline = prev[sy-1]
            curline = utf8.remove(curline, sx-2)
            prev[sy-1] = curline
          end
        end

        if sx == 1 then
          for i,pid in ipairs(pids[sy]) do
            if i > 1 then
              table.insert(pids[sy-1], pid)
            end
          end
          table.remove(pids, sy)
        else
          table.remove(pids[sy], sx)
        end

      end

    end
    allprev[buf] = prev
    allpids[buf] = pids
    local aut = id2author[other_agent]

    if lastPID and other_agent ~= agent then
      local x, y = findCharPositionExact(lastPID)

      if old_namespace[aut] then
        if attached[old_namespace[aut].buf] then
          vim.api.nvim_buf_clear_namespace(
            old_namespace[aut].buf, old_namespace[aut].id,
            0, -1)
        end
        old_namespace[aut] = nil
      end

      if cursors[aut] then
        if attached[cursors[aut].buf] then
          vim.api.nvim_buf_clear_namespace(
            cursors[aut].buf, cursors[aut].id,
            0, -1)
        end
        cursors[aut] = nil
      end

      if x then
        if x == 1 then x = 2 end
        old_namespace[aut] = {
          id = vim.api.nvim_create_namespace(aut),
          buf = buf,
        }
        vim.api.nvim_buf_set_extmark(
          buf,
          old_namespace[aut].id,
          math.max(y - 2, 0),
          0,
          {
            virt_text = {{  aut, vtextGroup[client_hl_group[other_agent]] } },
            virt_text_pos = "right_align"
          }
        )

        if prev[y-1] and x-2 >= 0 and x-2 <= utf8.len(prev[y-1]) then
          local bx = vim.str_byteindex(prev[y-1], x-2)
          cursors[aut] = {
            id = vim.api.nvim_buf_add_highlight(buf,
              0, cursorGroup[client_hl_group[other_agent]], y-2, bx, bx+1),
            buf = buf,
            line = y-2,
          }
          if vim.api.nvim_buf_set_extmark then
            cursors[aut].ext_id =
              vim.api.nvim_buf_set_extmark(
                buf, cursors[aut].id, y-2, bx, {})
          end

        end

      end
      if follow and follow_aut == aut then
        local curbuf = vim.api.nvim_get_current_buf()
        if curbuf ~= buf then
          vim.api.nvim_set_current_buf(buf)
        end

        vim.api.nvim_command("normal " .. (y-1) .. "gg")
      end


      for _, o in pairs(api_attach) do
        if o.on_change then
          o.on_change(aut, buf, y-2)
        end
      end

    end
    -- @check_if_pid_match_with_prev

    SendOp(buf, op)

  end
  disable_undo = false
  if lastPID then
    local x, y = findCharPositionExact(lastPID)

    if prev[y-1] and x-2 >= 0 and x-2 <= utf8.len(prev[y-1]) then
      local bx = vim.str_byteindex(prev[y-1], x-2)
      vim.api.nvim_call_function("cursor", { y-1, bx+1 })
    end
  end

end

local function redo(buf)
  if undosp[buf] == #undostack[buf] then
    print("Already at newest change")
    return
  end

  undosp[buf] = undosp[buf]+1

  if undosp[buf] == 0 then
    print("Already at oldest change.")
    return
  end
  local ops = undostack[buf][undosp[buf]]
  local rev_ops = {}
  for i=#ops,1,-1 do
    table.insert(rev_ops, ops[i])
  end
  ops = rev_ops

  -- quick hack to avoid bug when first line is
  -- restored. The newlines are stored at
  -- the beginning. Because the undo will reverse
  -- the inserted character, it can happen that
  -- character are entered before any newline
  -- which will error. To avoid the last op is
  -- swapped with first
  local lowest = nil
  local firstpid = allpids[buf][2][1]
  for i,op in ipairs(ops) do
    if op[1] == OP_TYPE.INS and isLowerOrEqual(op[3], firstpid) then
      lowest = i
      break
    end
  end

  if lowest then
    ops[lowest], ops[1] = ops[1], ops[lowest]
  end

  local other_rem, other_agent = loc2rem[buf], agent
  disable_undo = true
  local lastPID
  for _, op in ipairs(ops) do
    local ag, bufid = unpack(other_rem)
    buf = rem2loc[ag][bufid]

    prev = allprev[buf]
    pids = allpids[buf]

    local tick = vim.api.nvim_buf_get_changedtick(buf)+1
    ignores[buf][tick] = true

    if op[1] == OP_TYPE.INS then
      lastPID = op[3]

      local x, y = findCharPositionBefore(op[3])

      if op[2] == "\n" then
        local py, py1 = splitArray(pids[y], x+1)
        pids[y] = py
        table.insert(py1, 1, op[3])
        table.insert(pids, y+1, py1)
      else table.insert(pids[y], x+1, op[3] ) end

      if op[2] == "\n" then
        if y-2 >= 0 then
          local curline = vim.api.nvim_buf_get_lines(buf, y-2, y-1, true)[1]
          local l, r = utf8.split(curline, x-1)
          vim.api.nvim_buf_set_lines(buf, y-2, y-1, true, { l, r })
        else
          vim.api.nvim_buf_set_lines(buf, 0, 0, true, { "" })
        end
      else
        local curline = vim.api.nvim_buf_get_lines(buf, y-2, y-1, true)[1]
        curline = utf8.insert(curline, x-1, op[2])
        vim.api.nvim_buf_set_lines(buf, y-2, y-1, true, { curline })
      end

      if op[2] == "\n" then
        if y-1 >= 1 then
          local l, r = utf8.split(prev[y-1], x-1)
          prev[y-1] = l
          table.insert(prev, y, r)
        else
          table.insert(prev, y, "")
        end
      else
        prev[y-1] = utf8.insert(prev[y-1], x-1, op[2])
      end


    elseif op[1] == OP_TYPE.DEL then
      lastPID = findPIDBefore(op[3])

      local sx, sy = findCharPositionExact(op[3])

      if sx then
        if sx == 1 then
          if sy-3 >= 0 then
            local prevline = vim.api.nvim_buf_get_lines(buf, sy-3, sy-2, true)[1]
            local curline = vim.api.nvim_buf_get_lines(buf, sy-2, sy-1, true)[1]
            vim.api.nvim_buf_set_lines(buf, sy-3, sy-1, true, { prevline .. curline })
          else
            vim.api.nvim_buf_set_lines(buf, sy-2, sy-1, true, {})
          end
        else
          if sy > 1 then
            local curline = vim.api.nvim_buf_get_lines(buf, sy-2, sy-1, true)[1]
            curline = utf8.remove(curline, sx-2)
            vim.api.nvim_buf_set_lines(buf, sy-2, sy-1, true, { curline })
          end
        end

        if sx == 1 then
          if sy-2 >= 1 then
            prev[sy-2] = prev[sy-2] .. string.sub(prev[sy-1], 1)
          end
          table.remove(prev, sy-1)
        else
          if sy > 1 then
            local curline = prev[sy-1]
            curline = utf8.remove(curline, sx-2)
            prev[sy-1] = curline
          end
        end

        if sx == 1 then
          for i,pid in ipairs(pids[sy]) do
            if i > 1 then
              table.insert(pids[sy-1], pid)
            end
          end
          table.remove(pids, sy)
        else
          table.remove(pids[sy], sx)
        end

      end

    end
    allprev[buf] = prev
    allpids[buf] = pids
    local aut = id2author[other_agent]

    if lastPID and other_agent ~= agent then
      local x, y = findCharPositionExact(lastPID)

      if old_namespace[aut] then
        if attached[old_namespace[aut].buf] then
          vim.api.nvim_buf_clear_namespace(
            old_namespace[aut].buf, old_namespace[aut].id,
            0, -1)
        end
        old_namespace[aut] = nil
      end

      if cursors[aut] then
        if attached[cursors[aut].buf] then
          vim.api.nvim_buf_clear_namespace(
            cursors[aut].buf, cursors[aut].id,
            0, -1)
        end
        cursors[aut] = nil
      end

      if x then
        if x == 1 then x = 2 end
        old_namespace[aut] = {
          id = vim.api.nvim_create_namespace(aut),
          buf = buf,
        }
        vim.api.nvim_buf_set_extmark(
          buf,
          old_namespace[aut].id,
          math.max(y - 2, 0),
          0,
          {
            virt_text = {{  aut, vtextGroup[client_hl_group[other_agent]] } },
            virt_text_pos = "right_align"
          }
        )

        if prev[y-1] and x-2 >= 0 and x-2 <= utf8.len(prev[y-1]) then
          local bx = vim.str_byteindex(prev[y-1], x-2)
          cursors[aut] = {
            id = vim.api.nvim_buf_add_highlight(buf,
              0, cursorGroup[client_hl_group[other_agent]], y-2, bx, bx+1),
            buf = buf,
            line = y-2,
          }
          if vim.api.nvim_buf_set_extmark then
            cursors[aut].ext_id =
              vim.api.nvim_buf_set_extmark(
                buf, cursors[aut].id, y-2, bx, {})
          end

        end

      end
      if follow and follow_aut == aut then
        local curbuf = vim.api.nvim_get_current_buf()
        if curbuf ~= buf then
          vim.api.nvim_set_current_buf(buf)
        end

        vim.api.nvim_command("normal " .. (y-1) .. "gg")
      end


      for _, o in pairs(api_attach) do
        if o.on_change then
          o.on_change(aut, buf, y-2)
        end
      end

    end
    -- @check_if_pid_match_with_prev

    SendOp(buf, op)

  end
  disable_undo = false
  if lastPID then
    local x, y = findCharPositionExact(lastPID)

    if prev[y-1] and x-2 >= 0 and x-2 <= utf8.len(prev[y-1]) then
      local bx = vim.str_byteindex(prev[y-1], x-2)
      vim.api.nvim_call_function("cursor", { y-1, bx+1 })
    end
  end

end


local function attach(callbacks)
  local o = {}
  for name, fn in pairs(callbacks) do
    if name == "on_connect" then
      o.on_connect = callbacks.on_connect

    elseif name == "on_disconnect" then
      o.on_disconnect = callbacks.on_disconnect

    elseif name == "on_change" then
      o.on_change = callbacks.on_change

    elseif name == "on_clientconnected" then
      o.on_clientconnected = callbacks.on_clientconnected

    elseif name == "on_clientdisconnected" then
      o.on_clientdisconnected = callbacks.on_clientdisconnected

    elseif name == "on_data" then
      o.on_data = callbacks.on_data

    else
      error("[blue_sentinel] Unknown callback " .. name)
    end
  end
  api_attach[api_attach_id] = o
  api_attach_id = api_attach_id + 1
  return api_attach_id
end

local function detach(id)
  if not api_attach[id] then
    error("[blue_sentinel] Could not detach (already detached?")
  end
  api_attach[id] = nil
end

local function get_connected_list()
  local connected = {}
  for _, aut in pairs(id2author) do
    table.insert(connected, aut)
  end
  return connected
end

local function send_data(data)
  local obj = {
    MSG_TYPE.DATA,
    data
  }

local encoded = vim.api.nvim_call_function("json_encode", { obj })
  ws_client:send_text(encoded)

end

local function get_connected_buf_list()
  local bufs = {}
  for buf, _ in pairs(loc2rem) do
    table.insert(bufs, buf)
  end
  return bufs
end


return {
attach = attach,

detach = detach,

get_connected_list = get_connected_list,

send_data = send_data,

get_connected_buf_list = get_connected_buf_list,
StartFollow = StartFollow,
StopFollow = StopFollow,

Start = Start,
Join = Join,
Stop = Stop,

StartSession = StartSession,
JoinSession = JoinSession,

undo = undo,

redo = redo,

LeaveInsert = LeaveInsert,

MarkRange = MarkRange,

MarkClear = MarkClear,

SaveBuffers = SaveBuffers,

OpenBuffers = OpenBuffers,

Status = Status,

}