# Fire Emblem GBA Editor (fe_editor)

An Android ROM editing tool for the three GBA *Fire Emblem* games.
Written in Flutter with **zero third-party plugin dependencies**, in the spirit of
FEBuilderGBA for Windows.

English | [简体中文](README.md)

Supports the original Japanese / US releases of **The Binding Blade (FE6)**,
**The Blazing Blade (FE7)** and **The Sacred Stones (FE8)**, and can open many
community hacks (20–32 MB expanded ROMs) as well.

## Features

### Units, classes and items

- **Units**: level, stats, constitution, weapon ranks, growth rates, affinity and
  support partners; portrait and description text; search by name.
- **Classes**: base stats, stat caps, growth rates, promotion bonuses, movement,
  constitution and class ability flags; description text; **terrain tables**
  (movement cost and terrain avoid / defense / resistance).
- **Items**: might, hit, weight, crit, range, price, uses and weapon rank;
  item ability flags; 16×16 icon preview; description and use description;
  **stat bonus table** (9 signed entries, negatives allowed);
  **exclusive locks** (a weapon usable only by units carrying the matching flag).

### Chapters

- Map rendering with traps and the actual unit sprites; tap a tile to read its tile
  value and the units standing on it.
- **Tile editing**: pick a tile and paint it on the map, save back, undoable.
- **Chipset (TSA) graphics editing**, and **map size editing**
  (which names the other chapters sharing that map first).
- **Initial units**: position, level, class and items are all editable —
  tap a number to type it, or pick a class/item from a searchable list.
  Includes arena/enemy slots (FE8) and the red/blue unit lists (FE6).

### Story and events

- **Event inspection**: which triggers a chapter has (turn / character / location /
  misc) and which units each one spawns.
- **Append events**: add a trigger at the end of a list that spawns units at given
  coordinates, optionally showing an existing line of dialogue first.
  The tool **only appends**; it never rewrites the game's original scripts.
- **Edit spawned units**: level, class, position, items and allegiance.
- **Chest rewards and shop stock**: edit them right in the event table
  (in-place byte writes, undoable).
- **Chapter dialogue**: list every text the chapter references and edit them;
  or use **scene editing**, which groups dialogue into "one scene → one line at a time".
  Whole-chapter import / export is supported.
- **Chapter preview**: a dialogue timeline and an event-trigger view, refreshed as
  you edit. Note that the preview renders **the tool's parsed data, not the actual
  game screen** — it verifies internal consistency (text IDs, coordinates, indices),
  while "will this line really play on turn 3" still needs an emulator or real hardware.

### Assets

- **Portraits**: 96×80 face, half-closed and closed eyes, mouth frames,
  32×32 map face and 80×80 class card.
- **Portrait porting**: move a portrait from one ROM to another (format converted
  across games, colors preserved), either appending a new entry or replacing an
  existing one.
- **Portrait editor**: turn an external image (PNG / JPG) into a game portrait —
  auto-scaled, quantized to 16 colors, background keyed to transparent.
  Full 128×112 FEBuilderGBA-style sheets (with real mouth and blink frames) are
  supported; mouth and blink each have three modes (real frames / fixed / none),
  and the 32×32 map face can be replaced at the same time.
- **Battle animations**: frame browsing, four palettes, PNG export, and whole-package
  porting to another ROM.
- **Text**: a viewer that auto-detects five text engines (Huffman+SJIS, plain GBK,
  plain UTF-8, Huffman+Chinese table, unknown), with whole-ROM find and replace.
- **Missing-glyph check**: know up front which characters would render blank on the
  current ROM; the text editor warns as you type.
- **Asset library**: a folder on the device that collects exported assets, whose PNGs
  can be written back into the ROM as portraits.

### Tools

- **Cheats**: 13 batch presets (maxed growths, 200% growths, big stats, S weapon ranks,
  triple EXP, class caps, unbreakable weapons, all supports A, support growth/range,
  a full-suite combo), six "who counts as playable" criteria plus a custom roster.
  Wide criteria ask for confirmation before touching suspected enemy units.
- **Simulator**: growth curves (expected / worst / best, with class caps),
  battle forecast, weapon ranking, and a before-vs-after comparison.
- **Hex editor**: pick a byte, type with the on-screen keypad, search, and changed
  bytes stay highlighted.
- **Disassembler**: ARM and Thumb, jump to branch targets, patch machine code.
- **Patches**: a community patch library (FEBuilderGBA patches, fixed-byte writes only);
  apply external UPS / IPS patches; export the modified GBA or a UPS / IPS patch.
- Multiple ROMs open at once, external workspace folder, manual table addresses,
  free-space search, ROM health check, importable edit recipes, sharing the ROM to an
  emulator, logs and a dark theme.

## Which base ROM to use for a story hack

The deciding factor is the **font/glyph table**. Missing glyphs do not raise errors —
they just silently disappear in game:

