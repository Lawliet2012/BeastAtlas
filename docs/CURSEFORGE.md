# CurseForge project page

What to enter when creating the project at https://authors.curseforge.com (Create a project -> World of Warcraft -> Addons).

| Field | Value |
| --- | --- |
| Name | BeastAtlas |
| Summary | Hunter's atlas for WoW Forever: which beasts teach which pet ability ranks, where they live, and how to pick a pet. |
| Category | Class -> Hunter (main); Map & Minimap, Companions (additional) |
| Logo | `docs/icon.png` |
| License | MIT License |
| Game version | WoW Forever 1.60.1 |

The first file (`dist/BeastAtlas-<version>.zip`) is uploaded with `python -I tools/release.py upload <projectId>`
once the project exists; the project ID is shown on the project's page ("Project ID").

## Description (paste into the description field)

**BeastAtlas** is a hunter's helper for **WoW Forever**. It knows which wild beasts teach which ranks of pet
abilities, shows where they live and tells you which ones are worth taming right now. English and Russian.

### What it does

- **Atlas window** (`/ba` or the minimap button). *Nearby*: beasts around you that teach ranks you can use now,
  nearest first. *Abilities*: every pet ability with all its ranks, the pet level and training points each rank
  needs, and every beast that teaches it. 3D model of the selected beast, search, waypoints.
- **World map.** Beasts are round family icons with a coloured ring: green means "tame it now", yellow "soon".
  Hover an icon to see where that beast lives. Pet trainers are marked as well; continent maps show how many
  useful beasts each zone has.
- **Training helper.** A small panel that leads you through learning one rank: tame the teacher, fight until the
  chat says you learned it, take your main pet back, teach it at Beast Training. It knows about training points
  and tells you when you are short.
- **Pet catalogue.** All pet families by role (offense, general, defense) with their diet, attack speeds and
  abilities, and every beast a hunter can tame - more than 600, each with its 3D model, with rare and elite ones
  marked. Plus a short guide **"How to choose a pet"**: the fastest beasts and the ones worth taming at your level.
- **Smart picks.** Beasts that teach several ranks you need at once are marked, and one click shows all teachers
  of a chosen rank on the map.
- **Chat tips** when your pet levels up or you enter a zone with beasts that teach something new.

The addon tracks what you have learned by itself (chat messages, the Beast Training window) and plans for your
main pet; nothing needs to be configured.

### Data and credits

- [Petopia](https://www.wow-petopia.com/forever/) - pet abilities, ranks, the beasts that teach them, attack
  speeds, family roles and diets. Petopia is the reference for hunter pets; please visit and support it.
- [Wowhead](https://www.wowhead.com/forever) - Russian names, coordinates, pet trainers.

The game is new and so is the data: some ranks have no known teacher yet and some training point costs are
unknown. Corrections are welcome in the issue tracker.

### Commands

`/ba` - window, `/ba map` - beasts on the map on/off, `/ba main` - make the summoned pet the main one,
`/ba reset` - forget learned ranks.

---

## Описание на русском (можно добавить ниже английского)

**BeastAtlas («Атлас зверей»)** - помощник охотника для **WoW Forever**. Знает, какие дикие звери учат каким
рангам способностей питомца, показывает, где они обитают, и подсказывает, кого стоит приручить прямо сейчас.

- **Окно атласа** (`/ba` или кнопка у миникарты): звери рядом с нужными сейчас рангами, все способности с
  рангами и учителями, 3D-модели, поиск, метки на карте.
- **Карта мира**: значки семейств с цветным кольцом, ареал зверя при наведении, дрессировщики питомцев.
- **Помощник обучения**: панель, которая по шагам ведёт от приручения учителя до обучения своего питомца.
- **Семейства** и гайд **«Как выбрать питомца»**: роли, рацион, скорость атаки, кого приручить на вашем уровне.
- **Подсказки в чат** при повышении уровня питомца и входе в зону с полезными зверями.

Данные: [Petopia](https://www.wow-petopia.com/forever/) и [Wowhead](https://www.wowhead.com/forever).
