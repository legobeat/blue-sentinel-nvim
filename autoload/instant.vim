function blue_sentinelStartSingleWrapper(...)
	if a:0 == 0 || a:0 > 2
		echoerr "ARGUMENTS: [host] [port (default: 80)]"
		return
	endif

	if a:0 == 1
		call luaeval('require("instant").Start("' .. a:1 .. '")')
	else
		call luaeval('require("instant").Start("' .. a:1 .. '", ' .. a:2 .. ')')
	endif
endfunction

function blue_sentinelJoinSingleWrapper(...)
	if a:0 == 0 || a:0 > 2
		echoerr "ARGUMENTS: [host] [port (default: 80)]"
		return
	endif

	if a:0 == 1
		call luaeval('require("instant").Join("' .. a:1 .. '")')
	else
		call luaeval('require("instant").Join("' .. a:1 .. '", ' .. a:2 .. ')')
	endif
endfunction

function blue_sentinelStartSessionWrapper(...)
	if a:0 == 0 || a:0 > 2
		echoerr "ARGUMENTS: [host] [port (default: 80)]"
		return
	endif

	if a:0 == 1
		call luaeval('require("instant").StartSession("' .. a:1 .. '")')
	else
		call luaeval('require("instant").StartSession("' .. a:1 .. '", ' .. a:2 .. ')')
	endif
endfunction

function blue_sentinelJoinSessionWrapper(...)
	if a:0 == 0 || a:0 > 2
		echoerr "ARGUMENTS: [host] [port (default: 80)]"
		return
	endif

	if a:0 == 1
		call luaeval('require("instant").JoinSession("' .. a:1 .. '")')
	else
		call luaeval('require("instant").JoinSession("' .. a:1 .. '", ' .. a:2 .. ')')
	endif
endfunction

function blue_sentinelStartFollowWrapper(...)
	if a:0 == 0 || a:0 > 1
		echoerr "ARGUMENTS: [username]"
		return
	endif

	call luaeval('require("instant").StartFollow("' .. a:1.. '")')
endfunction

function blue_sentinelStopFollowWrapper()
	call luaeval('require("instant").StopFollow()')
endfunction

function blue_sentinelSaveAllWrapper(bang)
	if a:bang == 1
		call luaeval('require("instant").SaveBuffers(true)')
	else
		call luaeval('require("instant").SaveBuffers(false)')
	endif
endfunction

function blue_sentinelStartServerWrapper(...)
	if a:0 == 0
		call luaeval('require("instant.server").StartServer()')
	elseif a:0 == 2
		call luaeval('require("instant.server").StartServer("' .. a:1 .. '",' .. a:2 .. ')')
	else
		echoerr "ARGUMENTS: [host] [port]"
		return
	endif
endfunction
