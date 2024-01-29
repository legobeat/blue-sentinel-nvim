local vim = vim
local websocket_client = require("blue_sentinel.websocket_client")
local log = require("blue_sentinel.log")
local constants = require("blue_sentinel.constants")
local MSG_TYPE = constants.MSG_TYPE
local OP_TYPE = constants.OP_TYPE
local MAXINT = constants.MAXINT
local utf8 = require("blue_sentinel.utf8")
local util = require("blue_sentinel.util")
local isLowerOrEqual = util.isLowerOrEqual
local genPID = util.genPID
local genPIDSeq = util.genPIDSeq
local splitArray = util.splitArray
local getConfig = util.getConfig

local app_state = {
  agent = 0,
  allpids = {},
  allprev = {},
  api_attach = {},
  api_attach_id = 1,
  attached = {},
  author = vim.api.nvim_get_var("blue_sentinel_username"),
  autocmd_init = false,
  client_hl_group = {},
  cursorGroup = nil,
  cursors = {},
  detach = {},
  disable_undo = false,
  endpos = { { MAXINT, 0 } },
  follow = false,
  follow_aut = nil,
  hl_group = {},
  id2author = {},
  ignores = {},
  loc2rem = {},
  marks = {},
  old_namespace = nil,
  only_share_cwd = nil,
  pids = {},
  prev = { "" },
  received = {},
  rem2loc = {},
  sessionshare = false,
  singlebuf = nil,
  startpos = { { 0, 0 } },
  undoslice = {},
  undosp = {},
  undostack = {},
  vtextGroup = nil,
  ws_client = nil,
}

