// ps2save.dart
//
// Ported from ps2save.py by Ross Ridge (Public Domain)
// A simple interface for working with various PS2 save file formats.

import 'dart:io';
import 'dart:typed_data';
import 'lzari.dart';
import 'ps2mc_dir.dart';
import 'round.dart';
import 'sjistab.dart';

// Save file format magic bytes
const String ps2saveMaxMagic = 'Ps2PowerSave';
const List<int> ps2saveSpsMagicBytes = [0x0D, 0x00, 0x00, 0x00];
const String ps2saveSpsStr = 'SharkPortSave';
const String ps2saveCbsMagic = 'CFU\x00';
const String ps2saveNpoMagic = 'nPort';

// Graphically similar ASCII substitutions for Unicode characters
// that can't be encoded in the target encoding.
const Map<String, String> charSubsts = {
  '\u00A2': 'c',  '\u00B4': "'", '\u00D7': 'x',  '\u00F7': '/',
  '\u2010': '-',  '\u2015': '-', '\u2018': "'",  '\u2019': "'",
  '\u201C': '"',  '\u201D': '"', '\u2032': "'",  '\u2212': '-',
  '\u226A': '<<', '\u226B': '>>', '\u2500': '-', '\u2501': '-',
  '\u2502': '|',  '\u2503': '|', '\u250C': '+',  '\u250F': '+',
  '\u2510': '+',  '\u2513': '+', '\u2514': '+',  '\u2517': '+',
  '\u2518': '+',  '\u251B': '+', '\u251C': '+',  '\u251D': '+',
  '\u2520': '+',  '\u2523': '+', '\u2524': '+',  '\u2525': '+',
  '\u2528': '+',  '\u252B': '+', '\u252C': '+',  '\u252F': '+',
  '\u2530': '+',  '\u2533': '+', '\u2537': '+',  '\u2538': '+',
  '\u253B': '+',  '\u253C': '+', '\u253F': '+',  '\u2542': '+',
  '\u254B': '+',  '\u25A0': '#', '\u25A1': '#',  '\u2605': '*',
  '\u2606': '*',  '\u3001': ',', '\u3002': '.',  '\u3003': '"',
  '\u3007': '0',  '\u3008': '<', '\u3009': '>',  '\u300A': '<<',
  '\u300B': '>>', '\u300C': '[', '\u300D': ']',  '\u300E': '[',
  '\u300F': ']',  '\u3010': '[', '\u3011': ']',  '\u3014': '[',
  '\u3015': ']',  '\u301C': '~', '\u30FC': '-',
};

/// Decode Shift-JIS bytes to a Unicode string.
///
/// ASCII (0x00-0x7E) is identical in Shift-JIS.
/// Half-width Katakana (0xA1-0xDF) maps to U+FF61-U+FF9F.
/// Double-byte sequences: proper conversion requires a full lookup table.
///
/// TODO: implement full double-byte Shift-JIS decoding for Phase 4.
String decodeShiftJis(Uint8List bytes) {
  final result = StringBuffer();
  int i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b == 0) break; // null terminator
    if (b < 0x80) {
      result.writeCharCode(b); // ASCII (identical in Shift-JIS)
      i++;
    } else if (b >= 0xA1 && b <= 0xDF) {
      // Half-width Katakana: U+FF61 + (b - 0xA1)
      result.writeCharCode(0xFF61 + (b - 0xA1));
      i++;
    } else if ((b >= 0x81 && b <= 0x9F) || (b >= 0xE0 && b <= 0xFC)) {
      // Double-byte sequence.
      if (i + 1 >= bytes.length) {
        result.writeCharCode(0xFFFD);
        i++;
      } else {
        final trail = bytes[i + 1];
        i += 2;
        if (b == 0x81) {
          if (trail == 0x40) {
            result.writeCharCode(0x3000); // ideographic space
          } else {
            result.writeCharCode(0xFFFD);
          }
        } else if (b == 0x82) {
          if (trail >= 0x4F && trail <= 0x58) {
            result.writeCharCode(0xFF10 + (trail - 0x4F)); // full-width 0-9
          } else if (trail >= 0x60 && trail <= 0x79) {
            result.writeCharCode(0xFF21 + (trail - 0x60)); // full-width A-Z
          } else if (trail >= 0x81 && trail <= 0x9A) {
            result.writeCharCode(0xFF41 + (trail - 0x81)); // full-width a-z
          } else {
            result.writeCharCode(0xFFFD);
          }
        } else {
          result.writeCharCode(0xFFFD);
        }
      }
    } else {
      result.writeCharCode(0xFFFD);
      i++;
    }
  }
  return result.toString();
}

