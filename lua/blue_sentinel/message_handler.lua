local vim = vim
local constants = require("blue_sentinel.constants")
local MSG_TYPE = constants.MSG_TYPE
local OP_TYPE = constants.OP_TYPE
local START_POS = constants.START_POS
local END_POS = constants.END_POS

local util = require("blue_sentinel.util")
local genPID = util.genPID
local genPIDSeq = util.genPIDSeq
local splitArray = util.splitArray

local log = require("blue_sentinel.log")
local utf8 = require("blue_sentinel.utf8")

local function on_text(args)
  local first = args.first
  local wsdata = args.wsdata
  local app_state = args.app_state
  local attach_to_current_buffer = args.attach_to_current_buffer
  local findPIDBefore = args.findPIDBefore
  local findCharPositionExact = args.findCharPositionExact
  local findCharPositionBefore = args.findCharPositionBefore

      local decoded = vim.api.nvim_call_function("json_decode", { wsdata })

      if decoded then
        log(string.format("rec[%d] : %s", app_state.client_id, vim.inspect(decoded)))
        if decoded[1] == MSG_TYPE.TEXT then
          local _, op, other_rem, other_agent = unpack(decoded)
          local lastPID

          local agent, bufid = unpack(other_rem)
          local buf = app_state.buffer_id_to_buffer[agent][bufid]

          app_state.contents = app_state.buffer_contents[buf]
          app_state.pids = app_state.buffer_pids[buf]

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
                local l, r = utf8.split(app_state.contents[y - 1], x - 1)
                app_state.contents[y - 1] = l
                table.insert(app_state.contents, y, r)
              else
                table.insert(app_state.contents, y, "")
              end
            else
              app_state.contents[y - 1] = utf8.insert(app_state.contents[y - 1], x - 1, op[2])
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
                  app_state.contents[sy - 2] = app_state.contents[sy - 2] .. string.sub(app_state.contents[sy - 1], 1)
                end
                table.remove(app_state.contents, sy - 1)
              else
                if sy > 1 then
                  local curline = app_state.contents[sy - 1]
                  curline = utf8.remove(curline, sx - 2)
                  app_state.contents[sy - 1] = curline
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
          app_state.buffer_contents[buf] = app_state.contents
          app_state.buffer_pids[buf] = app_state.pids
          local author = app_state.client_id_to_author[other_agent]

          if lastPID and other_agent ~= app_state.client_id then
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

              if app_state.contents[y - 1] and x - 2 >= 0 and x - 2 <= utf8.len(app_state.contents[y - 1]) then
                local bx = vim.str_byteindex(app_state.contents[y - 1], x - 2)
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
            if app_state.follow and app_state.following_author == author then
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
            for _, lpid in ipairs(app_state.buffer_pids[b]) do
              for _, pid in ipairs(lpid) do
                table.insert(ps, pid)
              end
            end
            return ps
          end

          local function send_initial_for_buffer(buf)
            local rem
            if app_state.buffer_to_buffer_id[buf] then
              rem = app_state.buffer_to_buffer_id[buf]
            else
              rem = { app_state.client_id, buf }
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
              app_state.buffer_contents[buf]
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

          local agent, bufid = unpack(bufid)
          if not app_state.buffer_id_to_buffer[agent] or not app_state.buffer_id_to_buffer[agent][bufid] then
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

            if not app_state.buffer_id_to_buffer[agent] then
              app_state.buffer_id_to_buffer[agent] = {}
            end

            app_state.buffer_id_to_buffer[agent][bufid] = buf
            app_state.buffer_to_buffer_id[buf] = { agent, bufid }


            app_state.contents = content

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
              0, -1, false, app_state.contents)

            app_state.buffer_contents[buf] = app_state.contents
            app_state.buffer_pids[buf] = app_state.pids
          else
            local buf = app_state.buffer_id_to_buffer[agent][bufid]

            app_state.contents = content

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
              0, -1, false, app_state.contents)

            app_state.buffer_contents[buf] = app_state.contents
            app_state.buffer_pids[buf] = app_state.pids

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
            client_id = client_id


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

                local middlepos = genPID(START_POS, END_POS, client_id, 1)
                app_state.pids = {
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
                local newpids = genPIDSeq(middlepos, END_POS, client_id, 1, numgen)

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

                app_state.contents = lines

                app_state.buffer_contents[buf] = app_state.contents
                app_state.buffer_pids[buf] = app_state.pids
                if not app_state.buffer_id_to_buffer[client_id] then
                  app_state.buffer_id_to_buffer[client_id] = {}
                end

                app_state.buffer_id_to_buffer[client_id][buf] = buf
                app_state.buffer_to_buffer_id[buf] = { client_id, buf }
              end
            else
              local buf = app_state.singlebuf

              attach_to_current_buffer(buf)

              if not app_state.buffer_id_to_buffer[client_id] then
                app_state.buffer_id_to_buffer[client_id] = {}
              end

              app_state.buffer_id_to_buffer[client_id][buf] = buf
              app_state.buffer_to_buffer_id[buf] = { client_id, buf }

              local rem = app_state.buffer_to_buffer_id[buf]


              local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)

              local middlepos = genPID(START_POS, END_POS, client_id, 1)
              app_state.pids = {
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
              local newpids = genPIDSeq(middlepos, END_POS, client_id, 1, numgen)

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

              app_state.contents = lines

              app_state.buffer_contents[buf] = app_state.contents
              app_state.buffer_pids[buf] = app_state.pids
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


              for bufhandle, _ in pairs(app_state.buffer_contents) do
                if vim.api.nvim_buf_is_loaded(bufhandle) then
                  DetachFromBuffer(bufhandle)
                end
              end

              client_id = 0
            else
              client_id = client_id


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


            for bufhandle, _ in pairs(app_state.buffer_contents) do
              if vim.api.nvim_buf_is_loaded(bufhandle) then
                DetachFromBuffer(bufhandle)
              end
            end

            client_id = 0
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


            for bufhandle, _ in pairs(app_state.buffer_contents) do
              if vim.api.nvim_buf_is_loaded(bufhandle) then
                DetachFromBuffer(bufhandle)
              end
            end

            client_id = 0
          end
        end

        if decoded[1] == MSG_TYPE.CONNECT then
          local _, new_id, new_author = unpack(decoded)
          app_state.client_id_to_author[new_id] = new_author
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
              o.on_clientconnected(new_author)
            end
          end
        end

        if decoded[1] == MSG_TYPE.DISCONNECT then
          local _, remove_id = unpack(decoded)
          local author = app_state.client_id_to_author[remove_id]
          if author then
            app_state.client_id_to_author[remove_id] = nil
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
          local agent, rembuf = unpack(rem)
          local buf = app_state.buffer_id_to_buffer[agent][rembuf]

          local sx, sy = findCharPositionExact(spid)
          local ex, ey = findCharPositionExact(epid)

          if app_state.marks[other_agent] then
            vim.api.nvim_buf_clear_namespace(app_state.marks[other_agent].buf, app_state.marks[other_agent].ns_id, 0, -1)
            app_state.marks[other_agent] = nil
          end

          app_state.marks[other_agent] = {}
          app_state.marks[other_agent].buf = buf
          app_state.marks[other_agent].ns_id = vim.api.nvim_create_namespace("")
          local scol = vim.str_byteindex(app_state.contents[sy - 1], sx - 1)
          local ecol = vim.str_byteindex(app_state.contents[ey - 1], ex - 1)

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

          local author = app_state.client_id_to_author[other_agent]

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

          if app_state.follow and app_state.following_author == author then
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
    end
return on_text