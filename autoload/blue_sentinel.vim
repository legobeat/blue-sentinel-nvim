function blue_sentinel#StartSingleWrapper(...)
	if a:0 == 0 || a:0 > 2
		echoerr "ARGUMENTS: [host] [port (default: 80)]"
		return
	endif

	if a:0 == 1
		call luaeval('require("blue_sentinel").Start("' .. a:1 .. '")')
	else
		call luaeval('require("blue_sentinel").Start("' .. a:1 .. '", ' .. a:2 .. ')')
	endif
endfunction

function blue_sentinel#JoinSingleWrapper(...)
	if a:0 == 0 || a:0 > 2
		echoerr "ARGUMENTS: [host] [port (default: 80)]"
		return
	endif

	if a:0 == 1
		call luaeval('require("blue_sentinel").Join("' .. a:1 .. '")')
	else
		call luaeval('require("blue_sentinel").Join("' .. a:1 .. '", ' .. a:2 .. ')')
	endif
endfunction

function blue_sentinel#StartSessionWrapper(...)
	if a:0 == 0 || a:0 > 2
		echoerr "ARGUMENTS: [host] [port (default: 80)]"
		return
	endif

	if a:0 == 1
		call luaeval('require("blue_sentinel").StartSession("' .. a:1 .. '")')
	else
		call luaeval('require("blue_sentinel").StartSession("' .. a:1 .. '", ' .. a:2 .. ')')
	endif
endfunction

function blue_sentinel#JoinSessionWrapper(...)
	if a:0 == 0 || a:0 > 2
		echoerr "ARGUMENTS: [host] [port (default: 80)]"
		return
	endif

	if a:0 == 1
		call luaeval('require("blue_sentinel").JoinSession("' .. a:1 .. '")')
	else
		call luaeval('require("blue_sentinel").JoinSession("' .. a:1 .. '", ' .. a:2 .. ')')
	endif
endfunction

function blue_sentinel#StartFollowWrapper(...)
	if a:0 == 0 || a:0 > 1
		echoerr "ARGUMENTS: [username]"
		return
	endif

	call luaeval('require("blue_sentinel").StartFollow("' .. a:1.. '")')
endfunction

function blue_sentinel#StopFollowWrapper()
	call luaeval('require("blue_sentinel").StopFollow()')
endfunction

function blue_sentinel#SaveAllWrapper(bang)
	if a:bang == 1
		call luaeval('require("blue_sentinel").SaveBuffers(true)')
	else
		call luaeval('require("blue_sentinel").SaveBuffers(false)')
	endif
endfunction

function blue_sentinel#StartServerWrapper(...)
	if a:0 == 0
		call luaeval('require("blue_sentinel.server").StartServer()')
	elseif a:0 == 2
		call luaeval('require("blue_sentinel.server").StartServer("' .. a:1 .. '",' .. a:2 .. ')')
	else
		echoerr "ARGUMENTS: [host] [port]"
		return
	endif
endfunction
