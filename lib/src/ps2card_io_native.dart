// ps2card_io_native.dart
//
// dart:io-backed I/O backends for native (desktop / CLI) use.
// Depends on dart:io — not available on web platforms.
//
// Web-safe interfaces (Ps2CardIo, SaveIo) and in-memory backends
// (MemoryCardIo, MemorySaveIo) live in ps2card_io.dart.

import 'dart:io';
import 'dart:typed_data';

import 'ps2card_io.dart';
import 'ps2mc.dart';

/// dart:io backed card I/O (desktop / CLI).
class FileCardIo implements Ps2CardIo {
  final RandomAccessFile _f;
  FileCardIo(this._f);

  /// Open a card file by path.  [creating] = true uses write mode (truncate).
  factory FileCardIo.fromPath(String path, {bool creating = false}) {
    final mode = creating ? FileMode.write : FileMode.append;
    return FileCardIo(File(path).openSync(mode: mode));
  }

  @override
  void setPosition(int offset) => _f.setPositionSync(offset);

  @override
  Uint8List read(int length) => _f.readSync(length);

  @override
  void write(Uint8List data) => _f.writeFromSync(data);

  @override
  void flush() {} // dart:io RAF has no explicit flush; OS handles it

  @override
  void close() => _f.closeSync();
}

/// Open or create a [Ps2MemoryCard] from a file path (native only).
Ps2MemoryCard openCardFile(String path,
    {bool ignoreEcc = false, List<int>? formatParams}) {
  final io = FileCardIo.fromPath(path, creating: formatParams != null);
  return Ps2MemoryCard.fromIo(io,
      filePath: path, ignoreEcc: ignoreEcc, formatParams: formatParams);
}

/// dart:io backed save I/O (desktop / CLI).
class FileSaveIo implements SaveIo {
  final RandomAccessFile _f;
  FileSaveIo(this._f);

  @override
  Uint8List read(int n) => _f.readSync(n);

  @override
  void write(List<int> data) => _f.writeFromSync(data);

  @override
  void setPosition(int offset) => _f.setPositionSync(offset);

  @override
  int position() => _f.positionSync();

  @override
  int length() => _f.lengthSync();

  @override
  void flush() => _f.flushSync();
}
