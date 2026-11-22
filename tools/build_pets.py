#!/usr/bin/env python3
"""
Builds BeastAtlas/Data/Pets.lua: every creature Petopia Forever lists for a pet family, whether it teaches
an ability rank or not. Data/Beasts.lua (tools/build_db.py) stays the list of teachers; this wider list is
what the companion addon BeastScout checks a beast against ("is it known at all?").

Sources
  * Petopia Forever: home page -> family pages -> look pages. A look page has one row per creature:
    tameable or not, name, level, location, Wowhead NPC id, known abilities, attack speed.
  * Wowhead tooltip API: Russian names.

Responses are cached under tools/cache, like build_db.py does.

Usage:  python -I tools/build_pets.py            (from the addon folder)
"""
import html
import os
import re
import sys
from datetime import date

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I leaves the script's folder out
from build_db import PETOPIA, PLURALS, ROOT, fetch, fetch_json, lua_str, strip_tags  # noqa: E402

OUT = os.path.join(ROOT, "Data", "Pets.lua")
BEASTS = os.path.join(ROOT, "Data", "Beasts.lua")
# alt text of a row's icon -> (tameable, side: "A" / "H" / None for both)
TAMEABLE = {
    "Can Be Tamed": (True, None),
    "Available to Horde Hunters Only": (True, "H"),
    "Available to Alliance Hunters Only": (True, "A"),
    "Cannot Be Tamed": (False, None),
}


def family_slugs():
    home = fetch(PETOPIA, "petopia/index.html") or ""
    slugs = re.findall(r"family_panel_item (?:offensive|general|defensive) classic forever'>"
                       r"<a href='family\.php\?id=(\w+)'", home)
    if len(slugs) < 18:
        sys.exit(f"Petopia's home page lists {len(slugs)} families: its markup has changed")
    return slugs


def parse_family(page):
    """-> family key ("Carrion Bird"), look ids"""
    m = re.search(r"<h1 class='familyheadingname[^']*'>(?:<img[^>]*>)?\s*([^<]+?)\s*</h1>", page)
    if not m:
        return None, []
    plural = html.unescape(m.group(1)).strip()
    family = PLURALS.get(plural, plural[:-1] if plural.endswith("s") else plural)
    looks = []
    for look in re.findall(r"href='look\.php\?id=([^']+)'", page):
        if look not in looks:
            looks.append(look)
    return family, looks


def parse_look(page):
    """-> rows: { id, en, tame (alt text of the icon), level text, zone, knows [(key, rank)], speed }"""
    rows = []
    for m in re.finditer(r"<tr class='petstats[^']*'>(.*?)</tr>\s*(?:<tr class='petnotes[^']*'>(.*?)</tr>)?", page, re.S):
        stats, notes = m.group(1), m.group(2) or ""
        npc = re.search(r"wowhead\.com/forever/npc=(\d+)", stats)
        name = re.search(r"<div class='pettablename'>(.*?)</div>", stats, re.S)
        icon = re.search(r"<div class='tameableicon'>\s*<img[^>]*alt='([^']*)'", stats)
        level = re.search(r"<td class='level'>(.*?)</td>", stats, re.S)
        zone = re.search(r"<td class='zone'>(.*?)</td>", stats, re.S)
        speed = re.search(r"Attack speed: ([0-9.]+)", notes)
        rows.append({
            "id": int(npc.group(1)) if npc else None,
            "en": strip_tags(name.group(1)) if name else "",
            "tame": icon.group(1) if icon else "",
            "level": strip_tags(level.group(1)) if level else "",
            "zone": strip_tags(zone.group(1)) if zone else "",
            # the anchor is the ability's name as typed ("mine!1"); the key drops the punctuation
            "knows": [(re.sub(r"[^a-z]", "", k), int(r))
                      for k, r in re.findall(r"abilities\.php#([^'#]*?)(\d+)'", notes)],
            "speed": float(speed.group(1)) if speed else None,
        })
    return rows


