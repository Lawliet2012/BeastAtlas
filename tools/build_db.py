#!/usr/bin/env python3
"""
Builds BeastAtlas/Data/Beasts.lua for WoW Forever.

Sources
  * Petopia Forever (https://www.wow-petopia.com/forever/): abilities, ranks, pet level,
    training point cost, the beasts that teach each rank (NPC id, family, level, zone),
    beast attack speeds, family icons.
  * Wowhead tooltip API (nether.wowhead.com, dataEnv=16 = Forever, locale=7 = ruRU):
    Russian names, Russian family names and spawn coordinates of each beast.
  * Wowhead search suggestions (www.wowhead.com/forever): spell ids of ability ranks.

Every HTTP response is cached under tools/cache, so re-running is cheap and offline.
Delete the cache folder (or a single file in it) to refresh data.

Usage:  python -I tools/build_db.py            (from the addon folder)
"""
import html
import json
import math
import os
import re
import sys
import time
import urllib.parse
import urllib.request

sys.stdout.reconfigure(encoding="utf-8")
from datetime import date

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "tools", "cache")
OUT = os.path.join(ROOT, "Data", "Beasts.lua")

PETOPIA = "https://www.wow-petopia.com/forever/"
UA = "BeastAtlas-databuilder/1.0 (WoW addon data build; low rate)"
DELAY = 0.35  # seconds between uncached requests

GAME_VERSION = "1.60.1"

# Classic uiMapIDs, which Forever keeps (Zephras Isle is new in Forever).
ZONE_MAP_IDS = {
    "Durotar": 1411, "Mulgore": 1412, "The Barrens": 1413, "Alterac Mountains": 1416,
    "Arathi Highlands": 1417, "Badlands": 1418, "Blasted Lands": 1419, "Tirisfal Glades": 1420,
    "Silverpine Forest": 1421, "Western Plaguelands": 1422, "Eastern Plaguelands": 1423,
    "Hillsbrad Foothills": 1424, "The Hinterlands": 1425, "Dun Morogh": 1426, "Searing Gorge": 1427,
    "Burning Steppes": 1428, "Elwynn Forest": 1429, "Deadwind Pass": 1430, "Duskwood": 1431,
    "Loch Modan": 1432, "Redridge Mountains": 1433, "Stranglethorn Vale": 1434,
    "Swamp of Sorrows": 1435, "Westfall": 1436, "Wetlands": 1437, "Teldrassil": 1438,
    "Darkshore": 1439, "Ashenvale": 1440, "Thousand Needles": 1441, "Stonetalon Mountains": 1442,
    "Desolace": 1443, "Feralas": 1444, "Dustwallow Marsh": 1445, "Tanaris": 1446,
    "Azshara": 1447, "Felwood": 1448, "Un'Goro Crater": 1449, "Moonglade": 1450,
    "Silithus": 1451, "Winterspring": 1452, "Stormwind City": 1453, "Orgrimmar": 1454,
    "Ironforge": 1455, "Thunder Bluff": 1456, "Darnassus": 1457, "Undercity": 1458,
    "Zephras Isle": 2521,
}

# Spell ids Wowhead's search can't find by name (a "!" in the name breaks the query).
SPELL_HINTS = {"Mine!": [1265054]}