-- HELPERS {{{
local function afterPID(x, y)
  if x == #app_state.pids[y] then
    return app_state.pids[y + 1][1]
  else
    return app_state.pids[y][x + 1]
  end
end

local function findCharPositionBefore(opid)
  local y1, y2 = 1, #app_state.pids
  while true do
    local ym = math.floor((y2 + y1) / 2)
    if ym == y1 then break end
    if isLowerOrEqual(app_state.pids[ym][1], opid) then
      y1 = ym
    else
      y2 = ym
    end
  end

  local px, py = 1, 1
  for y = y1, #app_state.pids do
    for x, pid in ipairs(app_state.pids[y]) do
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
    return app_state.pids[y - 1][#app_state.pids[y - 1]]
  elseif x then
    return app_state.pids[y][x - 1]
  end
end
-- }}}

function SendOp(buf, op)
  if not app_state.disable_undo then
    table.insert(app_state.undoslice[buf], op)
  end

  local rem = app_state.loc2rem[buf]

  local obj = {
    MSG_TYPE.TEXT,
    op,
    rem,
    app_state.agent,
  }

  local encoded = vim.api.nvim_call_function("json_encode", { obj })

  log(string.format("send[%d] : %s", app_state.agent, vim.inspect(encoded)))
  app_state.ws_client:send_text(encoded)
end

local function on_lines(_, buf, changedtick, firstline, lastline, new_lastline, _bytecount)
  if app_state.detach[buf] then
    app_state.detach[buf] = nil
    return true
  end

  if app_state.ignores[buf][changedtick] then
    app_state.ignores[buf][changedtick] = nil
    return
  end

  app_state.prev = app_state.allprev[buf]
  app_state.pids = app_state.allpids[buf]

  local cur_lines = vim.api.nvim_buf_get_lines(buf, firstline, new_lastline, true)

  local add_range = {
    start_char = -1,
    start_line = firstline,
    end_char = -1, -- at position there is \n
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
      c2 = utf8.char(app_state.prev[del_range.end_line + 1] or "", del_range.end_char)
    end

    if c1 ~= c2 then
      break
    end

    local add_prev, del_prev
    if add_range.end_char == -1 then
      add_prev = {
        end_line = add_range.end_line - 1,
        end_char = utf8.len(cur_lines[add_range.end_line - firstline] or "") - 1
      }
    else
      add_prev = { end_char = add_range.end_char - 1, end_line = add_range.end_line }
    end

    if del_range.end_char == -1 then
      del_prev = { end_line = del_range.end_line - 1, end_char = utf8.len(app_state.prev[del_range.end_line] or "") - 1 }
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
      c2 = utf8.char(app_state.prev[del_range.start_line + 1] or "", del_range.start_char)
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

    if del_range.start_char == utf8.len(app_state.prev[del_range.start_line + 1] or "") then
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
        if #app_state.prev > 1 then
          if y > 0 then
            app_state.prev[y] = app_state.prev[y] .. (app_state.prev[y + 1] or "")
          end
          table.remove(app_state.prev, y + 1)

          local del_pid = app_state.pids[y + 2][1]
          for i, pid in ipairs(app_state.pids[y + 2]) do
            if i > 1 then
              table.insert(app_state.pids[y + 1], pid)
            end
          end
          table.remove(app_state.pids, y + 2)

          SendOp(buf, { OP_TYPE.DEL, "\n", del_pid })
        end
      else
        local c = utf8.char(app_state.prev[y + 1], x)

        app_state.prev[y + 1] = utf8.remove(app_state.prev[y + 1], x)

        local del_pid = app_state.pids[y + 2][x + 2]
        table.remove(app_state.pids[y + 2], x + 2)

        SendOp(buf, { OP_TYPE.DEL, c, del_pid })
      end
    end
    endx = utf8.len(app_state.prev[y] or "") - 1
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
      pidx = #app_state.pids[y + 1]
    end
    before_pid = app_state.pids[y + 1][pidx]
    after_pid = afterPID(pidx, y + 1)
  else
    local x, y = add_range.start_char, add_range.start_line
    before_pid = app_state.pids[y + 2][x + 1]
    after_pid = afterPID(x + 1, y + 2)
  end

  local newpidindex = 1
  local newpids = genPIDSeq(before_pid, after_pid, app_state.agent, 1, len_insert)

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
          local l, r = utf8.split(app_state.prev[y], utf8.len(cur_lines[y - firstline]))
          app_state.prev[y] = l
          table.insert(app_state.prev, y + 1, r)
        else
          table.insert(app_state.prev, y + 1, "")
        end

        local pidx
        if cur_lines[y - firstline] then
          pidx = utf8.len(cur_lines[y - firstline]) + 1
        else
          pidx = #app_state.pids[y + 1]
        end

        local new_pid = newpids[newpidindex]
        newpidindex = newpidindex + 1

        local l, r = splitArray(app_state.pids[y + 1], pidx + 1)
        app_state.pids[y + 1] = l
        table.insert(r, 1, new_pid)
        table.insert(app_state.pids, y + 2, r)

        SendOp(buf, { OP_TYPE.INS, "\n", new_pid })
      else
        local c = utf8.char(cur_lines[y - firstline + 1], x)
        app_state.prev[y + 1] = utf8.insert(app_state.prev[y + 1], x, c)

        local new_pid = newpids[newpidindex]
        newpidindex = newpidindex + 1

        table.insert(app_state.pids[y + 2], x + 2, new_pid)

        SendOp(buf, { OP_TYPE.INS, c, new_pid })
      end
    end
    startx = -1
  end

  app_state.allprev[buf] = app_state.prev
  app_state.allpids[buf] = app_state.pids

  local mode = vim.api.nvim_call_function("mode", {})
  local insert_mode = mode == "i"

  if not insert_mode then
    if #app_state.undoslice[buf] > 0 then
      while app_state.undosp[buf] < #app_state.undostack[buf] do
        table.remove(app_state.undostack[buf]) -- remove last element
      end
      table.insert(app_state.undostack[buf], app_state.undoslice[buf])
      app_state.undosp[buf] = app_state.undosp[buf] + 1
      app_state.undoslice[buf] = {}
    end
  end
end

local function attach_to_current_buffer(buf)
  app_state.attached[buf] = nil

  app_state.detach[buf] = nil

  app_state.undostack[buf] = {}
  app_state.undosp[buf] = 0

  app_state.undoslice[buf] = {}

  app_state.ignores[buf] = {}

  if not app_state.attached[buf] then
    local attach_success = vim.api.nvim_buf_attach(buf, false, {
      on_lines = on_lines,
      on_detach = function(_, buf)
        app_state.attached[buf] = nil
      end
    })

    -- Commented until I understand how the undo engine works
    -- vim.api.nvim_buf_set_keymap(buf, 'n', 'u', '<cmd>lua require("blue_sentinel").undo(' .. buf .. ')<CR>', {noremap = true})
    -- vim.api.nvim_buf_set_keymap(buf, 'n', '<C-r>', '<cmd>lua require("blue_sentinel").redo(' .. buf .. ')<CR>', {noremap = true})


    if attach_success then
      app_state.attached[buf] = true
    end
  else
    app_state.detach[buf] = nil
  end
end

function BlueSentinelOpenOrCreateBuffer(buf)
  if (app_state.sessionshare and not app_state.received[buf]) then
    local fullname = vim.api.nvim_buf_get_name(buf)
    local cwdname = vim.api.nvim_call_function("fnamemodify",
      { fullname, ":." })
    local bufname = cwdname
    if bufname == fullname then
      bufname = vim.api.nvim_call_function("fnamemodify",
        { fullname, ":t" })
    end


    if cwdname ~= fullname or not app_state.only_share_cwd then
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)

      local middlepos = genPID(app_state.startpos, app_state.endpos, app_state.agent, 1)
      app_state.pids = {
        { app_state.startpos },
        { middlepos },
        { app_state.endpos },
      }

      local numgen = 0
      for i = 1, #lines do
        local line = lines[i]
        if i > 1 then
          numgen = numgen + 1
        end

        for j = 1, string.len(line) do
          numgen = numgen + 1
        end
      end

      local newpidindex = 1
      local newpids = genPIDSeq(middlepos, app_state.endpos, app_state.agent, 1, numgen)

      for i = 1, #lines do
        local line = lines[i]
        if i > 1 then
          local newpid = newpids[newpidindex]
          newpidindex = newpidindex + 1

          table.insert(app_state.pids, i + 1, { newpid })
        end

        for j = 1, string.len(line) do
          local newpid = newpids[newpidindex]
          newpidindex = newpidindex + 1

          table.insert(app_state.pids[i + 1], newpid)
        end
      end

      app_state.prev = lines

      app_state.allprev[buf] = app_state.prev
      app_state.allpids[buf] = app_state.pids

      if not app_state.rem2loc[app_state.agent] then
        app_state.rem2loc[app_state.agent] = {}
      end

      app_state.rem2loc[app_state.agent][buf] = buf
      app_state.loc2rem[buf] = { app_state.agent, buf }

      local rem = app_state.loc2rem[buf]

      local pidslist = {}
      for _, lpid in ipairs(app_state.allpids[buf]) do
        for _, pid in ipairs(lpid) do
          table.insert(pidslist, pid[1][1])
        end
      end

      local obj = {
        MSG_TYPE.INITIAL,
        bufname,
        rem,
        pidslist,
        app_state.allprev[buf]
      }

      local encoded = vim.api.nvim_call_function("json_encode", { obj })

      app_state.ws_client:send_text(encoded)

      attach_to_current_buffer(buf)
    end
  end
end

function LeaveInsert()
  for buf, _ in pairs(app_state.undoslice) do
    if #app_state.undoslice[buf] > 0 then
      while app_state.undosp[buf] < #app_state.undostack[buf] do
        table.remove(app_state.undostack[buf]) -- remove last element
      end
      table.insert(app_state.undostack[buf], app_state.undoslice[buf])
      app_state.undosp[buf] = app_state.undosp[buf] + 1
      app_state.undoslice[buf] = {}
    end
  end
end

local function MarkRange()
  local _, snum, scol, _ = unpack(vim.api.nvim_call_function("getpos", { "'<" }))
  local _, enum, ecol, _ = unpack(vim.api.nvim_call_function("getpos", { "'>" }))

  local curbuf = vim.api.nvim_get_current_buf()
  local pids = app_state.allpids[curbuf]
  local prev = app_state.allprev[curbuf]

  ecol = math.min(ecol, string.len(prev[enum]) + 1)

  local bscol = vim.str_utfindex(prev[snum], scol - 1)
  local becol = vim.str_utfindex(prev[enum], ecol - 1)

  local spid = pids[snum + 1][bscol + 1]
  local epid
  if #pids[enum + 1] < becol + 1 then
    epid = pids[enum + 2][1]
  else
    epid = pids[enum + 1][becol + 1]
  end

  if app_state.marks[app_state.agent] then
    vim.api.nvim_buf_clear_namespace(app_state.marks[app_state.agent].buf, app_state.marks[app_state.agent].ns_id, 0, -1)
    app_state.marks[app_state.agent] = nil
  end

  app_state.marks[app_state.agent] = {}
  app_state.marks[app_state.agent].buf = curbuf
  app_state.marks[app_state.agent].ns_id = vim.api.nvim_create_namespace("")
  for y = snum - 1, enum - 1 do
    local lscol
    if y == snum - 1 then
      lscol = scol - 1
    else
      lscol = 0
    end

    local lecol
    if y == enum - 1 then
      lecol = ecol - 1
    else
      lecol = -1
    end

    vim.api.nvim_buf_add_highlight(
      app_state.marks[app_state.agent].buf,
      app_state.marks[app_state.agent].ns_id,
      "TermCursor",
      y, lscol, lecol)
  end

  local rem = app_state.loc2rem[curbuf]
  local obj = {
    MSG_TYPE.MARK,
    app_state.agent,
    rem,
    spid, epid,
  }

  local encoded = vim.api.nvim_call_function("json_encode", { obj })
  app_state.ws_client:send_text(encoded)
end

local function MarkClear()
  for _, mark in pairs(app_state.marks) do
    vim.api.nvim_buf_clear_namespace(mark.buf, mark.ns_id, 0, -1)
  end

  app_state.marks = {}
end

local function isPIDEqual(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i][1] ~= b[i][1] then return false end
    if a[i][2] ~= b[i][2] then return false end
  end
  return true
end

local function findCharPositionExact(opid)
  local y1, y2 = 1, #app_state.pids
  while true do
    local ym = math.floor((y2 + y1) / 2)
    if ym == y1 then break end
    if isLowerOrEqual(app_state.pids[ym][1], opid) then
      y1 = ym
    else
      y2 = ym
    end
  end

  local y = y1
  for x, pid in ipairs(app_state.pids[y]) do
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

  app_state.detach = {}

  app_state.vtextGroup = {
    getConfig("blue_sentinel_name_hl_group_user1", "CursorLineNr"),
    getConfig("blue_sentinel_name_hl_group_user2", "CursorLineNr"),
    getConfig("blue_sentinel_name_hl_group_user3", "CursorLineNr"),
    getConfig("blue_sentinel_name_hl_group_user4", "CursorLineNr"),
    getConfig("blue_sentinel_name_hl_group_default", "CursorLineNr")
  }

  app_state.old_namespace = {}

  app_state.cursorGroup = {
    getConfig("blue_sentinel_cursor_hl_group_user1", "Cursor"),
    getConfig("blue_sentinel_cursor_hl_group_user2", "Cursor"),
    getConfig("blue_sentinel_cursor_hl_group_user3", "Cursor"),
    getConfig("blue_sentinel_cursor_hl_group_user4", "Cursor"),
    getConfig("blue_sentinel_cursor_hl_group_default", "Cursor")
  }

  app_state.cursors = {}

  app_state.loc2rem = {}
  app_state.rem2loc = {}

  app_state.only_share_cwd = getConfig("g:blue_sentinel_only_cwd", true)

  app_state.ws_client = websocket_client { uri = appuri, port = port }
  if not app_state.ws_client then
    error("Could not connect to server")
    return
  end

  app_state.ws_client:connect {
    on_connect = function()
      local obj = {
        MSG_TYPE.INFO,
        app_state.sessionshare,
        app_state.author,
        app_state.agent,
      }
      local encoded = vim.api.nvim_call_function("json_encode", { obj })
      app_state.ws_client:send_text(encoded)


      for _, o in pairs(app_state.api_attach) do
        if o.on_connect then
          o.on_connect()
        end
      end

      vim.schedule(function() print("Connected!") end)
    end,
    on_text = function(wsdata)
      local decoded = vim.api.nvim_call_function("json_decode", { wsdata })

      if decoded then
        log(string.format("rec[%d] : %s", app_state.agent, vim.inspect(decoded)))
        if decoded[1] == MSG_TYPE.TEXT then
          local _, op, other_rem, other_agent = unpack(decoded)
          local lastPID

          local ag, bufid = unpack(other_rem)
          local buf = app_state.rem2loc[ag][bufid]

          app_state.prev = app_state.allprev[buf]
          app_state.pids = app_state.allpids[buf]

          local tick = vim.api.nvim_buf_get_changedtick(buf) + 1
          app_state.ignores[buf][tick] = true

          if op[1] == OP_TYPE.INS then
            lastPID = op[3]

            local x, y = findCharPositionBefore(op[3])

            if op[2] == "\n" then
              local py, py1 = splitArray(app_state.pids[y], x + 1)
              app_state.pids[y] = py
              table.insert(py1, 1, op[3])
              table.insert(app_state.pids, y + 1, py1)
            else
              table.insert(app_state.pids[y], x + 1, op[3])
            end

            if op[2] == "\n" then
              if y - 2 >= 0 then
                local curline = vim.api.nvim_buf_get_lines(buf, y - 2, y - 1, true)[1]
                local l, r = utf8.split(curline, x - 1)
                vim.api.nvim_buf_set_lines(buf, y - 2, y - 1, true, { l, r })
              else
                vim.api.nvim_buf_set_lines(buf, 0, 0, true, { "" })
              end
            else
              local curline = vim.api.nvim_buf_get_lines(buf, y - 2, y - 1, true)[1]
              curline = utf8.insert(curline, x - 1, op[2])
              vim.api.nvim_buf_set_lines(buf, y - 2, y - 1, true, { curline })
            end

            if op[2] == "\n" then
              if y - 1 >= 1 then
                local l, r = utf8.split(app_state.prev[y - 1], x - 1)
                app_state.prev[y - 1] = l
                table.insert(app_state.prev, y, r)
              else
                table.insert(app_state.prev, y, "")
              end
            else
              app_state.prev[y - 1] = utf8.insert(app_state.prev[y - 1], x - 1, op[2])
            end
          elseif op[1] == OP_TYPE.DEL then
            lastPID = findPIDBefore(op[3])

            local sx, sy = findCharPositionExact(op[3])

            if sx then
              if sx == 1 then
                if sy - 3 >= 0 then
                  local prevline = vim.api.nvim_buf_get_lines(buf, sy - 3, sy - 2, true)[1]
                  local curline = vim.api.nvim_buf_get_lines(buf, sy - 2, sy - 1, true)[1]
                  vim.api.nvim_buf_set_lines(buf, sy - 3, sy - 1, true, { prevline .. curline })
                else
                  vim.api.nvim_buf_set_lines(buf, sy - 2, sy - 1, true, {})
                end
              else
                if sy > 1 then
                  local curline = vim.api.nvim_buf_get_lines(buf, sy - 2, sy - 1, true)[1]
                  curline = utf8.remove(curline, sx - 2)
                  vim.api.nvim_buf_set_lines(buf, sy - 2, sy - 1, true, { curline })
                end
              end

              if sx == 1 then
                if sy - 2 >= 1 then
                  app_state.prev[sy - 2] = app_state.prev[sy - 2] .. string.sub(app_state.prev[sy - 1], 1)
                end
                table.remove(app_state.prev, sy - 1)
              else
                if sy > 1 then
                  local curline = app_state.prev[sy - 1]
                  curline = utf8.remove(curline, sx - 2)
                  app_state.prev[sy - 1] = curline
                end
              end

              if sx == 1 then
                for i, pid in ipairs(app_state.pids[sy]) do
                  if i > 1 then
                    table.insert(app_state.pids[sy - 1], pid)
                  end
                end
                table.remove(app_state.pids, sy)
              else
                table.remove(app_state.pids[sy], sx)
              end
            end
          end
          app_state.allprev[buf] = app_state.prev
          app_state.allpids[buf] = app_state.pids
          local author = app_state.id2author[other_agent]

          if lastPID and other_agent ~= app_state.agent then
            local x, y = findCharPositionExact(lastPID)

            if app_state.old_namespace[author] then
              if app_state.attached[app_state.old_namespace[author].buf] then
                vim.api.nvim_buf_clear_namespace(
                  app_state.old_namespace[author].buf, app_state.old_namespace[author].id,
                  0, -1)
              end
              app_state.old_namespace[author] = nil
            end

            if app_state.cursors[author] then
              if app_state.attached[app_state.cursors[author].buf] then
                vim.api.nvim_buf_clear_namespace(
                  app_state.cursors[author].buf, app_state.cursors[author].id,
                  0, -1)
              end
              app_state.cursors[author] = nil
            end

            if x then
              if x == 1 then x = 2 end
              app_state.old_namespace[author] = {
                id = vim.api.nvim_create_namespace(author),
                buf = buf,
              }
              vim.api.nvim_buf_set_extmark(
                buf,
                app_state.old_namespace[author].id,
                math.max(y - 2, 0),
                0,
                {
                  virt_text = { { author, app_state.vtextGroup[app_state.client_hl_group[other_agent]] } },
                  virt_text_pos = "right_align"
                }
              )

              if app_state.prev[y - 1] and x - 2 >= 0 and x - 2 <= utf8.len(app_state.prev[y - 1]) then
                local bx = vim.str_byteindex(app_state.prev[y - 1], x - 2)
                app_state.cursors[author] = {
                  id = vim.api.nvim_buf_add_highlight(buf,
                    0, app_state.cursorGroup[app_state.client_hl_group[other_agent]], y - 2, bx, bx + 1),
                  buf = buf,
                  line = y - 2,
                }
                if vim.api.nvim_buf_set_extmark then
                  app_state.cursors[author].ext_id =
                      vim.api.nvim_buf_set_extmark(
                        buf, app_state.cursors[author].id, y - 2, bx, {})
                end
              end
            end
            if app_state.follow and app_state.follow_aut == author then
              local curbuf = vim.api.nvim_get_current_buf()
              if curbuf ~= buf then
                vim.api.nvim_set_current_buf(buf)
              end

              vim.api.nvim_command("normal " .. (y - 1) .. "gg")
            end


            for _, o in pairs(app_state.api_attach) do
              if o.on_change then
                o.on_change(author, buf, y - 2)
              end
            end
          end
          -- @check_if_pid_match_with_prev
        end

        if decoded[1] == MSG_TYPE.REQUEST then
          local encoded

          local function pidslist(b)
            local ps = {}
            for _, lpid in ipairs(app_state.allpids[b]) do
              for _, pid in ipairs(lpid) do
                table.insert(ps, pid)
              end
            end
            return ps
          end

          local function send_initial_for_buffer(buf)
            local rem
            if app_state.loc2rem[buf] then
              rem = app_state.loc2rem[buf]
            else
              rem = { app_state.agent, buf }
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
              app_state.allprev[buf]
            }

            encoded = vim.api.nvim_call_function("json_encode", { obj })

            app_state.ws_client:send_text(encoded)
          end

          if not app_state.sessionshare then
            send_initial_for_buffer(app_state.singlebuf)
          else
            local allbufs = vim.api.nvim_list_bufs()
            local bufs = {}
            -- skip terminal, help, ... buffers
            for _, buf in ipairs(allbufs) do
              local buftype = vim.api.nvim_buf_get_option(buf, "buftype")
              if buftype == "" then
                table.insert(bufs, buf)
              end
            end

            for _, buf in ipairs(bufs) do
              send_initial_for_buffer(buf)
            end
          end
        end


        if decoded[1] == MSG_TYPE.INITIAL then
          local _, bufname, bufid, pidslist, content = unpack(decoded)

          local ag, bufid = unpack(bufid)
          if not app_state.rem2loc[ag] or not app_state.rem2loc[ag][bufid] then
            local buf
            if not app_state.sessionshare then
              buf = app_state.singlebuf
              vim.api.nvim_buf_set_name(buf, bufname)

              if vim.api.nvim_buf_call then
                vim.api.nvim_buf_call(buf, function()
                  vim.api.nvim_command("doautocmd BufRead " .. vim.api.nvim_buf_get_name(buf))
                end)
              end
            else
              buf = vim.api.nvim_create_buf(true, true)

              app_state.received[buf] = true

              attach_to_current_buffer(buf)

              vim.api.nvim_buf_set_name(buf, bufname)

              if vim.api.nvim_buf_call then
                vim.api.nvim_buf_call(buf, function()
                  vim.api.nvim_command("doautocmd BufRead " .. vim.api.nvim_buf_get_name(buf))
                end)
              end

              vim.api.nvim_buf_set_option(buf, "buftype", "")
            end

            if not app_state.rem2loc[ag] then
              app_state.rem2loc[ag] = {}
            end

            app_state.rem2loc[ag][bufid] = buf
            app_state.loc2rem[buf] = { ag, bufid }


            app_state.prev = content

            local pidindex = 1
            app_state.pids = {}

            table.insert(app_state.pids, { pidslist[pidindex] })
            pidindex = pidindex + 1

            for _, line in ipairs(content) do
              local lpid = {}
              for i = 0, utf8.len(line) do
                table.insert(lpid, pidslist[pidindex])
                pidindex = pidindex + 1
              end
              table.insert(app_state.pids, lpid)
            end

            table.insert(app_state.pids, { pidslist[pidindex] })


            local tick = vim.api.nvim_buf_get_changedtick(buf) + 1
            app_state.ignores[buf][tick] = true

            vim.api.nvim_buf_set_lines(
              buf,
              0, -1, false, app_state.prev)

            app_state.allprev[buf] = app_state.prev
            app_state.allpids[buf] = app_state.pids
          else
            local buf = app_state.rem2loc[ag][bufid]

            app_state.prev = content

            local pidindex = 1
            app_state.pids = {}

            table.insert(app_state.pids, { pidslist[pidindex] })
            pidindex = pidindex + 1

            for _, line in ipairs(content) do
              local lpid = {}
              for i = 0, utf8.len(line) do
                table.insert(lpid, pidslist[pidindex])
                pidindex = pidindex + 1
              end
              table.insert(app_state.pids, lpid)
            end

            table.insert(app_state.pids, { pidslist[pidindex] })


            local tick = vim.api.nvim_buf_get_changedtick(buf) + 1
            app_state.ignores[buf][tick] = true

            vim.api.nvim_buf_set_lines(
              buf,
              0, -1, false, app_state.prev)

            app_state.allprev[buf] = app_state.prev
            app_state.allpids[buf] = app_state.pids

            vim.api.nvim_buf_set_name(buf, bufname)

            if vim.api.nvim_buf_call then
              vim.api.nvim_buf_call(buf, function()
                vim.api.nvim_command("doautocmd BufRead " .. vim.api.nvim_buf_get_name(buf))
              end)
            end
          end
        end

        if decoded[1] == MSG_TYPE.AVAILABLE then
          local _, is_first, client_id, is_sessionshare = unpack(decoded)
          if is_first and first then
            app_state.agent = client_id


            if app_state.sessionshare then
              local allbufs = vim.api.nvim_list_bufs()
              local bufs = {}
              -- skip terminal, help, ... buffers
              for _, buf in ipairs(allbufs) do
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

                local middlepos = genPID(app_state.startpos, app_state.endpos, app_state.agent, 1)
                app_state.pids = {
                  { app_state.startpos },
                  { middlepos },
                  { app_state.endpos },
                }

                local numgen = 0
                for i = 1, #lines do
                  local line = lines[i]
                  if i > 1 then
                    numgen = numgen + 1
                  end

                  for j = 1, string.len(line) do
                    numgen = numgen + 1
                  end
                end

                local newpidindex = 1
                local newpids = genPIDSeq(middlepos, app_state.endpos, app_state.agent, 1, numgen)

                for i = 1, #lines do
                  local line = lines[i]
                  if i > 1 then
                    local newpid = newpids[newpidindex]
                    newpidindex = newpidindex + 1

                    table.insert(app_state.pids, i + 1, { newpid })
                  end

                  for j = 1, string.len(line) do
                    local newpid = newpids[newpidindex]
                    newpidindex = newpidindex + 1

                    table.insert(app_state.pids[i + 1], newpid)
                  end
                end

                app_state.prev = lines

                app_state.allprev[buf] = app_state.prev
                app_state.allpids[buf] = app_state.pids
                if not app_state.rem2loc[app_state.agent] then
                  app_state.rem2loc[app_state.agent] = {}
                end

                app_state.rem2loc[app_state.agent][buf] = buf
                app_state.loc2rem[buf] = { app_state.agent, buf }
              end
            else
              local buf = app_state.singlebuf

              attach_to_current_buffer(buf)

              if not app_state.rem2loc[app_state.agent] then
                app_state.rem2loc[app_state.agent] = {}
              end

              app_state.rem2loc[app_state.agent][buf] = buf
              app_state.loc2rem[buf] = { app_state.agent, buf }

              local rem = app_state.loc2rem[buf]


              local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)

              local middlepos = genPID(app_state.startpos, app_state.endpos, app_state.agent, 1)
              app_state.pids = {
                { app_state.startpos },
                { middlepos },
                { app_state.endpos },
              }

              local numgen = 0
              for i = 1, #lines do
                local line = lines[i]
                if i > 1 then
                  numgen = numgen + 1
                end

                for j = 1, string.len(line) do
                  numgen = numgen + 1
                end
              end

              local newpidindex = 1
              local newpids = genPIDSeq(middlepos, app_state.endpos, app_state.agent, 1, numgen)

              for i = 1, #lines do
                local line = lines[i]
                if i > 1 then
                  local newpid = newpids[newpidindex]
                  newpidindex = newpidindex + 1

                  table.insert(app_state.pids, i + 1, { newpid })
                end

                for j = 1, string.len(line) do
                  local newpid = newpids[newpidindex]
                  newpidindex = newpidindex + 1

                  table.insert(app_state.pids[i + 1], newpid)
                end
              end

              app_state.prev = lines

              app_state.allprev[buf] = app_state.prev
              app_state.allpids[buf] = app_state.pids
            end

            vim.api.nvim_command("augroup blueSentinelSession")
            vim.api.nvim_command("autocmd!")
            -- this is kind of messy
            -- a better way to write this
            -- would be great
            vim.api.nvim_command(
            "autocmd BufNewFile,BufRead * call execute('lua BlueSentinelOpenOrCreateBuffer(' . expand('<abuf>') . ')', '')")
            vim.api.nvim_command("augroup end")
          elseif not is_first and not first then
            if is_sessionshare ~= app_state.sessionshare then
              print("ERROR: Share mode client server mismatch (session mode, single buffer mode)")
              for author, _ in pairs(app_state.cursors) do
                if app_state.cursors[author] then
                  if app_state.attached[app_state.cursors[author].buf] then
                    vim.api.nvim_buf_clear_namespace(
                      app_state.cursors[author].buf, app_state.cursors[author].id,
                      0, -1)
                  end
                  app_state.cursors[author] = nil
                end

                if app_state.old_namespace[author] then
                  if app_state.attached[app_state.old_namespace[author].buf] then
                    vim.api.nvim_buf_clear_namespace(
                      app_state.old_namespace[author].buf, app_state.old_namespace[author].id,
                      0, -1)
                  end
                  app_state.old_namespace[author] = nil
                end
              end
              app_state.cursors = {}
              vim.api.nvim_command("augroup blueSentinelSession")
              vim.api.nvim_command("autocmd!")
              vim.api.nvim_command("augroup end")


              for bufhandle, _ in pairs(app_state.allprev) do
                if vim.api.nvim_buf_is_loaded(bufhandle) then
                  DetachFromBuffer(bufhandle)
                end
              end

              app_state.agent = 0
            else
              app_state.agent = client_id


              if not app_state.sessionshare then
                local buf = app_state.singlebuf
                attach_to_current_buffer(buf)
              end
              local obj = {
                MSG_TYPE.REQUEST,
              }
              local encoded = vim.api.nvim_call_function("json_encode", { obj })
              app_state.ws_client:send_text(encoded)


              vim.api.nvim_command("augroup blueSentinelSession")
              vim.api.nvim_command("autocmd!")
              -- this is kind of messy
              -- a better way to write this
              -- would be great
              vim.api.nvim_command(
              "autocmd BufNewFile,BufRead * call execute('lua BlueSentinelOpenOrCreateBuffer(' . expand('<abuf>') . ')', '')")
              vim.api.nvim_command("augroup end")
            end
          elseif is_first and not first then
            print("ERROR: Tried to join an empty server")
            for author, _ in pairs(app_state.cursors) do
              if app_state.cursors[author] then
                if app_state.attached[app_state.cursors[author].buf] then
                  vim.api.nvim_buf_clear_namespace(
                    app_state.cursors[author].buf, app_state.cursors[author].id,
                    0, -1)
                end
                app_state.cursors[author] = nil
              end

              if app_state.old_namespace[author] then
                if app_state.attached[app_state.old_namespace[author].buf] then
                  vim.api.nvim_buf_clear_namespace(
                    app_state.old_namespace[author].buf, app_state.old_namespace[author].id,
                    0, -1)
                end
                app_state.old_namespace[author] = nil
              end
            end
            app_state.cursors = {}
            vim.api.nvim_command("augroup blueSentinelSession")
            vim.api.nvim_command("autocmd!")
            vim.api.nvim_command("augroup end")


            for bufhandle, _ in pairs(app_state.allprev) do
              if vim.api.nvim_buf_is_loaded(bufhandle) then
                DetachFromBuffer(bufhandle)
              end
            end

            app_state.agent = 0
          elseif not is_first and first then
            print("ERROR: Tried to start a server which is already busy")
            for author, _ in pairs(app_state.cursors) do
              if app_state.cursors[author] then
                if app_state.attached[app_state.cursors[author].buf] then
                  vim.api.nvim_buf_clear_namespace(
                    app_state.cursors[author].buf, app_state.cursors[author].id,
                    0, -1)
                end
                app_state.cursors[author] = nil
              end

              if app_state.old_namespace[author] then
                if app_state.attached[app_state.old_namespace[author].buf] then
                  vim.api.nvim_buf_clear_namespace(
                    app_state.old_namespace[author].buf, app_state.old_namespace[author].id,
                    0, -1)
                end
                app_state.old_namespace[author] = nil
              end
            end
            app_state.cursors = {}
            vim.api.nvim_command("augroup blueSentinelSession")
            vim.api.nvim_command("autocmd!")
            vim.api.nvim_command("augroup end")


            for bufhandle, _ in pairs(app_state.allprev) do
              if vim.api.nvim_buf_is_loaded(bufhandle) then
                DetachFromBuffer(bufhandle)
              end
            end

            app_state.agent = 0
          end
        end

        if decoded[1] == MSG_TYPE.CONNECT then
          local _, new_id, new_aut = unpack(decoded)
          app_state.id2author[new_id] = new_aut
          local user_hl_group = 5
          for i = 1, 4 do
            if not app_state.hl_group[i] then
              app_state.hl_group[i] = true
              user_hl_group = i
              break
            end
          end

          app_state.client_hl_group[new_id] = user_hl_group

          for _, o in pairs(app_state.api_attach) do
            if o.on_clientconnected then
              o.on_clientconnected(new_aut)
            end
          end
        end

        if decoded[1] == MSG_TYPE.DISCONNECT then
          local _, remove_id = unpack(decoded)
          local author = app_state.id2author[remove_id]
          if author then
            app_state.id2author[remove_id] = nil
            if app_state.client_hl_group[remove_id] ~= 5 then -- 5 means default hl group (there are four predefined)
              app_state.hl_group[app_state.client_hl_group[remove_id]] = nil
            end
            app_state.client_hl_group[remove_id] = nil

            for _, o in pairs(app_state.api_attach) do
              if o.on_clientdisconnected then
                o.on_clientdisconnected(author)
              end
            end
          end
        end
        if decoded[1] == MSG_TYPE.DATA then
          local _, data = unpack(decoded)
          for _, o in pairs(app_state.api_attach) do
            if o.on_data then
              o.on_data(data)
            end
          end
        end

        if decoded[1] == MSG_TYPE.MARK then
          local _, other_agent, rem, spid, epid = unpack(decoded)
          local ag, rembuf = unpack(rem)
          local buf = app_state.rem2loc[ag][rembuf]

          local sx, sy = findCharPositionExact(spid)
          local ex, ey = findCharPositionExact(epid)

          if app_state.marks[other_agent] then
            vim.api.nvim_buf_clear_namespace(app_state.marks[other_agent].buf, app_state.marks[other_agent].ns_id, 0, -1)
            app_state.marks[other_agent] = nil
          end

          app_state.marks[other_agent] = {}
          app_state.marks[other_agent].buf = buf
          app_state.marks[other_agent].ns_id = vim.api.nvim_create_namespace("")
          local scol = vim.str_byteindex(app_state.prev[sy - 1], sx - 1)
          local ecol = vim.str_byteindex(app_state.prev[ey - 1], ex - 1)

          for y = sy - 1, ey - 1 do
            local lscol
            if y == sy - 1 then
              lscol = scol
            else
              lscol = 0
            end

            local lecol
            if y == ey - 1 then
              lecol = ecol
            else
              lecol = -1
            end

            vim.api.nvim_buf_add_highlight(
              app_state.marks[other_agent].buf,
              app_state.marks[other_agent].ns_id,
              app_state.cursorGroup[app_state.client_hl_group[other_agent]],
              y - 1, lscol, lecol)
          end

          local author = app_state.id2author[other_agent]

          app_state.old_namespace[author] = {
            id = vim.api.nvim_create_namespace(author),
            buf = buf,
          }

          vim.api.nvim_buf_set_extmark(
            buf,
            app_state.marks[other_agent].ns_id,
            sy - 2,
            0,
            {
              virt_text = { { author, app_state.vtextGroup[app_state.client_hl_group[other_agent]] } },
              virt_text_pos = "right_align"
            }
          )

          if app_state.follow and app_state.follow_aut == author then
            local curbuf = vim.api.nvim_get_current_buf()
            if curbuf ~= buf then
              vim.api.nvim_set_current_buf(buf)
            end

            local y = sy
            vim.api.nvim_command("normal " .. (y - 1) .. "gg")
          end
        end
      else
        error("Could not decode json " .. wsdata)
      end
    end,
    on_disconnect = function()
      for author, _ in pairs(app_state.cursors) do
        if app_state.cursors[author] then
          if app_state.attached[app_state.cursors[author].buf] then
            vim.api.nvim_buf_clear_namespace(
              app_state.cursors[author].buf, app_state.cursors[author].id,
              0, -1)
          end
          app_state.cursors[author] = nil
        end

        if app_state.old_namespace[author] then
          if app_state.attached[app_state.old_namespace[author].buf] then
            vim.api.nvim_buf_clear_namespace(
              app_state.old_namespace[author].buf, app_state.old_namespace[author].id,
              0, -1)
          end
          app_state.old_namespace[author] = nil
        end
      end
      app_state.cursors = {}
      vim.api.nvim_command("augroup blueSentinelSession")
      vim.api.nvim_command("autocmd!")
      vim.api.nvim_command("augroup end")


      for bufhandle, _ in pairs(app_state.allprev) do
        if vim.api.nvim_buf_is_loaded(bufhandle) then
          DetachFromBuffer(bufhandle)
        end
      end

      app_state.agent = 0
      for _, o in pairs(app_state.api_attach) do
        if o.on_disconnect then
          o.on_disconnect()
        end
      end

      vim.schedule(function() print("Disconnected.") end)
    end
  }
