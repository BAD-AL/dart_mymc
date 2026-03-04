// ps2save.dart
//
// Ported from ps2save.py by Ross Ridge (Public Domain)
// A simple interface for working with various PS2 save file formats.

import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';
import 'lzari.dart';
import 'ps2card_io.dart';
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
/// Shift-JIS double-byte lookup table.
///
/// Maps (lead << 8 | trail) → Unicode code point for lead bytes 0x81–0x84.
/// Generated from Python 2's shift_jis codec via tools/gen_sjis_table.py.
const Map<int, int> _sjisDoubleByte = {
  // Lead byte 0x81 — symbols and punctuation
  0x8140: 0x3000, 0x8141: 0x3001, 0x8142: 0x3002, 0x8143: 0xFF0C,
  0x8144: 0xFF0E, 0x8145: 0x30FB, 0x8146: 0xFF1A, 0x8147: 0xFF1B,
  0x8148: 0xFF1F, 0x8149: 0xFF01, 0x814A: 0x309B, 0x814B: 0x309C,
  0x814C: 0x00B4, 0x814D: 0xFF40, 0x814E: 0x00A8, 0x814F: 0xFF3E,
  0x8150: 0xFFE3, 0x8151: 0xFF3F, 0x8152: 0x30FD, 0x8153: 0x30FE,
  0x8154: 0x309D, 0x8155: 0x309E, 0x8156: 0x3003, 0x8157: 0x4EDD,
  0x8158: 0x3005, 0x8159: 0x3006, 0x815A: 0x3007, 0x815B: 0x30FC,
  0x815C: 0x2015, 0x815D: 0x2010, 0x815E: 0xFF0F, 0x815F: 0xFF3C,
  0x8160: 0x301C, 0x8161: 0x2016, 0x8162: 0xFF5C, 0x8163: 0x2026,
  0x8164: 0x2025, 0x8165: 0x2018, 0x8166: 0x2019, 0x8167: 0x201C,
  0x8168: 0x201D, 0x8169: 0xFF08, 0x816A: 0xFF09, 0x816B: 0x3014,
  0x816C: 0x3015, 0x816D: 0xFF3B, 0x816E: 0xFF3D, 0x816F: 0xFF5B,
  0x8170: 0xFF5D, 0x8171: 0x3008, 0x8172: 0x3009, 0x8173: 0x300A,
  0x8174: 0x300B, 0x8175: 0x300C, 0x8176: 0x300D, 0x8177: 0x300E,
  0x8178: 0x300F, 0x8179: 0x3010, 0x817A: 0x3011, 0x817B: 0xFF0B,
  0x817C: 0x2212, 0x817D: 0x00B1, 0x817E: 0x00D7, 0x8180: 0x00F7,
  0x8181: 0xFF1D, 0x8182: 0x2260, 0x8183: 0xFF1C, 0x8184: 0xFF1E,
  0x8185: 0x2266, 0x8186: 0x2267, 0x8187: 0x221E, 0x8188: 0x2234,
  0x8189: 0x2642, 0x818A: 0x2640, 0x818B: 0x00B0, 0x818C: 0x2032,
  0x818D: 0x2033, 0x818E: 0x2103, 0x818F: 0xFFE5, 0x8190: 0xFF04,
  0x8191: 0x00A2, 0x8192: 0x00A3, 0x8193: 0xFF05, 0x8194: 0xFF03,
  0x8195: 0xFF06, 0x8196: 0xFF0A, 0x8197: 0xFF20, 0x8198: 0x00A7,
  0x8199: 0x2606, 0x819A: 0x2605, 0x819B: 0x25CB, 0x819C: 0x25CF,
  0x819D: 0x25CE, 0x819E: 0x25C7, 0x819F: 0x25C6, 0x81A0: 0x25A1,
  0x81A1: 0x25A0, 0x81A2: 0x25B3, 0x81A3: 0x25B2, 0x81A4: 0x25BD,
  0x81A5: 0x25BC, 0x81A6: 0x203B, 0x81A7: 0x3012, 0x81A8: 0x2192,
  0x81A9: 0x2190, 0x81AA: 0x2191, 0x81AB: 0x2193, 0x81AC: 0x3013,
  0x81B8: 0x2208, 0x81B9: 0x220B, 0x81BA: 0x2286, 0x81BB: 0x2287,
  0x81BC: 0x2282, 0x81BD: 0x2283, 0x81BE: 0x222A, 0x81BF: 0x2229,
  0x81C8: 0x2227, 0x81C9: 0x2228, 0x81CA: 0x00AC, 0x81CB: 0x21D2,
  0x81CC: 0x21D4, 0x81CD: 0x2200, 0x81CE: 0x2203, 0x81DA: 0x2220,
  0x81DB: 0x22A5, 0x81DC: 0x2312, 0x81DD: 0x2202, 0x81DE: 0x2207,
  0x81DF: 0x2261, 0x81E0: 0x2252, 0x81E1: 0x226A, 0x81E2: 0x226B,
  0x81E3: 0x221A, 0x81E4: 0x223D, 0x81E5: 0x221D, 0x81E6: 0x2235,
  0x81E7: 0x222B, 0x81E8: 0x222C, 0x81F0: 0x212B, 0x81F1: 0x2030,
  0x81F2: 0x266F, 0x81F3: 0x266D, 0x81F4: 0x266A, 0x81F5: 0x2020,
  0x81F6: 0x2021, 0x81F7: 0x00B6, 0x81FC: 0x25EF,
  // Lead byte 0x82 — fullwidth digits, letters, hiragana
  0x824F: 0xFF10, 0x8250: 0xFF11, 0x8251: 0xFF12, 0x8252: 0xFF13,
  0x8253: 0xFF14, 0x8254: 0xFF15, 0x8255: 0xFF16, 0x8256: 0xFF17,
  0x8257: 0xFF18, 0x8258: 0xFF19,
  0x8260: 0xFF21, 0x8261: 0xFF22, 0x8262: 0xFF23, 0x8263: 0xFF24,
  0x8264: 0xFF25, 0x8265: 0xFF26, 0x8266: 0xFF27, 0x8267: 0xFF28,
  0x8268: 0xFF29, 0x8269: 0xFF2A, 0x826A: 0xFF2B, 0x826B: 0xFF2C,
  0x826C: 0xFF2D, 0x826D: 0xFF2E, 0x826E: 0xFF2F, 0x826F: 0xFF30,
  0x8270: 0xFF31, 0x8271: 0xFF32, 0x8272: 0xFF33, 0x8273: 0xFF34,
  0x8274: 0xFF35, 0x8275: 0xFF36, 0x8276: 0xFF37, 0x8277: 0xFF38,
  0x8278: 0xFF39, 0x8279: 0xFF3A,
  0x8281: 0xFF41, 0x8282: 0xFF42, 0x8283: 0xFF43, 0x8284: 0xFF44,
  0x8285: 0xFF45, 0x8286: 0xFF46, 0x8287: 0xFF47, 0x8288: 0xFF48,
  0x8289: 0xFF49, 0x828A: 0xFF4A, 0x828B: 0xFF4B, 0x828C: 0xFF4C,
  0x828D: 0xFF4D, 0x828E: 0xFF4E, 0x828F: 0xFF4F, 0x8290: 0xFF50,
  0x8291: 0xFF51, 0x8292: 0xFF52, 0x8293: 0xFF53, 0x8294: 0xFF54,
  0x8295: 0xFF55, 0x8296: 0xFF56, 0x8297: 0xFF57, 0x8298: 0xFF58,
  0x8299: 0xFF59, 0x829A: 0xFF5A,
  0x829F: 0x3041, 0x82A0: 0x3042, 0x82A1: 0x3043, 0x82A2: 0x3044,
  0x82A3: 0x3045, 0x82A4: 0x3046, 0x82A5: 0x3047, 0x82A6: 0x3048,
  0x82A7: 0x3049, 0x82A8: 0x304A, 0x82A9: 0x304B, 0x82AA: 0x304C,
  0x82AB: 0x304D, 0x82AC: 0x304E, 0x82AD: 0x304F, 0x82AE: 0x3050,
  0x82AF: 0x3051, 0x82B0: 0x3052, 0x82B1: 0x3053, 0x82B2: 0x3054,
  0x82B3: 0x3055, 0x82B4: 0x3056, 0x82B5: 0x3057, 0x82B6: 0x3058,
  0x82B7: 0x3059, 0x82B8: 0x305A, 0x82B9: 0x305B, 0x82BA: 0x305C,
  0x82BB: 0x305D, 0x82BC: 0x305E, 0x82BD: 0x305F, 0x82BE: 0x3060,
  0x82BF: 0x3061, 0x82C0: 0x3062, 0x82C1: 0x3063, 0x82C2: 0x3064,
  0x82C3: 0x3065, 0x82C4: 0x3066, 0x82C5: 0x3067, 0x82C6: 0x3068,
  0x82C7: 0x3069, 0x82C8: 0x306A, 0x82C9: 0x306B, 0x82CA: 0x306C,
  0x82CB: 0x306D, 0x82CC: 0x306E, 0x82CD: 0x306F, 0x82CE: 0x3070,
  0x82CF: 0x3071, 0x82D0: 0x3072, 0x82D1: 0x3073, 0x82D2: 0x3074,
  0x82D3: 0x3075, 0x82D4: 0x3076, 0x82D5: 0x3077, 0x82D6: 0x3078,
  0x82D7: 0x3079, 0x82D8: 0x307A, 0x82D9: 0x307B, 0x82DA: 0x307C,
  0x82DB: 0x307D, 0x82DC: 0x307E, 0x82DD: 0x307F, 0x82DE: 0x3080,
  0x82DF: 0x3081, 0x82E0: 0x3082, 0x82E1: 0x3083, 0x82E2: 0x3084,
  0x82E3: 0x3085, 0x82E4: 0x3086, 0x82E5: 0x3087, 0x82E6: 0x3088,
  0x82E7: 0x3089, 0x82E8: 0x308A, 0x82E9: 0x308B, 0x82EA: 0x308C,
  0x82EB: 0x308D, 0x82EC: 0x308E, 0x82ED: 0x308F, 0x82EE: 0x3090,
  0x82EF: 0x3091, 0x82F0: 0x3092, 0x82F1: 0x3093,
  // Lead byte 0x83 — fullwidth katakana and Greek
  0x8340: 0x30A1, 0x8341: 0x30A2, 0x8342: 0x30A3, 0x8343: 0x30A4,
  0x8344: 0x30A5, 0x8345: 0x30A6, 0x8346: 0x30A7, 0x8347: 0x30A8,
  0x8348: 0x30A9, 0x8349: 0x30AA, 0x834A: 0x30AB, 0x834B: 0x30AC,
  0x834C: 0x30AD, 0x834D: 0x30AE, 0x834E: 0x30AF, 0x834F: 0x30B0,
  0x8350: 0x30B1, 0x8351: 0x30B2, 0x8352: 0x30B3, 0x8353: 0x30B4,
  0x8354: 0x30B5, 0x8355: 0x30B6, 0x8356: 0x30B7, 0x8357: 0x30B8,
  0x8358: 0x30B9, 0x8359: 0x30BA, 0x835A: 0x30BB, 0x835B: 0x30BC,
  0x835C: 0x30BD, 0x835D: 0x30BE, 0x835E: 0x30BF, 0x835F: 0x30C0,
  0x8360: 0x30C1, 0x8361: 0x30C2, 0x8362: 0x30C3, 0x8363: 0x30C4,
  0x8364: 0x30C5, 0x8365: 0x30C6, 0x8366: 0x30C7, 0x8367: 0x30C8,
  0x8368: 0x30C9, 0x8369: 0x30CA, 0x836A: 0x30CB, 0x836B: 0x30CC,
  0x836C: 0x30CD, 0x836D: 0x30CE, 0x836E: 0x30CF, 0x836F: 0x30D0,
  0x8370: 0x30D1, 0x8371: 0x30D2, 0x8372: 0x30D3, 0x8373: 0x30D4,
  0x8374: 0x30D5, 0x8375: 0x30D6, 0x8376: 0x30D7, 0x8377: 0x30D8,
  0x8378: 0x30D9, 0x8379: 0x30DA, 0x837A: 0x30DB, 0x837B: 0x30DC,
  0x837C: 0x30DD, 0x837D: 0x30DE, 0x837E: 0x30DF, 0x8380: 0x30E0,
  0x8381: 0x30E1, 0x8382: 0x30E2, 0x8383: 0x30E3, 0x8384: 0x30E4,
  0x8385: 0x30E5, 0x8386: 0x30E6, 0x8387: 0x30E7, 0x8388: 0x30E8,
  0x8389: 0x30E9, 0x838A: 0x30EA, 0x838B: 0x30EB, 0x838C: 0x30EC,
  0x838D: 0x30ED, 0x838E: 0x30EE, 0x838F: 0x30EF, 0x8390: 0x30F0,
  0x8391: 0x30F1, 0x8392: 0x30F2, 0x8393: 0x30F3, 0x8394: 0x30F4,
  0x8395: 0x30F5, 0x8396: 0x30F6,
  0x839F: 0x0391, 0x83A0: 0x0392, 0x83A1: 0x0393, 0x83A2: 0x0394,
  0x83A3: 0x0395, 0x83A4: 0x0396, 0x83A5: 0x0397, 0x83A6: 0x0398,
  0x83A7: 0x0399, 0x83A8: 0x039A, 0x83A9: 0x039B, 0x83AA: 0x039C,
  0x83AB: 0x039D, 0x83AC: 0x039E, 0x83AD: 0x039F, 0x83AE: 0x03A0,
  0x83AF: 0x03A1, 0x83B0: 0x03A3, 0x83B1: 0x03A4, 0x83B2: 0x03A5,
  0x83B3: 0x03A6, 0x83B4: 0x03A7, 0x83B5: 0x03A8, 0x83B6: 0x03A9,
  0x83BF: 0x03B1, 0x83C0: 0x03B2, 0x83C1: 0x03B3, 0x83C2: 0x03B4,
  0x83C3: 0x03B5, 0x83C4: 0x03B6, 0x83C5: 0x03B7, 0x83C6: 0x03B8,
  0x83C7: 0x03B9, 0x83C8: 0x03BA, 0x83C9: 0x03BB, 0x83CA: 0x03BC,
  0x83CB: 0x03BD, 0x83CC: 0x03BE, 0x83CD: 0x03BF, 0x83CE: 0x03C0,
  0x83CF: 0x03C1, 0x83D0: 0x03C3, 0x83D1: 0x03C4, 0x83D2: 0x03C5,
  0x83D3: 0x03C6, 0x83D4: 0x03C7, 0x83D5: 0x03C8, 0x83D6: 0x03C9,
  // Lead byte 0x84 — Cyrillic and box-drawing
  0x8440: 0x0410, 0x8441: 0x0411, 0x8442: 0x0412, 0x8443: 0x0413,
  0x8444: 0x0414, 0x8445: 0x0415, 0x8446: 0x0401, 0x8447: 0x0416,
  0x8448: 0x0417, 0x8449: 0x0418, 0x844A: 0x0419, 0x844B: 0x041A,
  0x844C: 0x041B, 0x844D: 0x041C, 0x844E: 0x041D, 0x844F: 0x041E,
  0x8450: 0x041F, 0x8451: 0x0420, 0x8452: 0x0421, 0x8453: 0x0422,
  0x8454: 0x0423, 0x8455: 0x0424, 0x8456: 0x0425, 0x8457: 0x0426,
  0x8458: 0x0427, 0x8459: 0x0428, 0x845A: 0x0429, 0x845B: 0x042A,
  0x845C: 0x042B, 0x845D: 0x042C, 0x845E: 0x042D, 0x845F: 0x042E,
  0x8460: 0x042F, 0x8470: 0x0430, 0x8471: 0x0431, 0x8472: 0x0432,
  0x8473: 0x0433, 0x8474: 0x0434, 0x8475: 0x0435, 0x8476: 0x0451,
  0x8477: 0x0436, 0x8478: 0x0437, 0x8479: 0x0438, 0x847A: 0x0439,
  0x847B: 0x043A, 0x847C: 0x043B, 0x847D: 0x043C, 0x847E: 0x043D,
  0x8480: 0x043E, 0x8481: 0x043F, 0x8482: 0x0440, 0x8483: 0x0441,
  0x8484: 0x0442, 0x8485: 0x0443, 0x8486: 0x0444, 0x8487: 0x0445,
  0x8488: 0x0446, 0x8489: 0x0447, 0x848A: 0x0448, 0x848B: 0x0449,
  0x848C: 0x044A, 0x848D: 0x044B, 0x848E: 0x044C, 0x848F: 0x044D,
  0x8490: 0x044E, 0x8491: 0x044F,
  0x849F: 0x2500, 0x84A0: 0x2502, 0x84A1: 0x250C, 0x84A2: 0x2510,
  0x84A3: 0x2518, 0x84A4: 0x2514, 0x84A5: 0x251C, 0x84A6: 0x252C,
  0x84A7: 0x2524, 0x84A8: 0x2534, 0x84A9: 0x253C, 0x84AA: 0x2501,
  0x84AB: 0x2503, 0x84AC: 0x250F, 0x84AD: 0x2513, 0x84AE: 0x251B,
  0x84AF: 0x2517, 0x84B0: 0x2523, 0x84B1: 0x2533, 0x84B2: 0x252B,
  0x84B3: 0x253B, 0x84B4: 0x254B, 0x84B5: 0x2520, 0x84B6: 0x252F,
  0x84B7: 0x2528, 0x84B8: 0x2537, 0x84B9: 0x253F, 0x84BA: 0x251D,
  0x84BB: 0x2530, 0x84BC: 0x2525, 0x84BD: 0x2538, 0x84BE: 0x2542,
};