# Pet trainer NPCs (subtitle "Pet Trainer"), from Wowhead's Forever search for "pet trainer" on 2026-11-13:
# id -> (English name, side). Side comes from Wowhead's reaction data: "A" Alliance, "H" Horde, None both.
# The search page is behind bot protection, so this list is a snapshot; coordinates and Russian names
# are fetched per NPC below. The "World <Family> Trainer" placeholder NPCs have no location and are left out.
PET_TRAINERS = {
    543: ("Nalesette Wildbringer", "A"), 2878: ("Peria Lamenur", "A"), 2879: ("Karrina Mekenda", "A"),
    3306: ("Keldas", "A"), 3545: ("Claude Erksine", "A"), 3698: ("Bolyun", "A"),
    3702: ("Alanndarian Nightsong", "A"), 4320: ("Caelyb", "A"), 10089: ("Silvaria", "A"),
    10090: ("Belia Thundergranite", "A"), 258930: ("Isaac Chan", "A"),
    3620: ("Harruk", "H"), 3622: ("Grokor", "H"), 3624: ("Zudd", "H"), 3688: ("Reban Freerunner", "H"),
    10086: ("Hesuwa Thunderhorn", "H"), 10088: ("Xao'tsu", "H"),
    254411: ("Quel'dora Quickgale", None),
}
# Wowhead area id -> zone, for areas that have no teaching beasts (capital cities).
CITY_AREAS = {1519: "Stormwind City", 1537: "Ironforge", 1637: "Orgrimmar", 1638: "Thunder Bluff",
              1657: "Darnassus", 1497: "Undercity"}

# Stable masters: tools/stable_masters_wowhead.json is a snapshot of Wowhead's search for the NPC tag
# "Stable Master" (rows: id, name, tag, [reaction to Alliance, to Horde], [area ids], status, level).
# Every id in the snapshot must be either usable or listed here with the reason; anything else stops the build.
STABLE_SNAPSHOT = os.path.join(ROOT, "tools", "stable_masters_wowhead.json")
STABLES_LEFT_OUT = {
    9896: "placeholder 'World Stable Master', no location",
    9567: "placeholder 'Test Stable Master', no location",
    13616: "Alterac Valley (battleground), no coordinates",
    13617: "Alterac Valley (battleground), no coordinates",
    16156: "Naxxramas, hostile to both factions",
}
# Wowhead area id -> zone, for areas new to the atlas (no teaching beasts there). No uiMapID is known for
# them: the addon finds the map by the area's name in the client (ns.ZoneMap).
STABLE_AREAS = {16591: "Riverglades", 616: "Mount Hyjal"}

# Petopia lists families in plural on ability pages.
PLURALS = {
    "Wolves": "Wolf", "Foxes": "Fox", "Birds of Prey": "Bird of Prey", "Carrion Birds": "Carrion Bird",
    "Core Hounds": "Core Hound", "Wind Serpents": "Wind Serpent",
}


# ---------------------------------------------------------------------------- http
_last = [0.0]


# Petopia's food names and family categories; anything else stops the build instead of shipping a guess.
DIETS = ("Bread", "Cheese", "Fish", "Fruit", "Fungus", "Meat", "Raw Fish")
ROLES = {"offensive": "O", "general": "G", "defensive": "D"}


def fetch(url, cache_name):
    path = os.path.join(CACHE, cache_name)
    if os.path.exists(path):
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    wait = DELAY - (time.time() - _last[0])
    if wait > 0:
        time.sleep(wait)
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                body = r.read()
            break
        except Exception as e:  # noqa: BLE001
            if attempt == 2:
                print("  ! failed", url, e, file=sys.stderr)
                return None
            time.sleep(2 + attempt * 3)
    _last[0] = time.time()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(body)
    return body.decode("utf-8", "replace")


def fetch_json(url, cache_name):
    body = fetch(url, cache_name)
    if not body:
        return None
    try:
        return json.loads(body)
    except ValueError:
        return None


def read_cached_json(cache_name):
    """Cache only, no network: Wowhead's search endpoint refuses scripted requests now."""
    path = os.path.join(CACHE, cache_name)
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except ValueError:
        return None


