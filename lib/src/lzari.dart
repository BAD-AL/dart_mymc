// lzari.dart
//
// Port of lzari.py by Ross Ridge (Public Domain)
// Implementation of Haruhiko Okumura's LZARI data compression algorithm.

import 'dart:typed_data';

const int _histLen = 4096;
const int _minMatchLen = 3;
const int _maxMatchLen = 60;
const int _arithBits = 15;
const int _q1 = 1 << _arithBits; // 32768
const int _q2 = _q1 * 2; // 65536
const int _q3 = _q1 * 3; // 98304
const int _q4 = _q1 * 4; // 131072
const int _maxCum = _q1 - 1; // 32767
const int _maxChar = 256 + _maxMatchLen - _minMatchLen + 1; // 314

// ---------------------------------------------------------------------------
// Bit array helpers — MSB first per byte
// ---------------------------------------------------------------------------

List<int> _bytesToBits(Uint8List src) {
  final bits = List<int>.filled(src.length * 8, 0, growable: true);
  int bi = 0;
  for (final b in src) {
    for (int shift = 7; shift >= 0; shift--) {
      bits[bi++] = (b >> shift) & 1;
    }
  }
  return bits;
}

Uint8List _bitsToBytes(List<int> bits) {
  final rem = bits.length % 8;
  if (rem != 0) bits.addAll(List.filled(8 - rem, 0));
  final out = Uint8List(bits.length >> 3);
  for (int i = 0; i < out.length; i++) {
    int b = 0;
    for (int j = 0; j < 8; j++) b = (b << 1) | bits[i * 8 + j];
    out[i] = b;
  }
  return out;
}

// positionCum[0..HIST_LEN]: descending, positionCum[0] is max, [HIST_LEN]=0
List<int> _makePositionCum() {
  final pc = List<int>.filled(_histLen + 1, 0);
  int a = 0;
  for (int i = _histLen; i >= 1; i--) {
    a += 10000 ~/ (200 + i);
    pc[i - 1] = a;
  }
  return pc;
}

// Binary search on descending table: first index c where table[c] <= x.
int _searchDesc(List<int> table, int x) {
  int c = 1, s = table.length - 1;
  while (true) {
    final a = (s + c) ~/ 2;
    if (table[a] <= x) {
      s = a;
    } else {
      c = a + 1;
    }
    if (c >= s) break;
  }
  return c;
}

// ---------------------------------------------------------------------------
// Decode
// ---------------------------------------------------------------------------