end

function DetachFromBuffer(bufnr)
  app_state.detach[bufnr] = true
end

local function setup_autocmd()
  if not app_state.autocmd_init then
    vim.api.nvim_command("augroup blueSentinelUndo")
    vim.api.nvim_command("autocmd!")
    vim.api.nvim_command([[autocmd InsertLeave * lua require"blue_sentinel".LeaveInsert()]])
    vim.api.nvim_command("augroup end")
    app_state.autocmd_init = true
  end
end

local function start_with(args)
  local host = args.host
  local port = args.port
  local first = args.first
  local sessionshare = args.sessionshare

  if app_state.ws_client and app_state.ws_client:is_active() then
    print("Client is already connected. Use BlueSentinelStop first to disconnect.")
    return
  end

  setup_autocmd()

  local buf = vim.api.nvim_get_current_buf()
  app_state.singlebuf = buf
  app_state.sessionshare = sessionshare
  StartClient(first, host, port)
end

local function StartSingle(host, port)
  start_with({ host = host, port = port, first = true, sessionshare = false })
end

local function JoinSingle(host, port)
  start_with({ host = host, port = port, first = false, sessionshare = false })
end

local function StartSession(host, port)
  start_with({ host = host, port = port, first = true, sessionshare = true })
end

local function JoinSession(host, port)
  start_with({ host = host, port = port, first = false, sessionshare = true })
