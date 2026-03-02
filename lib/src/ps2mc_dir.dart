// ps2mc_dir.dart
//
// Ported from ps2mc_dir.py by Ross Ridge (Public Domain)
// Functions for working with PS2 memory card directory entries.

import 'dart:typed_data';

const int ps2mcDirentLength = 512;

// Mode flags
const int dfRead      = 0x0001;
const int dfWrite     = 0x0002;
const int dfExecute   = 0x0004;
const int dfRwx       = dfRead | dfWrite | dfExecute;
const int dfProtected = 0x0008;
const int dfFile      = 0x0010;
const int dfDir       = 0x0020;
const int dfODcreat   = 0x0040;
const int df0080      = 0x0080;
const int df0100      = 0x0100;
const int dfOCreat    = 0x0200;
const int df0400      = 0x0400;
const int dfPocketstn = 0x0800;
const int dfPsx       = 0x1000;
const int dfHidden    = 0x2000;
const int df4000      = 0x4000;
const int dfExists    = 0x8000;

/// Truncate a byte list at the first zero byte.
Uint8List zeroTerminateBytes(Uint8List s) {
  final i = s.indexOf(0);
  if (i == -1) return s;
  return s.sublist(0, i);
}

// Time-of-Day structure
// Binary format: <xBBBBBH = 1 padding byte + secs(B) + mins(B) + hours(B) + mday(B) + month(B) + year(H) = 8 bytes
class PS2Tod {
  final int secs;
  final int mins;
  final int hours;
  final int mday;
  final int month;
  final int year;

  const PS2Tod(
      this.secs, this.mins, this.hours, this.mday, this.month, this.year);

  static PS2Tod unpack(Uint8List data, int offset) {
    final bd = ByteData.sublistView(data, offset, offset + 8);
    return PS2Tod(
      bd.getUint8(1), // secs  (skip padding byte 0)
      bd.getUint8(2), // mins
      bd.getUint8(3), // hours
      bd.getUint8(4), // mday
      bd.getUint8(5), // month
      bd.getUint16(6, Endian.little), // year
    );
  }

  Uint8List pack() {
    final bd = ByteData(8);
    bd.setUint8(0, 0); // padding
    bd.setUint8(1, secs);
    bd.setUint8(2, mins);
    bd.setUint8(3, hours);
    bd.setUint8(4, mday);
    bd.setUint8(5, month);
    bd.setUint16(6, year, Endian.little);
    return bd.buffer.asUint8List();
  }

  /// Convert to a Unix timestamp (seconds since epoch).
  /// PS2 ToD timestamps are stored in JST (UTC+9).
  /// Python equivalent: calendar.timegm(...) - 9*3600
  int toUnixTimestamp() {
    final m = month == 0 ? 1 : month;
    // Treat the stored JST time as UTC, then subtract 9 hours to get real UTC.
    final asUtc = DateTime.utc(year, m, mday, hours, mins, secs);
    return asUtc.millisecondsSinceEpoch ~/ 1000 - 9 * 3600;
  }

  DateTime toLocalDateTime() =>
      DateTime.fromMillisecondsSinceEpoch(toUnixTimestamp() * 1000);
}

PS2Tod todNow() {
  // Store current time in JST (UTC+9), as the PS2 does.
  final now = DateTime.now().toUtc().add(const Duration(hours: 9));
  return PS2Tod(
      now.second, now.minute, now.hour, now.day, now.month, now.year);
}

// Directory entry structure
// Binary format: <HHL8sLL8sL28x448s
//   mode(H) + unused(H) + length(L) + created(8s) +
//   fat_cluster(L) + parent_entry(L) + modified(8s) + attr(L) +
//   28x padding + name(448s)
//
// Offsets:
//   0:   mode       (uint16)
//   2:   unused     (uint16)
//   4:   length     (uint32)
//   8:   created    (8 bytes, PS2Tod)
//   16:  fat_cluster (uint32)
//   20:  parent_entry (uint32)
//   24:  modified   (8 bytes, PS2Tod)
//   32:  attr       (uint32)
//   36:  padding    (28 bytes)
//   64:  name       (448 bytes)
// Total: 512 bytes = ps2mcDirentLength

class PS2DirEntry {
  int mode;
  int unused;
  int length;
  PS2Tod created;
  int fatCluster;
  int parentEntry;
  PS2Tod modified;
  int attr;
  String name;

  PS2DirEntry({
    required this.mode,
    this.unused = 0,
    required this.length,
    required this.created,
    required this.fatCluster,
    required this.parentEntry,
    required this.modified,
    this.attr = 0,
    required this.name,
  });

  static PS2DirEntry unpack(Uint8List data) {
    assert(data.length >= ps2mcDirentLength);
    final bd = ByteData.sublistView(data, 0, ps2mcDirentLength);

    final mode = bd.getUint16(0, Endian.little);
    final unused = bd.getUint16(2, Endian.little);
    final length = bd.getUint32(4, Endian.little);
    final created = PS2Tod.unpack(data, 8);
    final fatCluster = bd.getUint32(16, Endian.little);
    final parentEntry = bd.getUint32(20, Endian.little);
    final modified = PS2Tod.unpack(data, 24);
    final attr = bd.getUint32(32, Endian.little);
    // 28 bytes padding at offset 36
    final nameBytes = zeroTerminateBytes(data.sublist(64, 64 + 448));
    final name = String.fromCharCodes(nameBytes);

    return PS2DirEntry(
      mode: mode,
      unused: unused,
      length: length,
      created: created,
      fatCluster: fatCluster,
      parentEntry: parentEntry,
      modified: modified,
      attr: attr,
      name: name,
    );
  }

  Uint8List pack() {
    final data = Uint8List(ps2mcDirentLength);
    final bd = ByteData.sublistView(data);

    bd.setUint16(0, mode, Endian.little);
    bd.setUint16(2, unused, Endian.little);
    bd.setUint32(4, length, Endian.little);
    data.setRange(8, 16, created.pack());
    bd.setUint32(16, fatCluster, Endian.little);
    bd.setUint32(20, parentEntry, Endian.little);
    data.setRange(24, 32, modified.pack());
    bd.setUint32(32, attr, Endian.little);
    // offset 36..63: padding (already zero)
    final nameBytes = name.codeUnits;
    final nameLen = nameBytes.length < 448 ? nameBytes.length : 448;
    for (int i = 0; i < nameLen; i++) {
      data[64 + i] = nameBytes[i];
    }
    return data;
  }

  bool get isFile =>
      (mode & (dfFile | dfDir | dfExists)) == (dfFile | dfExists);
  bool get isDir =>
      (mode & (dfFile | dfDir | dfExists)) == (dfDir | dfExists);
  bool get exists => (mode & dfExists) != 0;

  PS2DirEntry copyWith({
    int? mode,
    int? unused,
    int? length,
    PS2Tod? created,
    int? fatCluster,
    int? parentEntry,
    PS2Tod? modified,
    int? attr,
    String? name,
  }) {
    return PS2DirEntry(
      mode: mode ?? this.mode,
      unused: unused ?? this.unused,
      length: length ?? this.length,
      created: created ?? this.created,
      fatCluster: fatCluster ?? this.fatCluster,
      parentEntry: parentEntry ?? this.parentEntry,
      modified: modified ?? this.modified,
      attr: attr ?? this.attr,
      name: name ?? this.name,
    );
  }
}

bool modeIsFile(int mode) =>
    (mode & (dfFile | dfDir | dfExists)) == (dfFile | dfExists);

bool modeIsDir(int mode) =>
    (mode & (dfFile | dfDir | dfExists)) == (dfDir | dfExists);
