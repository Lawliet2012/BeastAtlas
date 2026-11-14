# BeastAtlas v0.2 — implementation spec

BeastAtlas is a World of Warcraft **Forever** addon (Interface 16001, Lua 5.1) for hunters: it shows which wild
beasts teach which pet-ability ranks, where they live, and which of them are worth taming right now.
v0.1 exists in this folder. This spec fixes the review findings. Each executor owns a set of files (see
"Roles") and implements exactly its section against the shared contract below.

> **Status.** This is the brief the v0.2 executors worked from, kept as a description of the module contract.
> The reviewer changed a few things afterwards; where this file and the code disagree, the code wins:
> - §2.3: when every tameable teacher of the target rank is off the map (dungeon-only), the best lower rank with
>   a tameable teacher that *is* on a zone map is READY as well (`ns.Plan(key).alt`), not OBSOLETE.
> - Observations are merged at `PLAYER_LOGIN` (before the `"LOGIN"` bus event), not at `ADDON_LOADED`.
> - Tracker fires the bus event `"PET"` when the summoned pet changes; the window header listens to it.
> - A spellbook read with missing rank text sets `ns.petRanksPartial`; such a read is never stored (main pet
>   ranks, observations).
> - Collect records a tame only while the new pet still carries the beast's (or its family's) name.
> - The chat fallback also requires a separator before the ability name.
> - Pet trainers were added after the brief: `ns.TRAINERS[npcId] = { en, ru, z, side = "A"|"H"|nil, c = { x*10,
>   y*10, ... } }`, `ns.TrainersOnMap(mapID)` (player's faction only), `ns.SetTrainerWaypoint(id, spot)`, the
>   option `trainers`, and the pin template `BeastAtlasTrainerPinTemplate` (zone maps only).
> - v0.3: the window uses stock widgets (`ButtonFrameTemplate`, `PanelTabButtonTemplate`, `SearchBoxTemplate`,
>   `WowScrollBoxList` + `MinimalScrollBar` with the row template in `UI.xml`, `InsetFrameTemplate`); §8's layout
>   details are superseded. Ranks carry `spell` (the pet ability spell id) for the native tooltip
>   (`GameTooltip:SetSpellByID`) and `C_Spell.GetSpellDescription`. Map pins use the addon's own textures in
>   `Media/`.
> - v0.4: `Helper.lua` adds the training helper panel (`ns.TrainingGoals()`, options `helper`/`helperPos`,
>   `BeastAtlasCharDB.helperDismissed`); Tracker fires `"PET"` also when the summoned pet's spellbook changes;
>   `ns.HaveRank(key)` = the hunter's rank or the main pet's own, whichever is higher, and drives the statuses.
> - v0.5: the Families tab (`UI.lua`: `BuildFamilies`, `BuildFamilyCard`, `BuildGuide`; row kinds `family`, `guide`,
>   `pet`, `text`; `BeastAtlasTextRowTemplate` rows take their height from the measured text). `ns.FAMILIES[key]`
>   gained `role` ("O"/"G"/"D", Petopia's home page) and `diet` (Petopia's family pages); the build stops if either
>   is missing. Beasts on this tab are shown as pets to keep (can it be tamed now, attack speed, what it knows),
>   not by rank status, and ignore the rank filters. The guide text follows Petopia's Forever pages (differences, training,
>   attack speeds); the one rule not found there, "no taming above your own level", is the Classic rule of section 1.
> - v0.5.1: habitat pins are circles (the mean of the canvas sides times the cluster radius) and are drawn only
>   for the beast under the mouse or the highlighted one; the option `areasAlways` (default false) replaces `areas`.
>   Every habitat pin is still acquired on refresh and registers itself per beast, so hovering only toggles textures.
> - v0.6: stable masters. `ns.STABLES` (same shape as `ns.TRAINERS`) is built from the Wowhead snapshot
>   `tools/stable_masters_wowhead.json`; the build stops on any id that is neither used nor listed in
>   `STABLES_LEFT_OUT`. Core: `ns.StablesOnMap`, `ns.NearestStable(cont, x, y)`, `ns.NearestStableToPlayer`,
>   `ns.NearestStableToBeast` (from the edge of the nearest habitat), `ns.StableText`, `ns.SetStableWaypoint`,
>   option `stables`, `/ba stable`. Trainers and stable masters share `BeastAtlasTrainerPinTemplate`
>   (`OnAcquired(kind, id, spot, dx)`; everything kind-specific is set there because pins are pooled).
>   Distances are straight lines. Zones without a known uiMapID (Riverglades, Mount Hyjal) are looked up by
>   area name; when that fails their stable masters are skipped everywhere.
> - Other client languages: `ns.LearnFamily` (family names learned from tooltips of known beasts, saved in
>   `BeastAtlasDB.familyNames`) and the client's own spell names are accepted by `ns.AbilityByName`.

## 0. Ground rules (every role)

1. **Do not invent client APIs.** The client's UI source is at
   `Interface/AddOns` of the `forever` branch of https://github.com/Gethe/wow-ui-source (a local checkout,
   read-only). Use only functions, events, templates and enum values that are (a) listed in §1, (b) already used
   by the v0.1 code, or (c) found by you with grep in that source. If something the spec asks for turns out not to
   exist there, implement the closest guarded variant and list it under `deviations` in your report. Never guess a
   function name, an event name, or a return order.
2. **Edit only your own files** (see Roles). Other files are read-only for you, even if you see a bug there —
   report it under `problemsInOtherFiles` instead. Never touch `tools/`, `Data/`, `README.md`, `docs/`.
3. **Use the contract in §2 exactly** — names, arguments, return values. If you are the owner of a function,
   implement that signature. If you consume a function owned by another role, call it as specified even though it
   may not exist on disk yet (another executor is writing it in parallel); guard only where the spec says so.
