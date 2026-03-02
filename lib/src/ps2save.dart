// ps2save.dart
//
// Ported from ps2save.py by Ross Ridge (Public Domain)
// A simple interface for working with various PS2 save file formats.
//
// Phase 1: icon.sys parsing and Shift-JIS conversion only.
// Full save file format support (max/psu/cbs/sps) added in later phases.

import 'dart:typed_data';
import 'ps2mc_dir.dart';
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
// Full load/save support added in later phases.
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
}

// Extension to allow .let{} style chaining (used in IconSys.unpack)
extension _Let<T> on T {
  R let<R>(R Function(T) block) => block(this);
}
