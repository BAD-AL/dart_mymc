// ps2card.dart
//
// Clean public facade for the dart_mymc library.
// Hides internal types (Ps2MemoryCard, Ps2SaveFile, PS2DirEntry, etc.)
// behind simple value types and factory constructors.

import 'dart:typed_data';
import 'package:archive/archive.dart';

import 'ps2card_io.dart';
import 'ps2icon.dart';
import 'ps2mc.dart';
import 'ps2mc_dir.dart';
import 'ps2save.dart';

// ---------------------------------------------------------------------------
// Enums & value types
// ---------------------------------------------------------------------------

enum Ps2SaveFormat { psu, max, sps, cbs }

class Ps2SaveInfo {
  final String dirName;
  final String title;
  final int sizeBytes;
  final DateTime modified;

  /// Parsed 3D icon data, or null if the save has no icon.
  final Ps2IconData? iconData;

  const Ps2SaveInfo({
    required this.dirName,
    required this.title,
    required this.sizeBytes,
    required this.modified,
    this.iconData,
  });

  @override
  String toString() => 'Ps2SaveInfo($dirName, "$title", ${sizeBytes}B)';
}

class Ps2CardInfo {
  final int freeBytes;
  final int totalBytes;
  final List<Ps2SaveInfo> saves;

  const Ps2CardInfo({
    required this.freeBytes,
    required this.totalBytes,
    required this.saves,
  });
}

/// A single file inside a [Ps2Save], with its name, size, and raw bytes.
class Ps2FileInfo {
  final String name;
  final int sizeBytes;
  final Uint8List _bytes;
  const Ps2FileInfo({required this.name, required this.sizeBytes, required Uint8List bytes})
      : _bytes = bytes;

  /// Returns the raw bytes of this file.
  Uint8List toBytes() => _bytes;
}

// ---------------------------------------------------------------------------
// Ps2Save — public wrapper around Ps2SaveFile
// ---------------------------------------------------------------------------

class Ps2Save {
  final Ps2SaveFile _sf;
  Ps2Save._(this._sf);

  /// Build a save from an in-memory map of filename → bytes.
  /// [dirName] becomes the save directory name on the card.
  /// Keys in [files] must be plain filenames (no path separators).
  factory Ps2Save.fromFiles(String dirName, Map<String, Uint8List> files) {
    final ts = todNow();
    final sf = Ps2SaveFile();
    final names = files.keys.toList()..sort();
    sf.setDirectory(PS2DirEntry(
      mode: dfRwx | dfDir | df0400 | dfExists,
      length: names.length,
      created: ts,
      fatCluster: 0,
      parentEntry: 0,
      modified: ts,
      name: dirName,
    ));
    for (int i = 0; i < names.length; i++) {
      final data = files[names[i]]!;
      sf.setFile(
        i,
        PS2DirEntry(
          mode: dfRwx | dfFile | df0400 | dfExists,
          length: data.length,
          created: ts,
          fatCluster: 0,
          parentEntry: 0,
          modified: ts,
          name: names[i],
        ),
        data,
      );
    }
    return Ps2Save._(sf);
  }

  /// Auto-detect format from magic bytes and load.
  factory Ps2Save.fromBytes(Uint8List data) {
    final ftype = detectFileType(data);
    if (ftype == null) throw ArgumentError('Unrecognised save file format');
    final sf = Ps2SaveFile();
    final mio = MemorySaveIo(data);
    switch (ftype) {
      case 'psu':
        sf.loadEms(mio);
      case 'max':
        sf.loadMax(mio);
      case 'sps':
        sf.loadSps(mio);
      case 'cbs':
        sf.loadCbs(mio);
      default:
        throw ArgumentError('Unsupported format: $ftype');
    }
    return Ps2Save._(sf);
  }

  String get dirName => _sf.getDirectory().name;

  String get title {
    final ic = _sf.getIconSys();
    if (ic == null) return dirName;
    final (t1, t2) = ic.title();
    final combined = '$t1 $t2'.trim();
    return combined.isEmpty ? dirName : combined;
  }

  /// Parsed 3D icon data, or null if the save has no icon.
  Ps2IconData? get iconData {
    final ic = _sf.getIconSys();
    if (ic == null) return null;
    final iconName = ic.normalIcon;
    if (iconName.isEmpty) return null;
    final dir = _sf.getDirectory();
    final lower = iconName.toLowerCase();
    for (int i = 0; i < dir.length; i++) {
      final (PS2DirEntry ent, Uint8List data) = _sf.getFile(i);
      if (ent.name.toLowerCase() == lower) return parseIconFile(data, ic);
    }
    return null;
  }

  /// Every file stored in this save, with name, size, and raw bytes.
  List<Ps2FileInfo> get files {
    final dir = _sf.getDirectory();
    return List.generate(dir.length, (int i) {
      final (PS2DirEntry ent, Uint8List data) = _sf.getFile(i);
      return Ps2FileInfo(name: ent.name, sizeBytes: ent.length, bytes: data);
    });
  }

  Uint8List toBytes({Ps2SaveFormat format = Ps2SaveFormat.psu}) {
    final mio = MemorySaveIo();
    switch (format) {
      case Ps2SaveFormat.psu:
        _sf.saveEms(mio);
      case Ps2SaveFormat.max:
        _sf.saveMax(mio);
      case Ps2SaveFormat.sps:
        _sf.saveSps(mio);
      case Ps2SaveFormat.cbs:
        _sf.saveCbs(mio);
    }
    return mio.toBytes();
  }

  /// Returns this save as a ZIP archive containing all its files
  /// (prefixed by the directory name as a folder inside the ZIP).
  Uint8List toZip() => _sf.toZip();
}