4. **Strings.** Every user-visible string comes from `ns.L` (`L.KEY`). Use only keys listed in §3. No hard-coded
   user-visible text, in any language.
5. **Text handling.** Never use `string.lower`/`upper` or the pattern classes `%a %d %l %s %u %w %x` on text that
   can be non-ASCII (they depend on the C locale and corrupt UTF-8). Use `ns.Lower(s)`, and explicit classes like
   `[0-9]`, `[ \t]`. Write a tab inside a pattern as `\t`, never as a literal tab character.
6. **Secret values.** `UnitName`, `UnitGUID`, `UnitCreatureFamily`, `UnitLevel` and chat message text can be
   "secret" values in this client. Before doing string operations, comparisons or arithmetic on such a value,
   check `ns.IsSecret(v)` and bail out if true.
7. **Performance.** No `OnUpdate` scripts except the two existing drag handlers (model rotation, minimap button).
   No new polling timers except the ones named in this spec. Don't allocate tables per row per refresh where a
   cached value exists (use `ns.Ctx()` and the memoised `ns.BeastInfo`).
8. Optional client APIs are guarded: `if C_X and C_X.Fn then ... end`. The addon must load without errors for a
   non-hunter too (modules simply do nothing; see `ns.isHunter`).
9. Style: 4 spaces, `local` functions, comments only where the *why* is not obvious. Keep files focused; do not
   add features that are not in this spec.
10. Before you finish, run the syntax check on every file you changed and fix what it reports:
    `python -I tools/luacheck.py <files>` (run from the project folder). Do **not** run or
    edit `tools/test_load.py` — it tests v0.1 behaviour and will be rewritten by the reviewer.

## 1. Verified facts about the Forever client (from its UI source)

- **Beast Training has no craft window.** `GetNumCrafts`/`GetCraftInfo`/`CRAFT_SHOW` do not exist. Beast Training
  uses the trainer window: events `TRAINER_SHOW`, `TRAINER_UPDATE`, `TRAINER_CLOSED`;
  `C_Trainer.GetTrainerType() == Enum.TrainerType.Pet`; `GetNumTrainerServices()`;
  `GetTrainerServiceInfo(i)` returns `serviceName, serviceType, texture, reqLevel, serviceSubText, category`
  where `serviceType` is `"available"`, `"unavailable"` or `"used"` and `serviceSubText` is the rank text.
- `C_PetInfo.GetPetTrainingPoints()` → `totalPoints, usedPoints`. Event `UNIT_PET_TRAINING_POINTS`.
- `C_SpellBook.HasPetSpells()` → `numPetSpells` (nothing when there are none).
  `C_SpellBook.GetSpellBookItemName(slot, Enum.SpellBookSpellBank.Pet)` → `name, subName`.
  `C_SpellBook.IsSpellKnown(spellID)` → bool. `C_Spell.GetSpellName(spellID)` → name.
- Map: `C_Map.GetMapInfo(id)` → `{ mapID, name, mapType, parentMapID }`; `Enum.UIMapType.Continent/Zone/Micro`;
  `C_Map.GetBestMapForUnit`, `C_Map.GetPlayerMapPosition`, `C_Map.GetWorldPosFromMapPos(mapID, vec2)` →
  `continentID, worldPos`; `C_Map.GetAreaInfo(areaID)` → name; `C_Map.GetMapChildrenInfo`;
  `C_Map.GetMapRectOnMap(uiMapID, topUiMapID)` → `minX, maxX, minY, maxY`; `C_Map.SetUserWaypoint`,
  `C_Map.CanSetUserWaypointOnMap`; global `OpenWorldMap(mapID)`; `WorldMapFrame:SetMapID(id)`.
- **Map pins** (`Blizzard_MapCanvas`): `WorldMapFrame:AddDataProvider(provider)`,
  `map:AcquirePin(template, ...)`, `map:RemoveAllPinsByTemplate(template)`. `AcquirePin` calls `pin:OnLoad()`
  itself, **asserts the pin has no `OnEnter`/`OnLeave` script**, clears a Button's `OnClick`, and routes the mouse
  to the mixin methods `OnMouseEnter`, `OnMouseLeave` and (through `MapCanvasPinMixin:OnClick`)
  `OnMouseClickAction(button)`. So pin templates carry **no XML `<Scripts>`**. After `OnAcquired` it calls
  `pin:CheckMouseButtonPassthrough("RightButton")`, whose default implementation calls
  `SetPassThroughButtons`, which is a protected function. The canvas refreshes providers itself on map change and
  on show (`RefreshAllData`). Frame level types that exist: `PIN_FRAME_LEVEL_MAP_HIGHLIGHT`,
  `PIN_FRAME_LEVEL_AREA_POI`.
- Tooltips: `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, fn)`.
- Templates that exist: `BackdropTemplate`, `FauxScrollFrameTemplate` (+ `FauxScrollFrame_Update/GetOffset/
  SetOffset/OnVerticalScroll`), `UICheckButtonTemplate`, `InputBoxTemplate`, `UIPanelButtonTemplate`,
  `UIPanelCloseButton`.
- Spellcast events: `UNIT_SPELLCAST_SENT(unit, target, castGUID, spellID)`,
  `UNIT_SPELLCAST_START(unit, castGUID, spellID)`, `UNIT_SPELLCAST_CHANNEL_START(unit, castGUID, spellID)`.
- Hunters can only tame beasts whose level is not above their own.
- A hunter learns an ability rank **not** at the moment of taming: the tamed beast has to use the ability until a
  chat message says the hunter learned it. A tamed beast's spellbook is therefore not proof the hunter knows it.

## 2. Shared contract

### 2.1 Data (generated, read-only) — `Data/Beasts.lua`

