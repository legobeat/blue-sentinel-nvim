local M = {}

M.MSG_TYPE = {
  TEXT       = 1,
  AVAILABLE  = 2,
  REQUEST    = 3,
  INFO       = 5,
  INITIAL    = 6,
  CONNECT    = 7,
  DISCONNECT = 8,
  DATA       = 9,
  MARK       = 10,
}

M.OP_TYPE = {
  DEL = 1,
  INS = 2,
}

return M