def load_pet_spells():
    """{ (name, rank): (spellID, petLevel) } from tools/pet_spells_wowhead.txt"""
    out = {}
    path = os.path.join(ROOT, "tools", "pet_spells_wowhead.txt")
    for line in open(path, encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        for item in line.strip().split(";"):
            sid, name, rank, level = item.split("|")
            if rank:
                out[(name, int(rank))] = (int(sid), int(level))
    return out


def strip_tags(s):
    return html.unescape(re.sub(r"<[^>]+>", "", s)).strip()


# ---------------------------------------------------------------------------- petopia
def parse_abilities(page):
    abilities = []
    # split by ability heading
    parts = re.split(r"<h3 class='guide_heading[^']*' id='([^']+)'>", page)
    for i in range(1, len(parts), 2):
        key, body = re.sub(r"[^a-z0-9]", "", parts[i]), parts[i + 1]
        m = re.match(r"\s*<img[^>]*src='/images/icons/([^'.]+)\.png'>([^<]+)</h3>", body)
        if not m:
            continue
        icon, name = m.group(1), html.unescape(m.group(2)).strip()
        desc = re.search(r"<p class='abilitymaindesc[^']*'>(.*?)</p>", body, re.S)
        fam_html = re.search(r"<span class='ability_family_list classic[^']*'>(.*?)</span>", body, re.S)
        families = []
        if fam_html:
            for f in re.findall(r">([^<]+)</a>", fam_html.group(1)):
                f = html.unescape(f).strip()
                families.append(PLURALS.get(f, f[:-1] if f.endswith("s") else f))
            if not families and "All Families" in fam_html.group(1):
                families = ["*"]
        ranks = {}
        trainer = False
        for rk in re.finditer(r"<li id='[^']+' class='abilityrank[^']*'>(.*?)</li>\s*(?=<li id=|</ul>)", body, re.S):
            rb = rk.group(1)
            head = re.search(r"abilityrankname[^']*'>([^<]+?) (\d+)</span>: Pet Level (\d+), Cost (\d+) TP", rb)
            if not head:
                continue
            rank, lvl, tp = int(head.group(2)), int(head.group(3)), int(head.group(4))
            rdesc = re.search(r"<span class='abilityrankdesc[^']*'>(.*?)</span>\s*(?:<span class='abilitysource|$)", rb, re.S)
            npcs = []
            for n in re.finditer(r"href='https://www\.wowhead\.com/forever/npc=(\d+)'>([^<]+)</a>\s*\(([^)]*\)?)\)", rb):
                npcs.append((int(n.group(1)), html.unescape(n.group(2)).strip(), html.unescape(n.group(3))))
            from_trainer = "learned from trainers" in rb
            trainer = trainer or from_trainer
            ranks[rank] = {"lvl": lvl, "tp": tp, "desc": strip_tags(rdesc.group(1)) if rdesc else "",
                           "npcs": npcs, "trainer": from_trainer}
        abilities.append({"key": key, "en": name, "icon": icon,
                          "desc": strip_tags(desc.group(1)) if desc else "",
                          "families": families, "ranks": ranks, "trainer": trainer})
    return abilities


def parse_npc_meta(meta):
    """'Wolf, 2-3, Tirisfal Glades' -> family, lmin, lmax, zone"""
    bits = [b.strip() for b in meta.split(",")]
    family = bits[0]
    lv = bits[1] if len(bits) > 1 else "0"
    zone = ", ".join(bits[2:]) if len(bits) > 2 else ""
    m = re.match(r"(\d+)(?:-(\d+))?", lv)
    lmin = int(m.group(1)) if m else 0
    lmax = int(m.group(2) or m.group(1)) if m else 0
    return family, lmin, lmax, zone


def parse_attack_speeds(page):
    speeds = {}
    for sec in re.split(r"Attack Speed ", page)[1:]:
        m = re.match(r"([0-9.]+)", sec)
        if not m:
            continue
        sp = float(m.group(1))
        for n in re.finditer(r"href='https://www\.wowhead\.com/forever/npc=(\d+)'", sec.split("Attack Speed")[0]):
            speeds.setdefault(int(n.group(1)), sp)
    return speeds


# ---------------------------------------------------------------------------- coords
def cluster(points, eps=5.0, max_clusters=6):
    """Greedy + k-means style clustering of percent coords. Returns [(x, y, r, n)]."""
    if not points:
        return []
    cl = []
    for x, y in sorted(points):
        best, bd = None, eps
        for c in cl:
            d = math.hypot(c[0] - x, c[1] - y)
            if d < bd:
                best, bd = c, d
        if best is None:
            cl.append([x, y, [(x, y)]])
        else:
            best[2].append((x, y))
            best[0] = sum(p[0] for p in best[2]) / len(best[2])
            best[1] = sum(p[1] for p in best[2]) / len(best[2])
    # merge clusters that drifted close together
    merged = True
    while merged:
        merged = False
        for i in range(len(cl)):
            for j in range(i + 1, len(cl)):
                if math.hypot(cl[i][0] - cl[j][0], cl[i][1] - cl[j][1]) < eps * 1.2:
                    pts = cl[i][2] + cl[j][2]
                    cl[i] = [sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts), pts]
                    del cl[j]
                    merged = True
                    break
            if merged:
                break
    cl.sort(key=lambda c: -len(c[2]))
    biggest = len(cl[0][2])
    out = []
    for cx, cy, pts in cl:
        if len(out) >= max_clusters:
            break
        if len(points) > 6 and len(pts) < max(2, biggest * 0.08):
            continue  # stray single spawn far from the herd
        r = max(math.hypot(px - cx, py - cy) for px, py in pts) + 1.5
        r = min(max(r, 2.0), 14.0)
        out.append((round(cx, 1), round(cy, 1), round(r, 1), len(pts)))
    return out


