# dart_mymc Project Checklist

> Dart port of `mymc` — PS2 Memory Card manager (Python 2.7 → Dart)
> Python source: `mymc-pysrc-2.7/` | Dart source: `lib/`
> Last updated: 2026-03-03

---

## Overall Goal

Produce a Dart CLI program with full feature parity to `mymc.py`, plus two
additional features:
1. Convert between `.psu` and `.max` save formats
2. Create a new `.ps2` memory card image from a `.max` or `.psu` save file

Browser / WASM support is a future concern; desktop OS is the current target.

---

## Phase 1 — Foundation ✅ COMPLETE

**Goal:** Core data structures, ECC, Shift-JIS, icon.sys, and a working CLI entry point.

- [x] `lib/src/round.dart` — `divRoundUp`, `roundUp`, `roundDown`
- [x] `lib/src/ps2mc_dir.dart` — `DF_*` mode constants, `PS2Tod`, `PS2DirEntry`, `modeIsFile`, `modeIsDir`, `todNow()`
- [x] `lib/src/ps2mc_ecc.dart` — `eccCalculate`, `eccCheck`, `eccCalculatePage`, `eccCheckPage`
- [x] `lib/src/sjistab.dart` — Shift-JIS fullwidth→ASCII normalisation table
- [x] `lib/src/ps2save.dart` — `decodeShiftJis`, `shiftJisConv`, `IconSys`, `detectFileType`, `Ps2SaveFile` skeleton
- [x] `lib/dart_mymc.dart` — `runMain()`, argument parser, `_printHelp()`
- [x] `bin/dart_mymc.dart` — thin `main()` wrapper

---

## Phase 2 — Read-Only Commands ✅ COMPLETE

**Goal:** Read and display data from an existing `.ps2` card image.

- [x] `lib/src/ps2mc.dart` — `Ps2MemoryCard` filesystem driver (read path)
  - [x] Superblock parse, ECC auto-detection
  - [x] Page / cluster I/O with LRU cache (12 FAT, 64 cluster slots)
  - [x] FAT traversal (`lookupFat`, indirect FAT lookup)
  - [x] `pathSearch` — resolve `/dir/file` paths
  - [x] `Ps2McDirectory` + `Ps2McFile` open/read/seek/close
  - [x] `getFreeSpace`, `getDirSize`, `listDir`
  - [x] `getDirectory`, `getIconSys`, `chdir`
- [x] CLI commands: `ls`, `dir`, `df`
- [x] Tests: 17 unit tests + 3 CLI integration tests (20 total) — all pass

---

## Phase 3 — Write Operations ✅ COMPLETE

**Goal:** Full read-write filesystem: format, create, delete, rename, import, export.

- [x] `PS2Tod.now()` static factory
- [x] `allocateCluster()` — scan FAT, mark allocated, update cursor
- [x] `_readFatCluster(n)` — indirect→FAT lookup returning `(Uint32List, int)`
- [x] `setFat(n, value)` — write one FAT entry back to card
- [x] `Ps2McFile.write()` — cluster-chain write with auto-extension
- [x] `Ps2McFile._extendFile(n)` — allocate + link new cluster
- [x] `Ps2McDirectory.writeRawEnt()` — write one `PS2DirEntry` at slot index
- [x] `_updateDirentAll()` — merge + write dirent, notify open-file handles
- [x] `updateDirent()` — thin public wrapper
- [x] `createDirEntry()` — create file or directory entry in parent dir
- [x] `deleteDirloc()` — free FAT chain + clear/truncate dirent
- [x] `writeSuperblock()` — pack + write page 0, erase goodBlock2
- [x] `_format()` — full card format (ECC optional, indirect FAT, root dir)
- [x] `_removeDir()` — recursive directory delete
- [x] `mkdir` / `rmdir` / `remove` / `rename` — high-level path operations
- [x] `exportSaveFile()` → `Ps2SaveFile`
- [x] `importSaveFile()` — write save + update timestamps/modes
- [x] `getDirent` / `setDirent` — for `set` / `clear` mode commands
- [x] `check()` — FAT consistency walk, lost-cluster detection
- [x] `Ps2SaveFile.loadEms` / `saveEms` — EMS (`.psu`) format
- [x] CLI commands: `format`, `mkdir`, `remove`, `delete`, `rename`, `add`,
      `extract`, `import`, `export`, `set`, `clear`, `check`
- [x] Tests: 11 unit tests + 2 CLI integration tests (31 total) — all pass

---

## Phase 4 — Full Save Format Support ✅ COMPLETE

**Goal:** Read/write all four save formats: `.psu` (done in Phase 3), `.max`, `.sps`, `.cbs`.

- [x] `lib/src/lzari.dart` — LZARI arithmetic codec
  - [x] `lzariDecode(Uint8List compressed, int uncompLen)` → `Uint8List`
  - [x] `lzariEncode(Uint8List src)` → `Uint8List`
  - [x] Key fix: `effMax = min(inLen - pos, maxMatch)` clamp in `addSuffix`
  - [x] Key fix: `safeKey()` guard for `String.fromCharCodes` bounds