/// Decompress LZARI-compressed [src] into exactly [outLength] bytes.
Uint8List lzariDecode(Uint8List src, int outLength) {
  if (outLength == 0) return Uint8List(0);

  final bits = _bytesToBits(src);
  bits.addAll(List.filled(32, 0)); // safety padding
  int bitPos = 0;
  int nextBit() => bits[bitPos++];

  // Decode model (ascending sym_cum)
  final symCum = List<int>.generate(_maxChar + 1, (i) => i); // [0,1,...,314]
  final symFreq = [0, ...List<int>.filled(_maxChar, 1)];
  final symbolToChar = [0, ...List<int>.generate(_maxChar, (i) => i)];
  final positionCum = _makePositionCum();

  int high = _q4, low = 0, code = 0;
  for (int i = 0; i < _arithBits + 2; i++) code = code * 2 + nextBit();

  // History: first (HIST_LEN-MAX_MATCH_LEN) bytes = 0x20, rest = 0x00
  final histPos0 = _histLen - _maxMatchLen; // 4036
  final history = List<int>.filled(_histLen, 0);
  for (int i = 0; i < histPos0; i++) history[i] = 0x20;
  int histPos = histPos0;

  void updateModel(int symbol) {
    if (symCum[_maxChar] >= _maxCum) {
      int c = 0;
      for (int i = _maxChar; i >= 1; i--) {
        symCum[_maxChar - i] = c;
        final a = (symFreq[i] + 1) ~/ 2;
        symFreq[i] = a;
        c += a;
      }
      symCum[_maxChar] = c;
    }
    final freq = symFreq[symbol];
    int ns = symbol;
    while (symFreq[ns - 1] == freq) ns--;
    if (ns != symbol) {
      final sc = symbolToChar[ns];
      symbolToChar[ns] = symbolToChar[symbol];
      symbolToChar[symbol] = sc;
    }
    symFreq[ns] = freq + 1;
    for (int i = _maxChar - ns + 1; i <= _maxChar; i++) symCum[i]++;
  }

  int decodeChar() {
    final range = high - low;
    final mcf = symCum[_maxChar];
    final n = ((code - low + 1) * mcf - 1) ~/ range;
    // bisect_right(symCum, n, 1): first i>=1 where symCum[i] > n
    int lo = 1, hi = _maxChar + 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (symCum[mid] <= n) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final idx = lo;
    high = low + symCum[idx] * range ~/ mcf;
    low += symCum[idx - 1] * range ~/ mcf;
    final symbol = _maxChar + 1 - idx;
    while (true) {
      if (low < _q2) {
        if (low < _q1 || high > _q3) {
          if (high > _q2) break;
        } else {
          low -= _q1;
          code -= _q1;
          high -= _q1;
        }
      } else {
        low -= _q2;
        code -= _q2;
        high -= _q2;
      }
      low *= 2;
      high *= 2;
      code = code * 2 + nextBit();
    }
    final ret = symbolToChar[symbol];
    updateModel(symbol);
    return ret;
  }

  int decodePosition() {
    final range = high - low;
    final maxCum = positionCum[0];
    final pos = _searchDesc(positionCum, ((code - low + 1) * maxCum - 1) ~/ range) - 1;
    high = low + positionCum[pos] * range ~/ maxCum;
    low += positionCum[pos + 1] * range ~/ maxCum;
    while (true) {
      if (low < _q2) {
        if (low < _q1 || high > _q3) {
          if (high > _q2) return pos;
        } else {
          low -= _q1;
          code -= _q1;
          high -= _q1;
        }
      } else {
        low -= _q2;
        code -= _q2;
        high -= _q2;
      }
      low *= 2;
      high *= 2;
      code = nextBit() + code * 2;
    }
  }

  final out = Uint8List(outLength);
  int outpos = 0;
  while (outpos < outLength) {
    final ch = decodeChar();
    if (ch >= 0x100) {
      final pos = decodePosition();
      final length = ch - 0x100 + _minMatchLen;
      final base = (histPos - pos - 1) % _histLen;
      for (int off = 0; off < length; off++) {
        final a = history[(base + off) % _histLen];
        out[outpos++] = a;
        history[histPos] = a;
        histPos = (histPos + 1) % _histLen;
      }
    } else {
      out[outpos++] = ch;
      history[histPos] = ch;
      histPos = (histPos + 1) % _histLen;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Encode
// ---------------------------------------------------------------------------

/// Compress [src] using the LZARI algorithm.
Uint8List lzariEncode(Uint8List src) {
  final length = src.length;
  if (length == 0) return Uint8List(0);

  final maxMatch = _maxMatchLen < length ? _maxMatchLen : length;

  // Prepend maxMatch spaces (0x20) — matches the Python
  final padded = List<int>.filled(maxMatch + length, 0x20);
  for (int i = 0; i < length; i++) padded[maxMatch + i] = src[i];
  final inLen = padded.length;

  // Encode model (descending sym_cum)
  final symCum = List<int>.generate(_maxChar + 1, (i) => _maxChar - i);
  final symFreq = [0, ...List<int>.filled(_maxChar, 1)];
  final symbolToChar = [0, ...List<int>.generate(_maxChar, (i) => i)];
  final charToSymbol = List<int>.generate(_maxChar, (i) => i + 1);
  final positionCum = _makePositionCum();

  int high = _q4, low = 0, shifts = 0;
  final outBits = <int>[];

  void outputBit(int bit) {
    outBits.add(bit);
    final inv = bit ^ 1;
    for (int i = 0; i < shifts; i++) outBits.add(inv);
    shifts = 0;
  }

  void updateModelEncode(int symbol) {
    if (symCum[0] >= _maxCum) {
      int c = 0;
      for (int i = _maxChar; i >= 1; i--) {
        symCum[i] = c;
        final a = (symFreq[i] + 1) ~/ 2;
        symFreq[i] = a;
        c += a;
      }
      symCum[0] = c;
    }
    final freq = symFreq[symbol];
    int ns = symbol;
    while (symFreq[ns - 1] == freq) ns--;
    if (ns != symbol) {
      final sc = symbolToChar[ns];
      final ch = symbolToChar[symbol];
      symbolToChar[ns] = ch;
      symbolToChar[symbol] = sc;
      charToSymbol[ch] = ns;
      charToSymbol[sc] = symbol;
    }
    symFreq[ns]++;
    for (int i = 0; i < ns; i++) symCum[i]++;
  }

  void encodeChar(int char_) {
    final symbol = charToSymbol[char_];
    final range = high - low;
    high = low + range * symCum[symbol - 1] ~/ symCum[0];
    low += range * symCum[symbol] ~/ symCum[0];
    while (true) {
      if (high <= _q2) {
        outputBit(0);
      } else if (low >= _q2) {
        outputBit(1);
        low -= _q2;
        high -= _q2;
      } else if (low >= _q1 && high <= _q3) {
        shifts++;
        low -= _q1;
        high -= _q1;
      } else {
        break;
      }
      low *= 2;
      high *= 2;
    }
    updateModelEncode(symbol);
  }

  void encodePosition(int position) {
    final range = high - low;
    high = low + range * positionCum[position] ~/ positionCum[0];
    low += range * positionCum[position + 1] ~/ positionCum[0];
    while (true) {
      if (high <= _q2) {
        outputBit(0);
      } else if (low >= _q2) {
        outputBit(1);
        low -= _q2;
        high -= _q2;
      } else if (low >= _q1 && high <= _q3) {
        shifts++;
        low -= _q1;
        high -= _q1;
      } else {
        break;
      }
      low *= 2;
      high *= 2;
    }
  }

  // Safe key: slice padded[start..end], returning '' when start >= end or out of bounds.
  String safeKey(int start, int end) {
    if (start >= end || start >= inLen) return '';
    final safeEnd = end > inLen ? inLen : end;
    return String.fromCharCodes(padded, start, safeEnd);
  }

  // ---------------------------------------------------------------------------
  // Two-level suffix table for LZ77 matching (port of add_suffix_2)
  // ---------------------------------------------------------------------------

  final Map<String, List<dynamic>> suffixTable = {};
  final nextTable = List<int>.filled(_histLen, 0);
  final next2Table = List<int>.filled(_histLen, 0);

  // Check if padded[pos..pos+m] == padded[hpos..hpos+m], then extend to end.
  // Returns the new extended match length (>= curMlen+1), or null if no improvement.
  int? matchExtend(int pos, int hpos, int curMlen, int end) {
    final m = curMlen + 1;
    if (pos + m > inLen || hpos + m > inLen) return null;
    for (int k = 0; k < m; k++) {
      if (padded[pos + k] != padded[hpos + k]) return null;
    }
    int i = m;
    while (i < end) {
      if (pos + i >= inLen || hpos + i >= inLen) return i;
      if (padded[pos + i] != padded[hpos + i]) return i;
      i++;
    }
    return end;
  }

  Map<String, int> rehashTable2(int chars, int head, int histInvalid) {
    int p = head;
    final l = <int>[];
    while (p > histInvalid) {
      l.add(p);
      p = nextTable[p % _histLen];
    }
    final result = <String, int>{};
    for (int ii = l.length - 1; ii >= 0; ii--) {
      final pp = l[ii];
      final p2 = pp + _minMatchLen;
      final k2 = safeKey(p2, p2 + chars);
      next2Table[pp % _histLen] = result[k2] ?? histInvalid;
      result[k2] = pp;
    }
    return result;
  }

  (int?, int) addSuffix(int pos, bool find) {
    // Clamp effective max match to remaining input (mirrors Python's min(max_match, len(src)-pos))
    final effMax = (inLen - pos) < maxMatch ? (inLen - pos) : maxMatch;
    if (effMax <= 0) return (null, -1);

    final histInvalid = pos - _histLen - 1;
    final modpos = pos % _histLen;
    final pos2 = pos + _minMatchLen;
    final key = safeKey(pos, pos2);

    int mlen = -1;
    int? mpos;

    final existing = suffixTable[key];
    if (existing != null) {
      int count = existing[0] as int;
      int head = existing[1] as int;
      Map<String, int> table2 = existing[2] as Map<String, int>;
      int chars = existing[3] as int;

      final pos3 = pos2 + chars; // absolute source position past the two-level key
      final key2 = safeKey(pos2, pos3);
      final minMatch2 = _minMatchLen + chars;

      if (find) {
        int p = table2[key2] ?? histInvalid;
        final maxmlen = effMax - minMatch2;
        while (p > histInvalid && mlen != maxmlen) {
          final p3 = p + minMatch2;
          if (mpos == null && p3 <= pos) {
            mpos = p;
            mlen = 0;
          }
          if (p3 >= pos) {
            p = next2Table[p % _histLen];
            continue;
          }
          final lim = pos - p3;
          final end = maxmlen < lim ? maxmlen : lim;
          final rlen = matchExtend(pos3, p3, mlen, end);
          if (rlen != null) {
            mpos = p;
            mlen = rlen;
          }
          p = next2Table[p % _histLen];
        }
      }

      if (mpos != null) {
        mlen += minMatch2;
      } else if (find) {
        // Level-1 fallback when no level-2 match found
        int p = head;
        final maxmlen2 =
            chars < effMax - _minMatchLen ? chars : effMax - _minMatchLen;
        int iCount = 0;
        while (p > histInvalid && iCount < 50000 && mlen < maxmlen2) {
          iCount++;
          final p2 = p + _minMatchLen;
          final l2raw = pos - p2;
          if (mpos == null && l2raw >= 0) {
            mpos = p;
            mlen = 0;
          }
          if (l2raw <= 0) {
            p = nextTable[p % _histLen];
            continue;
          }
          final l2 = l2raw > maxmlen2 ? maxmlen2 : l2raw;
          final m = mlen + 1;
          bool ok = pos2 + m <= inLen && p2 + m <= inLen;
          if (ok) {
            for (int k = 0; k < m; k++) {
              if (padded[pos2 + k] != padded[p2 + k]) {
                ok = false;
                break;
              }
            }
          }
          if (ok) {
            mpos = p;
            int j = m;
            while (j < l2 && pos2 + j < inLen && p2 + j < inLen) {
              if (padded[pos2 + j] != padded[p2 + j]) {
                mlen = j;
                break;
              }
              j++;
            }
            if (j >= l2 || pos2 + j >= inLen || p2 + j >= inLen) mlen = l2;
          }
          p = nextTable[p % _histLen];
        }
        if (mpos != null) mlen += _minMatchLen;
      }

      // Grow secondary key if count warrants it
      count++;
      int newChars = count > 1 ? (count.bitLength - 1) : 0;
      final maxChars = effMax - _minMatchLen;
      if (newChars > maxChars) newChars = maxChars;
      if (newChars > chars) {
        chars = newChars;
        table2 = rehashTable2(chars, head, histInvalid);
      }

      nextTable[modpos] = head;
      head = pos;
      final nk2 = safeKey(pos2, pos2 + chars);
      next2Table[modpos] = table2[nk2] ?? histInvalid;
      table2[nk2] = pos;

      existing[0] = count;
      existing[1] = head;
      existing[2] = table2;
      existing[3] = chars;
    } else {
      nextTable[modpos] = histInvalid;
      next2Table[modpos] = histInvalid;
      suffixTable[key] = [1, pos, <String, int>{'': pos}, 0];
    }

    // Remove expired suffix (position pos - HIST_LEN)
    final oldPos = pos - _histLen;
    if (oldPos >= 0) {
      final op2 = oldPos + _minMatchLen;
      final opKeyEnd = op2 < inLen ? op2 : inLen;
      final opKey = String.fromCharCodes(padded, oldPos, opKeyEnd);
      final opEntry = suffixTable[opKey];
      if (opEntry != null) {
        int opCount = (opEntry[0] as int) - 1;
        if (opCount == 0) {
          suffixTable.remove(opKey);
        } else {
          final opChars = opEntry[3] as int;
          final opTable2 = opEntry[2] as Map<String, int>;
          final opk2End = op2 + opChars < inLen ? op2 + opChars : inLen;
          final opk2 = String.fromCharCodes(padded, op2, opk2End);
          if (opTable2[opk2] == oldPos) opTable2.remove(opk2);
          opEntry[0] = opCount;
        }
      }
    }

    return (mpos, mlen);
  }

  // Prime suffix table with first maxMatch positions
  for (int pos = 0; pos < maxMatch; pos++) {
    addSuffix(pos, false);
  }

  int inPos = maxMatch;
  while (inPos < inLen) {
    final (matchPos, matchLen) = addSuffix(inPos, true);
    if (matchLen < _minMatchLen) {
      encodeChar(padded[inPos]);
    } else {
      encodeChar(256 - _minMatchLen + matchLen);
      encodePosition(inPos - matchPos! - 1);
      for (int i = 0; i < matchLen - 1; i++) {
        inPos++;
        addSuffix(inPos, false);
      }
    }
    inPos++;
  }

  shifts++;
  outputBit(low < _q1 ? 0 : 1);

  return _bitsToBytes(outBits);
}