/// Convert a Shift-JIS byte string to a printable Unicode string,
/// substituting graphically similar ASCII characters where needed.
///
/// Mirrors ps2save.shift_jis_conv(src, encoding=None).
String shiftJisConv(Uint8List src) {
  final unicode = decodeShiftJis(src);
  final result = StringBuffer();
  // Iterate code units (fine for BMP characters that PS2 titles use).
  for (int i = 0; i < unicode.length; i++) {
    final ch = unicode[i]; // single-code-unit String
    final normalized = shiftJisNormalizeTable[ch] ?? ch;
    for (int j = 0; j < normalized.length; j++) {
      final nc = normalized[j];
      result.write(charSubsts[nc] ?? nc);
    }
  }
  return result.toString();
}

// ---------------------------------------------------------------------------
// icon.sys parsing
//
// Binary format: <4s2xH4x L 16s16s16s16s 16s16s16s 16s16s16s 16s
//                          68s 64s 64s 64s 512x>
// Total: 964 bytes
//
// Field offsets (0-based):
//   0:   magic         (4 bytes, "PS2D")
//   4:   padding       (2 bytes)
//   6:   title_offset  (uint16) — byte offset splitting title into two lines
//   8:   padding       (4 bytes)
//   12:  [2]           (uint32)
//   16:  [3-6]         (4 × 16 bytes)
//   80:  [7-9]         (3 × 16 bytes)
//   128: [10-12]       (3 × 16 bytes)
//   176: [13]          (16 bytes)
//   192: title         (68 bytes, Shift-JIS, null-terminated)
//   260: normal icon   (64 bytes)
//   324: copy icon     (64 bytes)
//   388: del icon      (64 bytes)
//   452: padding       (512 bytes)
// ---------------------------------------------------------------------------

class IconSys {
  final String magic;
  final int titleOffset;
  final Uint8List titleBytes; // 68 bytes, Shift-JIS, null-terminated
  final Uint8List normalIconName; // 64 bytes
  final Uint8List copyIconName; // 64 bytes
  final Uint8List delIconName; // 64 bytes

  IconSys({
    required this.magic,
    required this.titleOffset,
    required this.titleBytes,
    required this.normalIconName,
    required this.copyIconName,
    required this.delIconName,
  });

  static const int size = 964;
  static const String expectedMagic = 'PS2D';

  static IconSys? unpack(Uint8List data) {
    if (data.length < size) return null;
    final magic = String.fromCharCodes(data.sublist(0, 4));
    if (magic != expectedMagic) return null;

    final bd = ByteData.sublistView(data);
    final titleOffset = bd.getUint16(6, Endian.little);

    return IconSys(
      magic: magic,
      titleOffset: titleOffset,
      titleBytes: Uint8List.fromList(data.sublist(192, 192 + 68)),
      normalIconName: Uint8List.fromList(data.sublist(260, 260 + 64)),
      copyIconName: Uint8List.fromList(data.sublist(324, 324 + 64)),
      delIconName: Uint8List.fromList(data.sublist(388, 388 + 64)),
    );
  }

  /// Extract the two title lines stored in the icon.sys, converted from Shift-JIS.
  /// Returns (line1, line2).  Mirrors ps2save.icon_sys_title(a, enc).
  (String, String) title() {
    final offset = titleOffset;
    final nullEnd =
        titleBytes.indexOf(0).let((i) => i == -1 ? titleBytes.length : i);
    final fullTitle = titleBytes.sublist(0, nullEnd);

    final splitAt = offset < fullTitle.length ? offset : fullTitle.length;
    final part1 = Uint8List.fromList(fullTitle.sublist(0, splitAt));
    final part2 = splitAt < fullTitle.length
        ? Uint8List.fromList(fullTitle.sublist(splitAt))
        : Uint8List(0);

    return (shiftJisConv(part1), shiftJisConv(part2));
  }
}