- [x] `Ps2SaveFile.loadMax()` — MAX Drive (`.max`) loader
- [x] `Ps2SaveFile.saveMax()` — MAX Drive writer (CRC32 over header+body)
- [x] `Ps2SaveFile.loadSps()` — SharkPort (`.sps`) loader
- [x] `Ps2SaveFile.loadCbs()` — CodeBreaker (`.cbs`) loader (RC4 + zlib)
- [x] `_crc32()`, `_rc4Crypt()` helpers in `ps2save.dart`
- [x] CLI `import` wired for `.max`, `.cbs`, `.sps`
- [x] CLI `export -t max` wired
- [x] Tests: 4 LZARI unit + 4 MAX format unit + 1 MAX CLI integration (40 total) — all pass

---

## Phase 5 — Format Conversion & Card Creation ✅ COMPLETE

**Goal:** Cross-format conversion and creating a fresh `.ps2` card from a save file.

### 5a. Format conversion command
- [x] `dart_mymc convert [-f] <input> <output>` — detect input type, write output type
  - [x] `.psu` → `.max`
  - [x] `.max` → `.psu`
  - [ ] `.psu`/`.max` → `.sps` — `saveSps()` stub (UnimplementedError, no test data)
  - [ ] `.psu`/`.max` → `.cbs` — `saveCbs()` stub (UnimplementedError, no test data)
- [x] `doConvert()` in `lib/dart_mymc.dart`
- [x] `_typeFromExtension()` helper — infer output format from file extension
- [ ] `Ps2SaveFile.saveSps()` — SharkPort writer (blocked: no test data)
- [ ] `Ps2SaveFile.saveCbs()` — CodeBreaker writer (blocked: no test data)

### 5b. Create `.ps2` from save file
- [x] `dart_mymc <new.ps2> create [-f] <save.(max|psu|sps|cbs)> [...]`
- [x] `doCreate()` in `lib/dart_mymc.dart`
  - [x] Validates input files before touching disk
  - [x] Formats blank card, imports each save
  - [x] `-f` / `--overwrite-existing` mirrors Python behavior
- [x] Tests: 2 unit + 4 CLI integration (48 total) — all pass

---

## Phase 6 — Parity Testing & Polish ☐ TODO

**Goal:** Systematic verification of Dart vs Python output for every command.

- [ ] Cross-validate `ls`, `dir`, `df` output character-for-character against Python
- [ ] Cross-validate exported `.psu` byte-for-byte against Python (`mymc.py export`)
- [ ] Cross-validate exported `.max` byte-for-byte against Python
- [ ] Test `.cbs` and `.sps` import against real save files (need test data)
- [ ] `saveSps` / `saveCbs` produce files loadable by original Python
- [ ] `--ignore-ecc` / `-i` flag wired through to `Ps2MemoryCard`
- [ ] `--version` flag prints version string
- [ ] Error messages match Python originals (non-critical)
- [ ] `dart_mymc help <command>` per-command help text

---

## Phase 7 — Browser / WASM ☐ FUTURE

**Goal:** Run dart_mymc in a browser context (no `dart:io`).

- [ ] Audit `dart:io` usage — isolate to thin adapters
- [ ] Replace `RandomAccessFile` I/O with `Uint8List`-backed virtual file
- [ ] Replace `Process.run` (test runner) with browser-compatible equivalent
- [ ] Compile to WASM / JS and smoke-test in Chrome

---

## Test Coverage Summary

| Phase | Tests | Status |
|---|---|---|
| Phase 1 & 2 (read-only) | 20 | ✅ All pass |
| Phase 3 (write ops) | 11 unit + 2 CLI = 13 | ✅ All pass (31 cumulative) |
| Phase 4 (save formats) | 9 unit/CLI | ✅ All pass (40 cumulative) |
| Phase 5 (conversion/create) | 2 unit + 4 CLI = 6 | ✅ All pass (48 cumulative) |
| Phase 6 (parity/polish) | 0 | ☐ Not started |
| **Total** | **48** | **All pass** |

---

## Source File Map

| Dart file | Python equivalent | Status |
|---|---|---|
| `lib/src/round.dart` | `round.py` | ✅ Complete |
| `lib/src/ps2mc_dir.dart` | `ps2mc_dir.py` | ✅ Complete |
| `lib/src/ps2mc_ecc.dart` | `ps2mc_ecc.py` | ✅ Complete |
| `lib/src/sjistab.dart` | `sjistab.py` | ✅ Complete |
| `lib/src/lzari.dart` | `lzari.py` | ✅ Complete |
| `lib/src/ps2save.dart` | `ps2save.py` | ✅ Complete (load all 4; save psu+max; save sps/cbs pending) |
| `lib/src/ps2mc.dart` | `ps2mc.py` | ✅ Complete |
| `lib/dart_mymc.dart` | `mymc.py` | ✅ Complete (convert/create pending) |
| `bin/dart_mymc.dart` | *(entry point)* | ✅ Complete |
| `gui.py` | — | ⛔ Out of scope (GUI excluded) |

---

## Key Reference Paths

- Python 2: `~/Programs/python2/bin/python2`
- Test card: `test/test_files/Mcd001.ps2`
- Test save (MAX): `test/test_files/NFL2K16.max`
- Scratch tools: `tools/` (e.g., `tools/current_tool.dart`)
- Python source: `mymc-pysrc-2.7/`
