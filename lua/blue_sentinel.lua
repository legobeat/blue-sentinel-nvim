local vim = vim
local websocket_client = require("blue_sentinel.websocket_client")
local log = require("blue_sentinel.log")
local constants = require("blue_sentinel.constants")
local MSG_TYPE = constants.MSG_TYPE
local OP_TYPE = constants.OP_TYPE
local START_POS = constants.START_POS
local END_POS = constants.END_POS
local utf8 = require("blue_sentinel.utf8")
local util = require("blue_sentinel.util")
local isLowerOrEqual = util.isLowerOrEqual
local genPID = util.genPID
local genPIDSeq = util.genPIDSeq
local splitArray = util.splitArray
local getConfig = util.getConfig

local app_state = {
  buffer_pids = {}, -- PID array for each buffer
  buffer_contents = {}, -- Line contents for each buffer
  api_attach = {},
  api_attach_id = 1,
  attached = {},
  autocmd_init = false,
  client_hl_group = {},
  cursorGroup = nil,
  cursors = {},
  detach = {},
  follow = false,
  following_author = nil,
  hl_group = {},
  client_id_to_author = {},
  ignores = {},
  buffer_id_to_buffer = {}, -- A table of buffers keyed by agent id, then buffer id
  buffer_to_buffer_id = {}, -- A table of buffer ids and agents, keyed by buffer
  marks = {},
  old_namespace = nil,
  only_share_cwd = nil,
  pids = {}, -- A table of PID arrays for the current buffer
  contents = { "" }, -- A table of lines representing the current buffer contents
  received = {},
  sessionshare = false,
  singlebuf = nil,
  vtextGroup = nil,
  ws_client = nil,
  client_id = 0,
}

local client_username = vim.api.nvim_get_var("blue_sentinel_username")