```lua
ns.ABILITIES = { -- ordered list
  { key="bite", en="Bite", ru="Укус", icon="ability_druid_ferociousbite", trainer=false,
    families={ "Wolf", ... } --[[ or { "*" } ]], desc="...",
    ranks = { [1] = { lvl=1, tp=1 --[[ nil = cost unknown ]], trainer=false, spells={ ids }, desc="..." }, ... } },
}
ns.BEASTS[npcId] = { en=, ru=, f="Wolf", l={ min, max }, z="Elwynn Forest", s=1.5,
                     t={ "bite", 2, "dash", 1 },          -- pairs: ability key, rank
                     c={ x*10, y*10, r*10, ... } }         -- triples, percent of the zone map (0..1000)
ns.FAMILIES[key] = { en=, ru=, icon= }
ns.ZONES[zoneEn] = { map=uiMapID|nil, area=areaID|nil }
```
`trainer=true` abilities (Growl, Great Stamina, Natural Armor, the five Resistances) come from the pet trainer NPC,
have no teaching beasts, and are **reference only** everywhere: they never get a READY/SOON status, never appear
on the map, in "Nearby", in notifications or in "can be trained" lists.

### 2.2 Saved variables

```lua
BeastAtlasDB = {            -- account wide
  mapPins=true, areas=true, petOnly=true, showLearned=false, lookahead=6, names="both"|"local",
  notify=true, scale=1.0, minimap={ angle=215, hide=false }, window={ point, relPoint, x, y },
  observed={},               -- §7 Collect
}
BeastAtlasCharDB = {        -- per character
  known={ [abilityKey]=highestKnownRank },
  main=nil | { id="Name|FamilyKey", name="Name", family="Wolf", level=24, ranks={ [abilityKey]=rank } },
}
```
`BeastAtlasCharDB.manual` from v0.1 is dropped (set it to nil on load).

### 2.3 Statuses

```lua
ns.STATUS = { READY=1, SOON=2, LATER=3, LEARNED=4, OBSOLETE=5 }
ns.STATUS_COLOR[OBSOLETE] = { 0.45, 0.45, 0.45 }   -- others unchanged
```
Meaning, for the **main pet** (see `ns.Ctx`):
- `usable(r)`  = `ranks[r].lvl <= ctx.petLevel`
- `teacherNow(r)` = some beast teaching rank r has `l[1] <= ctx.playerLevel`
- `known` = `ns.KnownRank(key)`
- `target` = the highest rank `r > known` with `usable(r) and teacherNow(r)`; nil if none.

| rank r | status |
|---|---|
| `r <= known` | LEARNED |
| `r == target` | READY |
| `known < r < target` | OBSOLETE (a better rank is available right now) |
| `r > (target or known)` and `usable(r)` (so no teacher is tameable now) | SOON if some teacher has `l[1] <= playerLevel + look`, else LATER |
| `r > (target or known)` and not usable | SOON if `ranks[r].lvl <= petLevel + look`, else LATER |

### 2.4 Functions — owner in brackets

**[Core.lua]**
- `ns.Lower(s)` — exists in Locale.lua, unchanged.
- `ns.IsSecret(v)`, `ns.Print(msg)`, `ns.On(name, fn)`, `ns.Fire(name, ...)` — unchanged.
- `ns.Changed()` — the one invalidation entry point: drops the cached context, then `ns.Fire("CHANGED")`.
  Called by whoever changes known ranks, the main pet, a filter/option, or notices a player level change.
  Consumers debounce their own redraw.
- `ns.Ctx()` → cached table, rebuilt lazily after `ns.Changed()`:
  `{ playerLevel = UnitLevel("player") or 1, main = ns.cdb.main, petLevel = main and main.level or playerLevel,
     family = main and main.family or nil, look = ns.db.lookahead or 0, plan = {}, info = {} }`
- `ns.Ability(key)` → ability table with `.maxRank` and, per rank, `.beasts = { npcId, ... }` (sorted by level).
  `ns.AbilityByName(name)` (localized or English, case-insensitive). `ns.FamilyKey(localizedFamilyName)`.
  `ns.FamilyIcon(key)`. `ns.FamilyCanLearn(ab, familyKey)` (true when familyKey is nil).
- `ns.KnownRank(key)` → number (0 if none).
- `ns.Plan(key)` → `{ known = n, target = n | nil }`, memoised in `ctx.plan`.
- `ns.RankStatus(key, rank)` → status per §2.3. For `trainer=true` abilities: LEARNED if `rank <= known`, else LATER.
- `ns.BeastRankStatus(id, key, rank)` → `status, tameLevel|nil`:
  `st = RankStatus`; if st is LEARNED or OBSOLETE return it; if `beast.l[1] <= playerLevel` return st; otherwise
  `return math.max(st, (beast.l[1] <= playerLevel + look) and SOON or LATER), beast.l[1]`.
- `ns.StatusNote(st, key, rank, tameLevel)` → string, first match wins: LEARNED → `L.LEARNED`; OBSOLETE →
  `L.OBSOLETE`; tameLevel → `L.TAME_AT:format(tameLevel)`; READY → `L.NEW`; `ranks[rank].lvl > ctx.petLevel` →
  `L.SOON:format(lvl)`; rank has no beasts → `L.NO_SOURCE`; else `L.NO_TAMEABLE`.
- `ns.AbilityPassesFilter(ab)` → false if `ab.trainer`; false if `ns.db.petOnly and ctx.family and not
  FamilyCanLearn(ab, ctx.family)`; else true.
- `ns.BeastInfo(id)` → `best, list` (memoised in `ctx.info`; **callers must not modify `list`**). `list` =
  `{ { key=, rank=, status=, tame= }, ... }` for every rank the beast teaches whose ability passes the filter,
  skipping LEARNED entries unless `ns.db.showLearned`. `best` = the smallest status among the entries whose status
  is not OBSOLETE; OBSOLETE if every entry is OBSOLETE. Returns nil when `list` is empty.
