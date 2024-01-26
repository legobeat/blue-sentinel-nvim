" Vim global plugin for remote collaborative editing
" Maintainer:  Bree Gardner
" License:     MIT

let s:save_cpo = &cpo
set cpo&vim

if exists("g:loaded_blue_sentinel")
	finish
endif
let g:loaded_blue_sentinel = 1

command! -nargs=* BlueSentinelStartSingle call blue_sentinel#StartSingleWrapper(<f-args>)

command! -nargs=* BlueSentinelJoinSingle call blue_sentinel#JoinSingleWrapper(<f-args>)

command! BlueSentinelStatus call luaeval('require("blue_sentinel").Status()')

command! -nargs=* BlueSentinelStop call luaeval('require("blue_sentinel").Stop()')

command! -nargs=* BlueSentinelStartSession call blue_sentinel#StartSessionWrapper(<f-args>)

command! -nargs=* BlueSentinelJoinSession call blue_sentinel#JoinSessionWrapper(<f-args>)

command! -nargs=* BlueSentinelFollow call blue_sentinel#StartFollowWrapper(<f-args>)

command! BlueSentinelStopFollow call blue_sentinel#StopFollowWrapper()

command! -bang BlueSentinelSaveAll call blue_sentinel#SaveAllWrapper(<bang>0)

command! BlueSentinelOpenAll call luaeval('require("blue_sentinel").OpenBuffers()')

command! -nargs=* BlueSentinelStartServer call blue_sentinel#StartServerWrapper(<f-args>)

command! BlueSentinelStopServer call luaeval('require("blue_sentinel.server").StopServer()')

command! -range BlueSentinelMark lua require("blue_sentinel").MarkRange()
command! BlueSentinelMarkClear lua require("blue_sentinel").MarkClear()

let &cpo = s:save_cpo
unlet s:save_cpo


