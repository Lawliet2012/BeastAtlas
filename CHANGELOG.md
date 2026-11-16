# Changelog

## 0.7.0

- **Pet catalogue.** The Families tab now lists every beast a hunter can tame, not only the ones that teach
  ability ranks: more than 600 pets with their level, place, attack speed and 3D model. Rare, elite and spawned
  beasts are marked, and a checkbox leaves only them. The search box on this tab looks through all pets by
  name, family and place.
- **Several ranks from one tame.** A beast that teaches two or more ranks you need right now is marked
  "2 at once" in the Nearby list and comes first in its zone.
- **Teachers of one rank on the map.** The "On map" button next to a rank in the Abilities tab leaves only the
  beasts that teach that rank on the map, with their habitats; continent maps show which zones they live in.
  A bar on the map brings all beasts back.

## 0.6.2

- Added the full list of hunter pets that Petopia knows for WoW Forever: 691 creatures with their levels,
  location, attack speed, whether they can be tamed, and Petopia's rare / elite / boss marks
  (`Data/Pets.lua`). The atlas window itself still lists the beasts that teach ability ranks; the wider list
  is the data the companion addon BeastScout works with.

## 0.6.1

- Fixed: a rank learned from a tamed beast was not marked when the game's chat message named the ability
  without its rank ("[Claw]" instead of "[Claw (Rank 3)]"). The rank is now taken from the spell link in the
  message or from the pet that taught it.

## 0.6.0

- **Stable masters.** To tame a beast that teaches a new rank you have to leave your own pet in a stable first,
  and take it back afterwards. The atlas now knows 50 stable masters (data from Wowhead) and shows the ones your
  faction can use: pins on the zone map (violet ring), the nearest one in the training helper on the steps where
  you need it, the one closest to a beast's habitat in the beast's details, and `/ba stable` for a waypoint.
  Distances are straight lines.
- A pet trainer and a stable master standing together no longer cover each other on the map: zoomed out the
  stable master's pin moves aside, zoomed in both are exactly where the NPCs stand.
- Habitat circles on the map: a thinner rim and a larger minimum size.

## 0.5.1

First public version. A hunter's helper for WoW Forever (interface 16001), English and Russian.

- **Atlas window** (`/ba`): beasts nearby that teach the pet ability ranks you need now, every ability with its
  ranks and teachers, 3D models, search, waypoints.
- **World map**: beasts as round family icons with a status ring; a beast's habitat appears as circles while the
  mouse is over its icon. Pet trainers are marked too. Continent maps show a summary per zone.
- **Training helper**: a small panel that walks you through learning one rank: tame the teacher, fight until the
  chat confirms it, get your main pet back, teach it at Beast Training.
- **Families tab**: all families by role, a card per family (role, diet, attack speed, abilities, beasts) and a
  short guide "How to choose a pet" with the fastest beasts and the ones worth taming right now.
- **Chat tips** when your main pet levels up or you enter a zone with useful beasts.

Data: Petopia Forever (abilities, ranks, teachers, attack speeds, family roles and diets) and Wowhead
(Russian names, coordinates, pet trainers).

Known limits: 33 ranks have no known teacher yet, 44 have no known training point cost; beasts inside dungeons
are listed but not shown on the map.