TAGS = ("Rare", "Elite", "RareElite", "Spawned", "SpawnedElite", "Boss")


def levels(text):
    """The level cell with its tags stripped of markup: '5-7' -> (5, 7, None); '12Rare' -> (12, 12, 'Rare');
    '30-31Elite' -> (30, 31, 'Elite'); 'Boss' -> (0, 0, 'Boss'). None for anything else."""
    m = re.match(r"(?:(\d+)(?:\s*-\s*(\d+))?)?\s*([A-Za-z]*)$", text.strip())
    if not m or not (m.group(1) or m.group(3)) or (m.group(3) and m.group(3) not in TAGS):
        return None
    lmin = int(m.group(1) or 0)
    return lmin, int(m.group(2) or lmin), m.group(3) or None


def teachers():
    """{ npcId: [(key, rank), ...] } from the shipped Data/Beasts.lua"""
    out = {}
    text = open(BEASTS, encoding="utf-8").read()
    for npc, t in re.findall(r'^\s*\[(\d+)\] = \{ en = "[^\n]*? f = "[^\n]*? t = \{ ([^}]*)\}', text, re.M):
        out[int(npc)] = [(k, int(r)) for k, r in re.findall(r'"([a-z]+)", (\d+)', t)]
    return out


def main():
    pets, icons, no_id, looks_seen, unexpected, unused = {}, {}, [], 0, [], 0
    for slug in family_slugs():
        family, looks = parse_family(fetch(PETOPIA + "family.php?id=" + slug, f"petopia/family_{slug}.html") or "")
        if not family or not looks:
            sys.exit(f"family page {slug}: no name or no looks, the markup has changed")
        for look in looks:
            looks_seen += 1
            name = re.sub(r"[^A-Za-z0-9_.-]", "_", look)
            page = fetch(PETOPIA + "look.php?id=" + look, f"petopia/look_{name}.html") or ""
            rows = parse_look(page)
            if not rows:
                # a look no creature of this game version wears ("Unused look") or no tameable one
                # ("Untameable look"); anything else is a row the parser missed
                if "Unused look" not in page and "Untameable look" not in page:
                    sys.exit(f"look page {look} ({slug}): no creature rows and not marked unused, the markup has changed")
                unused += 1
            for r in rows:
                icons[r["tame"]] = icons.get(r["tame"], 0) + 1
                if r["tame"] not in TAMEABLE:
                    unexpected.append(f"{r['tame']!r} for {r['en']!r} ({look})")
                    continue
                tame, side = TAMEABLE[r["tame"]]
                if not r["id"]:
                    no_id.append(f"{r['en']} ({look})")
                    continue
                level = levels(r["level"])
                if not level:
                    unexpected.append(f"level {r['level']!r} for {r['en']!r} ({look})")
                    continue
                lmin, lmax, tag = level
                p = pets.setdefault(r["id"], {"en": r["en"], "f": family, "lmin": lmin, "lmax": lmax, "tag": tag,
                                               "zone": r["zone"], "speed": r["speed"], "tame": tame, "side": side,
                                               "knows": r["knows"], "looks": []})
                if p["f"] != family:
                    sys.exit(f"npc {r['id']} {r['en']}: listed under {p['f']} and {family}")
                p["tame"] = p["tame"] or tame
                p["looks"].append(look)
    print(f"families: {len(family_slugs())}, looks: {looks_seen} ({unused} without creatures), creatures: {len(pets)}")
    print(f"tameable icons: {icons}")
    if unexpected:
        sys.exit(f"unexpected rows ({len(unexpected)}): " + "; ".join(unexpected[:30]))
    print(f"rows without an npc id ({len(no_id)}): {', '.join(no_id[:20])}")

    # ---- every teacher of Data/Beasts.lua must be here, with the same abilities
    known = teachers()
    if len(known) < 300:
        sys.exit(f"only {len(known)} beasts parsed from Data/Beasts.lua")
    missing = sorted(i for i in known if i not in pets)
    differ = sorted(i for i in known if i in pets and sorted(known[i]) != sorted(pets[i]["knows"]))
    print(f"teachers of Beasts.lua missing on look pages ({len(missing)}): {missing}")
    print(f"teachers whose abilities differ between the abilities page and look pages ({len(differ)}): "
          + "; ".join(f"{i} {pets[i]['en']}: {sorted(known[i])} vs {sorted(pets[i]['knows'])}" for i in differ[:15]))

    # ---- wowhead: ru names
    no_ru = []
    for i, npc in enumerate(sorted(pets)):
        if i % 100 == 0:
            print(f"  npc {i}/{len(pets)}")
        d = fetch_json(f"https://nether.wowhead.com/tooltip/npc/{npc}?dataEnv=16&locale=7",
                       f"wowhead/npc_ru_{npc}.json") or {}
        ru = d.get("name") or ""
        if not ru or ru.startswith("["):  # "[Grik]": Wowhead has no translation yet
            no_ru.append(npc)
            ru = pets[npc]["en"]
        pets[npc]["ru"] = ru
    print(f"creatures without a Russian name ({len(no_ru)}): {no_ru[:40]}")

    families = sorted({p["f"] for p in pets.values()})
    print(f"families ({len(families)}): {', '.join(families)}")
    print(f"tameable: {sum(1 for p in pets.values() if p['tame'])}, not tameable: "
          f"{sum(1 for p in pets.values() if not p['tame'])}, "
          f"teach nothing known: {sum(1 for i, p in pets.items() if p['tame'] and not p['knows'])}")
    write_lua(pets)


