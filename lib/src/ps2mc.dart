// ps2mc.dart
//
// Ported from ps2mc.py by Ross Ridge (Public Domain)
// Manipulate PS2 memory card images.

import 'dart:collection';
import 'dart:typed_data';

import 'ps2card_io.dart';
import 'ps2mc_dir.dart';
import 'ps2mc_ecc.dart';
import 'ps2save.dart';
import 'round.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const String ps2mcMagic = 'Sony PS2 Memory Card Format ';
const int ps2mcFatAllocatedBit = 0x80000000;
const int ps2mcFatChainEnd = 0xFFFFFFFF;
const int ps2mcFatChainEndUnalloc = 0x7FFFFFFF;
const int ps2mcFatClusterMask = 0x7FFFFFFF;
const int ps2mcMaxIndirectFatClusters = 32;
const int ps2mcClusterSize = 1024;
const int ps2mcIndirectFatOffset = 0x2000;

const int ps2mcStandardPageSize = 512;
const int ps2mcStandardPagesPerCard = 16384;
const int ps2mcStandardPagesPerEraseBlock = 16;

// ---------------------------------------------------------------------------
// Exceptions
// ---------------------------------------------------------------------------

class Ps2McError implements Exception {
  final String message;
  final String? filename;
  Ps2McError(this.message, [this.filename]);

  @override
  String toString() {
    if (filename != null) return '$filename: $message';
    return message;
  }
}

class Ps2McCorrupt extends Ps2McError {
  Ps2McCorrupt(super.message, [super.filename]);
}

class Ps2McEccError extends Ps2McCorrupt {
  Ps2McEccError(super.message, [super.filename]);
}

class Ps2McPathNotFound extends Ps2McError {
  Ps2McPathNotFound(String path) : super('path not found', path);
}

class Ps2McFileNotFound extends Ps2McError {
  Ps2McFileNotFound(String path) : super('file not found', path);
}

class Ps2McDirNotFound extends Ps2McError {
  Ps2McDirNotFound(String path) : super('directory not found', path);
}

class Ps2McIoError extends Ps2McError {
  Ps2McIoError(super.message, [super.filename]);
}

class Ps2McNoSpace extends Ps2McIoError {
  Ps2McNoSpace([String? path]) : super('out of space on image', path);
}

// ---------------------------------------------------------------------------
// LRU cache
// ---------------------------------------------------------------------------

class _LruCache<K, V> {
  final int _capacity;
  final _map = LinkedHashMap<K, V>();

  _LruCache(this._capacity);

  V? get(K key) {
    if (!_map.containsKey(key)) return null;
    final value = _map.remove(key) as V;
    _map[key] = value; // move to end (most recent)
    return value;
  }

  /// Add an entry.  Returns the evicted (key, value) pair if capacity exceeded.
  MapEntry<K, V>? add(K key, V value) {
    MapEntry<K, V>? evicted;
    if (_map.containsKey(key)) {
      _map.remove(key);
    } else if (_map.length >= _capacity) {
      final firstKey = _map.keys.first;
      final firstValue = _map.remove(firstKey) as V;
      evicted = MapEntry(firstKey, firstValue);
    }
    _map[key] = value;
    return evicted;
  }

  Iterable<MapEntry<K, V>> get entries => _map.entries;

  void clear() => _map.clear();
}

// ---------------------------------------------------------------------------
// FAT chain
// ---------------------------------------------------------------------------

/// Provides sequential and random access to a file's FAT cluster chain.
class FatChain {
  final int Function(int) _lookupFat;
  final int _first;
  int _offset = 0;
  int? _prev;
  late int _cur;

  FatChain(this._lookupFat, int first)
      : _first = first,
        _cur = first;

  /// Return the cluster number at position [i] in the chain.
  /// Returns [ps2mcFatChainEnd] if [i] is past the end of the chain.
  int operator [](int i) {
    // Cache hit: current or previous position.
    if (i == _offset) return _cur;
    if (i == _offset - 1) {
      assert(_prev != null);
      return _prev!;
    }

    // Rewind to start if going backward.
    int offset;
    int? prev;
    int cur;
    if (i < _offset) {
      if (i == 0) return _first; // fast path; cache not updated
      offset = 0;
      prev = null;
      cur = _first;
    } else {
      offset = _offset;
      prev = _prev;
      cur = _cur;
    }

    // Walk forward to position i.
    int next = ps2mcFatChainEnd;
    while (offset != i) {
      next = _lookupFat(cur);
      if (next == ps2mcFatChainEnd) break;
      if (next & ps2mcFatAllocatedBit != 0) {
        next &= ps2mcFatClusterMask;
      } else {
        // Corrupt: unallocated bit not set.
        next = ps2mcFatChainEnd;
        break;
      }
      offset++;
      prev = cur;
      cur = next;
    }

    _offset = offset;
    _prev = prev;
    _cur = cur;

    // After the loop, next == cur when we reach position i normally.
    return next;
  }

  int get length {
    final savedPrev = _prev;
    final savedCur = _cur;
    final savedOffset = _offset;
    int i = _offset;
    while (this[i] != ps2mcFatChainEnd) i++;
    _prev = savedPrev;
    _cur = savedCur;
    _offset = savedOffset;
    return i;
  }
}

// ---------------------------------------------------------------------------
// Superblock
// ---------------------------------------------------------------------------

class _Superblock {
  final String version; // 12 bytes
  final int pageSize;
  final int pagesPerCluster;
  final int pagesPerEraseBlock;
  final int clustersPerCard;
  final int allocatableClusterOffset;
  final int allocatableClusterEnd;
  final int rootdirFatCluster;
  final int goodBlock1;
  final int goodBlock2;
  final Uint32List indirectFatClusterList; // 32 entries
  final Uint32List badEraseBlockList; // 32 entries

  _Superblock({
    required this.version,
    required this.pageSize,
    required this.pagesPerCluster,
    required this.pagesPerEraseBlock,
    required this.clustersPerCard,
    required this.allocatableClusterOffset,
    required this.allocatableClusterEnd,
    required this.rootdirFatCluster,
    required this.goodBlock1,
    required this.goodBlock2,
    required this.indirectFatClusterList,
    required this.badEraseBlockList,
  });

  // Superblock binary layout: <28s12sHHHHLLLLLL8x128s128sbbxx>
  // Total size: 340 = 0x154 bytes
  static const int rawSize = 0x154;

  static _Superblock? parse(Uint8List data) {
    if (data.length < rawSize) return null;
    final magic = String.fromCharCodes(data.sublist(0, 28));
    if (magic != ps2mcMagic) return null;

    final bd = ByteData.sublistView(data, 0, rawSize);
    final version =
        String.fromCharCodes(data.sublist(28, 40)).replaceAll('\x00', '');

    return _Superblock(
      version: version,
      pageSize: bd.getUint16(40, Endian.little),
      pagesPerCluster: bd.getUint16(42, Endian.little),
      pagesPerEraseBlock: bd.getUint16(44, Endian.little),
      // offset 46: unknown uint16 (0xFF00) — skipped
      clustersPerCard: bd.getUint32(48, Endian.little),
      allocatableClusterOffset: bd.getUint32(52, Endian.little),
      allocatableClusterEnd: bd.getUint32(56, Endian.little),
      rootdirFatCluster: bd.getUint32(60, Endian.little),
      goodBlock1: bd.getUint32(64, Endian.little),
      goodBlock2: bd.getUint32(68, Endian.little),
      // offset 72: 8 bytes padding
      indirectFatClusterList: Uint32List.sublistView(data, 80, 80 + 128),
      badEraseBlockList: Uint32List.sublistView(data, 208, 208 + 128),
    );
  }

  Uint8List pack() {
    final data = Uint8List(rawSize);
    final bd = ByteData.sublistView(data);

    // magic (28 bytes)
    for (int i = 0; i < 28; i++) data[i] = ps2mcMagic.codeUnitAt(i);
    // version (12 bytes, zero-padded)
    final vb = version.codeUnits;
    for (int i = 0; i < vb.length && i < 12; i++) data[28 + i] = vb[i];

    bd.setUint16(40, pageSize, Endian.little);
    bd.setUint16(42, pagesPerCluster, Endian.little);
    bd.setUint16(44, pagesPerEraseBlock, Endian.little);
    bd.setUint16(46, 0xFF00, Endian.little); // unknown field
    bd.setUint32(48, clustersPerCard, Endian.little);
    bd.setUint32(52, allocatableClusterOffset, Endian.little);
    bd.setUint32(56, allocatableClusterEnd, Endian.little);
    bd.setUint32(60, rootdirFatCluster, Endian.little);
    bd.setUint32(64, goodBlock1, Endian.little);
    bd.setUint32(68, goodBlock2, Endian.little);
    // offset 72..79: padding (zeroes)

    // indirect FAT cluster list (128 bytes at offset 80)
    final ifcBytes = indirectFatClusterList.buffer.asUint8List(
        indirectFatClusterList.offsetInBytes, 128);
    data.setRange(80, 80 + 128, ifcBytes);

    // bad erase block list (128 bytes at offset 208)
    final bebBytes = badEraseBlockList.buffer
        .asUint8List(badEraseBlockList.offsetInBytes, 128);
    data.setRange(208, 208 + 128, bebBytes);

    data[336] = 2;
    data[337] = 0x2B;
    // offset 338..339: padding

    return data;
  }
}