// Detect file format type from first bytes of a save file stream.
// Returns "max", "psu", "cbs", "sps", "npo", or null if unrecognised.
String? detectFileType(Uint8List header) {
  if (header.length < 16) return null;
  final magic4 = String.fromCharCodes(header.sublist(0, 4));
  if (magic4 == ps2saveCbsMagic) return 'cbs';
  final magic12 = String.fromCharCodes(header.sublist(0, 12));
  if (magic12 == ps2saveMaxMagic) return 'max';
  if (magic4 == ps2saveNpoMagic.substring(0, 4) &&
      String.fromCharCodes(header.sublist(0, 5)) == ps2saveNpoMagic) {
    return 'npo';
  }
  // SharkPort: 0x0D 0x00 0x00 0x00 followed by "SharkPortSave"
  if (header[0] == 0x0D &&
      header[1] == 0x00 &&
      header[2] == 0x00 &&
      header[3] == 0x00 &&
      header.length >= 4 + ps2saveSpsStr.length) {
    final spsCheck = String.fromCharCodes(header.sublist(4, 4 + ps2saveSpsStr.length));
    if (spsCheck == ps2saveSpsStr) return 'sps';
  }
  // PSU (EMS): no distinctive magic; assumed if nothing else matched and
  // the directory entry at the start looks like a PS2 dir entry.
  // The heuristic used by Python: anything else is assumed psu.
  return 'psu';
}

// ---------------------------------------------------------------------------
// ps2_save_file: in-memory representation of a save file.
// ---------------------------------------------------------------------------

class Ps2SaveFile {
  PS2DirEntry? _dirent;
  List<PS2DirEntry?> _fileEnts = [];
  List<Uint8List?> _fileData = [];

  void setDirectory(PS2DirEntry ent) {
    _dirent = ent.copyWith();
    _fileEnts = List.filled(ent.length, null);
    _fileData = List.filled(ent.length, null);
  }

  PS2DirEntry getDirectory() {
    if (_dirent == null) throw StateError('No directory set');
    return _dirent!;
  }

  void setFile(int i, PS2DirEntry ent, Uint8List data) {
    _fileEnts[i] = ent;
    _fileData[i] = data;
  }

  (PS2DirEntry, Uint8List) getFile(int i) {
    final ent = _fileEnts[i];
    final data = _fileData[i];
    if (ent == null || data == null) {
      throw StateError('File $i not set');
    }
    return (ent, data);
  }

  IconSys? getIconSys() {
    if (_dirent == null) return null;
    for (int i = 0; i < _fileEnts.length; i++) {
      final ent = _fileEnts[i];
      if (ent != null && ent.name.toLowerCase() == 'icon.sys') {
        final data = _fileData[i];
        if (data != null) return IconSys.unpack(data);
      }
    }
    return null;
  }

  String makeLongname(String dirname) {
    final iconSys = getIconSys();
    if (iconSys == null) return dirname;
    final (t1, t2) = iconSys.title();
    final combined = (t1 + t2)
        .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return combined.isEmpty ? dirname : '$dirname $combined';
  }

  // ---------------------------------------------------------------------------
  // PSU (EMS) format — load / save
  // ---------------------------------------------------------------------------

  /// Load a PSU (.psu / EMS) save file from [f].
  void loadEms(RandomAccessFile f) {
    final direntBytes = f.readSync(ps2mcDirentLength);
    final dotBytes = f.readSync(ps2mcDirentLength);
    final dotdotBytes = f.readSync(ps2mcDirentLength);
    if (direntBytes.length != ps2mcDirentLength ||
        dotBytes.length != ps2mcDirentLength ||
        dotdotBytes.length != ps2mcDirentLength) {
      throw FormatException('Not a PSU (.psu) save file: truncated header');
    }
    final dirent = PS2DirEntry.unpack(direntBytes);
    final dotEnt = PS2DirEntry.unpack(dotBytes);
    final dotdotEnt = PS2DirEntry.unpack(dotdotBytes);
    if (!modeIsDir(dirent.mode) ||
        !modeIsDir(dotEnt.mode) ||
        !modeIsDir(dotdotEnt.mode) ||
        dirent.length < 2) {
      throw FormatException('Not a PSU (.psu) save file: invalid directory');
    }

    final fileCount = dirent.length - 2;
    setDirectory(dirent.copyWith(length: fileCount));

    const clusterSize = 1024;
    for (int i = 0; i < fileCount; i++) {
      final entBytes = f.readSync(ps2mcDirentLength);
      if (entBytes.length != ps2mcDirentLength) {
        throw FormatException('PSU file truncated at file entry $i');
      }
      final ent = PS2DirEntry.unpack(entBytes);
      if (!modeIsFile(ent.mode)) {
        throw FormatException('PSU file has a subdirectory (not supported)');
      }
      final flen = ent.length;
      final data = f.readSync(flen);
      if (data.length != flen) {
        throw FormatException('PSU file truncated at file data $i');
      }
      // Skip padding to next cluster boundary.
      final pad = roundUp(flen, clusterSize) - flen;
      if (pad > 0) f.readSync(pad);
      setFile(i, ent, data);
    }
  }

