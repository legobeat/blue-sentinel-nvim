" Vim global plugin for remote collaborative editing
" Creation Date: 2020 Sep 3
" Maintainer:  jbyuki
" License:     MIT

let s:save_cpo = &cpo
set cpo&vim

if exists("g:loaded_instant")
	finish
endif
let g:loaded_instant = 1

command! -nargs=* BlueSentinelStartSingle call instant#StartSingleWrapper(<f-args>)

command! -nargs=* BlueSentinelJoinSingle call instant#JoinSingleWrapper(<f-args>)

command! BlueSentinelStatus call luaeval('require("instant").Status()')

command! -nargs=* BlueSentinelStop call luaeval('require("instant").Stop()')

command! -nargs=* BlueSentinelStartSession call instant#StartSessionWrapper(<f-args>)

command! -nargs=* BlueSentinelJoinSession call instant#JoinSessionWrapper(<f-args>)

command! -nargs=* BlueSentinelFollow call instant#StartFollowWrapper(<f-args>)

command! BlueSentinelStopFollow call instant#StopFollowWrapper()

command! -bang BlueSentinelSaveAll call instant#SaveAllWrapper(<bang>0)

command! BlueSentinelOpenAll call luaeval('require("instant").OpenBuffers()')

command! -nargs=* BlueSentinelStartServer call instant#StartServerWrapper(<f-args>)

command! BlueSentinelStopServer call luaeval('require("instant.server").StopServer()')

command! -range BlueSentinelMark lua require("instant").MarkRange()
command! BlueSentinelMarkClear lua require("instant").MarkClear()

let &cpo = s:save_cpo
unlet s:save_cpo