// ---------------------------------------------------------------------------
// Ps2McFile — file-like object for a file inside the memory card
// ---------------------------------------------------------------------------

typedef _DirLoc = (int cluster, int index);

class Ps2McFile {
  final Ps2MemoryCard _mc;
  int length;
  int _firstCluster;
  final _DirLoc? dirloc;
  FatChain? _fatChain;
  int _pos = 0;
  Uint8List? _buffer;
  int? _bufferCluster;
  final String name;
  bool closed = false;
  final bool _write; // true if mode allows writing
  final bool _append;

  Ps2McFile(this._mc, this.dirloc, this._firstCluster, this.length,
      String mode, String? name)
      : name = name ?? '<ps2mc_file>',
        _write = mode.isNotEmpty &&
            (mode[0] == 'w' || mode[0] == 'a' || mode.contains('+')),
        _append = mode.isNotEmpty && mode[0] == 'a';

  // ---- internal cluster I/O ----

  int _findFileCluster(int n) {
    _fatChain ??= _mc._fatChain(_firstCluster);
    return _fatChain![n];
  }

  Uint8List? _readFileCluster(int n) {
    if (n == _bufferCluster) return _buffer;
    final cluster = _findFileCluster(n);
    if (cluster == ps2mcFatChainEnd) return null;
    _buffer = _mc._readAllocatableCluster(cluster);
    _bufferCluster = n;
    return _buffer;
  }

  void _invalidateBuffer() {
    _buffer = null;
    _bufferCluster = null;
  }

  void updateNotify(int firstCluster, int newLength) {
    if (_firstCluster != firstCluster) {
      _firstCluster = firstCluster;
      _fatChain = null;
    }
    length = newLength;
    _invalidateBuffer();
  }

  // ---- public file interface ----

  Uint8List read([int? size]) {
    if (closed) throw StateError('$name: file is closed');
    final pos = _pos;
    final clusterSize = _mc.clusterSize;
    int readSize = size ?? length;
    readSize = readSize.clamp(0, length - pos);
    final result = Uint8List(readSize);
    int written = 0;
    int cur = pos;
    while (written < readSize) {
      final off = cur % clusterSize;
      final l = (clusterSize - off).clamp(0, readSize - written);
      final buf = _readFileCluster(cur ~/ clusterSize);
      if (buf == null) break;
      result.setRange(written, written + l, buf, off);
      cur += l;
      written += l;
    }
    _pos = cur;
    return result.sublist(0, written);
  }

  int? _extendFile(int n) {
    final cluster = _mc.allocateCluster();
    if (cluster == null) return null;
    if (n == 0) {
      _firstCluster = cluster;
      _fatChain = null;
      _mc.updateDirent(dirloc!, this, cluster, null, false);
    } else {
      final prev = _findFileCluster(n - 1);
      _mc.setFat(prev, cluster | ps2mcFatAllocatedBit);
    }
    return cluster;
  }

  bool _writeFileCluster(int n, Uint8List buf) {
    final cluster = _findFileCluster(n);
    if (cluster != ps2mcFatChainEnd) {
      _mc._writeAllocatableCluster(cluster, buf);
      _buffer = buf;
      _bufferCluster = n;
      return true;
    }

    final clusterSize = _mc.clusterSize;
    final fileClusterEnd = divRoundUp(length, clusterSize);

    for (int i = fileClusterEnd; i < n; i++) {
      final newCluster = _extendFile(i);
      if (newCluster == null) {
        if (i != fileClusterEnd) {
          length = (i - 1) * clusterSize;
          _mc.updateDirent(dirloc!, this, null, length, true);
        }
        return false;
      }
      _mc._writeAllocatableCluster(newCluster, Uint8List(clusterSize));
    }

    final newCluster = _extendFile(n);
    if (newCluster == null) return false;

    _mc._writeAllocatableCluster(newCluster, buf);
    _buffer = buf;
    _bufferCluster = n;
    return true;
  }

  void write(Uint8List out, {bool setModified = true}) {
    if (closed) throw StateError('$name: file is closed');
    if (!_write && !_append) {
      throw Ps2McIoError('file not opened for writing', name);
    }

    final clusterSize = _mc.clusterSize;
    int pos = _append ? length : _pos;
    int size = out.length;
    int i = 0;

    while (size > 0) {
      final cluster = pos ~/ clusterSize;
      final off = pos % clusterSize;
      final l = (clusterSize - off) < size ? (clusterSize - off) : size;
      Uint8List buf;
      if (l == clusterSize) {
        buf = Uint8List.fromList(out.sublist(i, i + l));
      } else {
        final existing = _readFileCluster(cluster);
        buf = Uint8List(clusterSize);
        if (existing != null) buf.setRange(0, clusterSize, existing);
        buf.setRange(off, off + l, out, i);
      }
      if (!_writeFileCluster(cluster, buf)) {
        throw Ps2McNoSpace(name);
      }
      pos += l;
      _pos = pos;
      int? newLength;
      if (pos > length) {
        newLength = length = pos;
      }
      _mc.updateDirent(dirloc!, this, null, newLength, setModified);
      i += l;
      size -= l;
    }
  }

  void seek(int offset, [int whence = 0]) {
    if (closed) throw StateError('$name: file is closed');
    int base;
    if (whence == 1) {
      base = _pos;
    } else if (whence == 2) {
      base = length;
    } else {
      base = 0;
    }
    _pos = (base + offset).clamp(0, length);
  }

  int tell() {
    if (closed) throw StateError('$name: file is closed');
    return _pos;
  }

  void close() {
    if (!closed && _mc._openFiles != null && dirloc != null) {
      _mc._notifyClosed(dirloc!, this);
    }
    closed = true;
    _fatChain = null;
    _buffer = null;
  }
}

// ---------------------------------------------------------------------------
// Ps2McDirectory — iterable directory object
// ---------------------------------------------------------------------------

class Ps2McDirectory with Iterable<PS2DirEntry> {
  final Ps2McFile _f;

  Ps2McDirectory(Ps2MemoryCard mc, _DirLoc? dirloc, int firstCluster,
      int length, String mode, String? name)
      : _f = Ps2McFile(mc, dirloc, firstCluster,
            length * ps2mcDirentLength, mode, name);

  int get entryCount => _f.length ~/ ps2mcDirentLength;

  PS2DirEntry operator [](int index) {
    seek(index);
    final raw = _f.read(ps2mcDirentLength);
    if (raw.length != ps2mcDirentLength) {
      throw RangeError('Directory index $index out of range');
    }
    return PS2DirEntry.unpack(raw);
  }

  /// Merge non-null fields from [newEnt] into the entry at [index].
  /// Fields that are "sentinel" values (mode == -1 means "don't change name")
  /// follow Python's convention: pass a copyWith() with the changed fields.
  /// This operator only writes if the entry exists.
  void mergeEnt(int index, PS2DirEntry newEnt) {
    final ent = this[index];
    if (!ent.exists) return;
    // Mirror Python's __setitem__: only update mode (preserving FILE/DIR/EXISTS),
    // unused, created, modified, attr.  Do NOT touch length, fatCluster, parentEntry.
    final mergedMode = (newEnt.mode & ~(dfFile | dfDir | dfExists)) |
        (ent.mode & (dfFile | dfDir | dfExists));
    final merged = ent.copyWith(
      mode: mergedMode,
      unused: newEnt.unused,
      created: newEnt.created,
      modified: newEnt.modified,
      attr: newEnt.attr,
    );
    writeRawEnt(index, merged, setModified: false);
  }

  void writeRawEnt(int index, PS2DirEntry ent, {bool setModified = true}) {
    seek(index);
    _f.write(ent.pack(), setModified: setModified);
  }

  void seek(int offset) {
    _f.seek(offset * ps2mcDirentLength);
  }

  int tell() => _f.tell() ~/ ps2mcDirentLength;

  @override
  Iterator<PS2DirEntry> get iterator => _Ps2DirIterator(this);

  void close() {
    _f.close();
  }
}

class _Ps2DirIterator implements Iterator<PS2DirEntry> {
  final Ps2McDirectory _dir;
  PS2DirEntry? _current;
  int _index = 0;
  final int _count;

