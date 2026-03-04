// ps2card_io.dart
//
// Pluggable I/O backend for PS2 memory card images.
// Decouples Ps2MemoryCard from dart:io so the core logic can run
// against in-memory buffers (tests, WASM) as well as real files.

import 'dart:io';
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Abstract interface
// ---------------------------------------------------------------------------

/// Minimal sequential-access I/O interface used by Ps2MemoryCard.
abstract interface class Ps2CardIo {
  void setPosition(int offset);
  Uint8List read(int length);
  void write(Uint8List data);
  void flush();
  void close();
}

// ---------------------------------------------------------------------------
// FileCardIo — dart:io backed (desktop / CLI)
// ---------------------------------------------------------------------------

class FileCardIo implements Ps2CardIo {
  final RandomAccessFile _f;
  FileCardIo(this._f);

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

// ---------------------------------------------------------------------------
// MemoryCardIo — Uint8List backed (tests, WASM)
// ---------------------------------------------------------------------------

class MemoryCardIo implements Ps2CardIo {
  Uint8List _data;
  int _pos = 0;

  MemoryCardIo(this._data);

  /// Create a zeroed buffer of [size] bytes (e.g. for formatting a blank card).
  MemoryCardIo.blank(int size) : _data = Uint8List(size);

  /// Current contents as an unmodifiable view.
  Uint8List get bytes => _data;

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
