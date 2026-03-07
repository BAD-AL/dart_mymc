// ps2card_io.dart
//
// Web-safe I/O interfaces and in-memory backends for PS2 memory card images
// and save files.  No dart:io dependency — runs on all Dart platforms.
//
// For native (desktop/CLI) file-backed I/O see ps2card_io_native.dart,
// which provides FileCardIo and FileSaveIo using dart:io.

import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Ps2CardIo — card image I/O (used by Ps2MemoryCard)
// ---------------------------------------------------------------------------

/// Minimal sequential-access I/O interface used by Ps2MemoryCard.
abstract interface class Ps2CardIo {
  void setPosition(int offset);
  Uint8List read(int length);
  void write(Uint8List data);
  void flush();
  void close();
}

/// In-memory card I/O (tests, WASM).
class MemoryCardIo implements Ps2CardIo {
  Uint8List _data;
  int _pos = 0;

  MemoryCardIo(this._data);

  /// Create a zeroed buffer of [size] bytes (e.g. for formatting a blank card).
  MemoryCardIo.blank(int size) : _data = Uint8List(size);

  /// Returns the current card image as a snapshot.
  Uint8List toBytes() => _data;

  @override
  void setPosition(int offset) {
    if (offset < 0) throw RangeError('negative offset: $offset');
    _pos = offset;
  }

  @override
  Uint8List read(int length) {
    final end = _pos + length;
    if (end > _data.length) {
      // Grow buffer with zeros, like a sparse file.
      final grown = Uint8List(end);
      grown.setAll(0, _data);
      _data = grown;
    }
    final slice = _data.sublist(_pos, end);
    _pos = end;
    return slice;
  }

  @override
  void write(Uint8List data) {
    final end = _pos + data.length;
    if (end > _data.length) {
      final grown = Uint8List(end);
      grown.setAll(0, _data);
      _data = grown;
    }
    _data.setRange(_pos, end, data);
    _pos = end;
  }

  @override
  void flush() {}

  @override
  void close() {}
}

// ---------------------------------------------------------------------------
// SaveIo — save file I/O (used by Ps2SaveFile load/save methods)
// ---------------------------------------------------------------------------

/// Sequential-access I/O interface used by Ps2SaveFile load/save methods.
/// Mirrors the subset of RandomAccessFile used by the save codec.
abstract interface class SaveIo {
  Uint8List read(int length);
  void write(List<int> data);
  void setPosition(int offset);
  int position();
  int length();
  void flush();
}

/// In-memory save I/O (tests, WASM, Ps2Save.fromBytes/toBytes).
class MemorySaveIo implements SaveIo {
  final _buf = <int>[];
  int _pos = 0;

  /// Create empty, or pre-loaded with [initial] bytes.
  MemorySaveIo([List<int>? initial]) {
    if (initial != null) _buf.addAll(initial);
  }

  /// Returns all bytes written so far.
  Uint8List toBytes() => Uint8List.fromList(_buf);

  @override
  Uint8List read(int n) {
    final end = (_pos + n).clamp(0, _buf.length);
    final result = Uint8List.fromList(_buf.sublist(_pos, end));
    _pos = end;
    return result;
  }

  @override
  void write(List<int> data) {
    final needed = _pos + data.length;
    if (needed > _buf.length) {
      _buf.addAll(List.filled(needed - _buf.length, 0));
    }
    for (int i = 0; i < data.length; i++) {
      _buf[_pos + i] = data[i];
    }
    _pos += data.length;
  }

  @override
  void setPosition(int offset) => _pos = offset;

  @override
  int position() => _pos;

  @override
  int length() => _buf.length;

  @override
  void flush() {}
}
