#!/usr/bin/env python3
"""
Offline checks for BeastAtlas (no game client needed):
  1. pin templates carry no XML scripts (the map canvas asserts on that),
  2. every .lua file in the TOC compiles under Lua 5.1 (WoW's dialect),
  3. the addon loads against stand-ins for the client API (tools/wow_stubs.lua) and the scenarios in
     tools/test_scenarios.lua pass: main pet, known-rank sources, statuses, map pins, window, tames, tips.
The stand-ins follow the client's UI source, but this is not the game: see README "Known limits".
Requires: pip install lupa
"""
import os
import re
import sys

from lupa import lua51

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(ROOT, "tools")


def read(*parts):
    with open(os.path.join(*parts), encoding="utf-8") as f:
        return f.read()


def toc_files():
    files = []
    for line in read(ROOT, "BeastAtlas.toc").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            files.append(line.replace("\\", os.sep))
    return files


def pin_templates():
    """{ template: (mixin, [parentKeys], mouseEnabled) } from MapPins.xml"""
    xml = re.sub(r"<!--.*?-->", "", read(ROOT, "MapPins.xml"), flags=re.S)
    out = {}
    for m in re.finditer(r'<(Frame|Button) name="(\w+)" mixin="(\w+)"([^>]*)>(.*?)\n    </\1>', xml, re.S):
        keys = re.findall(r'parentKey="(\w+)"', m.group(5))
        out[m.group(2)] = (m.group(3), keys, 'enableMouse="true"' in m.group(4))
    return xml, out


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def run(locale, cls, templates):
    lua = lua51.LuaRuntime(unpack_returned_tuples=True, encoding=None)
    tpl = ", ".join(
        f"[{lua_str(name)}] = {{ mixin = {lua_str(mixin)}, mouse = {str(mouse).lower()}, "
        f"keys = {{ {', '.join(f'[{lua_str(k)}] = true' for k in keys)} }} }}"
        for name, (mixin, keys, mouse) in templates.items())
    rows = ", ".join(f"[{lua_str(n)}] = {h}" for n, h in
                     re.findall(r'<Button name="(\w+)" virtual="true">\s*<Size x="\d+" y="(\d+)"/>', read(ROOT, "UI.xml")))
    lua.execute(f'__LOCALE = "{locale}"; __CLASS = "{cls}"; __TEMPLATES = {{ {tpl} }}; '
                f'__ROW_TEMPLATES = {{ {rows} }}; __NS = {{}}'.encode())
    load = lua.eval(b"function(src, name, ...) return assert(loadstring(src, name))(...) end")
    load(read(TOOLS, "wow_stubs.lua").encode(), b"wow_stubs.lua")
    ns = lua.eval(b"__NS")
    for rel in toc_files():
        if rel.endswith(".lua"):
            load(read(ROOT, rel).encode(), rel.encode(), b"BeastAtlas", ns)
    fails, info = load(read(TOOLS, "test_scenarios.lua").encode(), b"test_scenarios.lua")
    return (fails or b"").decode("utf-8", "replace"), (info or b"").decode("utf-8", "replace")


def main():
    errors = 0
    xml, templates = pin_templates()
    if re.search(r"<Scripts>|<OnEnter|<OnLeave|<OnLoad|<OnClick", xml):
        print("XML: pin templates must not define scripts")
        errors += 1
    if len(templates) != 4:
        print(f"XML: expected 4 pin templates, parsed {len(templates)}")
        errors += 1

    # Only characters already seen drawn in the game: ASCII, Cyrillic and the quotes of the Russian client.
    # (Arrows, bullets, ellipsis and check marks came out as empty boxes.)
    for rel in toc_files():
        if rel.endswith(".lua") and not rel.startswith("Data"):
            odd = sorted({c for c in read(ROOT, rel)
                          if not (c in "\n\t" or " " <= c <= "~" or "\u0400" <= c <= "\u04ff" or c in "\u00ab\u00bb\u00a7")})
            if odd:
                print(f"{rel}: characters the game font may not draw: " + " ".join(f"U+{ord(c):04X}" for c in odd))
                errors += 1

    check = lua51.LuaRuntime(encoding=None).eval(b"function(s, n) local f, e = loadstring(s, n) return e end")
    for rel in toc_files():
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            print("TOC lists a missing file:", rel)
            errors += 1
        elif rel.endswith(".lua"):
            err = check(read(path).encode(), rel.encode())
            if err:
                print("SYNTAX", err.decode("utf-8", "replace"))
                errors += 1
    if errors:
        return errors
    print("syntax: ok")

    for locale, cls in (("enUS", "HUNTER"), ("ruRU", "HUNTER"), ("enUS", "MAGE")):
        try:
            fails, info = run(locale, cls, templates)
        except Exception as e:  # noqa: BLE001
            msg = e.args[0] if e.args else e
            if isinstance(msg, bytes):
                msg = msg.decode("utf-8", "replace")
            print(f"[{locale} {cls}] RUNTIME ERROR: {msg}")
            errors += 1
            continue
        problems = [line for line in fails.split("\n") if line]
        print(f"[{locale} {cls}] {info}" + ("" if not problems else f"  -- {len(problems)} FAILED"))
        for p in problems[:30]:
            print("   ", p)
        if len(problems) > 30:
            print(f"    ... {len(problems) - 30} more")
        errors += len(problems)
    return errors


if __name__ == "__main__":
    n = main()
    print("FAILED" if n else "ALL OK", n)
    sys.exit(1 if n else 0)