- `ns.BeastUseful(id)` → `best, list` only when `best` is READY or SOON, or LEARNED with `showLearned`; else nil.
- Zones: `ns.ZoneMap(zoneEn)` → uiMapID|nil (the hard-coded id is used only if `C_Map.GetMapInfo(id)` returns a
  table; otherwise fall back to matching the localized area name, as v0.1 does for unknown zones; cached).
  `ns.ZoneName(zoneEn)` → localized name (cached). `ns.ZoneByMap(mapID)` → zoneEn|nil.
  `ns.BeastsOnMap(mapID)` → `{ npcId, ... }|nil`. `ns.BeastsByMap()` → the whole `{ [mapID] = { npcId, ... } }`.
  `ns.PlayerZoneMap()` → uiMapID of the map the player is on, walking up `parentMapID` while the map type is
  `Enum.UIMapType.Micro`; nil if unknown/secret.
- Distances: `ns.PlayerWorldPos()` → `continentID, x, y` | nil.
  `ns.BeastDistance(id, cont, px, py)` → `yards, clusterIndex` where yards is the distance to the **edge** of the
  nearest habitat on that continent (`max(0, centerDistance - habitatRadiusInYards)`), nil if none.
  (`ns.BeastWorldSpots(id)` keeps per-cluster `{ cont, wx, wy, clusterIndex, radiusYd }`; radiusYd is derived by
  converting the point `(x + r, y)` to world coordinates as well.)
- `ns.TrainingPoints()` → `free, total` | nil (pcall-guarded `C_PetInfo.GetPetTrainingPoints`).
- `ns.SetOption(key, value)` — for top-level `BeastAtlasDB` keys: sets it, `ns.Changed()`, `ns.Fire("OPTION", key)`.
- `ns.ResetKnown()` — wipes `ns.cdb.known`, prints `L.RESET_DONE`, `ns.Changed()`.
- `ns.RebuildIndexes()` — drops the ability/beast/map/world-position indexes so they are rebuilt lazily, then
  `ns.Changed()`. (Used by Collect after it adds a beast or a rank at runtime.)
- `ns.OpenMapFor(id)` — sets `ns.highlight = id`, opens the world map on the beast's zone
  (`OpenWorldMap(mapID)` if that global exists, else the v0.1 way), `ns.Fire("MAP_REFRESH")`.
  `ns.ClearHighlight()` — `ns.highlight = nil` and `ns.Fire("MAP_REFRESH")` if it was set.
  `ns.SetWaypoint(id, clusterIndex)` — unchanged.
- Bus events fired by Core: `"LOGIN"` (PLAYER_LOGIN), `"CHANGED"`, `"OPTION"(key)`, `"MAP_REFRESH"`.
  v0.1's `STATE_CHANGED`, `KNOWN_CHANGED`, `FILTER_CHANGED` are **removed**; everyone listens to `"CHANGED"`.
- On `ADDON_LOADED`: init saved variables (§2.2 defaults), then `if ns.MergeObserved then ns.MergeObserved() end`.
- Slash `/ba`, `/beastatlas`, `/атлас`: no arg → `ns.ToggleWindow()`; `map` → toggle `mapPins` via `ns.SetOption`
  and print `L.PINS_ON/OFF`; `main` → `ns.SetMainPet()`; `trainer` → `ns.DumpTrainer()`; `reset` →
  `ns.ResetKnown()`; `help`/`?` → `L.HELP`. For a non-hunter every form just prints `L.NOT_HUNTER`.

**[Tracker.lua]**
- `ns.petRanks` — `{ [abilityKey] = rank }` of the **currently summoned** pet's spellbook. `ns.ScanPetSpellbook()`
  refreshes it (exported so Collect can force a read).
- `ns.PetId()` → `"Name|FamilyKey"` of the summoned pet, or nil (no pet, secret values, or unknown family).
- `ns.ActivePetIsMain()` → true when a pet is out and `ns.PetId() == ns.cdb.main.id`.
- `ns.SetMainPet()` — makes the summoned pet the main pet (`ns.cdb.main` per §2.2, `ranks` = copy of
  `ns.petRanks`), prints `L.MAIN_SET:format(name)`, `ns.Changed()`. With no pet out: prints `L.NO_ACTIVE_PET`.
- `ns.SetKnown(key, rank)` — manual toggle as in v0.1 (without the `manual` table), then `ns.Changed()`.
- `ns.PetTrainable()` → list of `{ ab = abilityTable, rank = n, tp = cost|nil }`: for the **main** pet, each
  non-trainer ability its family can learn where the hunter knows a rank that the pet is old enough for
  (`ranks[r].lvl <= main.level`, highest such `r <= known`) and that is above `main.ranks[key]`. Empty list or nil
  when there is no main pet.
- `ns.DumpTrainer()` — diagnostics for `/ba trainer` (see §5).
- Bus events fired by Tracker: `"MAIN_LEVEL"(oldLevel, newLevel)` when the main pet's stored level rises;
  `"OTHER_PET"(activeName, mainName)` once per session per pet id when a pet that is not the main one is out;
  `"TP"` on `UNIT_PET_TRAINING_POINTS`.

**[Collect.lua]** `ns.MergeObserved()` (§7). **[UI.lua]** `ns.ToggleWindow()`, `ns.ShowBeast(id)`,
`ns.ShowStack(ids)` (§8), `ns.RefreshWindow()`, `ns.ShowTooltipModel(id)`, `ns.HideTooltipModel()`.

## 3. Locale keys (Role A writes them into Locale.lua; everyone else only reads)

Keep every v0.1 key **except** these, which are deleted: `LATER`, `MARK_LEARNED`, `MARK_UNLEARNED`, `TT_UPGRADE`,
`NEARBY_OTHER_CONT`. Change/add the following (en / ru):