# ---------------------------------------------------------------------------- lua output
def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def main():
    page = fetch(PETOPIA + "abilities.php", "petopia/abilities.html")
    abilities = parse_abilities(page)
    speeds = parse_attack_speeds(fetch(PETOPIA + "attackspeed.php", "petopia/attackspeed.html"))
    print(f"abilities: {len(abilities)}")

    # ---- collect npcs
    npcs = {}
    for ab in abilities:
        for rank, r in ab["ranks"].items():
            for npc_id, name, meta in r["npcs"]:
                fam, lmin, lmax, zone = parse_npc_meta(meta)
                n = npcs.setdefault(npc_id, {"id": npc_id, "en": name, "family": fam, "lmin": lmin,
                                             "lmax": lmax, "zone": zone, "teaches": []})
                if (ab["key"], rank) not in n["teaches"]:
                    n["teaches"].append((ab["key"], rank))
    print(f"teaching npcs: {len(npcs)}")
    # Petopia lists a beast under a rank because the beast knows it; the family list of the ability says
    # which pets can learn it. The two need not agree (a bat that knows a carrion bird's ability).
    outside = [f"{n['en']} ({n['family']}): {ab['en']} {rank}"
               for ab in abilities if "*" not in ab["families"]
               for rank, r in sorted(ab["ranks"].items())
               for n in (npcs[i] for i, _, _ in r["npcs"]) if n["family"] not in ab["families"]]
    print(f"teachers of another family than the ability's ({len(outside)}): {'; '.join(outside)}")

    # ---- family icons from Petopia family pages
    families = {}
    for n in npcs.values():
        families.setdefault(n["family"], {"en": n["family"]})
    for fam in families:
        slug = re.sub(r"[^a-z]", "", fam.lower())
        fp = fetch(PETOPIA + "family.php?id=" + slug, f"petopia/family_{slug}.html") or ""
        m = re.search(r"<img src='/images/icons/(ability_hunter_pet_[a-z_]+)\.png'", fp)
        families[fam]["icon"] = m.group(1) if m else "ability_hunter_beasttaming"
        # what the family eats: "Fish - Meat"
        m = re.search(r"familydetailsabilities diet'><div class='familydetailsdata'>\s*(.*?)</div>", fp, re.S)
        diet = [d.strip() for d in strip_tags(m.group(1)).split(" - ")] if m else []
        if not diet or any(d not in DIETS for d in diet):
            sys.exit(f"family {fam}: unexpected diet {diet!r}")
        families[fam]["diet"] = diet

    # ---- family roles from Petopia's home page (Offense / General / Defense)
    home = fetch(PETOPIA, "petopia/index.html") or ""
    roles = {slug: ROLES[cls] for cls, slug in
             re.findall(r"family_panel_item (offensive|general|defensive) classic forever'><a href='family\.php\?id=(\w+)'", home)}
    for fam in families:
        slug = re.sub(r"[^a-z]", "", fam.lower())
        if slug not in roles:
            sys.exit(f"family {fam}: no role on Petopia's home page")
        families[fam]["role"] = roles[slug]

    # ---- wowhead: ru names + coords
    missing_coords, zone_area = [], {}
    for i, n in enumerate(sorted(npcs.values(), key=lambda v: v["id"])):
        if i % 50 == 0:
            print(f"  npc {i}/{len(npcs)}")
        d = fetch_json(f"https://nether.wowhead.com/tooltip/npc/{n['id']}?dataEnv=16&locale=7",
                       f"wowhead/npc_ru_{n['id']}.json")
        if not d or "name" not in d:
            n["ru"] = n["en"]
            missing_coords.append(n["id"])
            continue
        n["ru"] = d["name"]
        rows = re.findall(r"<td>(.*?)</td>", d.get("tooltip", ""))
        if len(rows) >= 3:
            fam_ru = strip_tags(rows[2])
            if fam_ru and not re.search(r"\d", fam_ru):
                families[n["family"]].setdefault("ru_votes", {}).setdefault(fam_ru, 0)
                families[n["family"]]["ru_votes"][fam_ru] += 1
        m = d.get("map") or {}
        pts = []
        for floor, coords in (m.get("coords") or {}).items():
            pts.extend((float(x), float(y)) for x, y in coords)
        n["area"] = m.get("zone")
        if n["area"]:
            zone_area.setdefault(n["zone"], {}).setdefault(n["area"], 0)
            zone_area[n["zone"]][n["area"]] += 1
        n["clusters"] = cluster(pts)
        if not pts:
            missing_coords.append(n["id"])

    for fam, f in families.items():
        votes = f.pop("ru_votes", {})
        f["ru"] = max(votes, key=votes.get) if votes else fam

    # zone -> wowhead area id (majority), uiMapID
    zones, area_to_zone = {}, {}
    for zone, votes in zone_area.items():
        if ";" in zone:
            continue  # "Westfall; Redridge Mountains": resolved per beast below
        zones[zone] = {"area": max(votes, key=votes.get), "map": ZONE_MAP_IDS.get(zone)}
        area_to_zone.setdefault(zones[zone]["area"], zone)
    for n in npcs.values():
        area = n.get("area")
        z = zones.get(n["zone"])
        if area and (z is None or (z["area"] and z["area"] != area)):
            # Wowhead's coords are for another zone than Petopia names (or Petopia lists several):
            # trust Wowhead, since the coords come from it.
            if area in area_to_zone:
                n["zone"] = area_to_zone[area]
            else:
                n["clusters_area"] = area  # unknown map for these coords: list only
        if ";" in n["zone"]:
            n["zone"] = n["zone"].split(";")[0].strip()
        zones.setdefault(n["zone"], {"area": area, "map": ZONE_MAP_IDS.get(n["zone"])})

    # ---- spell ids + ru ability names
    # rank["spell"]  = the pet ability spell (clean list from Wowhead's pet-abilities listing): used in game
    #                  for the localized name and the native tooltip;
    # rank["spells"] = that id plus other *hunter* spells of the same name and rank found by Wowhead's search
    #                  (the hunter-side "known" copies), used only to ask the client whether the rank is known.
    pet_spells, level_notes, no_spell = load_pet_spells(), [], []
    for ab in abilities:
        cached = read_cached_json(f"wowhead/search_{ab['key']}.json") or {}
        for rank, r in ab["ranks"].items():
            hit = pet_spells.get((ab["en"], rank))
            r["spells"] = []
            if hit:
                r["spell"] = hit[0]
                r["spells"].append(hit[0])
                if hit[1] != r["lvl"]:
                    level_notes.append(f"{ab['en']} {rank}: Petopia {r['lvl']}, Wowhead {hit[1]}")
            else:
                no_spell.append(f"{ab['en']} {rank}")
        for res in cached.get("results", []):
            if res.get("type") != 6 or res.get("name") != ab["en"] or "Hunter" not in (res.get("pinBreadcrumb") or []):
                continue
            m = re.match(r"Rank (\d+)", res.get("rank") or "")
            rank = int(m.group(1)) if m else None
            if rank in ab["ranks"] and res["id"] not in ab["ranks"][rank]["spells"]:
                ab["ranks"][rank]["spells"].append(res["id"])
        ab["ru"] = ab["en"]
        for rank in sorted(ab["ranks"]):
            sid = ab["ranks"][rank].get("spell")
            t = sid and fetch_json(f"https://nether.wowhead.com/tooltip/spell/{sid}?dataEnv=16&locale=7",
                                   f"wowhead/spell_ru_{sid}.json")
            if t and t.get("name"):
                ab["ru"] = t["name"]
                break
        if ab["ru"] == ab["en"]:  # no pet spell id: fall back to a same-named hunter spell from the search cache
            for res in cached.get("results", []):
                if res.get("type") == 6 and res.get("name") == ab["en"]:
                    t = read_cached_json(f"wowhead/spell_ru_{res['id']}.json")
                    if t and t.get("name"):
                        ab["ru"] = t["name"]
                        break
    print(f"ranks without a pet spell id ({len(no_spell)}): {', '.join(no_spell)}")
    print(f"pet level differs between sources ({len(level_notes)}): {'; '.join(level_notes)}")

    # ---- pet trainers
    trainers, trainer_problems = {}, []
    for tid, (name, side) in sorted(PET_TRAINERS.items()):
        d = fetch_json(f"https://nether.wowhead.com/tooltip/npc/{tid}?dataEnv=16&locale=7",
                       f"wowhead/npc_ru_{tid}.json") or {}
        m = d.get("map") or {}
        pts = [(float(x), float(y)) for coords in (m.get("coords") or {}).values() for x, y in coords]
        area = m.get("zone")
        zone = area_to_zone.get(area) or CITY_AREAS.get(area)
        if not pts or not zone:
            trainer_problems.append(f"{tid} {name}: area {area}, {len(pts)} coords")
            continue
        zones.setdefault(zone, {"area": area, "map": ZONE_MAP_IDS.get(zone)})
        # A trainer stands in one spot: nearby samples are merged. Samples far apart are separate spots
        # (Wowhead has two for some trainers; one of them may be from an older build) and all are kept.
        spots = [(x, y) for x, y, _, _ in cluster(pts, eps=5.0, max_clusters=4)]
        if len(spots) > 1:
            trainer_problems.append(f"{tid} {name}: {len(spots)} separate spots {spots}")
        trainers[tid] = {"en": name, "ru": d.get("name") or name, "side": side, "zone": zone,
                         "c": [int(round(v * 10)) for spot in spots for v in spot]}

    # ---- stable masters
    stables, stable_notes = {}, []
    with open(STABLE_SNAPSHOT, encoding="utf-8") as f:
        snapshot = json.load(f)
    for sid, name, tag, react, _areas, _status, _level in sorted(snapshot):
        if sid in STABLES_LEFT_OUT:
            continue
        if tag != "Stable Master":
            sys.exit(f"stable master {sid} {name}: unexpected tag {tag!r}")
        d = fetch_json(f"https://nether.wowhead.com/tooltip/npc/{sid}?dataEnv=16&locale=7",
                       f"wowhead/npc_ru_{sid}.json") or {}
        m = d.get("map") or {}
        pts = [(float(x), float(y)) for coords in (m.get("coords") or {}).values() for x, y in coords]
        area = m.get("zone")
        zone = area_to_zone.get(area) or CITY_AREAS.get(area) or STABLE_AREAS.get(area)
        if not pts or not zone:
            sys.exit(f"stable master {sid} {name}: area {area}, {len(pts)} coords - add it to STABLES_LEFT_OUT "
                     f"with the reason, or its area to STABLE_AREAS")
        # reaction: 1 friendly, 0 neutral, -1 hostile, None unknown. Usable by a faction it is not hostile to;
        # an unknown reaction counts as "not for that faction".
        ally, horde = (react or [None, None])
        for_ally, for_horde = ally is not None and ally >= 0, horde is not None and horde >= 0
        if not (for_ally or for_horde):
            sys.exit(f"stable master {sid} {name}: usable by nobody (reaction {react})")
        side = None if (for_ally and for_horde) else ("A" if for_ally else "H")
        if None in (ally, horde) and 0 in (ally, horde):
            stable_notes.append(f"{sid} {name}: reaction {react}, taken as {side or 'both'}")
        zones.setdefault(zone, {"area": area, "map": ZONE_MAP_IDS.get(zone)})
        spots = [(x, y) for x, y, _, _ in cluster(pts, eps=5.0, max_clusters=4)]
        if len(spots) > 1:
            stable_notes.append(f"{sid} {name}: {len(spots)} separate spots {spots}")
        ru = d.get("name") or name
        if ru.startswith("["):  # Wowhead has no translation yet: "[Grik]"
            stable_notes.append(f"{sid} {name}: no Russian name")
            ru = name
        stables[sid] = {"en": name, "ru": ru, "side": side, "zone": zone,
                        "c": [int(round(v * 10)) for spot in spots for v in spot]}
    unknown = [row[0] for row in snapshot if row[0] not in stables and row[0] not in STABLES_LEFT_OUT]
    if unknown:
        sys.exit(f"stable masters neither used nor left out: {unknown}")

    write_lua(abilities, npcs, families, zones, speeds, trainers, stables)
    print(f"pet trainers: {len(trainers)} of {len(PET_TRAINERS)}"
          + (f"; notes: {trainer_problems}" if trainer_problems else ""))
    print(f"stable masters: {len(stables)} used, {len(STABLES_LEFT_OUT)} left out"
          + (f"; notes: {stable_notes}" if stable_notes else ""))

    # ---- report
    print(f"npcs without coords: {len(missing_coords)}")
    unresolved = sorted(z for z, v in zones.items() if not v["map"])
    print(f"zones without uiMapID ({len(unresolved)}): {', '.join(unresolved)}")
    no_ru = [a["en"] for a in abilities if a["ru"] == a["en"]]
    print(f"abilities without ru name: {no_ru}")
    print(f"families: {', '.join(f'{k}={v['ru']}' for k, v in sorted(families.items()))}")