end

local function Stop()
  app_state.ws_client:disconnect()
  app_state.ws_client = nil
end

local function Status()
  if app_state.ws_client and app_state.ws_client:is_active() then
    local positions = {}
    for _, author in pairs(app_state.id2author) do
      local c = app_state.cursors[author]
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
          line, _ = unpack(vim.api.nvim_buf_get_extmark_by_id(
            buf, c.id, c.ext_id, {}))
        else
          line = c.y
        end

        table.insert(positions, { author, bufname, line + 1 })
      else
        table.insert(positions, { author, "", "" })
      end
    end

    local info_str = {}
    for _, pos in ipairs(positions) do
      table.insert(info_str, table.concat(pos, " "))
    end
    print("Connected. " .. #info_str .. " other client(s)\n\n" .. table.concat(info_str, "\n"))
  else
    print("Disconnected.")
  end
end

local function StartFollow(author)
  app_state.follow = true
  app_state.follow_aut = author
  print("Following " .. author)
end

local function StopFollow()
  app_state.follow = false
  print("Following Stopped.")
end

local function SaveBuffers(force)
  local allbufs = vim.api.nvim_list_bufs()
  local bufs = {}
  -- skip terminal, help, ... buffers
  for _, buf in ipairs(allbufs) do
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

  for _, buf in ipairs(bufs) do
    local fullname = vim.api.nvim_buf_get_name(buf)

    local parentdir = vim.api.nvim_call_function("fnamemodify", { fullname, ":h" })
    local isdir = vim.api.nvim_call_function("isdirectory", { parentdir })
    if isdir == 0 then
      vim.api.nvim_call_function("mkdir", { parentdir, "p" })
    end

    vim.api.nvim_command("b " .. buf)
    if force then
      vim.api.nvim_command("w!") -- write all
    else
      vim.api.nvim_command("w")  -- write all
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
  for _, file in ipairs(files) do
    vim.api.nvim_command("args " .. file)
    num_files = num_files + 1
  end
  print("Opened " .. num_files .. " files.")
end

local function undo(buf)
  if app_state.undosp[buf] == 0 then
    print("Already at oldest change.")
    return
  end
  local ops = app_state.undostack[buf][app_state.undosp[buf]]
  local rev_ops = {}
  for i = #ops, 1, -1 do
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
  local firstpid = app_state.allpids[buf][2][1]
  for i, op in ipairs(ops) do
    if op[1] == OP_TYPE.INS and isLowerOrEqual(op[3], firstpid) then
      lowest = i
      break
    end
  end

  if lowest then
    ops[lowest], ops[1] = ops[1], ops[lowest]
  end

  app_state.undosp[buf] = app_state.undosp[buf] - 1


  app_state.disable_undo = true
  local other_rem, other_agent = app_state.loc2rem[buf], app_state.agent
  local lastPID
  for _, op in ipairs(ops) do
    if op[1] == OP_TYPE.INS then
      op = { OP_TYPE.DEL, op[3], op[2] }
    elseif op[1] == OP_TYPE.DEL then
      op = { OP_TYPE.INS, op[3], op[2] }
    end

    local ag, bufid = unpack(other_rem)
    buf = app_state.rem2loc[ag][bufid]

    app_state.prev = app_state.allprev[buf]
    app_state.pids = app_state.allpids[buf]

    local tick = vim.api.nvim_buf_get_changedtick(buf) + 1
    app_state.ignores[buf][tick] = true

    if op[1] == OP_TYPE.INS then
      lastPID = op[3]

      local x, y = findCharPositionBefore(op[3])

      if op[2] == "\n" then
        local py, py1 = splitArray(app_state.pids[y], x + 1)
        app_state.pids[y] = py
        table.insert(py1, 1, op[3])
        table.insert(app_state.pids, y + 1, py1)
      else
        table.insert(app_state.pids[y], x + 1, op[3])
      end

      if op[2] == "\n" then
        if y - 2 >= 0 then
          local curline = vim.api.nvim_buf_get_lines(buf, y - 2, y - 1, true)[1]
          local l, r = utf8.split(curline, x - 1)
          vim.api.nvim_buf_set_lines(buf, y - 2, y - 1, true, { l, r })
        else
          vim.api.nvim_buf_set_lines(buf, 0, 0, true, { "" })
        end
      else
        local curline = vim.api.nvim_buf_get_lines(buf, y - 2, y - 1, true)[1]
        curline = utf8.insert(curline, x - 1, op[2])
        vim.api.nvim_buf_set_lines(buf, y - 2, y - 1, true, { curline })
      end

      if op[2] == "\n" then
        if y - 1 >= 1 then
          local l, r = utf8.split(app_state.prev[y - 1], x - 1)
          app_state.prev[y - 1] = l
          table.insert(app_state.prev, y, r)
        else
          table.insert(app_state.prev, y, "")
        end
      else
        app_state.prev[y - 1] = utf8.insert(app_state.prev[y - 1], x - 1, op[2])
      end
    elseif op[1] == OP_TYPE.DEL then
      lastPID = findPIDBefore(op[3])

      local sx, sy = findCharPositionExact(op[3])

      if sx then
        if sx == 1 then
          if sy - 3 >= 0 then
            local prevline = vim.api.nvim_buf_get_lines(buf, sy - 3, sy - 2, true)[1]
            local curline = vim.api.nvim_buf_get_lines(buf, sy - 2, sy - 1, true)[1]
            vim.api.nvim_buf_set_lines(buf, sy - 3, sy - 1, true, { prevline .. curline })
          else
            vim.api.nvim_buf_set_lines(buf, sy - 2, sy - 1, true, {})
          end
        else
          if sy > 1 then
            local curline = vim.api.nvim_buf_get_lines(buf, sy - 2, sy - 1, true)[1]
            curline = utf8.remove(curline, sx - 2)
            vim.api.nvim_buf_set_lines(buf, sy - 2, sy - 1, true, { curline })
          end
        end

        if sx == 1 then
          if sy - 2 >= 1 then
            app_state.prev[sy - 2] = app_state.prev[sy - 2] .. string.sub(app_state.prev[sy - 1], 1)
          end
          table.remove(app_state.prev, sy - 1)
        else
          if sy > 1 then
            local curline = app_state.prev[sy - 1]
            curline = utf8.remove(curline, sx - 2)
            app_state.prev[sy - 1] = curline
          end
        end

        if sx == 1 then
          for i, pid in ipairs(app_state.pids[sy]) do
            if i > 1 then
              table.insert(app_state.pids[sy - 1], pid)
            end
          end
          table.remove(app_state.pids, sy)
        else
          table.remove(app_state.pids[sy], sx)
        end
      end
    end
    app_state.allprev[buf] = app_state.prev
    app_state.allpids[buf] = app_state.pids
    local author = app_state.id2author[other_agent]

    if lastPID and other_agent ~= app_state.agent then
      local x, y = findCharPositionExact(lastPID)

      if app_state.old_namespace[author] then
        if app_state.attached[app_state.old_namespace[author].buf] then
          vim.api.nvim_buf_clear_namespace(
            app_state.old_namespace[author].buf, app_state.old_namespace[author].id,
            0, -1)
        end
        app_state.old_namespace[author] = nil
      end

      if app_state.cursors[author] then
        if app_state.attached[app_state.cursors[author].buf] then
          vim.api.nvim_buf_clear_namespace(
            app_state.cursors[author].buf, app_state.cursors[author].id,
            0, -1)
        end
        app_state.cursors[author] = nil
      end

      if x then
        if x == 1 then x = 2 end
        app_state.old_namespace[author] = {
          id = vim.api.nvim_create_namespace(author),
          buf = buf,
        }
        vim.api.nvim_buf_set_extmark(
          buf,
          app_state.old_namespace[author].id,
          math.max(y - 2, 0),
          0,
          {
            virt_text = { { author, app_state.vtextGroup[app_state.client_hl_group[other_agent]] } },
            virt_text_pos = "right_align"
          }
        )

        if app_state.prev[y - 1] and x - 2 >= 0 and x - 2 <= utf8.len(app_state.prev[y - 1]) then
          local bx = vim.str_byteindex(app_state.prev[y - 1], x - 2)
          app_state.cursors[author] = {
            id = vim.api.nvim_buf_add_highlight(buf,
              0, app_state.cursorGroup[app_state.client_hl_group[other_agent]], y - 2, bx, bx + 1),
            buf = buf,
            line = y - 2,
          }
          if vim.api.nvim_buf_set_extmark then
            app_state.cursors[author].ext_id =
                vim.api.nvim_buf_set_extmark(
                  buf, app_state.cursors[author].id, y - 2, bx, {})
          end
        end
      end
      if app_state.follow and app_state.follow_aut == author then
        local curbuf = vim.api.nvim_get_current_buf()
        if curbuf ~= buf then
          vim.api.nvim_set_current_buf(buf)
        end

        vim.api.nvim_command("normal " .. (y - 1) .. "gg")
      end


      for _, o in pairs(app_state.api_attach) do
        if o.on_change then
          o.on_change(author, buf, y - 2)
        end
      end
    end
    -- @check_if_pid_match_with_prev

    SendOp(buf, op)
  end
  app_state.disable_undo = false
  if lastPID then
    local x, y = findCharPositionExact(lastPID)

    if app_state.prev[y - 1] and x - 2 >= 0 and x - 2 <= utf8.len(app_state.prev[y - 1]) then
      local bx = vim.str_byteindex(app_state.prev[y - 1], x - 2)
      vim.api.nvim_call_function("cursor", { y - 1, bx + 1 })
    end
  end
end

local function redo(buf)
  if app_state.undosp[buf] == #app_state.undostack[buf] then
    print("Already at newest change")
    return
  end

  app_state.undosp[buf] = app_state.undosp[buf] + 1

  if app_state.undosp[buf] == 0 then
    print("Already at oldest change.")
    return
  end
  local ops = app_state.undostack[buf][app_state.undosp[buf]]
  local rev_ops = {}
  for i = #ops, 1, -1 do
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
  local firstpid = app_state.allpids[buf][2][1]
  for i, op in ipairs(ops) do
    if op[1] == OP_TYPE.INS and isLowerOrEqual(op[3], firstpid) then
      lowest = i
      break
    end
  end

  if lowest then
    ops[lowest], ops[1] = ops[1], ops[lowest]
  end

  local other_rem, other_agent = app_state.loc2rem[buf], app_state.agent
  app_state.disable_undo = true
  local lastPID
  for _, op in ipairs(ops) do
    local ag, bufid = unpack(other_rem)
    buf = app_state.rem2loc[ag][bufid]

    app_state.prev = app_state.allprev[buf]
    app_state.pids = app_state.allpids[buf]

    local tick = vim.api.nvim_buf_get_changedtick(buf) + 1
    app_state.ignores[buf][tick] = true

    if op[1] == OP_TYPE.INS then
      lastPID = op[3]

      local x, y = findCharPositionBefore(op[3])

      if op[2] == "\n" then
        local py, py1 = splitArray(app_state.pids[y], x + 1)
        app_state.pids[y] = py
        table.insert(py1, 1, op[3])
        table.insert(app_state.pids, y + 1, py1)
      else
        table.insert(app_state.pids[y], x + 1, op[3])
      end

      if op[2] == "\n" then
        if y - 2 >= 0 then
          local curline = vim.api.nvim_buf_get_lines(buf, y - 2, y - 1, true)[1]
          local l, r = utf8.split(curline, x - 1)
          vim.api.nvim_buf_set_lines(buf, y - 2, y - 1, true, { l, r })
        else
          vim.api.nvim_buf_set_lines(buf, 0, 0, true, { "" })
        end
      else
        local curline = vim.api.nvim_buf_get_lines(buf, y - 2, y - 1, true)[1]
        curline = utf8.insert(curline, x - 1, op[2])
        vim.api.nvim_buf_set_lines(buf, y - 2, y - 1, true, { curline })
      end

      if op[2] == "\n" then
        if y - 1 >= 1 then
          local l, r = utf8.split(app_state.prev[y - 1], x - 1)
          app_state.prev[y - 1] = l
          table.insert(app_state.prev, y, r)
        else
          table.insert(app_state.prev, y, "")
        end
      else
        app_state.prev[y - 1] = utf8.insert(app_state.prev[y - 1], x - 1, op[2])
      end
    elseif op[1] == OP_TYPE.DEL then
      lastPID = findPIDBefore(op[3])

      local sx, sy = findCharPositionExact(op[3])

      if sx then
        if sx == 1 then
          if sy - 3 >= 0 then
            local prevline = vim.api.nvim_buf_get_lines(buf, sy - 3, sy - 2, true)[1]
            local curline = vim.api.nvim_buf_get_lines(buf, sy - 2, sy - 1, true)[1]
            vim.api.nvim_buf_set_lines(buf, sy - 3, sy - 1, true, { prevline .. curline })
          else
            vim.api.nvim_buf_set_lines(buf, sy - 2, sy - 1, true, {})
          end
        else
          if sy > 1 then
            local curline = vim.api.nvim_buf_get_lines(buf, sy - 2, sy - 1, true)[1]
            curline = utf8.remove(curline, sx - 2)
            vim.api.nvim_buf_set_lines(buf, sy - 2, sy - 1, true, { curline })
          end
        end

        if sx == 1 then
          if sy - 2 >= 1 then
            app_state.prev[sy - 2] = app_state.prev[sy - 2] .. string.sub(app_state.prev[sy - 1], 1)
          end
          table.remove(app_state.prev, sy - 1)
        else
          if sy > 1 then
            local curline = app_state.prev[sy - 1]
            curline = utf8.remove(curline, sx - 2)
            app_state.prev[sy - 1] = curline
          end
        end

        if sx == 1 then
          for i, pid in ipairs(app_state.pids[sy]) do
            if i > 1 then
              table.insert(app_state.pids[sy - 1], pid)
            end
          end
          table.remove(app_state.pids, sy)
        else
          table.remove(app_state.pids[sy], sx)
        end
      end
    end
    app_state.allprev[buf] = app_state.prev
    app_state.allpids[buf] = app_state.pids
    local author = app_state.id2author[other_agent]

    if lastPID and other_agent ~= app_state.agent then
      local x, y = findCharPositionExact(lastPID)

      if app_state.old_namespace[author] then
        if app_state.attached[app_state.old_namespace[author].buf] then
          vim.api.nvim_buf_clear_namespace(
            app_state.old_namespace[author].buf, app_state.old_namespace[author].id,
            0, -1)
        end
        app_state.old_namespace[author] = nil
      end

      if app_state.cursors[author] then
        if app_state.attached[app_state.cursors[author].buf] then
          vim.api.nvim_buf_clear_namespace(
            app_state.cursors[author].buf, app_state.cursors[author].id,
            0, -1)
        end
        app_state.cursors[author] = nil
      end

      if x then
        if x == 1 then x = 2 end
        app_state.old_namespace[author] = {
          id = vim.api.nvim_create_namespace(author),
          buf = buf,
        }
        vim.api.nvim_buf_set_extmark(
          buf,
          app_state.old_namespace[author].id,
          math.max(y - 2, 0),
          0,
          {
            virt_text = { { author, app_state.vtextGroup[app_state.client_hl_group[other_agent]] } },
            virt_text_pos = "right_align"
          }
        )

        if app_state.prev[y - 1] and x - 2 >= 0 and x - 2 <= utf8.len(app_state.prev[y - 1]) then
          local bx = vim.str_byteindex(app_state.prev[y - 1], x - 2)
          app_state.cursors[author] = {
            id = vim.api.nvim_buf_add_highlight(buf,
              0, app_state.cursorGroup[app_state.client_hl_group[other_agent]], y - 2, bx, bx + 1),
            buf = buf,
            line = y - 2,
          }
          if vim.api.nvim_buf_set_extmark then
            app_state.cursors[author].ext_id =
                vim.api.nvim_buf_set_extmark(
                  buf, app_state.cursors[author].id, y - 2, bx, {})
          end
        end
      end
      if app_state.follow and app_state.follow_aut == author then
        local curbuf = vim.api.nvim_get_current_buf()
        if curbuf ~= buf then
          vim.api.nvim_set_current_buf(buf)
        end

        vim.api.nvim_command("normal " .. (y - 1) .. "gg")
      end


      for _, o in pairs(app_state.api_attach) do
        if o.on_change then
          o.on_change(author, buf, y - 2)
        end
      end
    end
    -- @check_if_pid_match_with_prev

    SendOp(buf, op)
  end
  app_state.disable_undo = false
  if lastPID then
    local x, y = findCharPositionExact(lastPID)

    if app_state.prev[y - 1] and x - 2 >= 0 and x - 2 <= utf8.len(app_state.prev[y - 1]) then
      local bx = vim.str_byteindex(app_state.prev[y - 1], x - 2)
      vim.api.nvim_call_function("cursor", { y - 1, bx + 1 })
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
  app_state.api_attach[app_state.api_attach_id] = o
  app_state.api_attach_id = app_state.api_attach_id + 1
  return app_state.api_attach_id
end

local function detach(id)
  if not app_state.api_attach[id] then
    error("[blue_sentinel] Could not detach (already detached?")
  end
  app_state.api_attach[id] = nil
end

local function get_connected_list()
  local connected = {}
  for _, author in pairs(app_state.id2author) do
    table.insert(connected, author)
  end
  return connected
end

local function send_data(data)
  local obj = {
    MSG_TYPE.DATA,
    data
  }

  local encoded = vim.api.nvim_call_function("json_encode", { obj })
  app_state.ws_client:send_text(encoded)
end

local function get_connected_buf_list()
  local bufs = {}
  for buf, _ in pairs(app_state.loc2rem) do
    table.insert(bufs, buf)
  end
  return bufs
end

return {
  Join = JoinSingle,
  JoinSession = JoinSession,
  LeaveInsert = LeaveInsert,
  MarkClear = MarkClear,
  MarkRange = MarkRange,
  OpenBuffers = OpenBuffers,
  SaveBuffers = SaveBuffers,
  Start = StartSingle,
  StartFollow = StartFollow,
  StartSession = StartSession,
  Status = Status,
  Stop = Stop,
  StopFollow = StopFollow,
  attach = attach,
  detach = detach,
  get_connected_buf_list = get_connected_buf_list,
  get_connected_list = get_connected_list,
  redo = redo,
  send_data = send_data,
  undo = undo,
}