| key | en | ru |
|---|---|---|
| PET_LINE | `Main pet: %s (%s, level %d)` | `Основной питомец: %s (%s, %d ур.)` |
| NO_PET | `No main pet yet. Using your level: %d` | `Основной питомец не выбран. Берём ваш уровень: %d` |
| TP_LINE | `Training points: %d free of %d` | `Очки обучения: свободно %d из %d` |
| TP_UNKNOWN | `? TP` | `? ОО` |
| PETCAN | `Can be taught at Beast Training: %s` | `Можно обучить в «Дрессировке»: %s` |
| OBSOLETE | `a higher rank is available` | `есть ранг выше` |
| NO_TAMEABLE | `no teacher you can tame yet` | `учителя пока не приручить` |
| HERE | `here` | `здесь` |
| MAKE_MAIN | `Make main: %s` | `Сделать основным: %s` |
| MAIN_SET | `main pet is now %s.` | `основной питомец теперь %s.` |
| NO_ACTIVE_PET | `summon a pet first.` | `сначала призовите питомца.` |
| OTHER_PET | `%s is out; the atlas still plans for %s. To switch: /ba main` | `вызван %s; атлас по-прежнему считает для %s. Сменить: /ba main` |
| MARKED | `marked as learned: %s (%s). Wrong? Right-click the rank in the Abilities tab.` | `отмечено изученным: %s (%s). Ошибка? ПКМ по рангу во вкладке «Способности».` |
| SRC_CHAT | `chat message` | `сообщение в чате` |
| SRC_TRAINER | `Beast Training window` | `окно «Дрессировки»` |
| SRC_SPELLBOOK | `spellbook` | `книга заклинаний` |
| TRAINER_DUMP | `Beast Training dump (trainer type %s, npc unit %s, rows %d):` | `Дамп «Дрессировки» (тип тренера %s, юнит npc %s, строк %d):` |
| TRAINER_CLOSED | `open the Beast Training window first.` | `сначала откройте окно «Дрессировки».` |
| GROUP_HERE | `In this zone: %s` | `В этой зоне: %s` |
| GROUP_ELSEWHERE | `Elsewhere on the continent` | `В других зонах континента` |
| GROUP_STACK | `Selected on the map: %d (click to clear)` | `Выбрано на карте: %d (нажмите, чтобы сбросить)` |
| GROUP_TRAINER | `From the pet trainer (reference only)` | `У учителя питомцев (только справка)` |
| TAB_SETTINGS | `Settings` | `Настройки` |
| OPT_MAP_PINS | `Show beasts on the world map` | `Показывать зверей на карте мира` |
| OPT_AREAS | `Show habitat areas on the map` | `Показывать ареалы на карте` |
| OPT_NOTIFY | `Chat tips (pet level-up, entering a zone)` | `Подсказки в чат (уровень питомца, вход в зону)` |
| OPT_BOTH_NAMES | `Names in both languages` | `Названия на двух языках` |
| OPT_MINIMAP | `Minimap button` | `Кнопка у миникарты` |
| OPT_SCALE | `Window scale: %d%%` | `Масштаб окна: %d%%` |
| OPT_RESET_KNOWN | `Forget learned ranks (Shift+click)` | `Забыть изученные ранги (Shift+клик)` |
| SETTINGS_HELP | `Commands:\n/ba - window\n/ba map - beasts on the map on/off\n/ba main - make the summoned pet the main one\n/ba trainer - Beast Training diagnostics\n/ba reset - forget learned ranks` | `Команды:\n/ba - окно\n/ba map - звери на карте вкл/выкл\n/ba main - сделать вызванного питомца основным\n/ba trainer - диагностика «Дрессировки»\n/ba reset - забыть изученные ранги` |
| HELP | `/ba - window, /ba map - map beasts, /ba main - set main pet, /ba trainer - diagnostics, /ba reset - forget learned ranks` | `/ba - окно, /ba map - звери на карте, /ba main - основной питомец, /ba trainer - диагностика, /ba reset - забыть изученные ранги` |
| NOT_HUNTER | `this addon only works for hunters.` | `аддон работает только для охотников.` |
| ZONE_READY | `Ready to learn now: %d` | `Можно учить сейчас: %d` |
| ZONE_SOON | `Soon: %d` | `Скоро: %d` |
| ZONE_PIN_HINT | `Click: open the zone map` | `ЛКМ: открыть карту зоны` |
| PIN_HINT_STACK | `Click: list these beasts  ·  Shift+click: waypoint` | `ЛКМ: список этих зверей  ·  Shift+ЛКМ: метка` |
| MAP_TOGGLE_HINT | unchanged | unchanged |
| OBSERVED | `recorded your tame of %s: %s.` | `записано приручение, %s: %s.` |
| OBSERVED_TAG | `includes your own observations` | `есть ваши наблюдения` |
| NOTIFY_LEVEL | `%s reached level %d:` | `%s достиг %d ур.:` |
| NOTIFY_TRAIN | `  %s - you already know it, teach it at Beast Training` | `  %s - вы уже знаете, обучите в «Дрессировке»` |
| NOTIFY_LEARN | `  %s - nearest teacher: %s (%s)` | `  %s - ближайший учитель: %s (%s)` |
| NOTIFY_NO_TEACHER | `  %s - no teacher you can tame yet` | `  %s - пока нет учителя, которого можно приручить` |
| NOTIFY_ZONE | `%d beasts in this zone teach ranks you need now: %s. Open: /ba` | `в этой зоне зверей с нужными сейчас рангами: %d (%s). Открыть: /ba` |
| AND_MORE | `and more` | `и другие` |

## 4. Role A — `Core.lua`, `Locale.lua`, `BeastAtlas.toc`

- Implement every `[Core.lua]` item of §2.4 and the saved-variable defaults of §2.2.
- `ns.Ctx()` / `ns.Plan` / statuses per §2.3. `ns.BeastInfo` memoised per context.
- Zone handling per §2.4 (validation of hard-coded map ids, cached names, `ZoneByMap`, `BeastsByMap`,
  `PlayerZoneMap`). Distance to habitat edge.
