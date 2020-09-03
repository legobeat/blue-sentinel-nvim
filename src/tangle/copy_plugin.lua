local plugvim = io.open("plugin/ntrance.vim", "w")
for line in io.lines("src/tangle/ntrance.vim") do
	plugvim:write(line .. '\n')
end
plugvim:close()

local pluglua = io.open("lua/ntrance.lua", "w")
for line in io.lines("src/tangle/ntrance.lua") do
	pluglua:write(line .. '\n')
end
pluglua:close()

local plugjs = io.open("server/ws_server.js", "w")
for line in io.lines("src/tangle/ws_server.js") do
	plugjs:write(line .. '\n')
end
plugjs:close()