// ---------------------------------------------------------------------------
// Ps2Card — public facade around Ps2MemoryCard
// ---------------------------------------------------------------------------

class Ps2Card {
  final Ps2MemoryCard _mc;
  Ps2Card._(this._mc);

  /// Open a card from a custom [Ps2CardIo] backend (e.g. a network or WASM buffer).
  factory Ps2Card.fromIo(Ps2CardIo io, {bool ignoreEcc = false}) =>
      Ps2Card._(Ps2MemoryCard.fromIo(io, ignoreEcc: ignoreEcc));

  /// Open a card image from raw bytes (in-memory).
  factory Ps2Card.openMemory(Uint8List bytes, {bool ignoreEcc = false}) =>
      Ps2Card._(Ps2MemoryCard.fromIo(MemoryCardIo(bytes),
          ignoreEcc: ignoreEcc));

  /// Format a blank card entirely in memory (no files created).
  ///
  /// [sizeMb] can be 8 (default), 16, 32, or 64.
  factory Ps2Card.format({int sizeMb = 8}) {
    if (sizeMb != 8 && sizeMb != 16 && sizeMb != 32 && sizeMb != 64) {
      throw ArgumentError('Invalid card size: $sizeMb MB (must be 8, 16, 32, or 64)');
    }
    final pagesPerCard = (sizeMb * 1024 * 1024) ~/ ps2mcStandardPageSize;
    final rawPageSize = ps2mcStandardPageSize + 16; // 512 + spare(16)
    final totalBytes = pagesPerCard * rawPageSize;
    final io = MemoryCardIo.blank(totalBytes);
    return Ps2Card._(Ps2MemoryCard.fromIo(io, formatParams: [
      1,
      ps2mcStandardPageSize,
      ps2mcStandardPagesPerEraseBlock,
      pagesPerCard
    ]));
  }

  /// Summary of the card: free/total bytes + save list.
  Ps2CardInfo get info => Ps2CardInfo(
        freeBytes: _mc.getFreeSpace(),
        totalBytes: _mc.getAllocatableSpace(),
        saves: listSaves(),
      );

  /// List all saves on the card.
  List<Ps2SaveInfo> listSaves() {
    final dir = _mc.dirOpen('/');
    final result = <Ps2SaveInfo>[];
    for (final ent in dir) {
      if (!ent.exists || !modeIsDir(ent.mode)) continue;
      if (ent.name == '.' || ent.name == '..') continue;
      final rawIconSys = _mc.getIconSys('/${ent.name}');
      String title = ent.name;
      Ps2IconData? iconData;
      if (rawIconSys != null) {
        final ic = IconSys.unpack(rawIconSys);
        if (ic != null) {
          final (t1, t2) = ic.title();
          final combined = '$t1 $t2'.trim();
          if (combined.isNotEmpty) title = combined;
          final iconName = ic.normalIcon;
          if (iconName.isNotEmpty) {
            final iconBytes = _mc.getFileBytes('/${ent.name}/$iconName');
            if (iconBytes != null) iconData = parseIconFile(iconBytes, ic);
          }
        }
      }
      result.add(Ps2SaveInfo(
        dirName: ent.name,
        title: title,
        sizeBytes: _mc.dirSize('/${ent.name}'),
        modified: ent.modified.toLocalDateTime(),
        iconData: iconData,
      ));
    }
    dir.close();
    return result;
  }

  /// Export one save as bytes in the given format.
  Uint8List exportSave(String dirName,
      {Ps2SaveFormat format = Ps2SaveFormat.psu}) {
    final sf = _mc.exportSaveFile(dirName);
    return Ps2Save._(sf).toBytes(format: format);
  }

  /// Export one save as a ZIP archive containing all its files.
  Uint8List exportSaveZip(String dirName) {
    final sf = _mc.exportSaveFile(dirName);
    return Ps2Save._(sf).toZip();
  }

  /// Export all saves on the card as a single ZIP archive.
  Uint8List exportAllZip() {
    final archive = Archive();
    final saves = listSaves();
    for (final saveInfo in saves) {
      final sf = _mc.exportSaveFile(saveInfo.dirName);
      sf.toArchive(archive);
    }
    return Uint8List.fromList(ZipEncoder().encode(archive)!);
  }

  /// Import a save from bytes (auto-detect format).
  void importSave(Uint8List data, {bool overwrite = false}) {
    final save = Ps2Save.fromBytes(data);
    _mc.importSaveFile(save._sf, overwrite);
  }

  /// Import one or more saves from a ZIP archive.
  ///
  /// Files are grouped by their top-level directory name in the ZIP.
  /// Each group is imported as a separate save.
  void importZip(Uint8List data, {bool overwrite = false}) {
    final archive = ZipDecoder().decodeBytes(data);
    final saves = <String, Map<String, Uint8List>>{};

    for (final file in archive) {
      if (!file.isFile) continue;
      final parts = file.name.split('/');
      if (parts.length < 2) continue; // Not in a subdirectory

      final dirName = parts[0];
      final fileName = parts.sublist(1).join('/');
      if (fileName.isEmpty) continue;

      saves.putIfAbsent(dirName, () => {})[fileName] =
          file.content as Uint8List;
    }

    for (final entry in saves.entries) {
      final save = Ps2Save.fromFiles(entry.key, entry.value);
      _mc.importSaveFile(save._sf, overwrite);
    }
  }

  /// Delete a save directory and all its files.
  void deleteSave(String dirName) => _mc.rmdir(dirName);

  /// Returns the card image as a [Uint8List].
  /// Only available for memory-backed cards; throws [UnsupportedError] otherwise.
  Uint8List toBytes() => _mc.toBytes();

  void close() => _mc.close();
}
