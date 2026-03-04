# dart_mymc Project Checklist

> Dart port of `mymc` — PS2 Memory Card manager (Python 2.7 → Dart)
> Python source: `mymc-pysrc-2.7/` | Dart source: `lib/`
> Last updated: 2026-03-04

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

## Phase 6 — Parity Testing & Polish ✅ COMPLETE

**Goal:** Systematic verification of Dart vs Python output for every command.

- [x] `ls` output — character-for-character identical to Python (golden file)
- [x] `df` output — identical to Python (golden file)
- [x] `dir` output — identical to Python (golden file; fixed Shift-JIS 0x81xx punctuation)
- [x] Exported `.psu` — byte-for-byte identical to Python
- [x] Exported `.max` — byte-for-byte identical to Python
- [x] `--ignore-ecc` / `-i` flag — wired through to `Ps2MemoryCard`
- [x] `--version` flag — works
- [x] `dart_mymc help <command>` — per-command help text (all 17 commands)
- [x] `test/README.md` — documents all fixture files and regeneration commands
- [ ] `.cbs` and `.sps` import test against real save files (blocked: no test data)
- [ ] `saveSps` / `saveCbs` writers (blocked: no test data / Python reference)

---

## Phase 7 — Clean Library API ✅ COMPLETE

**Goal:** Make `dart_mymc` usable as a library with a stable, clean public surface.

- [x] `lib/src/ps2card_io.dart` — `Ps2CardIo` abstract interface + `FileCardIo` + `MemoryCardIo`
- [x] `lib/src/ps2mc.dart` — `Ps2CardIo` threaded through; `Ps2MemoryCard.fromIo()` constructor
- [x] `lib/src/ps2card.dart` — `Ps2Card` facade, `Ps2Save`, `Ps2SaveInfo`, `Ps2CardInfo`, `Ps2SaveFormat`, `_MemoryFile` shim
- [x] `lib/dart_mymc.dart` — barrel exports only the public facade + exception types
- [x] Tests use direct `src/` imports for internals; 4 new `Ps2Card` API tests
- [x] `README.md` — full library API documentation with examples
- [x] 52 tests total, all pass

---

## Phase 8 — Browser / WASM Readiness ☐ TODO

**Goal:** Remove `dart:io` from the core logic so the library compiles for browser/WASM.
The CLI (`bin/`, `lib/dart_mymc.dart`) and file-path adapters (`FileCardIo`, `Ps2Card.openFile`)
may keep `dart:io`. The core codec and filesystem logic must not.

### dart:io audit (current state)

| File | dart:io usage | Action |
|---|---|---|
| `lib/src/ps2card_io.dart` | `FileCardIo` wraps `RandomAccessFile` | ✅ Intentional — file adapter |
| `lib/src/ps2card.dart` | `_MemoryFile` implements `RandomAccessFile`; `File` in `openFile`/`formatFile` | Decouple `_MemoryFile` from RAF; file factories stay |
| `lib/src/ps2mc.dart` | `File(path)` in factory; `stdout`/`stderr` in `check()` + `exportSaveFile()` | Move `File` to `FileCardIo`; remove stdout/stderr from core |
| `lib/src/ps2save.dart` | `RandomAccessFile` in all load/save methods | Replace with a `SaveIo` interface (mirrors `Ps2CardIo`) |
| `lib/dart_mymc.dart` | stdout, stderr, File, Platform, exit — intentional CLI I/O | ✅ Keep as-is |

### Tasks

- [ ] Define `SaveIo` abstract interface in `lib/src/ps2save.dart` (or shared file)
  - Methods: `read(n)`, `write(buf)`, `setPosition(n)`, `position()`, `length()`, `flush()`
  - Implement `FileSaveIo` (wraps `RandomAccessFile`) in `lib/src/ps2card_io.dart`
  - `_MemoryFile` in `ps2card.dart` becomes `MemorySaveIo` implementing `SaveIo`
- [ ] Update all `Ps2SaveFile` load/save methods to use `SaveIo` instead of `RandomAccessFile`
- [ ] Remove `stdout`/`stderr` from `Ps2MemoryCard.check()` and `exportSaveFile()` — return/throw instead
- [ ] Move `File(path).openSync()` out of `Ps2MemoryCard(String path)` factory into `FileCardIo`
- [ ] Remove `import 'dart:io'` from `ps2mc.dart` and `ps2save.dart`
- [ ] Compile to WASM / JS and smoke-test in a browser
- [ ] Add a `dart2wasm` or `dart compile js` build step to CI

---

## Test Coverage Summary

| Phase | Tests | Status |
|---|---|---|
| Phase 1 & 2 (read-only) | 20 | ✅ All pass |
| Phase 3 (write ops) | 11 unit + 2 CLI = 13 | ✅ All pass (31 cumulative) |
| Phase 4 (save formats) | 9 unit/CLI | ✅ All pass (40 cumulative) |
| Phase 5 (conversion/create) | 2 unit + 4 CLI = 6 | ✅ All pass (48 cumulative) |
| Phase 6 (parity/polish) | 3 golden-file CLI | ✅ All pass (48 cumulative, tests added to existing groups) |
| Phase 7 (library API) | 4 Ps2Card facade | ✅ All pass (52 cumulative) |
| Phase 8 (WASM readiness) | TBD | ☐ Not started |
| **Total** | **52** | **All pass** |

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
| `lib/src/ps2card_io.dart` | *(new)* | ✅ Complete — `Ps2CardIo`, `FileCardIo`, `MemoryCardIo` |
| `lib/src/ps2card.dart` | *(new)* | ✅ Complete — `Ps2Card`, `Ps2Save`, `Ps2SaveInfo`, `Ps2CardInfo` |
| `lib/dart_mymc.dart` | `mymc.py` | ✅ Complete |
| `bin/dart_mymc.dart` | *(entry point)* | ✅ Complete |
| `gui.py` | — | ⛔ Out of scope (GUI excluded) |

---

## Key Reference Paths

- Python 2: `~/Programs/python2/bin/python2`
- Test card: `test/test_files/Mcd001.ps2`
- Test save (MAX): `test/test_files/NFL2K16.max`
- Scratch tools: `tools/` (e.g., `tools/current_tool.dart`)
- Python source: `mymc-pysrc-2.7/`