  /// Write the save file in PSU (.psu / EMS) format to [f].
  void saveEms(RandomAccessFile f) {
    const clusterSize = 1024;
    final dirent = getDirectory();
    final dirWithDots = dirent.copyWith(length: dirent.length + 2);
    f.writeFromSync(dirWithDots.pack());
    f.writeFromSync(PS2DirEntry(
      mode: dfRwx | dfDir | df0400 | dfExists,
      length: 0,
      created: dirent.created,
      fatCluster: 0,
      parentEntry: 0,
      modified: dirent.created,
      name: '.',
    ).pack());
    f.writeFromSync(PS2DirEntry(
      mode: dfRwx | dfDir | df0400 | dfExists,
      length: 0,
      created: dirent.created,
      fatCluster: 0,
      parentEntry: 0,
      modified: dirent.created,
      name: '..',
    ).pack());

    for (int i = 0; i < dirent.length; i++) {
      final (ent, data) = getFile(i);
      if (!modeIsFile(ent.mode)) {
        throw StateError('Directory has a subdirectory.');
      }
      f.writeFromSync(ent.pack());
      f.writeFromSync(data);
      final pad = roundUp(data.length, clusterSize) - data.length;
      if (pad > 0) f.writeFromSync(Uint8List(pad));
    }
    f.flushSync();
  }
}

// ---------------------------------------------------------------------------
// CRC32 (standard, polynomial 0xEDB88320)
// ---------------------------------------------------------------------------