  _Ps2DirIterator(this._dir) : _count = _dir.entryCount {
    _dir.seek(0);
  }

  @override
  PS2DirEntry get current => _current!;

  @override
  bool moveNext() {
    if (_index >= _count) return false;
    _current = _dir[_index];
    _index++;
    return true;
  }
}

// Subclass that keeps the root directory alive (close() is a no-op).
class _RootDirectory extends Ps2McDirectory {
  _RootDirectory(Ps2MemoryCard mc, _DirLoc dirloc, int firstCluster,
      int length)
      : super(mc, dirloc, firstCluster, length, 'r+b', '/');

  @override
  void close() {} // intentionally no-op; use realClose()

  void realClose() => super.close();
}

// ---------------------------------------------------------------------------
// Ps2MemoryCard — the main filesystem driver
// ---------------------------------------------------------------------------

/// A DirLoc identifies a specific directory entry: (clusterOfParentDir, indexInThatDir).
/// The root directory's entry is at (0, 0) within its own first cluster.

class Ps2MemoryCard {
  // ---- fields from superblock ----
  late String version;
  late int pageSize;
  late int pagesPerCluster;
  late int pagesPerEraseBlock;
  late int clustersPerCard;
  late int allocatableClusterOffset;
  late int allocatableClusterEnd;
  late int rootdirFatCluster;
  late int goodBlock1;
  late int goodBlock2;
  late Uint32List indirectFatClusterList;
  late Uint32List badEraseBlockList;

  // ---- derived fields ----
  late int spareSize;
  late int rawPageSize;
  late int clusterSize;
  late int entriesPerCluster;
  late int allocatableClusterLimit;

  // ---- runtime state ----
  late Ps2CardIo _io;
  late String _filePath;
  bool ignoreEcc = false;
  bool modified = false;
  _DirLoc curdir = (0, 0);
  _RootDirectory? _rootdir;
  Map<_DirLoc, (Ps2McDirectory?, Set<Ps2McFile>)>? _openFiles = {};
  final _LruCache<int, (Uint32List, bool)> _fatCache = _LruCache(12);
  final _LruCache<int, (Uint8List, bool)> _allocClusterCache = _LruCache(64);
  int _fatCursor = 0;

  // ---------------------------------------------------------------------------
  // Constructor / open
  // ---------------------------------------------------------------------------

  /// Open or create a card from a file path.
  factory Ps2MemoryCard(String path,
      {bool ignoreEcc = false, List<int>? formatParams}) {
    final io = FileCardIo.fromPath(path, creating: formatParams != null);
    return Ps2MemoryCard.fromIo(io,
        filePath: path, ignoreEcc: ignoreEcc, formatParams: formatParams);
  }

  /// Open or create a card from any [Ps2CardIo] backend.
  Ps2MemoryCard.fromIo(Ps2CardIo io,
      {String? filePath,
      bool ignoreEcc = false,
      List<int>? formatParams}) {
    _io = io;
    _filePath = filePath ?? '<memory>';
    _openFiles = {};

    _io.setPosition(0);
    final headerBytes = _io.read(_Superblock.rawSize);

    if (headerBytes.length != _Superblock.rawSize ||
        !_startsWithMagic(headerBytes)) {
      if (formatParams == null) {
        throw Ps2McCorrupt('Not a PS2 memory card image', _filePath);
      }
      _format(formatParams);
    } else {
      final sb = _Superblock.parse(headerBytes)!;
      _loadSuperblock(sb);

      // Auto-detect ECC: try to read page 0; if it throws EccError,
      // assume no ECC (spare_size = 0).
      this.ignoreEcc = false;
      try {
        _readPage(0);
        this.ignoreEcc = ignoreEcc;
      } on Ps2McEccError {
        spareSize = 0;
        rawPageSize = pageSize;
        this.ignoreEcc = true;
      }
    }

    // Sanity check: root directory must have "." and ".." as first entries.
    final root = _directoryByLoc(null, 0, 1);
    final dot = root[0];
    final dotdot = root[1];
    root.close();
    if (dot.name != '.' ||
        dotdot.name != '..' ||
        !modeIsDir(dot.mode) ||
        !modeIsDir(dotdot.mode)) {
      throw Ps2McCorrupt('Root directory damaged.', _filePath);
    }

    curdir = (0, 0);
  }

  static bool _startsWithMagic(Uint8List data) {
    if (data.length < ps2mcMagic.length) return false;
    for (int i = 0; i < ps2mcMagic.length; i++) {
      if (data[i] != ps2mcMagic.codeUnitAt(i)) return false;
    }
    return true;
  }

  void _loadSuperblock(_Superblock sb) {
    version = sb.version;
    pageSize = sb.pageSize;
    pagesPerCluster = sb.pagesPerCluster;
    pagesPerEraseBlock = sb.pagesPerEraseBlock;
    clustersPerCard = sb.clustersPerCard;
    allocatableClusterOffset = sb.allocatableClusterOffset;
    allocatableClusterEnd = sb.allocatableClusterEnd;
    rootdirFatCluster = sb.rootdirFatCluster;
    goodBlock1 = sb.goodBlock1;
    goodBlock2 = sb.goodBlock2;
    indirectFatClusterList = sb.indirectFatClusterList;
    badEraseBlockList = sb.badEraseBlockList;
    _calculateDerived();
  }

  void _calculateDerived() {
    spareSize = divRoundUp(pageSize, 128) * 4;
    rawPageSize = pageSize + spareSize;
    clusterSize = pageSize * pagesPerCluster;
    entriesPerCluster = pageSize * pagesPerCluster ~/ 4;

    final limit = ((goodBlock2 < goodBlock1 ? goodBlock2 : goodBlock1) *
            pagesPerEraseBlock ~/
            pagesPerCluster) -
        allocatableClusterOffset;
    allocatableClusterLimit = limit;
  }

  // ---------------------------------------------------------------------------
  // Low-level page/cluster I/O
  // ---------------------------------------------------------------------------

  Uint8List _readPage(int n) {
    _io.setPosition(rawPageSize * n);
    final page = _io.read(pageSize);
    if (page.length != pageSize) {
      throw Ps2McCorrupt(
          'Attempted to read past EOF (page 0x${n.toRadixString(16)})',
          _filePath);
    }
    if (ignoreEcc) return page;
    final spare = _io.read(spareSize);
    if (spare.length != spareSize) {
      throw Ps2McCorrupt(
          'Attempted to read past EOF (spare of page 0x${n.toRadixString(16)})',
          _filePath);
    }
    final result = eccCheckPage(page, spare);
    if (result.status == eccCheckFailed) {
      throw Ps2McEccError(
          'Unrecoverable ECC error (page $n)', _filePath);
    }
    return result.page;
  }

  void _writePage(int n, Uint8List buf) {
    if (buf.length != pageSize) {
      throw Ps2McError('internal error: write_page size mismatch');
    }
    _io.setPosition(rawPageSize * n);
    _io.write(buf);
    modified = true;
    if (spareSize != 0) {
      final eccs = eccCalculatePage(buf);
      final spareData = Uint8List(spareSize);
      for (int i = 0; i < eccs.length; i++) {
        spareData[i * 3] = eccs[i][0];
        spareData[i * 3 + 1] = eccs[i][1];
        spareData[i * 3 + 2] = eccs[i][2];
      }
      _io.write(spareData);
    }
  }

  Uint8List _readCluster(int n) {
    if (spareSize == 0) {
      // No ECC: clusters are packed tightly.
      _io.setPosition(clusterSize * n);
      return _io.read(clusterSize);
    }
    // With ECC: read page-by-page.
    final base = n * pagesPerCluster;
    final result = Uint8List(clusterSize);
    for (int i = 0; i < pagesPerCluster; i++) {
      final page = _readPage(base + i);
      result.setRange(i * pageSize, (i + 1) * pageSize, page);
    }
    return result;
  }

  void _writeCluster(int n, Uint8List buf) {
    if (spareSize == 0) {
      _io.setPosition(clusterSize * n);
      _io.write(buf);
      return;
    }
    final base = n * pagesPerCluster;
    for (int i = 0; i < pagesPerCluster; i++) {
      _writePage(base + i, buf.sublist(i * pageSize, (i + 1) * pageSize));
    }
  }

  // ---------------------------------------------------------------------------
  // FAT cache
  // ---------------------------------------------------------------------------

  void _addFatClusterToCache(int n, Uint32List fat, bool dirty) {
    final evicted = _fatCache.add(n, (fat, dirty));
    if (evicted != null) {
      final (evictedFat, evictedDirty) = evicted.value;
      if (evictedDirty) _writeCluster(evicted.key, _packFat(evictedFat));
    }
  }