- Replace the literal tab characters in the two trim patterns with `\t`.
- Locale.lua: apply §3 exactly (both tables). Keep `ns.Lower`, `ns.Names`, `ns.DisplayName` as they are.
- TOC: version `0.2.0`; file list order: `Locale.lua`, `Data\Beasts.lua`, `Core.lua`, `Tracker.lua`,
  `Collect.lua`, `Notify.lua`, `MapPins.lua`, `MapPins.xml`, `UI.lua`, `Tooltip.lua`. Do not add an
  `AllowLoadGameType` line (it was removed on purpose).
- Do not keep compatibility shims for the removed bus events.

## 5. Role B — `Tracker.lua`

Sources that may raise `ns.cdb.known[key]` automatically:
1. **Chat** (`CHAT_MSG_SYSTEM`): patterns built from the client globals `ERR_LEARN_ABILITY_S` and
   `ERR_LEARN_SPELL_S` only (drop the two `ERR_PET_*` ones). If the message matches the pattern built from
   `ERR_SPELL_UNLEARNED_S` (when that global exists), ignore it. Fallback when no pattern matched: strip colour
   codes/links as v0.1 does, then require the whole message to match
   `^(.*) %([^()]-([0-9]+)%)[%.!]?$`; the ability is the one whose `en` or `ru` name is a suffix of the first
   capture (longest name wins); the number is the rank. Nothing else in the message is interpreted.
2. **Spell ids**: `C_SpellBook.IsSpellKnown(id)` (fall back to the globals `IsPlayerSpell`, then `IsSpellKnown`,
   if the C_ function is missing) over `ranks[r].spells` of non-trainer abilities, as v0.1 does.