int _crc32(Uint8List data, [int prev = 0]) {
  int crc = (prev ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (int i = 0; i < 8; i++) {
      if (crc & 1 != 0) {
        crc = ((crc >>> 1) ^ 0xEDB88320) & 0xFFFFFFFF;
      } else {
        crc = (crc >>> 1) & 0xFFFFFFFF;
      }
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

// ---------------------------------------------------------------------------
// RC4 cipher — used by CodeBreaker saves
// ---------------------------------------------------------------------------

// PS2SAVE_CBS_RC4S: initial S-box permutation state for CodeBreaker RC4.
const List<int> _cbsRc4S = [
  0x5f, 0x1f, 0x85, 0x6f, 0x31, 0xaa, 0x3b, 0x18,
  0x21, 0xb9, 0xce, 0x1c, 0x07, 0x4c, 0x9c, 0xb4,
  0x81, 0xb8, 0xef, 0x98, 0x59, 0xae, 0xf9, 0x26,
  0xe3, 0x80, 0xa3, 0x29, 0x2d, 0x73, 0x51, 0x62,
  0x7c, 0x64, 0x46, 0xf4, 0x34, 0x1a, 0xf6, 0xe1,
  0xba, 0x3a, 0x0d, 0x82, 0x79, 0x0a, 0x5c, 0x16,
  0x71, 0x49, 0x8e, 0xac, 0x8c, 0x9f, 0x35, 0x19,
  0x45, 0x94, 0x3f, 0x56, 0x0c, 0x91, 0x00, 0x0b,
  0xd7, 0xb0, 0xdd, 0x39, 0x66, 0xa1, 0x76, 0x52,
  0x13, 0x57, 0xf3, 0xbb, 0x4e, 0xe5, 0xdc, 0xf0,
  0x65, 0x84, 0xb2, 0xd6, 0xdf, 0x15, 0x3c, 0x63,
  0x1d, 0x89, 0x14, 0xbd, 0xd2, 0x36, 0xfe, 0xb1,
  0xca, 0x8b, 0xa4, 0xc6, 0x9e, 0x67, 0x47, 0x37,
  0x42, 0x6d, 0x6a, 0x03, 0x92, 0x70, 0x05, 0x7d,
  0x96, 0x2f, 0x40, 0x90, 0xc4, 0xf1, 0x3e, 0x3d,
  0x01, 0xf7, 0x68, 0x1e, 0xc3, 0xfc, 0x72, 0xb5,
  0x54, 0xcf, 0xe7, 0x41, 0xe4, 0x4d, 0x83, 0x55,
  0x12, 0x22, 0x09, 0x78, 0xfa, 0xde, 0xa7, 0x06,
  0x08, 0x23, 0xbf, 0x0f, 0xcc, 0xc1, 0x97, 0x61,
  0xc5, 0x4a, 0xe6, 0xa0, 0x11, 0xc2, 0xea, 0x74,
  0x02, 0x87, 0xd5, 0xd1, 0x9d, 0xb7, 0x7e, 0x38,
  0x60, 0x53, 0x95, 0x8d, 0x25, 0x77, 0x10, 0x5e,
  0x9b, 0x7f, 0xd8, 0x6e, 0xda, 0xa2, 0x2e, 0x20,
  0x4f, 0xcd, 0x8f, 0xcb, 0xbe, 0x5a, 0xe0, 0xed,
  0x2c, 0x9a, 0xd4, 0xe2, 0xaf, 0xd0, 0xa9, 0xe8,
  0xad, 0x7a, 0xbc, 0xa8, 0xf2, 0xee, 0xeb, 0xf5,
  0xa6, 0x99, 0x28, 0x24, 0x6c, 0x2b, 0x75, 0x5d,
  0xf8, 0xd3, 0x86, 0x17, 0xfb, 0xc0, 0x7b, 0xb3,
  0x58, 0xdb, 0xc7, 0x4b, 0xff, 0x04, 0x50, 0xe9,
  0x88, 0x69, 0xc9, 0x2a, 0xab, 0xfd, 0x5b, 0x1b,
  0x8a, 0xd9, 0xec, 0x27, 0x44, 0x0e, 0x33, 0xc8,
  0x6b, 0x93, 0x32, 0x48, 0xb6, 0x30, 0x43, 0xa5,
];

/// RC4 encrypt/decrypt [t] in-place using the given S-box permutation [s].
Uint8List _rc4Crypt(List<int> s, Uint8List t) {
  final sbox = List<int>.from(s);
  final out = Uint8List.fromList(t);
  int j = 0;
  for (int ii = 0; ii < out.length; ii++) {
    final i = (ii + 1) % 256;
    j = (j + sbox[i]) % 256;
    final tmp = sbox[i];
    sbox[i] = sbox[j];
    sbox[j] = tmp;
    out[ii] ^= sbox[(sbox[i] + sbox[j]) % 256];
  }
  return out;
}

Uint8List _readFixed(RandomAccessFile f, int n) {
  final data = f.readSync(n);
  if (data.length != n) throw FormatException('Save file truncated');
  return data;
}

Uint8List _readLongString(RandomAccessFile f) {
  final lenBytes = _readFixed(f, 4);
  final len = ByteData.sublistView(lenBytes).getUint32(0, Endian.little);
  return _readFixed(f, len);
}

extension Ps2SaveFileFormats on Ps2SaveFile {
  // ---------------------------------------------------------------------------
  // MAX Drive format — load / save
  // ---------------------------------------------------------------------------

  /// Load a MAX Drive (.max) save file from [f].
  /// Header: magic(12) + crc(4) + dirname(32) + iconsysname(32) +
  ///         clen(4) + dirlen(4) + length(4) = 92 bytes.
  /// Body: LZARI-compressed file entries.
  void loadMax(RandomAccessFile f, [PS2Tod? timestamp]) {
    final hdr = _readFixed(f, 0x5C); // 92 bytes
    final magic = String.fromCharCodes(hdr.sublist(0, 12));
    if (magic != ps2saveMaxMagic) {
      throw FormatException('Not a MAX Drive save file');
    }
    final bd = ByteData.sublistView(hdr);
    // crc at offset 12 (not verified here)
    final dirnameZ = zeroTerminateBytes(hdr.sublist(16, 48));
    final dirname = String.fromCharCodes(dirnameZ);
    // iconsysname at 48..80 (ignored)
    final clen = bd.getUint32(80, Endian.little);
    final dirlen = bd.getUint32(84, Endian.little);
    final uncompLen = bd.getUint32(88, Endian.little);

    // clen == uncompLen: some files incorrectly store uncompressed size as clen
    final Uint8List body;
    if (clen == uncompLen) {
      final pos = f.positionSync();
      final remaining = f.lengthSync() - pos;
      body = f.readSync(remaining);
    } else {
      body = _readFixed(f, clen - 4);
    }

    final ts = timestamp ?? todNow();
    setDirectory(PS2DirEntry(
      mode: dfRwx | dfDir | df0400 | dfExists,
      length: dirlen,
      created: ts,
      fatCluster: 0,
      parentEntry: 0,
      modified: ts,
      name: dirname,
    ));

    final decompressed = lzariDecode(body, uncompLen);
    int off = 0;
    for (int i = 0; i < dirlen; i++) {
      if (off + 36 > decompressed.length) {
        throw FormatException('MAX save truncated at entry $i');
      }
      final entBd = ByteData.sublistView(decompressed, off, off + 36);
      final l = entBd.getUint32(0, Endian.little);
      final nameZ = zeroTerminateBytes(decompressed.sublist(off + 4, off + 36));
      final name = String.fromCharCodes(nameZ);
      off += 36;
      if (off + l > decompressed.length) {
        throw FormatException('MAX save truncated at file data $i');
      }
      final data = Uint8List.fromList(decompressed.sublist(off, off + l));
      setFile(
        i,
        PS2DirEntry(
          mode: dfRwx | dfFile | df0400 | dfExists,
          length: l,
          created: ts,
          fatCluster: 0,
          parentEntry: 0,
          modified: ts,
          name: name,
        ),
        data,
      );
      off += l;
      off = roundUp(off + 8, 16) - 8;
    }
  }

  /// Write the save file in MAX Drive format to [f].
  void saveMax(RandomAccessFile f) {
    final dirent = getDirectory();

    // Build uncompressed body: for each file: uint32 size + 32-byte name + data,
    // padded so that (len + 8) is a multiple of 16.
    var body = <int>[];
    for (int i = 0; i < dirent.length; i++) {
      final (ent, data) = getFile(i);
      final sizeBd = ByteData(4);
      sizeBd.setUint32(0, ent.length, Endian.little);
      body.addAll(sizeBd.buffer.asUint8List());
      final namePad = Uint8List(32);
      final nb = ent.name.codeUnits;
      for (int j = 0; j < nb.length && j < 32; j++) namePad[j] = nb[j];
      body.addAll(namePad);
      body.addAll(data);
      final pad = roundUp(body.length + 8, 16) - 8 - body.length;
      if (pad > 0) body.addAll(Uint8List(pad));
    }

    final bodyBytes = Uint8List.fromList(body);
    final uncompLen = bodyBytes.length;
    final compressed = lzariEncode(bodyBytes);

    // Determine iconsysname from icon.sys title
    var iconSysName = '';
    final iconSys = getIconSys();
    if (iconSys != null) {
      final (t1, t2) = iconSys.title();
      if (t1.isNotEmpty && t1[t1.length - 1] != ' ') {
        iconSysName = '$t1 ${t2.trimRight()}';
      } else {
        iconSysName = '$t1${t2.trimRight()}';
      }
    }

    // Build header with CRC=0 first, then compute CRC over header+body
    final hdr = Uint8List(92);
    final hdrBd = ByteData.sublistView(hdr);
    final magicBytes = ps2saveMaxMagic.codeUnits;
    for (int j = 0; j < magicBytes.length; j++) hdr[j] = magicBytes[j];
    // hdr[12..15] = CRC (set to 0 for now)
    final dirnamePad = Uint8List(32);
    final dnb = dirent.name.codeUnits;
    for (int j = 0; j < dnb.length && j < 32; j++) dirnamePad[j] = dnb[j];
    hdr.setRange(16, 48, dirnamePad);
    final iconPad = Uint8List(32);
    final inb = iconSysName.codeUnits;
    for (int j = 0; j < inb.length && j < 32; j++) iconPad[j] = inb[j];
    hdr.setRange(48, 80, iconPad);
    hdrBd.setUint32(80, compressed.length + 4, Endian.little); // clen
    hdrBd.setUint32(84, dirent.length, Endian.little);
    hdrBd.setUint32(88, uncompLen, Endian.little);

    var crc = _crc32(hdr);
    crc = _crc32(compressed, crc);
    hdrBd.setUint32(12, crc & 0xFFFFFFFF, Endian.little);

    f.writeFromSync(hdr);
    f.writeFromSync(compressed);
    f.flushSync();
  }

  // ---------------------------------------------------------------------------
  // SharkPort / X-Port format — load
  // ---------------------------------------------------------------------------

  /// Load a SharkPort (.sps / .xps) save file from [f].
  /// Magic: \x0D\x00\x00\x00SharkPortSave (17 bytes).
  void loadSps(RandomAccessFile f) {
    // Magic already consumed by detectFileType caller; re-read from position 0
    // (caller seeks to 0 before calling us, so read fresh).
    final magic = _readFixed(f, 17);
    if (magic.length < 17 ||
        magic[0] != 0x0D ||
        magic[1] != 0x00 ||
        magic[2] != 0x00 ||
        magic[3] != 0x00 ||
        String.fromCharCodes(magic.sublist(4)) != ps2saveSpsStr) {
      throw FormatException('Not a SharkPort save file');
    }
    _readFixed(f, 4); // savetype (ignored)
    _readLongString(f); // dirname string (ignored — use dir entry below)
    _readLongString(f); // datestamp (ignored)
    _readLongString(f); // comment (ignored)
    _readFixed(f, 4); // total flen (ignored)

    // Directory entry: H64sL8xH2x8s8s = 98 bytes
    final dirHdr = _readFixed(f, 98);
    final dhBd = ByteData.sublistView(dirHdr);
    final dhLen = dhBd.getUint16(0, Endian.little);
    final dirnamePad = dirHdr.sublist(2, 66);
    final dirlen = dhBd.getUint32(66, Endian.little);
    // offset 70: 8 bytes padding (8x)
    int dirmode = dhBd.getUint16(78, Endian.little);
    // offset 80: 2 bytes padding (2x)
    final created = PS2Tod.unpack(dirHdr, 82);
    final modified = PS2Tod.unpack(dirHdr, 90);
    if (dhLen > 98) _readFixed(f, dhLen - 98); // skip extra header bytes

    final dirnameZ = zeroTerminateBytes(dirnamePad);
    final dirname = String.fromCharCodes(dirnameZ);

    // Mode values are byte-swapped in SPS format
    dirmode = ((dirmode & 0xFF) << 8) | ((dirmode >> 8) & 0xFF);
    dirmode |= dfExists;
    if (!modeIsDir(dirmode) || dirlen < 2) {
      throw FormatException('SPS bad directory entry');
    }

    final fileCount = dirlen - 2;
    setDirectory(PS2DirEntry(
      mode: dirmode,
      length: fileCount,
      created: created,
      fatCluster: 0,
      parentEntry: 0,
      modified: modified,
      name: dirname,
    ));

    for (int i = 0; i < fileCount; i++) {
      final fileHdr = _readFixed(f, 98);
      final fhBd = ByteData.sublistView(fileHdr);
      final fhLen = fhBd.getUint16(0, Endian.little);
      if (fhLen < 98) throw FormatException('SPS file header length too short');
      final namePad = fileHdr.sublist(2, 66);
      final flen = fhBd.getUint32(66, Endian.little);
      // offset 70: 8 bytes padding
      int mode = fhBd.getUint16(78, Endian.little);
      // offset 80: 2 bytes padding
      final fcreated = PS2Tod.unpack(fileHdr, 82);
      final fmodified = PS2Tod.unpack(fileHdr, 90);
      if (fhLen > 98) _readFixed(f, fhLen - 98);

      final nameZ = zeroTerminateBytes(namePad);
      final name = String.fromCharCodes(nameZ);
      mode = ((mode & 0xFF) << 8) | ((mode >> 8) & 0xFF);
      mode |= dfExists;
      if (!modeIsFile(mode)) throw FormatException('SPS has non-file entry');

      final data = _readFixed(f, flen);
      setFile(
        i,
        PS2DirEntry(
          mode: mode,
          length: flen,
          created: fcreated,
          fatCluster: 0,
          parentEntry: 0,
          modified: fmodified,
          name: name,
        ),
        data,
      );
    }
    // 4-byte checksum at end (ignored)
  }

  // ---------------------------------------------------------------------------
  // CodeBreaker format — load
  // ---------------------------------------------------------------------------

  /// Load a CodeBreaker (.cbs) save file from [f].
  /// Magic: CFU\x00 (4 bytes), followed by RC4-encrypted, zlib-compressed body.
  void loadCbs(RandomAccessFile f) {
    final magic = _readFixed(f, 4);
    if (String.fromCharCodes(magic) != ps2saveCbsMagic) {
      throw FormatException('Not a CodeBreaker save file');
    }
    final hdrFields = _readFixed(f, 8);
    final hfBd = ByteData.sublistView(hdrFields);
    // d04 at offset 0 (ignored)
    final hlen = hfBd.getUint32(4, Endian.little);
    if (hlen < 92 + 32) throw FormatException('CBS header length too short');

    final rest = _readFixed(f, hlen - 12);
    final rBd = ByteData.sublistView(rest);
    final dlen = rBd.getUint32(0, Endian.little); // decompressed length
    final flen = rBd.getUint32(4, Endian.little); // body length
    final dirnameZ = zeroTerminateBytes(rest.sublist(8, 40));
    final dirname = String.fromCharCodes(dirnameZ);
    final created = PS2Tod.unpack(rest, 40);
    final modified = PS2Tod.unpack(rest, 48);
    // d44/d48/dirmode/d50/d54/d58 at offsets 56..80
    int dirmode = rBd.getUint32(64, Endian.little);
    // title at offset 80.. (ignored)

    if ((dirmode & (dfFile | dfDir)) != dfDir) {
      dirmode = dfRwx | dfDir | df0400;
    }
    dirmode |= dfExists;

    final createdSafe =
        created.year == 0 ? todNow() : created;
    final modifiedSafe =
        modified.year == 0 ? todNow() : modified;

    // Body: RC4 decrypt then zlib decompress
    final rawBody = f.readSync(flen);
    if (rawBody.length != flen && rawBody.length != flen - hlen) {
      throw FormatException('CBS file truncated');
    }
    final decrypted = _rc4Crypt(_cbsRc4S, rawBody);
    final decompressed =
        Uint8List.fromList(ZLibDecoder().convert(decrypted).sublist(0, dlen));

    // Parse 64-byte file entries: 8s8sLHHLL32s
    final files = <(PS2DirEntry, Uint8List)>[];
    int off = 0;
    while (off < decompressed.length) {
      if (decompressed.length - off < 64) {
        throw FormatException('CBS body truncated at entry ${files.length}');
      }
      final eBd = ByteData.sublistView(decompressed, off, off + 64);
      final fcreated = PS2Tod.unpack(decompressed, off);
      final fmodified = PS2Tod.unpack(decompressed, off + 8);
      final size = eBd.getUint32(16, Endian.little);
      int mode = eBd.getUint16(20, Endian.little);
      // h06/h08/h0C at 22/24/28 (ignored)
      final nameZ =
          zeroTerminateBytes(decompressed.sublist(off + 32, off + 64));
      final name = String.fromCharCodes(nameZ);
      off += 64;
      if (off + size > decompressed.length) {
        throw FormatException('CBS body truncated at file data ${files.length}');
      }
      final data = Uint8List.fromList(decompressed.sublist(off, off + size));
      off += size;
      mode |= dfExists;
      if (!modeIsFile(mode)) throw FormatException('CBS has non-file entry');
      final fcrSafe = fcreated.year == 0 ? todNow() : fcreated;
      final fmodSafe = fmodified.year == 0 ? todNow() : fmodified;
      files.add((
        PS2DirEntry(
          mode: mode,
          length: size,
          created: fcrSafe,
          fatCluster: 0,
          parentEntry: 0,
          modified: fmodSafe,
          name: name,
        ),
        data,
      ));
    }

    setDirectory(PS2DirEntry(
      mode: dirmode,
      length: files.length,
      created: createdSafe,
      fatCluster: 0,
      parentEntry: 0,
      modified: modifiedSafe,
      name: dirname,
    ));
    for (int i = 0; i < files.length; i++) {
      final (ent, data) = files[i];
      setFile(i, ent, data);
    }
  }

  // ---------------------------------------------------------------------------
  // SharkPort / X-Port (.sps) writer — Phase 5
  // ---------------------------------------------------------------------------

  void saveSps(RandomAccessFile f) {
    throw UnimplementedError('saveSps not yet implemented');
  }

  // ---------------------------------------------------------------------------
  // CodeBreaker (.cbs) writer — Phase 5
  // ---------------------------------------------------------------------------

  void saveCbs(RandomAccessFile f) {
    throw UnimplementedError('saveCbs not yet implemented');
  }
}

// Extension to allow .let{} style chaining (used in IconSys.unpack)
extension _Let<T> on T {
  R let<R>(R Function(T) block) => block(this);
}
