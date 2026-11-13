#!/usr/bin/env python3
"""Lua 5.1 syntax check for addon files.  Usage: python -I tools/luacheck.py Core.lua UI.lua ..."""
import sys

from lupa import lua51

sys.stdout.reconfigure(encoding="utf-8")
check = lua51.LuaRuntime().eval("function(s, n) local f, e = loadstring(s, n) return e end")
bad = 0
for path in sys.argv[1:]:
    err = check(open(path, encoding="utf-8").read(), path)
    if isinstance(err, bytes):
        err = err.decode("utf-8", "replace")
    print(f"{path}: {err or 'OK'}")
    bad += bool(err)
sys.exit(1 if bad else 0)