def write_lua(pets):
    L = []
    w = L.append
    w("-- GENERATED by tools/build_pets.py. Do not edit by hand.")
    w("-- Data: Petopia Forever look pages (wow-petopia.com/forever); Russian names: Wowhead.")
    w("local _, ns = ...")
    w("")
    w(f'ns.PETS_VERSION = {{ built = "{date.today().isoformat()}" }}')
    w("")
    w("-- Every creature Petopia lists on its look pages. The teachers of ns.BEASTS are among them, except")
    w("-- the few that Petopia names on its abilities page only (the build prints which).")
    w("-- [npcId] = { en, ru, f = family key (ns.FAMILIES, or a family the atlas has no teachers for),")
    w("--            l = { min, max } (0 = unknown: bosses), z = Petopia's location text, s = attack speed or nil,")
    w("--            tag = \"Rare\" | \"Elite\" | \"RareElite\" | \"Spawned\" | \"SpawnedElite\" | \"Boss\" (Petopia's),")
    w("--            side = \"A\" | \"H\" when only that faction's hunters can tame it,")
    w("--            tame = false when Petopia marks it as not tameable (absent = tameable) }")
    w("ns.PETS = {")
    for npc in sorted(pets):
        p = pets[npc]
        fields = [f"en = {lua_str(p['en'])}", f"ru = {lua_str(p['ru'])}", f"f = {lua_str(p['f'])}",
                  f"l = {{ {p['lmin']}, {p['lmax']} }}", f"z = {lua_str(p['zone'])}"]
        if p["speed"]:
            fields.append(f"s = {p['speed']:g}")
        if p["tag"]:
            fields.append(f"tag = {lua_str(p['tag'])}")
        if p["side"]:
            fields.append(f"side = {lua_str(p['side'])}")
        if not p["tame"]:
            fields.append("tame = false")
        w(f"  [{npc}] = {{ {', '.join(fields)} }},")
    w("}")
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(L) + "\n")
    print(f"written {os.path.relpath(OUT, ROOT)}: {len(pets)} creatures, {os.path.getsize(OUT) // 1024} KB")


if __name__ == "__main__":
    main()
