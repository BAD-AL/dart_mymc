// ps2card.dart
//
// Clean public facade for the dart_mymc library.
// Hides internal types (Ps2MemoryCard, Ps2SaveFile, PS2DirEntry, etc.)
// behind simple value types and factory constructors.

import 'dart:io'; // File — used only in openFile / formatFile factories
import 'dart:typed_data';

import 'ps2card_io.dart';
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

  const Ps2SaveInfo({
    required this.dirName,
    required this.title,
    required this.sizeBytes,
    required this.modified,
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

// ---------------------------------------------------------------------------
// Ps2Save — public wrapper around Ps2SaveFile
// ---------------------------------------------------------------------------

class Ps2Save {
  final Ps2SaveFile _sf;
  Ps2Save._(this._sf);

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
    return mio.bytes;
  }
}

// ---------------------------------------------------------------------------
// Ps2Card — public facade around Ps2MemoryCard
// ---------------------------------------------------------------------------

class Ps2Card {
  final Ps2MemoryCard _mc;
  Ps2Card._(this._mc);

  /// Open an existing card image from a file path.
  factory Ps2Card.openFile(String path, {bool ignoreEcc = false}) =>
      Ps2Card._(Ps2MemoryCard(path, ignoreEcc: ignoreEcc));

  /// Open a card image from raw bytes (in-memory).
  factory Ps2Card.openMemory(Uint8List bytes, {bool ignoreEcc = false}) =>
      Ps2Card._(Ps2MemoryCard.fromIo(MemoryCardIo(bytes),
          ignoreEcc: ignoreEcc));

  /// Format a blank card into a new file on disk.
  factory Ps2Card.formatFile(String path, {bool overwrite = false}) {
    if (!overwrite && File(path).existsSync()) {
      throw Ps2McIoError('file exists', path);
    }
    return Ps2Card._(Ps2MemoryCard(path, formatParams: [
      1,
      ps2mcStandardPageSize,
      ps2mcStandardPagesPerEraseBlock,
      ps2mcStandardPagesPerCard
    ]));
  }

  /// Format a blank card entirely in memory (no files created).
  factory Ps2Card.formatMemory() {
    final rawPageSize = ps2mcStandardPageSize + 16; // 512 + spare(16)
    final totalBytes = ps2mcStandardPagesPerCard * rawPageSize;
    final io = MemoryCardIo.blank(totalBytes);
    return Ps2Card._(Ps2MemoryCard.fromIo(io, formatParams: [
      1,
      ps2mcStandardPageSize,
      ps2mcStandardPagesPerEraseBlock,
      ps2mcStandardPagesPerCard
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
      if (rawIconSys != null) {
        final ic = IconSys.unpack(rawIconSys);
        if (ic != null) {
          final (t1, t2) = ic.title();
          final combined = '$t1 $t2'.trim();
          if (combined.isNotEmpty) title = combined;
        }
      }
      result.add(Ps2SaveInfo(
        dirName: ent.name,
        title: title,
        sizeBytes: _mc.dirSize('/${ent.name}'),
        modified: ent.modified.toLocalDateTime(),
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

  /// Import a save from bytes (auto-detect format).
  void importSave(Uint8List data, {bool overwrite = false}) {
    final save = Ps2Save.fromBytes(data);
    _mc.importSaveFile(save._sf, overwrite);
  }

  /// Delete a save directory and all its files.
  void deleteSave(String dirName) => _mc.rmdir(dirName);

  void close() => _mc.close();
}
