local client1, client2
local client1pipe = [[\\.\\pipe\nvim-12392-0]]
local client2pipe = [[\\.\\pipe\nvim-28204-0]]

local num_connected = 0

local outputbuf
local outputwin

local test_passed = 0
local test_failed = 0

outputbuf = vim.api.nvim_create_buf(false, true)

local curwidth = vim.api.nvim_win_get_width(0)
local curheight = vim.api.nvim_win_get_height(0)

local opts = {
  relative =  'win',
  width =  curwidth-4,
  height = curheight-4,
  col = 2,
  row = 2,
  style =  'minimal'
}

ouputwin = vim.api.nvim_open_win(outputbuf, 0, opts)

local log

local assertEq

function log(str)
  table.insert(events,str)
  lines = {}
  for line in vim.gsplit(str, "\n") do
    table.insert(lines, line)
  end
  vim.api.nvim_buf_set_lines(outputbuf, -1, -1, true, lines)
end

function assertEq(str, val1, val2)
  if val1 == val2 then
    test_passed = test_passed + 1
    -- log(str .. " assertEq(" .. vim.inspect(val1) .. ", " .. vim.inspect(val2) .. ") OK")
  else
    test_failed = test_failed + 1
    log(str .. " assertEq(" .. vim.inspect(val1) .. ", " .. vim.inspect(val2) .. ") FAIL")
  end
end

client1 = vim.fn.sockconnect("pipe", client1pipe, { rpc = true })
client2 = vim.fn.sockconnect("pipe", client2pipe, { rpc = true })

local stdin, stdout, stderr
stdin = vim.loop.new_pipe(false)
stdout = vim.loop.new_pipe(false)
stderr = vim.loop.new_pipe(false)


handle, pid = vim.loop.spawn("node",
  {
    stdio = {stdin, stdout, stderr},
    args = { "ws_server.js" },
    cwd = "../server"
  }, function(code, signal)
    vim.schedule(function()
      log("exit code" .. code)
      log("exit signal" .. signal)
      vim.fn.chanclose(client2)
      vim.fn.chanclose(client1)

    end)
  end)


stdout:read_start(function(err, data)
  assert(not err, err)
  if data then
    if vim.startswith(data, "Server is listening") then
      vim.schedule(function()
        vim.fn.rpcrequest(client1, 'nvim_exec', "new", false)
        vim.fn.rpcrequest(client1, 'nvim_exec', "BlueSentinelStartSingle 127.0.0.1 8080", false)

      end)
    end

    if vim.startswith(data, "Peer connected") then
      vim.schedule(function()
        num_connected = num_connected + 1
        if num_connected == 1 then
          vim.fn.rpcrequest(client2, 'nvim_exec', "new", false)
          vim.fn.rpcrequest(client2, 'nvim_exec', "BlueSentinelJoinSingle 127.0.0.1 8080", false)

        elseif num_connected == 2 then
          local has_connect = vim.fn.rpcrequest(client1, 'nvim_eval', "v:lua.HasMessage('connect')")
          assertEq("Client 1 connect", has_connect, true)
          local has_connect = vim.fn.rpcrequest(client2, 'nvim_eval', "v:lua.HasMessage('connect')")
          assertEq("Client 2 connect", has_connect, true)

          vim.wait(300)

          local has_client = vim.fn.rpcrequest(client1, 'nvim_eval', "v:lua.HasMessage('in jbyuki')")
          assertEq("Client 2 connect from Client 1 ", has_client, true)


          vim.fn.rpcrequest(client1, 'nvim_eval', "v:lua.SendTestData()")
          vim.wait(200)
          local has_data = vim.fn.rpcrequest(client2, 'nvim_eval', "v:lua.HasMessage('data hello')")

          assertEq("send_data", has_data, true)

          local has_data = vim.fn.rpcrequest(client1, 'nvim_eval', "v:lua.HasMessage('data hello')")

          assertEq("send_data loopback", has_data, false)

          vim.fn.rpcrequest(client1, 'nvim_buf_set_lines', 0, 0, -1, true, { "test"} )
          vim.wait(200)

          local has_change = vim.fn.rpcrequest(client2, 'nvim_eval', "v:lua.HasMessage('change jbyuki 0')")

          assertEq("change client 2", has_change, true)

          local has_change = vim.fn.rpcrequest(client1, 'nvim_eval', "v:lua.HasMessage('change jbyuki 0')")

          assertEq("not change client 1", has_change, false)

          vim.fn.rpcrequest(client2, 'nvim_buf_set_lines', 0, 0, -1, true, { "hello"} )


          local has_change = vim.fn.rpcrequest(client1, 'nvim_eval', "v:lua.HasMessage('change jbyuki 0')")

          assertEq("change client 1", has_change, true)

          local connected = vim.fn.rpcrequest(client1, 'nvim_eval', "v:lua.GetConnectedList()")
          assertEq("connected client 1", #connected, 1)
          assertEq("connected client 1", connected[1], "jbyuki")

          local connected = vim.fn.rpcrequest(client2, 'nvim_eval', "v:lua.GetConnectedList()")
          assertEq("connected client 2", #connected, 1)
          assertEq("connected 2lient 2", connected[1], "jbyuki")

          local connected = vim.fn.rpcrequest(client1, 'nvim_eval', "v:lua.GetConnectedBufList()")
          assertEq("connected client 1", #connected, 1)

          local connected = vim.fn.rpcrequest(client2, 'nvim_eval', "v:lua.GetConnectedBufList()")
          assertEq("connected client 2", #connected, 1)
          vim.fn.rpcrequest(client2, 'nvim_exec', "BlueSentinelStop", false)
          vim.fn.rpcrequest(client2, 'nvim_exec', "bufdo bwipeout! %", false)

        end
      end)
    end

    if vim.startswith(data, "Peer disconnected") then
      vim.schedule(function()
        num_connected = num_connected - 1
        log("Peer disconnected " .. num_connected)
        if num_connected == 1 then
          vim.fn.rpcrequest(client1, 'nvim_exec', "BlueSentinelStop", false)
          vim.fn.rpcrequest(client1, 'nvim_exec', "bufdo bwipeout! %", false)

        elseif num_connected == 0 then
          local has_disconnect = vim.fn.rpcrequest(client1, 'nvim_eval', "v:lua.HasMessage('disconnect')")
          assertEq("Client 1 disconnect", has_disconnect, true)
          local has_disconnect = vim.fn.rpcrequest(client2, 'nvim_eval', "v:lua.HasMessage('disconnect')")
          assertEq("Client 2 disconnect", has_disconnect, true)

          local has_clientdisconnect = vim.fn.rpcrequest(client1, 'nvim_eval', "v:lua.HasMessage('out jbyuki')")
          assertEq("Client 2 disconnect from Client1", has_clientdisconnect, true)

          log("")
          log("PASSED " .. test_passed)
          log("")
          log("FAILED " .. test_failed)
          log("")

          handle:kill()
        end
      end)
    end


  end
end)

stderr:read_start(function(err, data)
  assert(not err, err)
end)