3. **Beast Training window**: on `TRAINER_SHOW` and `TRAINER_UPDATE`, only when
   `C_Trainer.GetTrainerType() == Enum.TrainerType.Pet` **and** `not UnitExists("npc")` (i.e. the window was
   opened by the hunter's own Beast Training spell, not by a trainer NPC): for each service, if `serviceType` is
   `"available"` or `"used"`, resolve `(serviceName, serviceSubText)` to an ability and rank (a missing/empty rank
   text means rank 1) and mark it. `"unavailable"` rows are ignored (not enough evidence). Remove `ScanCraft` and
   the `CRAFT_*` events.
4. Manual `ns.SetKnown`.

Rules:
- The summoned pet's spellbook never marks a rank as known (fact in §1). It only fills `ns.petRanks`.
- Every automatic mark that raises a rank is reported in chat: collect the raised `"<ability name> <rank>"`
  (ability name via `ns.Names(ab)` first value) per source during one scan and print **one** line
  `ns.Print(L.MARKED:format(table.concat(list, ", "), L.SRC_CHAT | L.SRC_TRAINER | L.SRC_SPELLBOOK))`, then
  `ns.Changed()`.
- `ns.DumpTrainer()`: if `GetNumTrainerServices` is missing or returns 0/nil → `ns.Print(L.TRAINER_CLOSED)`.
  Otherwise print `L.TRAINER_DUMP:format(tostring(trainerType), tostring(UnitExists("npc")), n)` and then, for up
  to 40 rows, a raw line `i: serviceName | serviceSubText | serviceType` via `print` (these raw rows are
  diagnostics, not localized). This exists so the user can report what the window really contains.
- Main pet: implement `ns.PetId`, `ns.ActivePetIsMain`, `ns.SetMainPet` per §2.4 and a sync step run after each
  rescan: no pet out → nothing; `ns.cdb.main == nil` → `ns.SetMainPet()`; summoned pet is the main one → update
  `main.level` and `main.ranks` (copy of `ns.petRanks`), fire `"MAIN_LEVEL"(old, new)` if the level rose, and
  `ns.Changed()` if level or ranks changed; another pet → fire `"OTHER_PET"(activeName, main.name)` once per
  session per pet id. The main pet is never switched automatically.
- Events (hunters only, registered on the `"LOGIN"` bus event): `UNIT_PET`, `UNIT_LEVEL` (only for `player`/
  `pet`), `PLAYER_LEVEL_UP`, `SPELLS_CHANGED`, `CHAT_MSG_SYSTEM`, `TRAINER_SHOW`, `TRAINER_UPDATE`,
  `UNIT_PET_TRAINING_POINTS`. Drop `PET_BAR_UPDATE`. Keep the v0.1 throttle (one pending rescan via
  `C_Timer.After`). A rescan = `ns.ScanPetSpellbook()` → main-pet sync → spell-id scan. `PLAYER_LEVEL_UP`
  additionally schedules `ns.Changed()` one second later (the new level is not readable immediately).
- `ns.PetTrainable()` per §2.4.

## 6. Role C — `MapPins.lua`, `MapPins.xml`

- Both existing pin mixins and the new one override `CheckMouseButtonPassthrough` with an empty function (comment:
  the default calls the protected `SetPassThroughButtons`; our pins don't need right-click passthrough).
- `Provider:RefreshAllData()`: always `RemoveAllData()` first. If `InCombatLockdown()` → remember that a refresh is
  owed and return without acquiring pins; on `PLAYER_REGEN_ENABLED` do the owed refresh (through the existing
  debounced queue).
- Redraw (debounced 0.1 s, only while `WorldMapFrame:IsShown()`) on the bus events `"CHANGED"` and
  `"MAP_REFRESH"`. Remove listeners for the deleted v0.1 events.
- Zone maps: as v0.1 (area ellipses + stacked icon pins), using `ns.BeastUseful`. Icon pin click: plain left
  click on a pin with one beast → `ns.ShowBeast(id)`; with several → `ns.ShowStack(ids)`; Shift+left click →
  `ns.SetWaypoint(leadId, cluster)`. Tooltip hint line: `L.PIN_HINT` for one beast, `L.PIN_HINT_STACK` for several.
- **Continent maps** (`mapType == Enum.UIMapType.Continent`): one summary pin per zone that has beasts
  (`ns.BeastsByMap()`): `ready` = number of its beasts with `ns.BeastUseful(id) == READY`, `soon` = number with
  SOON. Skip the zone if both are 0. Position = centre of `C_Map.GetMapRectOnMap(zoneMapID, continentMapID)`
  (pcall; skip if it returns nothing, a zero-size rect, or a centre outside 0..1). New template
  `BeastAtlasZonePinTemplate` (a mouse-enabled `Frame`, 26x26, no XML scripts): round status-coloured ring like
  the icon pin, dark round background, centred count text (`ready` if > 0 else `soon`), ring colour READY if
  `ready > 0` else SOON. Tooltip: localized zone name, `L.ZONE_READY:format(ready)` if > 0,
  `L.ZONE_SOON:format(soon)` if > 0, then up to 6 distinct READY `"<ability> <rank>"` lines, then
  `L.ZONE_PIN_HINT`. Left click → `WorldMapFrame:SetMapID(zoneMapID)`.
- Highlight: `WorldMapFrame:HookScript("OnHide", ...)` → `ns.ClearHighlight()`.
- The map toggle button keeps its behaviour but changes options through `ns.SetOption("mapPins"/"areas", v)` and
  refreshes its look on the `"OPTION"` bus event.
- All pins: no `OnUpdate`, nothing computed per frame.

## 7. Role E — new files `Collect.lua` and `Notify.lua`

### Collect.lua — learn from the player's own tames
Purpose: the shipped data is young; when the player tames a beast, record what it really knows.
- Hunters only; register on the `"LOGIN"` bus event: `UNIT_SPELLCAST_SENT`, `UNIT_SPELLCAST_START`,
  `UNIT_SPELLCAST_CHANNEL_START`, `UNIT_PET`.
- Tame Beast is spell id 1515 (as in Classic). A cast counts as a tame when its
  `spellID == 1515`, or when `C_Spell.GetSpellName(spellID)` and `C_Spell.GetSpellName(1515)` are both non-nil and
  equal. Only casts by `"player"`.
- On such a cast, snapshot the target (skip if anything needed is secret/nil): npc id (GUID type `Creature`, 6th
  dash-separated field), `UnitName("target")`, `UnitLevel("target")`,
  `ns.FamilyKey(UnitCreatureFamily("target"))` (skip if nil), `ns.PlayerZoneMap()` and the player's position on
  that map (`C_Map.GetPlayerMapPosition`), `UnitGUID("pet")` as `oldPet`, `GetTime()`.
- On `UNIT_PET` for `"player"` while a snapshot younger than 60 s is pending: 1.5 s later check that a pet exists,
  its GUID differs from `oldPet`, and its family key equals the snapshot's. If so call `ns.ScanPetSpellbook()` and
  read `ns.petRanks`, keeping only non-trainer abilities. If nothing is readable yet, retry up to 3 times, 1.5 s
  apart; give up silently after that (do not record an empty observation).
- Record: `BeastAtlasDB.observed[npcId] = { n=name, loc=GetLocale(), f=familyKey, l=level, m=uiMapID,
  x=0..1000, y=0..1000, t={ "key", rank, ... }, d=date("%Y-%m-%d") }` (merge with an existing record: union of
  ranks per ability keeping the highest rank).
- `ns.MergeObserved()` (called by Core on load, and by Collect after a new record followed by
  `ns.RebuildIndexes()`): for each observation —
  beast already in `ns.BEASTS`: append each `(key, rank)` pair that is not already in its `t` and set `b.o = true`
  if anything was appended (never remove shipped data);
  beast not in `ns.BEASTS`: only if `#t > 0` and `ns.ZoneByMap(obs.m)` gives a zone: add
  `{ en=obs.n, ru=obs.n, f=obs.f, l={ obs.l, obs.l }, z=zone, t=copy, c={ obs.x, obs.y, 30 }, o=true }`.
  Unknown ability keys in an observation are ignored. Must be idempotent (safe to call repeatedly).
- When a tame recorded something new (a new beast, or a rank the entry didn't have), print
  `ns.Print(L.OBSERVED:format(name, "<ability> <rank>, ..."))`.

### Notify.lua — chat tips (all gated by `ns.db.notify`, hunters only)
- `ns.On("MAIN_LEVEL", function(old, new))`: for each non-trainer ability the main pet's family can learn and each
  rank `r` with `old < ranks[r].lvl <= new`: if `ns.KnownRank(key) >= r` → a `L.NOTIFY_TRAIN` line; else among the
  rank's beasts with `l[1] <= ctx.playerLevel` pick the nearest (`ns.BeastDistance`; beasts without a distance
  rank last) → `L.NOTIFY_LEARN:format("<ability> <rank>", beastName, where)` where `where` is the localized zone
  name plus `", " .. L.YARDS:format(d)` when a distance is known; if no such beast → `L.NOTIFY_NO_TEACHER`.
  If there is at least one line, print `L.NOTIFY_LEVEL:format(main.name, new)` via `ns.Print` first, then the
  lines via `print`. Names via `ns.Names(...)` first value.
- Zone tip: on `ZONE_CHANGED_NEW_AREA` (and once, 5 s after `"LOGIN"`), 2 s later: `mapID = ns.PlayerZoneMap()`;
  if it is non-nil and not yet announced this session: `n` = number of beasts in `ns.BeastsOnMap(mapID)` whose
  `ns.BeastUseful(id)` is READY; if `n > 0`, collect the distinct READY `"<ability> <rank>"` strings (first 4,
  then `L.AND_MORE` if there are more) and `ns.Print(L.NOTIFY_ZONE:format(n, list))` (mind the argument order
  differs between en and ru in §3 — use the format string's order: the ru string takes `%d` then `%s` as well;
  both languages take the count first and the list second). Mark the map as announced.
- `ns.On("OTHER_PET", function(activeName, mainName))` → `ns.Print(L.OTHER_PET:format(activeName, mainName))`.

## 8. Role D — `UI.lua`, `Tooltip.lua`

Window (keep the v0.1 look: backdrop, list widget, detail panel with the 3D model, minimap button):
- `frame:SetScale(ns.db.scale)`; update on the `"OPTION"` bus event for key `scale`.
- Header. Line 1: `L.PET_LINE:format(main.name, familyName, main.level)` when `ns.Ctx().main` exists, else
  `L.NO_PET:format(playerLevel)`. When a pet is out and `not ns.ActivePetIsMain()`: a small button
  `L.MAKE_MAIN:format(activePetName)` → `ns.SetMainPet()` (hidden otherwise). Line 2: when
  `ns.ActivePetIsMain()` and `ns.TrainingPoints()` returns values → `L.TP_LINE:format(free, total)`, followed by
  `L.PETCAN:format(...)` built from `ns.PetTrainable()` as `"<ability> <rank> (<cost>)"` where cost is
  `L.TP:format(tp)` or `L.TP_UNKNOWN`. Refresh the header on `"CHANGED"` and `"TP"`.
- Three tabs: `L.TAB_NEARBY`, `L.TAB_ABILITIES`, `L.TAB_SETTINGS`. Filters (`petOnly`, `showLearned`, look-ahead
  +/-) stay in the header and go through `ns.SetOption`.
- **Nearby** tab. Rows are built from `ns.BeastUseful` (or `ns.BeastInfo` while a search text is present):
  1. group header `L.GROUP_HERE:format(zoneName)` followed by the beasts whose `ns.ZoneMap(b.z)` equals
     `ns.PlayerZoneMap()`, sorted by status, then distance;
  2. group header `L.GROUP_ELSEWHERE` followed by the other beasts that have a distance (same continent), sorted
     by distance, at most 60 rows (250 while searching; while searching, beasts without a distance are appended
     after them).
  A group with no beasts is omitted together with its header. Distance text: `L.HERE` when the distance is 0,
  else as v0.1. If `ns.ShowStack(ids)` was called, the tab shows only those beasts under a clickable header
  `L.GROUP_STACK:format(n)`; clicking that header, switching tabs or typing in the search box clears the stack
  filter.
  Rebuild triggers: window shown, `"CHANGED"` (debounced 0.15 s), search text (debounced 0.2 s), and the existing
  5-second ticker **only if** the player moved more than 40 yards since the last build (`ns.PlayerWorldPos`).
- **Abilities** tab. Left list: abilities passing `ns.AbilityPassesFilter` (data order), then — if any trainer
  abilities exist — a non-clickable header row `L.GROUP_TRAINER` and the `trainer=true` abilities (grey ring, no
  arrow, reference only; they stay selectable to view their ranks). Row status for a normal ability from
  `ns.Plan(key)`: `target` → READY with `"→ <target>"`; else the lowest rank whose `ns.RankStatus` is SOON → SOON
  with `"→ <rank>"`; else LEARNED when `known == maxRank`; else LATER.
  Right list (ranks of the selected ability): one header row per rank: `L.RANK`, `L.PET_LEVEL`, cost
  (`L.TP:format(tp)` or `L.TP_UNKNOWN`), then `ns.StatusNote(status, key, rank)` in the status colour; second line
  = the rank description. Under the header, the teaching beasts (nearest first), except that LEARNED (unless
  `showLearned`) and OBSOLETE ranks are collapsed to the header only; left-clicking such a header toggles its
  expansion. Right-clicking a rank header of a non-trainer ability calls `ns.SetKnown(key, rank)`.
- Row layout fix: the right-hand label of a row gets a fixed width of 110 with word wrap off and right
  justification, and the main text's right anchor is moved so the two can no longer overlap.
- Detail panel: as v0.1, statuses via `ns.BeastRankStatus`/`ns.StatusNote`, cost via `L.TP`/`L.TP_UNKNOWN`; add
  the line `L.OBSERVED_TAG` when `beast.o` is true.
- **Settings** tab (occupies the list area; one control per row): checkboxes `L.OPT_MAP_PINS` (`mapPins`),
  `L.OPT_AREAS` (`areas`), `L.OPT_NOTIFY` (`notify`), `L.OPT_BOTH_NAMES` (`names` = `"both"` when checked, else
  `"local"`), `L.OPT_MINIMAP` (`ns.db.minimap.hide = not checked`, then show/hide the minimap button); a
  `-`/`+` pair with the label `L.OPT_SCALE:format(percent)` changing `scale` in steps of 0.05 within 0.7..1.3; a
  button `L.OPT_RESET_KNOWN` that calls `ns.ResetKnown()` only when Shift is held; a text block
  `L.SETTINGS_HELP`. Top-level options go through `ns.SetOption`. Checkboxes re-read their state when the tab is
  shown and on the `"OPTION"` bus event.
- `ns.ShowStack(ids)`: opens the window on the Nearby tab with the stack filter set and selects the first beast.
- Tooltip model: also hide it from a `GameTooltip:HookScript("OnHide", ...)` so it cannot stay attached to an
  unrelated tooltip.
- Minimap button: right click toggles `mapPins` through `ns.SetOption`; visibility follows
  `ns.db.minimap.hide`.
- Remove listeners for the deleted v0.1 bus events; listen to `"CHANGED"`.

Tooltip.lua: same behaviour as v0.1 (lines under a wild beast's unit tooltip), using
`ns.BeastRankStatus`/`ns.StatusNote`, skipping trainer abilities, and not adding anything for non-hunters.

## 9. Report (structured output of every executor)

`filesChanged`, `summary` (what you implemented, 5-10 lines), `deviations` (every place you did not follow the
spec literally, and why), `unverified` (every assumption about the game client you could not confirm in the UI
source), `problemsInOtherFiles`, `syntaxCheck` (the exact output of the luacheck command).
