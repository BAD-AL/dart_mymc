// ps2mc.dart
//
// Ported from ps2mc.py by Ross Ridge (Public Domain)
// Manipulate PS2 memory card images.

import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

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

  void write(Uint8List out, {bool setModified = true}) {
    if (closed) throw StateError('$name: file is closed');
    if (!_write && !_append) {
      throw Ps2McIoError('file not opened for writing', name);
    }
    // Write implementation added in Phase 3.
    throw UnimplementedError('Ps2McFile.write() not yet implemented');
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

  // ignore: unused_element
  void operator []=(int index, PS2DirEntry newEnt) {
    // Used in Phase 3 write operations.
    // Mirrors ps2mc_directory.__setitem__ in Python.
    throw UnimplementedError('Directory entry modification not yet implemented');
  }

  void writeRawEnt(int index, PS2DirEntry ent, {bool setModified = true}) {
    seek(index);
    // Direct write into the underlying file's cluster buffer.
    // In Phase 1 (read-only) this is never called.
    throw UnimplementedError('writeRawEnt() not yet implemented');
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
  late RandomAccessFile _f;
  late String _filePath;
  bool ignoreEcc = false;
  bool modified = false;
  _DirLoc curdir = (0, 0);
  _RootDirectory? _rootdir;
  Map<_DirLoc, (Ps2McDirectory?, Set<Ps2McFile>)>? _openFiles = {};
  final _LruCache<int, (Uint32List, bool)> _fatCache = _LruCache(12);
  final _LruCache<int, (Uint8List, bool)> _allocClusterCache = _LruCache(64);
  // ignore: unused_field
  int _fatCursor = 0; // used in allocate_cluster() (Phase 3)

  // ---------------------------------------------------------------------------
  // Constructor / open
  // ---------------------------------------------------------------------------

  Ps2MemoryCard(String path, {bool ignoreEcc = false, List<int>? formatParams}) {
    _filePath = path;
    final mode = formatParams != null ? FileMode.write : FileMode.read;
    _f = File(path).openSync(mode: mode);
    _openFiles = {};

    _f.setPositionSync(0);
    final headerBytes = _f.readSync(_Superblock.rawSize);

    if (headerBytes.length != _Superblock.rawSize ||
        !_startsWithMagic(headerBytes)) {
      if (formatParams == null) {
        throw Ps2McCorrupt('Not a PS2 memory card image', path);
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
      throw Ps2McCorrupt('Root directory damaged.', path);
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
    _f.setPositionSync(rawPageSize * n);
    final page = _f.readSync(pageSize);
    if (page.length != pageSize) {
      throw Ps2McCorrupt(
          'Attempted to read past EOF (page 0x${n.toRadixString(16)})',
          _filePath);
    }
    if (ignoreEcc) return page;
    final spare = _f.readSync(spareSize);
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
    _f.setPositionSync(rawPageSize * n);
    _f.writeFromSync(buf);
    modified = true;
    if (spareSize != 0) {
      final eccs = eccCalculatePage(buf);
      final spareData = Uint8List(spareSize);
      for (int i = 0; i < eccs.length; i++) {
        spareData[i * 3] = eccs[i][0];
        spareData[i * 3 + 1] = eccs[i][1];
        spareData[i * 3 + 2] = eccs[i][2];
      }
      _f.writeFromSync(spareData);
    }
  }

  Uint8List _readCluster(int n) {
    if (spareSize == 0) {
      // No ECC: clusters are packed tightly.
      _f.setPositionSync(clusterSize * n);
      return _f.readSync(clusterSize);
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
      _f.setPositionSync(clusterSize * n);
      _f.writeFromSync(buf);
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

  // ignore: unused_element
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

  // ignore: unused_element
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

  // ignore: unused_element, unused_element_parameter
  Ps2McDirectory _opendirDirLoc(_DirLoc dirloc, {String mode = 'rb'}) {
    final ent = _dirLocToEnt(dirloc);
    return _directoryByLoc(dirloc, ent.fatCluster, ent.length,
        name: '_opendir temp');
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

      if (foundEnt == null) continue;

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
    final result = pathSearch(filename);
    if (result.dirloc == null) throw Ps2McPathNotFound(filename);
    if (result.isDir) throw Ps2McIoError('not a regular file', filename);
    if (!result.ent.exists) {
      if (!mode.startsWith('w') && !mode.startsWith('a')) {
        throw Ps2McFileNotFound(filename);
      }
      // Create file — Phase 3.
      throw UnimplementedError('File creation not yet implemented');
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
  // Write operations (stubs — implemented in Phase 3)
  // ---------------------------------------------------------------------------

  void mkdir(String filename) =>
      throw UnimplementedError('mkdir() not yet implemented');

  void remove(String filename) =>
      throw UnimplementedError('remove() not yet implemented');

  void rmdir(String dirname) =>
      throw UnimplementedError('rmdir() not yet implemented');

  void rename(String oldPath, String newPath) =>
      throw UnimplementedError('rename() not yet implemented');

  bool importSaveFile(Ps2SaveFile sf, bool ignoreExisting,
          {String? dirname}) =>
      throw UnimplementedError('importSaveFile() not yet implemented');

  Ps2SaveFile exportSaveFile(String filename) =>
      throw UnimplementedError('exportSaveFile() not yet implemented');

  bool check() =>
      throw UnimplementedError('check() not yet implemented');

  // ---------------------------------------------------------------------------
  // Flush / close
  // ---------------------------------------------------------------------------

  void flush() {
    _flushAllocClusterCache();
    flushFatCache();
  }

  void writeSuperblock() {
    throw UnimplementedError('writeSuperblock() not yet implemented');
  }

  void _format(List<int> params) {
    throw UnimplementedError('format() not yet implemented');
  }

  void close() {
    _rootdir?.realClose();
    _rootdir = null;
    _openFiles = null;
    _f.closeSync();
  }
}
