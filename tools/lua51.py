# 本机没有 Lua 5.1 时的替代品：用 Python 包 lupa 内置的 Lua 5.1 运行脚本。
# 用法（需要 uv）：uv run --no-project --with lupa python -I tools/lua51.py <脚本.lua> [参数...]
# 脚本里的 arg[0] 是脚本路径，os.exit(code) 的退出码会原样返回。
import sys, os
import lupa.lua51 as L

script = sys.argv[1]
lua = L.LuaRuntime(unpack_returned_tuples=True)
g = lua.globals()
args = lua.table_from({i: a for i, a in enumerate(sys.argv[1:])})
g.arg = args
code = {"v": 0}
def _exit(c=0):
    if c is True: c = 0
    elif c is False: c = 1
    code["v"] = int(c or 0)
    raise SystemExit
lua.execute("os.exit = ...", _exit)
try:
    lua.execute("local f = assert(loadfile(arg[0])); return f(select(1, unpack(arg)))")
except SystemExit:
    pass
except Exception as e:
    print("LUA ERROR:", e); code["v"] = 2
sys.stdout.flush()
os._exit(code["v"])