/// Decode a Shift-JIS byte sequence to a Unicode string.
///
/// ASCII (0x00-0x7E) is identical in Shift-JIS.
/// Half-width Katakana (0xA1-0xDF) maps to U+FF61-U+FF9F.
/// Double-byte sequences are looked up in [_sjisDoubleByte].
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
        final cp = _sjisDoubleByte[(b << 8) | trail] ?? 0xFFFD;
        result.writeCharCode(cp);
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
  void loadEms(SaveIo f) {
    final direntBytes = f.read(ps2mcDirentLength);
    final dotBytes = f.read(ps2mcDirentLength);
    final dotdotBytes = f.read(ps2mcDirentLength);
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
      final entBytes = f.read(ps2mcDirentLength);
      if (entBytes.length != ps2mcDirentLength) {
        throw FormatException('PSU file truncated at file entry $i');
      }
      final ent = PS2DirEntry.unpack(entBytes);
      if (!modeIsFile(ent.mode)) {
        throw FormatException('PSU file has a subdirectory (not supported)');
      }
      final flen = ent.length;
      final data = f.read(flen);
      if (data.length != flen) {
        throw FormatException('PSU file truncated at file data $i');
      }
      // Skip padding to next cluster boundary.
      final pad = roundUp(flen, clusterSize) - flen;
      if (pad > 0) f.read(pad);
      setFile(i, ent, data);
    }
  }

  /// Write the save file in PSU (.psu / EMS) format to [f].
  void saveEms(SaveIo f) {
    const clusterSize = 1024;
    final dirent = getDirectory();
    final dirWithDots = dirent.copyWith(length: dirent.length + 2);
    f.write(dirWithDots.pack());
    f.write(PS2DirEntry(
      mode: dfRwx | dfDir | df0400 | dfExists,
      length: 0,
      created: dirent.created,
      fatCluster: 0,
      parentEntry: 0,
      modified: dirent.created,
      name: '.',
    ).pack());
    f.write(PS2DirEntry(
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
      f.write(ent.pack());
      f.write(data);
      final pad = roundUp(data.length, clusterSize) - data.length;
      if (pad > 0) f.write(Uint8List(pad));
    }
    f.flush();
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

Uint8List _readFixed(SaveIo f, int n) {
  final data = f.read(n);
  if (data.length != n) throw FormatException('Save file truncated');
  return data;
}

Uint8List _readLongString(SaveIo f) {
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
  void loadMax(SaveIo f, [PS2Tod? timestamp]) {
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
      final pos = f.position();
      final remaining = f.length() - pos;
      body = f.read(remaining);
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
  void saveMax(SaveIo f) {
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

    f.write(hdr);
    f.write(compressed);
    f.flush();
  }

  // ---------------------------------------------------------------------------
  // SharkPort / X-Port format — load
  // ---------------------------------------------------------------------------

  /// Load a SharkPort (.sps / .xps) save file from [f].
  /// Magic: \x0D\x00\x00\x00SharkPortSave (17 bytes).
  void loadSps(SaveIo f) {
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
  void loadCbs(SaveIo f) {
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
    final rawBody = f.read(flen);
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

  void saveSps(SaveIo f) {
    throw UnimplementedError('saveSps not yet implemented');
  }

  // ---------------------------------------------------------------------------
  // CodeBreaker (.cbs) writer — Phase 5
  // ---------------------------------------------------------------------------

  void saveCbs(SaveIo f) {
    throw UnimplementedError('saveCbs not yet implemented');
  }
}

// Extension to allow .let{} style chaining (used in IconSys.unpack)
extension _Let<T> on T {
  R let<R>(R Function(T) block) => block(this);
}