-- CRDT HELPERS {{{
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
  local rem = app_state.buffer_to_buffer_id[buf]

  local obj = {
    MSG_TYPE.TEXT,
    op,
    rem,
    app_state.client_id,
  }

  local encoded = vim.api.nvim_call_function("json_encode", { obj })

  log(string.format("send[%d] : %s", app_state.client_id, vim.inspect(encoded)))
  app_state.ws_client:send_text(encoded)
end

local function get_edit_range(cur_lines, firstline, lastline, new_lastline)
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
      c2 = utf8.char(app_state.contents[del_range.end_line + 1] or "", del_range.end_char)
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
      del_prev = { end_line = del_range.end_line - 1, end_char = utf8.len(app_state.contents[del_range.end_line] or "") - 1 }
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
      c2 = utf8.char(app_state.contents[del_range.start_line + 1] or "", del_range.start_char)
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

    if del_range.start_char == utf8.len(app_state.contents[del_range.start_line + 1] or "") then
      del_range.start_char = -1
      del_range.start_line = del_range.start_line + 1
    end
  end

  return add_range, del_range
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

  app_state.contents = app_state.buffer_contents[buf]
  local current_pids = app_state.buffer_pids[buf]

  local cur_lines = vim.api.nvim_buf_get_lines(buf, firstline, new_lastline, true)

  local add_range, del_range = get_edit_range(cur_lines, firstline, lastline, new_lastline)

  local end_char = del_range.end_char
  for y = del_range.end_line, del_range.start_line, -1 do
    local start_char = -1
    if y == del_range.start_line then
      start_char = del_range.start_char
    end

    for x = end_char, start_char, -1 do
      if x == -1 then
        if #app_state.contents > 1 then
          if y > 0 then
            app_state.contents[y] = app_state.contents[y] .. (app_state.contents[y + 1] or "")
          end
          table.remove(app_state.contents, y + 1)

          local del_pid = current_pids[y + 2][1]
          for i, pid in ipairs(current_pids[y + 2]) do
            if i > 1 then
              table.insert(current_pids[y + 1], pid)
            end
          end
          table.remove(current_pids, y + 2)

          SendOp(buf, { OP_TYPE.DEL, "\n", del_pid })
        end
      else
        local c = utf8.char(app_state.contents[y + 1], x)

        app_state.contents[y + 1] = utf8.remove(app_state.contents[y + 1], x)

        local del_pid = current_pids[y + 2][x + 2]
        table.remove(current_pids[y + 2], x + 2)

        SendOp(buf, { OP_TYPE.DEL, c, del_pid })
      end
    end

    end_char = utf8.len(app_state.contents[y] or "") - 1
  end

  local len_insert = 0
  local start_char = add_range.start_char
  for y = add_range.start_line, add_range.end_line do
    local end_char
    if y == add_range.end_line then
      end_char = add_range.end_char
    else
      end_char = utf8.len(cur_lines[y - firstline + 1]) - 1
    end

    for _ = start_char, end_char do
      len_insert = len_insert + 1
    end
    start_char = -1
  end

  local before_pid, after_pid
  if add_range.start_char == -1 then
    local pidx
    local y = add_range.start_line
    if cur_lines[y - firstline] then
      pidx = utf8.len(cur_lines[y - firstline]) + 1
    else
      pidx = #current_pids[y + 1]
    end
    before_pid = current_pids[y + 1][pidx]
    after_pid = afterPID(pidx, y + 1)
  else
    local x, y = add_range.start_char, add_range.start_line
    before_pid = current_pids[y + 2][x + 1]
    after_pid = afterPID(x + 1, y + 2)
  end

  local newpidindex = 1
  local newpids = genPIDSeq(before_pid, after_pid, app_state.client_id, 1, len_insert)

  start_char = add_range.start_char
  for y = add_range.start_line, add_range.end_line do
    local end_char
    if y == add_range.end_line then
      end_char = add_range.end_char
    else
      end_char = utf8.len(cur_lines[y - firstline + 1]) - 1
    end

    for x = start_char, end_char do
      if x == -1 then
        if cur_lines[y - firstline] then
          local l, r = utf8.split(app_state.contents[y], utf8.len(cur_lines[y - firstline]))
          app_state.contents[y] = l
          table.insert(app_state.contents, y + 1, r)
        else
          table.insert(app_state.contents, y + 1, "")
        end

        local pidx
        if cur_lines[y - firstline] then
          pidx = utf8.len(cur_lines[y - firstline]) + 1
        else
          pidx = #current_pids[y + 1]
        end

        local new_pid = newpids[newpidindex]
        newpidindex = newpidindex + 1

        local l, r = splitArray(current_pids[y + 1], pidx + 1)
        current_pids[y + 1] = l
        table.insert(r, 1, new_pid)
        table.insert(current_pids, y + 2, r)

        SendOp(buf, { OP_TYPE.INS, "\n", new_pid })
      else
        local c = utf8.char(cur_lines[y - firstline + 1], x)
        app_state.contents[y + 1] = utf8.insert(app_state.contents[y + 1], x, c)

        local new_pid = newpids[newpidindex]
        newpidindex = newpidindex + 1

        table.insert(current_pids[y + 2], x + 2, new_pid)

        SendOp(buf, { OP_TYPE.INS, c, new_pid })
      end
    end
    start_char = -1
  end

  app_state.buffer_contents[buf] = app_state.contents
  app_state.buffer_pids[buf] = current_pids
end

local function attach_to_current_buffer(buf)
  app_state.attached[buf] = nil

  app_state.detach[buf] = nil

  app_state.ignores[buf] = {}

  if not app_state.attached[buf] then
    local attach_success = vim.api.nvim_buf_attach(buf, false, {
      on_lines = on_lines,
      on_detach = function(_, buf)
        app_state.attached[buf] = nil
      end
    })

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

      local middlepos = genPID(START_POS, END_POS, app_state.client_id, 1)
      local current_pids = {
        { START_POS },
        { middlepos },
        { END_POS },
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
      local newpids = genPIDSeq(middlepos, END_POS, app_state.client_id, 1, numgen)

      for i = 1, #lines do
        local line = lines[i]
        if i > 1 then
          local newpid = newpids[newpidindex]
          newpidindex = newpidindex + 1

          table.insert(current_pids, i + 1, { newpid })
        end

        for j = 1, string.len(line) do
          local newpid = newpids[newpidindex]
          newpidindex = newpidindex + 1

          table.insert(current_pids[i + 1], newpid)
        end
      end

      app_state.contents = lines

      app_state.buffer_contents[buf] = app_state.contents
      app_state.buffer_pids[buf] = current_pids

      if not app_state.buffer_id_to_buffer[app_state.client_id] then
        app_state.buffer_id_to_buffer[app_state.client_id] = {}
      end

      app_state.buffer_id_to_buffer[app_state.client_id][buf] = buf
      app_state.buffer_to_buffer_id[buf] = { app_state.client_id, buf }

      local rem = app_state.buffer_to_buffer_id[buf]

      local pidslist = {}
      for _, lpid in ipairs(app_state.buffer_pids[buf]) do
        for _, pid in ipairs(lpid) do
          table.insert(pidslist, pid[1][1])
        end
      end

      local obj = {
        MSG_TYPE.INITIAL,
        bufname,
        rem,
        pidslist,
        app_state.buffer_contents[buf]
      }

      local encoded = vim.api.nvim_call_function("json_encode", { obj })

      app_state.ws_client:send_text(encoded)

      attach_to_current_buffer(buf)
    end
  end
end

function LeaveInsert()
end

local function MarkRange()
  local _, snum, scol, _ = unpack(vim.api.nvim_call_function("getpos", { "'<" }))
  local _, enum, ecol, _ = unpack(vim.api.nvim_call_function("getpos", { "'>" }))

  local curbuf = vim.api.nvim_get_current_buf()
  local pids = app_state.buffer_pids[curbuf]
  local prev = app_state.buffer_contents[curbuf]

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

  if app_state.marks[app_state.client_id] then
    vim.api.nvim_buf_clear_namespace(app_state.marks[app_state.client_id].buf, app_state.marks[app_state.client_id].ns_id, 0, -1)
    app_state.marks[app_state.client_id] = nil
  end

  app_state.marks[app_state.client_id] = {}
  app_state.marks[app_state.client_id].buf = curbuf
  app_state.marks[app_state.client_id].ns_id = vim.api.nvim_create_namespace("")
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
      app_state.marks[app_state.client_id].buf,
      app_state.marks[app_state.client_id].ns_id,
      "TermCursor",
      y, lscol, lecol)
  end

  local rem = app_state.buffer_to_buffer_id[curbuf]
  local obj = {
    MSG_TYPE.MARK,
    app_state.client_id,
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

  app_state.buffer_to_buffer_id = {}
  app_state.buffer_id_to_buffer = {}

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
        client_username,
        app_state.client_id,
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
      require"blue_sentinel.message_handler"({
        wsdata = wsdata,
        first = first,
        app_state = app_state,
        findCharPositionBefore = findCharPositionBefore,
        findCharPositionExact = findCharPositionExact,
        attach_to_current_buffer = attach_to_current_buffer,
        findPIDBefore = findPIDBefore,
      })
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


      for bufhandle, _ in pairs(app_state.buffer_contents) do
        if vim.api.nvim_buf_is_loaded(bufhandle) then
          DetachFromBuffer(bufhandle)
        end
      end

      app_state.client_id = 0
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
    for _, author in pairs(app_state.client_id_to_author) do
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
  app_state.following_author = author
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

-- To be reimplemented - these were a mess and not working anyway
local function undo(buf)
end

local function redo(buf)
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
  for _, author in pairs(app_state.client_id_to_author) do
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
  for buf, _ in pairs(app_state.buffer_to_buffer_id) do
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
