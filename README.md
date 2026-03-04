# dart_mymc

A Dart port of [mymc](http://www.csclub.uwaterloo.ca/~mskala/programs/mymc/) —
a PS2 Memory Card manager originally written in Python 2.7 by Ross Ridge.

Supports reading and writing standard 8 MB PS2 memory card images (`.ps2`),
importing and exporting saves in four formats (`.psu`, `.max`, `.sps`, `.cbs`),
and converting between formats.

---

## CLI usage

```
dart run bin/dart_mymc.dart <memcard.ps2> <command> [options] [args]
```

| Command | Description |
|---|---|
| `ls [dir]` | List directory entries |
| `dir` | Show saves with titles and free space |
| `df` | Show free space |
| `format` | Format a new card image |
| `mkdir <dir>` | Create a directory |
| `import <file>` | Import a save file (`.psu`, `.max`, `.sps`, `.cbs`) |
| `export <dir>` | Export a save to `.psu` (default) or `.max` (`-t max`) |
| `delete <dir>` | Delete a save directory and all its files |
| `rename <old> <new>` | Rename a file or directory |
| `add <file>` | Add a raw file into the current directory |
| `extract <file>` | Extract a raw file from the card |
| `check` | Check FAT consistency |
| `set` / `clear` | Set or clear mode flags |
| `convert <in> <out>` | Convert between save formats (no card needed) |
| `create <new.ps2> <save>` | Create a new card from one or more save files |
| `help <command>` | Show per-command help |

### Examples

```sh
# List saves on a card
dart run bin/dart_mymc.dart Mcd001.ps2 dir

# Export a save as PSU
dart run bin/dart_mymc.dart Mcd001.ps2 export -o NFL2K16.psu /BASLUS-20919NFL2K16

# Export as MAX Drive format
dart run bin/dart_mymc.dart Mcd001.ps2 export -t max -o NFL2K16.max /BASLUS-20919NFL2K16

# Import a save onto a card
dart run bin/dart_mymc.dart Mcd001.ps2 import NFL2K16.psu

# Convert PSU → MAX (no card needed)
dart run bin/dart_mymc.dart convert NFL2K16.psu NFL2K16.max

# Create a fresh card from a save file
dart run bin/dart_mymc.dart new.ps2 create NFL2K16.psu

# Per-command help
dart run bin/dart_mymc.dart help export
dart run bin/dart_mymc.dart Mcd001.ps2 export --help
```

---

## Library API

Add to your `pubspec.yaml`:

```yaml
dependencies:
  dart_mymc:
    path: /path/to/dart_mymc
```

Import the public facade:

```dart
import 'package:dart_mymc/dart_mymc.dart';
```

### Core types

| Type | Description |
|---|---|
| `Ps2Card` | Main entry point — open, format, import, export, delete |
| `Ps2Save` | A save file in memory — load from bytes, convert to bytes |
| `Ps2CardInfo` | Snapshot of card state: free/total bytes + save list |
| `Ps2SaveInfo` | Metadata for one save: dir name, title, size, modified date |
| `Ps2SaveFormat` | Enum: `psu`, `max`, `sps`, `cbs` |
| `Ps2CardIo` | I/O interface (implement for custom backends / WASM) |
| `FileCardIo` | `dart:io`-backed I/O (used by default for file paths) |
| `MemoryCardIo` | `Uint8List`-backed I/O (in-memory, no files) |

### Create / format a card

```dart
// Format a new card file on disk
final card = Ps2Card.formatFile('new.ps2');
card.close();

// Format a card entirely in memory (no disk I/O)
final card = Ps2Card.formatMemory();
// ... use card ...
card.close();
```

### Open an existing card

```dart
// From a file path
final card = Ps2Card.openFile('Mcd001.ps2');

// From raw bytes (e.g. loaded from a database or network)
final bytes = File('Mcd001.ps2').readAsBytesSync();
final card = Ps2Card.openMemory(bytes);
```

### List saves

```dart
final card = Ps2Card.openFile('Mcd001.ps2');
try {
  final saves = card.listSaves();
  for (final save in saves) {
    print('${save.dirName}  "${save.title}"  ${save.sizeBytes ~/ 1024} KB');
  }

  // Or get everything at once
  final info = card.info;
  print('Free: ${info.freeBytes ~/ 1024} KB of ${info.totalBytes ~/ 1024} KB');
} finally {
  card.close();
}
```

### Import a save

```dart
final card = Ps2Card.openFile('Mcd001.ps2');
try {
  // Format is auto-detected from the magic bytes (.psu, .max, .sps, .cbs)
  final saveBytes = File('NFL2K16.psu').readAsBytesSync();
  card.importSave(saveBytes);

  // Allow overwriting an existing save with the same directory name
  card.importSave(saveBytes, overwrite: true);
} finally {
  card.close();
}
```

### Export a save

```dart
final card = Ps2Card.openFile('Mcd001.ps2');
try {
  // Export as PSU (default)
  final psuBytes = card.exportSave('BASLUS-20919NFL2K16');
  File('NFL2K16.psu').writeAsBytesSync(psuBytes);

  // Export as MAX Drive
  final maxBytes = card.exportSave('BASLUS-20919NFL2K16',
      format: Ps2SaveFormat.max);
  File('NFL2K16.max').writeAsBytesSync(maxBytes);
} finally {
  card.close();
}
```

### Delete a save

```dart
final card = Ps2Card.openFile('Mcd001.ps2');
try {
  card.deleteSave('BASLUS-20919NFL2K16');
} finally {
  card.close();
}
```

### Convert between save formats

`Ps2Save` works standalone — no card needed:

```dart
// Load from any supported format (auto-detected)
final psuBytes = File('NFL2K16.psu').readAsBytesSync();
final save = Ps2Save.fromBytes(psuBytes);

print(save.dirName);  // BASLUS-20919NFL2K16
print(save.title);    // ESPN NFL 2K5 NFL21Ros

// Convert to MAX Drive
final maxBytes = save.toBytes(format: Ps2SaveFormat.max);
File('NFL2K16.max').writeAsBytesSync(maxBytes);
```

### Create a new card from saves (fully in-memory)

```dart
final card = Ps2Card.formatMemory();
try {
  for (final path in ['save1.psu', 'save2.max']) {
    card.importSave(File(path).readAsBytesSync());
  }
  // Write the finished card to disk
  // (access the underlying bytes via MemoryCardIo if needed)
} finally {
  card.close();
}
```

### Custom I/O backend

Implement `Ps2CardIo` to plug in any storage backend:

```dart
class MyCloudIo implements Ps2CardIo {
  @override void setPosition(int offset) { ... }
  @override Uint8List read(int length) { ... }
  @override void write(Uint8List data) { ... }
  @override void flush() { ... }
  @override void close() { ... }
}

final card = Ps2Card._(
  Ps2MemoryCard.fromIo(MyCloudIo(), ignoreEcc: true),
);
```

---

## Save format support

| Format | Extension | Load | Save |
|---|---|---|---|
| EMS / MemoryCard Pro | `.psu` | ✅ | ✅ |
| MAX Drive | `.max` | ✅ | ✅ |
| SharkPort | `.sps` | ✅ | pending |
| CodeBreaker | `.cbs` | ✅ | pending |

---

## Development

```sh
dart test          # run all 52 tests
dart analyze       # static analysis
dart run bin/dart_mymc.dart --help
```

Python 2.7 is used as the reference implementation for parity testing.
Golden output files in `test/test_files/` were generated from
`mymc-pysrc-2.7/mymc.py` and are compared byte-for-byte in the test suite.
See `test/README.md` for details.