| Base ROM | Text engine | Glyph coverage | Good for |
|---|---|---|---|
| **Blazing Blade (Superxyj Chinese)** | plain GBK | Nearly all common Chinese characters (full GB2312) | **Best base for story hacks** |
| Japanese FE7 / FE8 | Huffman + SJIS | Japanese only; most simplified Chinese names are missing | Not for Chinese stories |
| Sacred Stones (Chinese) | Huffman + Chinese table | ~2500 glyphs, a subset chosen for the original script | Editing existing lines only |
| Heavily modified hacks | plain UTF-8 | Almost unlimited | But their maps and scenes are already changed |

Write a sample line (names, places, weapons, common verbs) and run the missing-glyph
check before committing to a base ROM.

## Supported ROMs

| Game | Versions | Size |
|---|---|---|
| The Binding Blade | Japanese / Chinese translation | 8 MB |
| The Blazing Blade | Japanese / US / Chinese translation | 16–18 MB |
| The Sacred Stones | Japanese / Chinese translations | 16 MB |
| Community hacks | e.g. The Last Promise, HoloEmblem, 圣邪的意志 | 16–32 MB |

ROMs are identified by structure rather than game code, and pointers beyond 16 MB in
expanded ROMs are resolved correctly.

## Building

```bash
flutter build apk --release --target-platform android-arm64
```

Tests: `flutter test` (requires 13 real ROM samples).
ROMs are copyrighted and not included; point the tests at your own copies with `FE_ROM_DIR`:

```bash
flutter test --dart-define=FE_ROM_DIR=/path/to/game-rom
```

It defaults to `../game-rom/` next to the project. `FE_ROM_DIR` also applies to
`tool/debugger_patch/fe8_build.py`.

## Built for AI collaboration

The app embeds an MCP server (enabled in settings, listening only on
`127.0.0.1:8422` by default). An AI client can inspect tables, edit fields and move
assets over MCP, sharing the same ROM buffer as the UI. Because a single wrong step
by an AI is otherwise only noticed by hand, the server adds a safety net:

- **`describe_rom`**: version, text engine, table sizes, usable ID ranges, editable
  field names, chapter titles and known limitations — no guessing offsets.
- **`dry_run`**: every writing tool supports it (it really runs, then rolls back) and
  reports the byte ranges it would change.
- **`snapshot` / `rollback`**: explicit transactions, roll back to any snapshot rather
  than only "undo everything".
- **`validate_rom`**: a post-edit structural check that shares its code with the UI's
  **ROM health check**.
- **`export_recipe` / `apply_recipe`**: export edits as a replayable recipe
  (optionally with an intent layer resolved by name) for sharing and reproduction.
- **Resources and task templates**: ROM summaries, field lists, chapter lists and
  beginner walkthroughs (strengthen a character, add reinforcements, rewrite dialogue,
  start a story hack from scratch).

## Known limitations

- **Instructions cannot be inserted into the game's existing event scripts.** The tool
  only appends a new event and leaves original scripts byte-for-byte untouched. This is
  a deliberate safety boundary: inserting instructions requires relocating scripts and
  re-pointing every reference, which has proven unreliable.
- **ROMs cannot be expanded and chapters cannot be added.** The original games' tables,
  text and event regions are full; expanded ROMs rely on the hacker's own addressing
  patch, and this tool only reads them.
- Chapter units can only be edited, not added or removed; shops can swap an existing
  slot but not add or remove entries (prices live in the item table).
- The portrait editor replaces the **face and palette** (optionally the 32×32 map face).
  Mouth and blink frames cannot be derived from a single still image; import a full
  128×112 FEBuilderGBA sheet if you need real frames.
- Battle animations cannot be edited frame by frame or instruction by instruction, and
  sound effects are not ported with them.
- The battle simulator is an **approximation**: terrain, supports, the weapon triangle
  and effectiveness are not taken into account.
- Map edits write in place only (map data is shared between chapters; if the compressed
  result does not fit, the edit is rejected rather than relocated).
- Class count is limited by the save format: a community ExModularSave patch exists for
  The Sacred Stones, but not for the other two games, so replacing an existing class is
  safer than adding one.
- The in-game debugger is not exposed yet (its patch still has defects).
- Chinese translations show the original in-game characters (the Sacred Stones
  translation substitutes homophones); the tool maps official names for units, classes
  and items.

## Credits and license

- Data and format knowledge derived from
  [FEBuilderGBA](https://github.com/FEBuilderGBA/FEBuilderGBA) (GPL-3.0, by 7743)
- The in-game debugger patch derives from
  [Vesly](https://github.com/Veslyquix/ASM)'s Nergal debugger (GPL-3.0)
- This project's code is an independent Dart implementation, licensed GPL-3.0
- Repository: [agenes-tea/fe_editor_flutter](https://github.com/agenes-tea/fe_editor_flutter)

### About the network permission

The `INTERNET` permission is used **only** by the MCP debugging feature (active only when
enabled in settings). The MCP server binds to `127.0.0.1` by default, makes no outbound
connections, and never uploads your ROM, game data or personal information. MCP is off by
default.

Please only modify ROMs you legally own.