def write_lua(abilities, npcs, families, zones, speeds, trainers, stables):
    L = []
    w = L.append
    w("-- GENERATED by tools/build_db.py. Do not edit by hand.")
    w("-- Data: Petopia Forever (wow-petopia.com/forever) and Wowhead (wowhead.com/forever).")
    w("local _, ns = ...")
    w("")
    w(f'ns.DATA_VERSION = {{ game = "{GAME_VERSION}", built = "{date.today().isoformat()}" }}')
    w("")
    w("-- [familyKey] = { en, ru, icon, role = \"O\"ffense | \"G\"eneral | \"D\"efense (Petopia), diet = { food, ... } }")
    w("ns.FAMILIES = {")
    for fam in sorted(families):
        f = families[fam]
        diet = ", ".join(lua_str(d) for d in f["diet"])
        w(f"  [{lua_str(fam)}] = {{ en = {lua_str(f['en'])}, ru = {lua_str(f['ru'])}, icon = {lua_str(f['icon'])}, "
          f"role = {lua_str(f['role'])}, diet = {{ {diet} }} }},")
    w("}")
    w("")
    w("-- [zone en] = { map = uiMapID or nil, area = AreaTable id }")
    w("ns.ZONES = {")
    for z in sorted(zones):
        v = zones[z]
        w(f"  [{lua_str(z)}] = {{ map = {v['map'] or 'nil'}, area = {v['area'] or 'nil'} }},")
    w("}")
    w("")
    w("-- Ordered list. ranks[n] = { lvl = pet level, tp = training points (nil = unknown), trainer = bool,")
    w("--                             spell = pet ability spell id (nil if unknown), spells = ids to test \"is it known\" }")
    w("ns.ABILITIES = {")
    for ab in abilities:
        fams = "{ " + ", ".join(lua_str(f) for f in ab["families"]) + " }"
        w(f"  {{ key = {lua_str(ab['key'])}, en = {lua_str(ab['en'])}, ru = {lua_str(ab['ru'])}, "
          f"icon = {lua_str(ab['icon'])}, trainer = {str(ab['trainer']).lower()}, families = {fams},")
        w(f"    desc = {lua_str(ab['desc'])},")
        w("    ranks = {")
        for rank in sorted(ab["ranks"]):
            r = ab["ranks"][rank]
            sp = "{ " + ", ".join(str(s) for s in r.get("spells", [])) + " }"
            spell = f"spell = {r['spell']}, " if r.get("spell") else ""
            # Petopia prints "Cost 0 TP" for abilities whose cost it doesn't know yet (all the new
            # Forever ones). Only trainer abilities (Growl) are really free: write unknown as nil.
            tp = r["tp"] if (r["tp"] > 0 or r["trainer"]) else "nil"
            w(f"      [{rank}] = {{ lvl = {r['lvl']}, tp = {tp}, trainer = {str(r['trainer']).lower()}, "
              f"{spell}spells = {sp}, desc = {lua_str(r['desc'])} }},")
        w("    },")
        w("  },")
    w("}")
    w("")
    w("-- [npcId] = { en, ru, f = family, l = {min, max}, z = zone en, s = attack speed,")
    w("--             t = { \"abilityKey\", rank, ... }, c = { x*10, y*10, r*10, ... } (percent of zone map) }")
    w("ns.BEASTS = {")
    for nid in sorted(npcs):
        n = npcs[nid]
        teach = ", ".join(f"{lua_str(k)}, {r}" for k, r in sorted(n["teaches"]))
        cl = n.get("clusters") or []
        if n.get("clusters_area"):
            cl = []  # coords are for a different map than Petopia's zone
        coords = ", ".join(f"{int(round(x * 10))}, {int(round(y * 10))}, {int(round(r * 10))}" for x, y, r, _ in cl)
        sp = speeds.get(nid)
        w(f"  [{nid}] = {{ en = {lua_str(n['en'])}, ru = {lua_str(n.get('ru', n['en']))}, f = {lua_str(n['family'])}, "
          f"l = {{ {n['lmin']}, {n['lmax']} }}, z = {lua_str(n['zone'])}, "
          f"{'s = ' + format(sp, 'g') + ', ' if sp else ''}t = {{ {teach} }}, c = {{ {coords} }} }},")
    w("}")
    w("")
    w("-- Pet trainer NPCs. [npcId] = { en, ru, z = zone en, side = \"A\" | \"H\" | nil (both),")
    w("--                               c = { x*10, y*10, ... } }  -- pairs, percent of the zone map; usually one spot")
    w("ns.TRAINERS = {")
    for tid in sorted(trainers):
        t = trainers[tid]
        side = f'side = "{t["side"]}", ' if t["side"] else ""
        w(f"  [{tid}] = {{ en = {lua_str(t['en'])}, ru = {lua_str(t['ru'])}, z = {lua_str(t['zone'])}, "
          f"{side}c = {{ {', '.join(str(v) for v in t['c'])} }} }},")
    w("}")
    w("")
    w("-- Stable masters (Wowhead). Same shape as ns.TRAINERS.")
    w("ns.STABLES = {")
    for sid in sorted(stables):
        t = stables[sid]
        side = f'side = "{t["side"]}", ' if t["side"] else ""
        w(f"  [{sid}] = {{ en = {lua_str(t['en'])}, ru = {lua_str(t['ru'])}, z = {lua_str(t['zone'])}, "
          f"{side}c = {{ {', '.join(str(v) for v in t['c'])} }} }},")
    w("}")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(L) + "\n")
    print(f"wrote {OUT} ({os.path.getsize(OUT) // 1024} KB)")


if __name__ == "__main__":
    main()