  Uint32List _readFatClusterRaw(int n) {
    final cached = _fatCache.get(n);
    if (cached != null) return cached.$1;
    final raw = _readCluster(n);
    final fat = Uint32List.sublistView(raw);
    _addFatClusterToCache(n, fat, false);
    return fat;
  }

  void _writeFatCluster(int n, Uint32List fat) {
    _addFatClusterToCache(n, fat, true);
  }

  static Uint8List _packFat(Uint32List fat) {
    return Uint8List.sublistView(fat);
  }

  void flushFatCache() {
    for (final entry in _fatCache.entries.toList()) {
      final (fat, dirty) = entry.value;
      if (dirty) {
        _writeCluster(entry.key, _packFat(fat));
        _fatCache.add(entry.key, (fat, false));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Allocatable cluster cache
  // ---------------------------------------------------------------------------

  void _addAllocClusterToCache(int n, Uint8List buf, bool dirty) {
    final evicted = _allocClusterCache.add(n, (buf, dirty));
    if (evicted != null) {
      final (evBuf, evDirty) = evicted.value;
      if (evDirty) {
        _writeCluster(evicted.key + allocatableClusterOffset, evBuf);
      }
    }
  }

  Uint8List _readAllocatableCluster(int n) {
    final cached = _allocClusterCache.get(n);
    if (cached != null) return cached.$1;
    final buf = _readCluster(n + allocatableClusterOffset);
    _addAllocClusterToCache(n, buf, false);
    return buf;
  }

  void _writeAllocatableCluster(int n, Uint8List buf) {
    _addAllocClusterToCache(n, buf, true);
  }

  void _flushAllocClusterCache() {
    for (final entry in _allocClusterCache.entries.toList()) {
      final (buf, dirty) = entry.value;
      if (dirty) {
        _writeCluster(entry.key + allocatableClusterOffset, buf);
        _allocClusterCache.add(entry.key, (buf, false));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // FAT access
  // ---------------------------------------------------------------------------

  (Uint32List fat, int offset, int cluster) _readFat(int n) {
    if (n < 0 || n >= allocatableClusterEnd) {
      throw Ps2McIoError('FAT cluster index out of range ($n)');
    }
    final offset = n % entriesPerCluster;
    final fatClusterIdx = n ~/ entriesPerCluster;
    final dblOffset = fatClusterIdx ~/ entriesPerCluster;
    final indirectOffset = fatClusterIdx % entriesPerCluster;
    final indirectCluster = indirectFatClusterList[dblOffset];
    final indirectFat = _readFatClusterRaw(indirectCluster);
    final cluster = indirectFat[indirectOffset];
    return (_readFatClusterRaw(cluster), offset, cluster);
  }

  int lookupFat(int n) {
    final (fat, offset, _) = _readFat(n);
    return fat[offset];
  }

  void setFat(int n, int value) {
    final (fat, offset, cluster) = _readFat(n);
    fat[offset] = value;
    _writeFatCluster(cluster, fat);
  }

  /// Read the FAT cluster at FAT-cluster index [n] (not allocatable cluster
  /// index).  Returns the fat array and the physical cluster number.
  /// Mirrors Python's read_fat_cluster(n).
  (Uint32List fat, int cluster) _readFatClusterByIdx(int n) {
    final indirectOffset = n % entriesPerCluster;
    final dblOffset = n ~/ entriesPerCluster;
    final indirectCluster = indirectFatClusterList[dblOffset];
    final indirectFat = _readFatClusterRaw(indirectCluster);
    final cluster = indirectFat[indirectOffset];
    return (_readFatClusterRaw(cluster), cluster);
  }

  /// Allocate a free cluster and mark it as chain-end.  Returns the cluster
  /// index, or null if the card is full.
  int? allocateCluster() {
    final epc = entriesPerCluster;
    final end = divRoundUp(allocatableClusterLimit, epc);
    final remainder = allocatableClusterLimit % epc;

    while (_fatCursor < end) {
      final (fat, cluster) = _readFatClusterByIdx(_fatCursor);
      final limit =
          (_fatCursor == end - 1 && remainder != 0) ? remainder : epc;
      // Find minimum value in range (Python uses min() to find a free slot
      // quickly since unallocated clusters have the high bit clear).
      int minVal = fat[0];
      for (int i = 1; i < limit; i++) {
        if (fat[i] < minVal) minVal = fat[i];
      }
      if ((minVal & ps2mcFatAllocatedBit) == 0) {
        // Find the index of the free slot.
        int offset = 0;
        for (int i = 0; i < limit; i++) {
          if (fat[i] == minVal) {
            offset = i;
            break;
          }
        }
        fat[offset] = ps2mcFatChainEnd;
        _writeFatCluster(cluster, fat);
        return _fatCursor * epc + offset;
      }
      _fatCursor++;
    }
    return null;
  }

  FatChain _fatChain(int firstCluster) =>
      FatChain(lookupFat, firstCluster);

  // ---------------------------------------------------------------------------
  // Directory helpers
  // ---------------------------------------------------------------------------

  /// Open a directory by (cluster, entryCount).  Mirrors ps2mc._directory().
  Ps2McDirectory _directoryByLoc(
      _DirLoc? dirloc, int firstCluster, int length,
      {String mode = 'rb', String? name}) {
    if (firstCluster != 0) {
      return Ps2McDirectory(this, dirloc, firstCluster, length, mode, name);
    }
    // Root directory (firstCluster == 0).
    final resolvedDirloc = dirloc ?? (0, 0);
    assert(resolvedDirloc == (0, 0));

    if (_rootdir != null) return _rootdir!;

    final root = _RootDirectory(this, resolvedDirloc, 0, length);
    // Verify length matches the "." entry.
    final actualLength = root[0].length;
    if (actualLength != length) {
      root.realClose();
      final root2 = _RootDirectory(this, resolvedDirloc, 0, actualLength);
      _rootdir = root2;
      return root2;
    }
    _rootdir = root;
    return root;
  }

  _DirLoc _getParentDirLoc(_DirLoc dirloc) {
    final cluster = _readAllocatableCluster(dirloc.$1);
    final ent = PS2DirEntry.unpack(cluster.sublist(0, ps2mcDirentLength));
    return (ent.fatCluster, ent.parentEntry);
  }

  PS2DirEntry _dirLocToEnt(_DirLoc dirloc) {
    final dir = _directoryByLoc(null, dirloc.$1, dirloc.$2 + 1,
        name: '_dirLocToEnt temp');
    final ent = dir[dirloc.$2];
    dir.close();
    return ent;
  }

  Ps2McDirectory _opendirDirLoc(_DirLoc dirloc, {String mode = 'rb'}) {
    final ent = _dirLocToEnt(dirloc);
    return _directoryByLoc(dirloc, ent.fatCluster, ent.length,
        mode: mode, name: '_opendir temp');
  }

  Ps2McDirectory _opendirParentDirLoc(_DirLoc dirloc, {String mode = 'rb'}) {
    return _opendirDirLoc(_getParentDirLoc(dirloc), mode: mode);
  }

  // ---------------------------------------------------------------------------
  // Open-file registry (for write notifications)
  // ---------------------------------------------------------------------------

  void _notifyClosed(_DirLoc dirloc, Ps2McFile thisFile) {
    final registry = _openFiles;
    if (registry == null) return;
    final entry = registry[dirloc];
    if (entry == null) return;
    flush();
    final (dir, files) = entry;
    files.remove(thisFile);
    if (files.isEmpty) {
      dir?.close();
      registry.remove(dirloc);
    }
  }

  // ---------------------------------------------------------------------------
  // Path resolution
  // ---------------------------------------------------------------------------

  ({_DirLoc? dirloc, PS2DirEntry ent, bool isDir}) pathSearch(
      String pathname) {
    if (pathname.isEmpty) {
      return (dirloc: null, ent: _emptyEnt(''), isDir: false);
    }

    final (components, relative, _) = _pathnameSplit(pathname);

    _DirLoc dirloc = relative ? curdir : (0, 0);

    late PS2DirEntry ent;
    Ps2McDirectory? dir;

    if (dirloc == (0, 0)) {
      final rootRaw = _readAllocatableCluster(0);
      ent = PS2DirEntry.unpack(rootRaw.sublist(0, ps2mcDirentLength));
      dir = _directoryByLoc(dirloc, 0, ent.length, name: '_pathSearch temp');
    } else {
      ent = _dirLocToEnt(dirloc);
      dir = _directoryByLoc(dirloc, ent.fatCluster, ent.length,
          name: '_pathSearch temp');
    }

    for (final s in components) {
      if (dir == null) {
        return (
          dirloc: null,
          ent: _emptyEnt(s),
          isDir: false,
        );
      }

      if (s == '.') continue;

      if (s == '..') {
        final dotEnt = dir[0];
        dir.close();
        dirloc = (dotEnt.fatCluster, dotEnt.parentEntry);
        ent = _dirLocToEnt(dirloc);
        dir = _directoryByLoc(dirloc, ent.fatCluster, ent.length,
            name: '_pathSearch temp');
        continue;
      }

      final dirCluster = ent.fatCluster;
      final (foundIdx, foundEnt) = _searchDirectory(dir, s);
      dir.close();
      dir = null;

      if (foundEnt == null) {
        ent = _emptyEnt(s);
        continue;
      }

      ent = foundEnt;
      dirloc = (dirCluster, foundIdx!);

      if (modeIsDir(ent.mode)) {
        dir = _directoryByLoc(dirloc, ent.fatCluster, ent.length,
            name: '_pathSearch temp');
      }
    }

    final isDir = dir != null;
    dir?.close();

    if (!ent.exists && components.isNotEmpty) {
      ent = _emptyEnt(components.last);
    }

    return (dirloc: dirloc, ent: ent, isDir: isDir);
  }

  static PS2DirEntry _emptyEnt(String name) => PS2DirEntry(
        mode: 0,
        length: 0,
        created: const PS2Tod(0, 0, 0, 1, 1, 2000),
        fatCluster: 0,
        parentEntry: 0,
        modified: const PS2Tod(0, 0, 0, 1, 1, 2000),
        name: name,
      );

  (List<String> components, bool relative, bool trailingSlash)
      _pathnameSplit(String pathname) {
    if (pathname.isEmpty) return ([], false, false);
    final parts = pathname.split('/');
    final components =
        parts.where((p) => p.isNotEmpty).toList();
    return (components, parts.first.isNotEmpty, parts.last.isEmpty);
  }

  (int? index, PS2DirEntry? ent) _searchDirectory(
      Ps2McDirectory dir, String name) {
    final count = dir.entryCount;
    final start = (dir.tell() - 1).clamp(0, count - 1);
    for (int i = start; i < count; i++) {
      final ent = dir[i];
      if (ent.name == name && ent.exists) return (i, ent);
    }
    for (int i = 0; i < start; i++) {
      final ent = dir[i];
      if (ent.name == name && ent.exists) return (i, ent);
    }
    return (null, null);
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  Ps2McDirectory dirOpen(String filename, {String mode = 'rb'}) {
    final result = pathSearch(filename);
    if (result.dirloc == null) throw Ps2McPathNotFound(filename);
    if (!result.ent.exists) throw Ps2McDirNotFound(filename);
    if (!result.isDir) throw Ps2McIoError('not a directory', filename);
    return _directoryByLoc(result.dirloc, result.ent.fatCluster,
        result.ent.length, mode: mode, name: filename);
  }

  Ps2McFile open(String filename, {String mode = 'r'}) {
    var result = pathSearch(filename);
    if (result.dirloc == null) throw Ps2McPathNotFound(filename);
    if (result.isDir) throw Ps2McIoError('not a regular file', filename);
    if (!result.ent.exists) {
      if (!mode.startsWith('w') && !mode.startsWith('a')) {
        throw Ps2McFileNotFound(filename);
      }
      // Create the file.
      final name = result.ent.name;
      final (newDirloc, newEnt) = createDirEntry(
          result.dirloc!, name, dfFile | dfRwx | df0400);
      flush();
      result = (dirloc: newDirloc, ent: newEnt, isDir: false);
    } else if (mode.startsWith('w')) {
      // Truncate existing file.
      deleteDirloc(result.dirloc!, true, filename);
      result = (
        dirloc: result.dirloc,
        ent: result.ent.copyWith(
            fatCluster: ps2mcFatChainEnd, length: 0),
        isDir: false
      );
    }
    final dirloc = result.dirloc!;
    final f = Ps2McFile(
        this, dirloc, result.ent.fatCluster, result.ent.length, mode, filename);
    _openFiles ??= {};
    if (!_openFiles!.containsKey(dirloc)) {
      _openFiles![dirloc] = (null, {f});
    } else {
      _openFiles![dirloc]!.$2.add(f);
    }
    return f;
  }

  void chdir(String filename) {
    final result = pathSearch(filename);
    if (result.dirloc == null) throw Ps2McPathNotFound(filename);
    if (!result.ent.exists) throw Ps2McDirNotFound(filename);
    if (!result.isDir) throw Ps2McIoError('not a directory', filename);
    curdir = result.dirloc!;
  }

  int? getMode(String filename) {
    final result = pathSearch(filename);
    if (!result.ent.exists) return null;
    return result.ent.mode;
  }

  /// Read the icon.sys file from a directory (if it exists and is valid).
  Uint8List? getIconSys(String dirname) {
    final path = dirname.endsWith('/')
        ? '${dirname}icon.sys'
        : '$dirname/icon.sys';
    final mode = getMode(path);
    if (mode == null || !modeIsFile(mode)) return null;
    final f = open(path);
    final data = f.read(IconSys.size);
    f.close();
    if (data.length == IconSys.size &&
        data[0] == 0x50 && // 'P'
        data[1] == 0x53 && // 'S'
        data[2] == 0x32 && // '2'
        data[3] == 0x44) { // 'D'
      return data;
    }
    return null;
  }

  /// Total size of directory contents in bytes (recursive).
  int dirSize(String dirname) {
    final dir = dirOpen(dirname);
    int length = roundUp(dir.entryCount * ps2mcDirentLength, clusterSize);
    for (final ent in dir) {
      if (ent.isFile) {
        length += roundUp(ent.length, clusterSize);
      } else if (ent.isDir && ent.name != '.' && ent.name != '..') {
        length += dirSize('$dirname/${ent.name}');
      }
    }
    dir.close();
    return length;
  }

  /// Total free space in bytes.
  int getFreeSpace() {
    int free = 0;
    for (int i = 0; i < allocatableClusterEnd; i++) {
      if ((lookupFat(i) & ps2mcFatAllocatedBit) == 0) free++;
    }
    return free * clusterSize;
  }

  /// Total allocatable space in bytes.
  int getAllocatableSpace() => allocatableClusterLimit * clusterSize;

  // ---------------------------------------------------------------------------
  // Glob
  // ---------------------------------------------------------------------------

  List<String> glob(String pattern) {
    final (components, relative, _) = _pathnameSplit(pattern);
    if (components.isEmpty) return [pattern];

    final dirParts = components.sublist(0, components.length - 1);
    final filePat = components.last;

    final dirPath = relative
        ? dirParts.join('/')
        : '/${dirParts.join('/')}';

    Ps2McDirectory dir;
    try {
      dir = dirOpen(dirPath.isEmpty ? '.' : dirPath);
    } catch (_) {
      return [pattern];
    }

    final matches = <String>[];
    for (final ent in dir) {
      if (!ent.exists) continue;
      if (_fnmatch(ent.name, filePat)) {
        final prefix = dirParts.isEmpty ? '' : '${dirParts.join('/')}/';
        matches.add(relative ? '$prefix${ent.name}' : '/$prefix${ent.name}');
      }
    }
    dir.close();
    return matches.isEmpty ? [pattern] : matches;
  }

  static bool _fnmatch(String name, String pattern) {
    // Simple glob: * matches anything, ? matches one character.
    final escaped = RegExp.escape(pattern)
        .replaceAll(r'\*', '.*')
        .replaceAll(r'\?', '.');
    return RegExp('^$escaped\$').hasMatch(name);
  }

  // ---------------------------------------------------------------------------
  // Write operations
  // ---------------------------------------------------------------------------

  /// Update a directory entry, merging only the non-null supplied fields.
  /// Mirrors Python's update_dirent_all().
  void _updateDirentAll(
    _DirLoc dirloc,
    Ps2McFile? thisFile, {
    int? mode,
    int? length,
    PS2Tod? created,
    int? fatCluster,
    PS2Tod? modified,
    int? attr,
  }) {
    final opened = _openFiles?[dirloc];
    Ps2McDirectory? dir;
    Set<Ps2McFile> files;
    if (opened == null) {
      files = {};
      dir = null;
    } else {
      dir = opened.$1;
      files = opened.$2;
    }
    if (dir == null) {
      dir = _opendirParentDirLoc(dirloc, mode: 'r+b');
      if (opened != null) {
        _openFiles![dirloc] = (dir, files);
      }
    }

    final ent = dir[dirloc.$2];
    final isDir = (ent.mode & dfDir) != 0;

    // For directories, caller supplies byte-length; convert to entry count.
    int? actualLength = length;
    if (isDir && thisFile != null && length != null) {
      actualLength = length ~/ ps2mcDirentLength;
    }

    bool changed = false;
    bool modifiedChanged = false;
    bool notify = false;

    if (mode != null && mode != ent.mode) {
      ent.mode = mode;
      changed = true;
    }
    if (actualLength != null && actualLength != ent.length) {
      ent.length = actualLength;
      changed = true;
      notify = true;
    }
    if (created != null) {
      ent.created = created;
      changed = true;
    }
    if (fatCluster != null && fatCluster != ent.fatCluster) {
      ent.fatCluster = fatCluster;
      changed = true;
      notify = true;
    }
    if (modified != null) {
      ent.modified = modified;
      changed = true;
      modifiedChanged = true;
    }
    if (attr != null) {
      ent.attr = attr;
      changed = true;
    }

    if (changed) {
      dir.writeRawEnt(dirloc.$2, ent, setModified: modifiedChanged && !isDir);
    }

    if (notify) {
      for (final f in files) {
        if (f != thisFile) {
          f.updateNotify(ent.fatCluster, ent.length);
        }
      }
    }

    if (opened == null) {
      dir.close();
    }
  }

  /// Update fat_cluster and/or length of a dir entry.  Mirrors Python's
  /// update_dirent().
  void updateDirent(_DirLoc dirloc, Ps2McFile thisFile, int? newFirstCluster,
      int? newLength, bool setModified) {
    PS2Tod? modified;
    if (setModified) {
      modified = todNow();
    } else {
      if (newFirstCluster == null && newLength == null) return;
      modified = null;
    }
    _updateDirentAll(dirloc, thisFile,
        length: newLength,
        fatCluster: newFirstCluster,
        modified: modified);
  }

  /// Create a new directory entry inside the directory at [parentDirloc].
  /// Returns the dirloc and the new entry.
  (_DirLoc, PS2DirEntry) createDirEntry(
      _DirLoc parentDirloc, String name, int mode) {
    if (name.isEmpty) throw Ps2McFileNotFound(name);

    final dirEnt = _dirLocToEnt(parentDirloc);
    final dir = _directoryByLoc(
        parentDirloc, dirEnt.fatCluster, dirEnt.length,
        mode: 'r+b');
    final l = dir.entryCount;
    assert(l >= 2);

    // Find first free slot or append.
    int i;
    for (i = 0; i < l; i++) {
      if (!dir[i].exists) break;
    }
    // i == l if all slots are occupied (will extend the directory file).

    final dirloc = (dirEnt.fatCluster, i);
    final now = todNow();

    int cluster;
    int length;
    if (mode & dfDir != 0) {
      mode = (mode & ~dfFile) | dfDir;
      final newCluster = allocateCluster();
      if (newCluster == null) {
        dir.close();
        throw Ps2McNoSpace(name);
      }
      cluster = newCluster;
      length = 1;
    } else {
      mode = (mode & ~dfDir) | dfFile;
      cluster = ps2mcFatChainEnd;
      length = 0;
    }

    final ent = PS2DirEntry(
      mode: mode | dfExists,
      length: length,
      created: now,
      fatCluster: cluster,
      parentEntry: 0,
      modified: now,
      name: name.length > 32 ? name.substring(0, 32) : name,
    );
    dir.writeRawEnt(i, ent, setModified: true);
    dir.close();

    if (mode & dfFile != 0) {
      return (dirloc, ent);
    }

    // For directories: write "." cluster and ".." entry.
    final dotEnt = PS2DirEntry(
      mode: dfRwx | df0400 | dfDir | dfExists,
      length: 0,
      created: now,
      fatCluster: dirloc.$1, // parent cluster (so _getParentDirLoc works)
      parentEntry: dirloc.$2, // index in parent
      modified: now,
      name: '.',
    );
    final dotData = Uint8List(clusterSize);
    dotData.setRange(0, ps2mcDirentLength, dotEnt.pack());
    _writeAllocatableCluster(cluster, dotData);

    final dir2 = _directoryByLoc(dirloc, cluster, 1,
        mode: 'wb', name: '<createDirEntry temp>');
    dir2.writeRawEnt(
        1,
        PS2DirEntry(
          mode: dfRwx | df0400 | dfDir | dfExists,
          length: 0,
          created: now,
          fatCluster: 0,
          parentEntry: 0,
          modified: now,
          name: '..',
        ),
        setModified: false);
    dir2.close();

    ent.length = 2;
    return (dirloc, ent);
  }

  /// Delete or truncate the entry at [dirloc].  Mirrors Python's
  /// delete_dirloc().
  void deleteDirloc(_DirLoc dirloc, bool truncate, String name) {
    if (dirloc == (0, 0)) {
      throw Ps2McIoError('cannot remove root directory', name);
    }
    if (dirloc.$2 == 0 || dirloc.$2 == 1) {
      throw Ps2McIoError('cannot remove "." or ".." entries', name);
    }
    if (_openFiles?.containsKey(dirloc) ?? false) {
      throw Ps2McIoError('cannot remove open file', name);
    }

    final epc = entriesPerCluster;
    final ent = _dirLocToEnt(dirloc);
    int cluster = ent.fatCluster;

    if (truncate) {
      _updateDirentAll(dirloc, null,
          length: 0,
          fatCluster: ps2mcFatChainEnd,
          modified: todNow());
    } else {
      _updateDirentAll(dirloc, null, mode: ent.mode & ~dfExists);
    }

    while (cluster != ps2mcFatChainEnd) {
      if (cluster ~/ epc < _fatCursor) {
        _fatCursor = cluster ~/ epc;
      }
      int nextCluster = lookupFat(cluster);
      if ((nextCluster & ps2mcFatAllocatedBit) == 0) break; // corrupted
      nextCluster &= ~ps2mcFatAllocatedBit;
      setFat(cluster, nextCluster);
      if (nextCluster == ps2mcFatChainEndUnalloc) break;
      cluster = nextCluster;
    }
  }

  bool _isEmptyDir(_DirLoc dirloc, PS2DirEntry ent) {
    final dir = _directoryByLoc(dirloc, ent.fatCluster, ent.length);
    try {
      for (int i = 2; i < ent.length; i++) {
        if (dir[i].exists) return false;
      }
    } finally {
      dir.close();
    }
    return true;
  }

  bool _isAncestor(_DirLoc dirloc, _DirLoc oldDirloc) {
    _DirLoc cur = dirloc;
    while (true) {
      if (cur == oldDirloc) return true;
      if (cur == (0, 0)) return false;
      cur = _getParentDirLoc(cur);
    }
  }

  void mkdir(String filename) {
    final result = pathSearch(filename);
    if (result.dirloc == null) throw Ps2McPathNotFound(filename);
    if (result.ent.exists) throw Ps2McIoError('directory exists', filename);
    createDirEntry(result.dirloc!, result.ent.name, dfDir | dfRwx | df0400);
    flush();
  }

  void remove(String filename) {
    final result = pathSearch(filename);
    if (result.dirloc == null) throw Ps2McPathNotFound(filename);
    if (!result.ent.exists) throw Ps2McFileNotFound(filename);
    if (result.isDir) {
      if (result.ent.fatCluster == 0) {
        throw Ps2McIoError('cannot remove root directory', filename);
      }
      if (!_isEmptyDir(result.dirloc!, result.ent)) {
        throw Ps2McIoError('directory not empty', filename);
      }
    }
    deleteDirloc(result.dirloc!, false, filename);
    flush();
  }

  PS2DirEntry getDirent(String filename) {
    final result = pathSearch(filename);
    if (result.dirloc == null) throw Ps2McPathNotFound(filename);
    if (!result.ent.exists) throw Ps2McFileNotFound(filename);
    return result.ent;
  }

  void setDirent(String filename, PS2DirEntry newEnt) {
    final result = pathSearch(filename);
    if (result.dirloc == null) throw Ps2McPathNotFound(filename);
    if (!result.ent.exists) throw Ps2McFileNotFound(filename);
    final dir = _opendirParentDirLoc(result.dirloc!, mode: 'r+b');
    try {
      dir.mergeEnt(result.dirloc!.$2, newEnt);
    } finally {
      dir.close();
    }
    flush();
  }

  void rename(String oldPath, String newPath) {
    final oldResult = pathSearch(oldPath);
    if (oldResult.dirloc == null) throw Ps2McPathNotFound(oldPath);
    if (!oldResult.ent.exists) throw Ps2McFileNotFound(oldPath);

    if (oldResult.dirloc == (0, 0)) {
      throw Ps2McIoError('cannot rename root directory', oldPath);
    }
    if (_openFiles?.containsKey(oldResult.dirloc) ?? false) {
      throw Ps2McIoError('cannot rename open file', oldPath);
    }

    final newResult = pathSearch(newPath);
    if (newResult.dirloc == null) throw Ps2McPathNotFound(newPath);
    if (newResult.ent.exists) throw Ps2McIoError('file exists', newPath);
    final newName = newResult.ent.name;

    final oldParentDirloc = _getParentDirLoc(oldResult.dirloc!);
    if (oldParentDirloc == newResult.dirloc) {
      // Same-parent rename: just update the name.
      final dir = _opendirDirLoc(oldParentDirloc, mode: 'r+b');
      try {
        final ent = dir[oldResult.dirloc!.$2];
        ent.name = newName;
        dir.writeRawEnt(oldResult.dirloc!.$2, ent, setModified: false);
      } finally {
        dir.close();
      }
      return;
    }

    if (oldResult.isDir &&
        _isAncestor(newResult.dirloc!, oldResult.dirloc!)) {
      throw Ps2McIoError('cannot move directory beneath itself', oldPath);
    }

    // Cross-parent rename: create in new location, then unlink from old.
    _DirLoc? newDirloc;
    bool newEntCreated = false;
    try {
      final tmpMode =
          (oldResult.ent.mode & ~dfDir) | dfFile; // create as file
      final (nd, _) =
          createDirEntry(newResult.dirloc!, newName, tmpMode);
      newDirloc = nd;
      newEntCreated = true;

      // Copy all fields from the old entry.
      final newParentDir =
          _opendirDirLoc(newResult.dirloc!, mode: 'r+b');
      try {
        final merged = oldResult.ent.copyWith(name: newName);
        newParentDir.writeRawEnt(newDirloc.$2, merged, setModified: true);
      } finally {
        newParentDir.close();
      }
      newEntCreated = false; // commit

      // Unlink old entry.
      _updateDirentAll(oldResult.dirloc!, null,
          mode: oldResult.ent.mode & ~dfExists);
    } catch (_) {
      if (newEntCreated && newDirloc != null) {
        try {
          deleteDirloc(newDirloc, false, newPath);
        } catch (_) {}
      }
      rethrow;
    }

    if (!oldResult.isDir) return;

    // Update the "." entry of the moved directory.
    final newDir = _opendirDirLoc(newDirloc);
    try {
      final dotEnt = newDir[0];
      dotEnt.fatCluster = newDirloc.$1;
      dotEnt.parentEntry = newDirloc.$2;
      newDir.writeRawEnt(0, dotEnt, setModified: false);
    } finally {
      newDir.close();
    }
  }

  void _removeDir(_DirLoc dirloc, PS2DirEntry ent, String dirname) {
    final firstCluster = ent.fatCluster;
    final length = ent.length;
    final dir = _directoryByLoc(dirloc, firstCluster, length);
    final entries = dir.toList().asMap().entries.skip(2).toList();
    dir.close();

    for (final e in entries) {
      final i = e.key;
      final childEnt = e.value;
      if (!childEnt.exists) continue;
      if (childEnt.isDir) {
        _removeDir((firstCluster, i), childEnt,
            '${dirname}${childEnt.name}/');
      } else {
        deleteDirloc((firstCluster, i), false, '$dirname${childEnt.name}');
      }
    }
    deleteDirloc(dirloc, false, dirname);
  }

  void rmdir(String dirname) {
    final result = pathSearch(dirname);
    if (result.dirloc == null) throw Ps2McPathNotFound(dirname);
    if (!result.ent.exists) throw Ps2McDirNotFound(dirname);
    if (!result.isDir) throw Ps2McIoError('not a directory', dirname);
    if (result.dirloc == (0, 0)) {
      throw Ps2McIoError("can't delete root directory", dirname);
    }
    final suffix = dirname.endsWith('/') ? dirname : '$dirname/';
    _removeDir(result.dirloc!, result.ent, suffix);
  }

  bool importSaveFile(Ps2SaveFile sf, bool ignoreExisting,
      {String? dirname}) {
    final dirEnt = sf.getDirectory();
    dirname ??= '/${dirEnt.name}';

    final rootResult = pathSearch(dirname);
    if (rootResult.dirloc == null) throw Ps2McPathNotFound(dirname);
    if (rootResult.ent.exists) {
      if (ignoreExisting) return false;
      throw Ps2McIoError('directory exists', dirname);
    }
    final name = rootResult.ent.name;
    final mode = dfDir | (dirEnt.mode & ~dfFile);

    final (dirDirloc, _) =
        createDirEntry(rootResult.dirloc!, name, mode);
    try {
      assert(dirname != '/');
      final dirPrefix = dirname.endsWith('/') ? dirname : '$dirname/';
      for (int i = 0; i < dirEnt.length; i++) {
        final (fileEnt, data) = sf.getFile(i);
        final fileMode = dfFile | (fileEnt.mode & ~dfDir);
        final (fileDirloc, _) =
            createDirEntry(dirDirloc, fileEnt.name, fileMode);
        final f = Ps2McFile(
            this, fileDirloc, ps2mcFatChainEnd, 0, 'wb', dirPrefix + fileEnt.name);
        _openFiles ??= {};
        _openFiles![fileDirloc] = (null, {f});
        try {
          f.write(data);
        } finally {
          f.close();
        }
      }
    } catch (e) {
      // Roll back: remove files and directory.
      try {
        for (int i = 0; i < dirEnt.length; i++) {
          try {
            remove('$dirname/${sf.getFile(i).$1.name}');
          } catch (_) {}
        }
        try {
          remove(dirname);
        } catch (_) {}
      } catch (_) {}
      rethrow;
    }

    // Apply timestamps/modes from the save file.
    final innerDir = _opendirDirLoc(dirDirloc, mode: 'r+b');
    try {
      for (int i = 0; i < dirEnt.length; i++) {
        innerDir.mergeEnt(i + 2, sf.getFile(i).$1);
      }
    } finally {
      innerDir.close();
    }

    final rootDir = _opendirDirLoc(rootResult.dirloc!, mode: 'r+b');
    try {
      final merged = dirEnt.copyWith(name: null); // keep name
      // merged.name is the save's name but we want to keep what we created.
      rootDir.mergeEnt(dirDirloc.$2, merged);
    } finally {
      rootDir.close();
    }

    flush();
    return true;
  }

  Ps2SaveFile exportSaveFile(String filename,
      {void Function(String)? onWarning}) {
    final result = pathSearch(filename);
    if (result.dirloc == null) throw Ps2McPathNotFound(filename);
    if (!result.ent.exists) throw Ps2McDirNotFound(filename);
    if (!result.isDir) throw Ps2McIoError('not a directory', filename);
    if (result.dirloc == (0, 0)) {
      throw Ps2McIoError("can't export root directory", filename);
    }

    final dirDirloc = result.dirloc!;
    final dirent = result.ent;
    final dir = _directoryByLoc(dirDirloc, dirent.fatCluster, dirent.length);
    final files = <(PS2DirEntry, Uint8List)>[];

    try {
      for (int i = 2; i < dirent.length; i++) {
        final ent = dir[i];
        if (!modeIsFile(ent.mode)) {
          onWarning?.call(
              'warning: ${dirent.name}/${ent.name} is not a file, ignored.');
          continue;
        }
        final f = Ps2McFile(
            this, (dirent.fatCluster, i), ent.fatCluster, ent.length, 'rb', null);
        final data = f.read(ent.length);
        f.close();
        assert(data.length == ent.length);
        files.add((ent, data));
      }
    } finally {
      dir.close();
    }

    final sf = Ps2SaveFile();
    sf.setDirectory(dirent.copyWith(length: files.length));
    for (int i = 0; i < files.length; i++) {
      sf.setFile(i, files[i].$1, files[i].$2);
    }
    return sf;
  }

  bool check({void Function(String)? onMessage}) {
    final fatLen = allocatableClusterEnd;
    final visited = List<bool>.filled(fatLen, false);

    final rootRaw = _readAllocatableCluster(0);
    final rootEnt = PS2DirEntry.unpack(rootRaw.sublist(0, ps2mcDirentLength));

    bool ok = _checkDir(visited, (0, 0), '/', rootEnt, onMessage);

    int lostClusters = 0;
    final lost = StringBuffer();
    for (int i = 0; i < fatLen; i++) {
      if ((lookupFat(i) & ps2mcFatAllocatedBit) != 0 && !visited[i]) {
        lost.write('$i ');
        lostClusters++;
      }
    }
    if (lostClusters > 0) {
      onMessage?.call(lost.toString().trim());
      onMessage?.call('found $lostClusters lost clusters');
      ok = false;
    }
    return ok;
  }

  bool _checkFile(List<bool> visited, int firstCluster, int length) {
    int cluster = firstCluster;
    int count = 0;
    while (cluster != ps2mcFatChainEnd) {
      if (cluster < 0 || cluster >= visited.length) {
        return false; // invalid cluster
      }
      if (visited[cluster]) return false; // cross-linked
      count++;
      visited[cluster] = true;
      final next = lookupFat(cluster);
      if (next == ps2mcFatChainEnd) break;
      if ((next & ps2mcFatAllocatedBit) == 0) return false; // unallocated
      cluster = next & ~ps2mcFatAllocatedBit;
    }
    final fileClusterEnd = divRoundUp(length, clusterSize);
    return count == fileClusterEnd;
  }

  bool _checkDir(List<bool> visited, _DirLoc dirloc, String dirname,
      PS2DirEntry ent, void Function(String)? onMessage) {
    final byteLen = ent.length * ps2mcDirentLength;
    if (!_checkFile(visited, ent.fatCluster, byteLen)) {
      onMessage?.call('bad directory: $dirname: bad cluster chain');
      return false;
    }
    bool ret = true;
    final firstCluster = ent.fatCluster;
    final length = ent.length;
    final dir = _directoryByLoc(dirloc, firstCluster, length);
    try {
      final dotEnt = dir[0];
      if (dotEnt.name != '.') {
        onMessage?.call('bad directory: $dirname: missing "." entry');
        ret = false;
      }
      if (dotEnt.fatCluster != dirloc.$1 ||
          dotEnt.parentEntry != dirloc.$2) {
        onMessage?.call('bad directory: $dirname: bad "." entry');
        ret = false;
      }
      if (dir[1].name != '..') {
        onMessage?.call('bad directory: $dirname: missing ".." entry');
        ret = false;
      }
      for (int i = 2; i < length; i++) {
        final child = dir[i];
        if (!child.exists) continue;
        if (child.isDir) {
          if (!_checkDir(visited, (firstCluster, i),
              '$dirname${child.name}/', child, onMessage)) {
            ret = false;
          }
        } else {
          if (!_checkFile(visited, child.fatCluster, child.length)) {
            onMessage?.call('bad file: $dirname${child.name}: bad chain');
            ret = false;
          }
        }
      }
    } finally {
      dir.close();
    }
    return ret;
  }

  // ---------------------------------------------------------------------------
  // Flush / close
  // ---------------------------------------------------------------------------

  void flush() {
    _flushAllocClusterCache();
    flushFatCache();
  }

  void writeSuperblock() {
    final sb = _Superblock(
      version: version,
      pageSize: pageSize,
      pagesPerCluster: pagesPerCluster,
      pagesPerEraseBlock: pagesPerEraseBlock,
      clustersPerCard: clustersPerCard,
      allocatableClusterOffset: allocatableClusterOffset,
      allocatableClusterEnd: allocatableClusterEnd,
      rootdirFatCluster: rootdirFatCluster,
      goodBlock1: goodBlock1,
      goodBlock2: goodBlock2,
      indirectFatClusterList: indirectFatClusterList,
      badEraseBlockList: badEraseBlockList,
    );
    final raw = sb.pack();
    final page = Uint8List(pageSize);
    page.setRange(0, raw.length, raw);
    _writePage(0, page);

    // Erase good_block2 (write 0xFF pages).
    final ffPage = Uint8List.fromList(List.filled(rawPageSize, 0xFF));
    final base = goodBlock2 * pagesPerEraseBlock;
    _io.setPosition(base * rawPageSize);
    for (int i = 0; i < pagesPerEraseBlock; i++) {
      _io.write(ffPage);
    }
    modified = false;
  }

  void _format(List<int> params) {
    final withEcc = params[0] != 0;
    final pgSize = params[1];
    final pagesPerEB = params[2];
    final paramPagesPerCard = params[3];

    if (pagesPerEB < 1) {
      throw Ps2McError('invalid pages per erase block ($pagesPerEB)');
    }

    final pagesPerCard = roundDown(paramPagesPerCard, pagesPerEB);
    const clSize = ps2mcClusterSize;
    final ppc = clSize ~/ pgSize;
    final clustersPerEB = pagesPerEB ~/ ppc;
    final eraseBlocksPerCard = pagesPerCard ~/ pagesPerEB;
    final clustersInCard = pagesPerCard ~/ ppc;
    final epc = clSize ~/ 4;

    if (pgSize < ps2mcDirentLength || ppc < 1 || ppc * pgSize != clSize) {
      throw Ps2McError('invalid page size ($pgSize)');
    }

    final gb1 = eraseBlocksPerCard - 1;
    final gb2 = eraseBlocksPerCard - 2;
    final firstIfc = divRoundUp(ps2mcIndirectFatOffset, clSize);

    var allocClusters = clustersInCard - (firstIfc + 2);
    var fatClusters = divRoundUp(allocClusters, epc);
    var indirectFatClusters = divRoundUp(fatClusters, epc);
    if (indirectFatClusters > ps2mcMaxIndirectFatClusters) {
      indirectFatClusters = ps2mcMaxIndirectFatClusters;
      fatClusters = indirectFatClusters * epc;
    }
    allocClusters = fatClusters * epc;

    final allocOffset = firstIfc + indirectFatClusters + fatClusters;
    final allocEnd =
        gb2 * clustersPerEB - allocOffset;
    if (allocEnd < 1) {
      throw Ps2McError('memory card image too small to be formatted');
    }

    final ifcList = Uint32List(ps2mcMaxIndirectFatClusters);
    ifcList.fillRange(0, ps2mcMaxIndirectFatClusters, 0);
    for (int i = 0; i < indirectFatClusters; i++) {
      ifcList[i] = firstIfc + i;
    }

    version = '1.2.0.0';
    pageSize = pgSize;
    pagesPerCluster = ppc;
    pagesPerEraseBlock = pagesPerEB;
    clustersPerCard = clustersInCard;
    allocatableClusterOffset = allocOffset;
    allocatableClusterEnd = allocClusters;
    rootdirFatCluster = 0;
    goodBlock1 = gb1;
    goodBlock2 = gb2;
    indirectFatClusterList = ifcList;
    badEraseBlockList = Uint32List(32)..fillRange(0, 32, 0xFFFFFFFF);
    _calculateDerived();

    ignoreEcc = !withEcc;
    if (!withEcc) spareSize = 0;

    // Write erased pages.
    final erasedPage = Uint8List(pgSize);
    Uint8List erasedRaw;
    if (!withEcc) {
      erasedRaw = erasedPage;
    } else {
      final eccs = eccCalculatePage(erasedPage);
      final spare = Uint8List(spareSize);
      for (int i = 0; i < eccs.length; i++) {
        spare[i * 3] = eccs[i][0];
        spare[i * 3 + 1] = eccs[i][1];
        spare[i * 3 + 2] = eccs[i][2];
      }
      erasedRaw = Uint8List(rawPageSize);
      erasedRaw.setRange(0, pgSize, erasedPage);
      erasedRaw.setRange(pgSize, pgSize + spare.length, spare);
    }
    _io.setPosition(0);
    for (int p = 0; p < pagesPerCard; p++) {
      _io.write(erasedRaw);
    }
    modified = true;

    // Write indirect FAT clusters.
    final firstFatCluster = firstIfc + indirectFatClusters;
    final remainder = fatClusters % epc;
    for (int i = 0; i < indirectFatClusters; i++) {
      final base = firstFatCluster + i * epc;
      final buf = Uint32List(epc);
      for (int j = 0; j < epc; j++) buf[j] = base + j;
      if (i == indirectFatClusters - 1 && remainder != 0) {
        buf.fillRange(remainder, epc, 0xFFFFFFFF);
      }
      _writeCluster(ifcList[i], Uint8List.sublistView(buf));
    }

    // Write FAT: go backwards for better cache usage.
    for (int i = allocClusters - 1; i >= allocEnd; i--) {
      setFat(i, ps2mcFatChainEnd);
    }
    for (int i = allocEnd - 1; i > 0; i--) {
      setFat(i, ps2mcFatClusterMask);
    }
    setFat(0, ps2mcFatChainEnd);

    allocatableClusterEnd = allocEnd;

    // Write root directory "." cluster.
    final now = todNow();
    final dotEnt = PS2DirEntry(
      mode: dfRwx | dfDir | df0400 | dfExists,
      length: 2,
      created: now,
      fatCluster: 0,
      parentEntry: 0,
      modified: now,
      name: '.',
    );
    final dotData = Uint8List(clusterSize);
    dotData.setRange(0, ps2mcDirentLength, dotEnt.pack());
    _writeAllocatableCluster(0, dotData);

    final rootDir =
        _directoryByLoc((0, 0), 0, 2, mode: 'wb', name: '/');
    rootDir.writeRawEnt(
        1,
        PS2DirEntry(
          mode: dfWrite | dfExecute | dfDir | df0400 | dfHidden | dfExists,
          length: 0,
          created: now,
          fatCluster: 0,
          parentEntry: 0,
          modified: now,
          name: '..',
        ),
        setModified: false);
    rootDir.close();

    flush();
  }

  void close() {
    if (_openFiles != null) flush();
    if (modified) writeSuperblock();
    _rootdir?.realClose();
    _rootdir = null;
    _openFiles = null;
    _io.close();
  }
}
