// ps2mc_ecc.dart
//
// Ported from ps2mc_ecc.py by Ross Ridge (Public Domain)
// Routines for calculating Hamming codes (ECC) as used on PS2 memory cards.

import 'dart:typed_data';
import 'round.dart';

const int eccCheckOk = 0;
const int eccCheckCorrected = 1;
const int eccCheckFailed = 2;

int _popcount(int a) {
  int count = 0;
  while (a != 0) {
    a &= a - 1;
    count++;
  }
  return count;
}

int _parityb(int a) {
  a = (a ^ (a >> 1));
  a = (a ^ (a >> 2));
  a = (a ^ (a >> 4));
  return a & 1;
}

// Precomputed lookup tables (built once at startup).
final List<int> _parityTable = List.generate(256, _parityb);

final List<int> _columnParityMasks = () {
  const cpmasks = [0x55, 0x33, 0x0F, 0x00, 0xAA, 0xCC, 0xF0];
  final masks = List.filled(256, 0);
  for (int b = 0; b < 256; b++) {
    int mask = 0;
    for (int i = 0; i < cpmasks.length; i++) {
      mask |= _parityTable[b & cpmasks[i]] << i;
    }
    masks[b] = mask;
  }
  return masks;
}();

/// Calculate the Hamming code for a 128-byte chunk.
/// Returns a 3-element list: [column_parity, line_parity_0, line_parity_1].
List<int> eccCalculate(Uint8List s) {
  int columnParity = 0x77;
  int lineParity0 = 0x7F;
  int lineParity1 = 0x7F;

  for (int i = 0; i < s.length; i++) {
    final b = s[i];
    columnParity ^= _columnParityMasks[b];
    if (_parityTable[b] != 0) {
      // ~i in Dart is -(i+1) — same two's-complement behaviour as Python 2.
      lineParity0 ^= ~i;
      lineParity1 ^= i;
    }
  }
  return [columnParity & 0xFF, lineParity0 & 0x7F, lineParity1 & 0xFF];
}

/// Detect and correct any single-bit errors in a 128-byte chunk.
///
/// [s] and [ecc] are modified in-place if a correction is made.
/// Returns eccCheckOk, eccCheckCorrected, or eccCheckFailed.
int eccCheck(Uint8List s, List<int> ecc) {
  final computed = eccCalculate(s);
  if (computed[0] == ecc[0] &&
      computed[1] == ecc[1] &&
      computed[2] == ecc[2]) {
    return eccCheckOk;
  }

  final cpDiff = (computed[0] ^ ecc[0]) & 0x77;
  final lp0Diff = (computed[1] ^ ecc[1]) & 0x7F;
  final lp1Diff = (computed[2] ^ ecc[2]) & 0x7F;
  final lpComp = lp0Diff ^ lp1Diff;
  final cpComp = (cpDiff >> 4) ^ (cpDiff & 0x07);

  if (lpComp == 0x7F && cpComp == 0x07) {
    // Correctable 1-bit error in data.
    s[lp1Diff] ^= 1 << (cpDiff >> 4);
    return eccCheckCorrected;
  }

  if ((cpDiff == 0 && lp0Diff == 0 && lp1Diff == 0) ||
      _popcount(lpComp) + _popcount(cpComp) == 1) {
    // Correctable 1-bit error in ECC (or unused bit set).
    ecc[0] = computed[0];
    ecc[1] = computed[1];
    ecc[2] = computed[2];
    return eccCheckCorrected;
  }

  return eccCheckFailed;
}

/// Return ECC codes for all 128-byte chunks in a PS2 memory card page.
List<List<int>> eccCalculatePage(Uint8List page) {
  final numChunks = divRoundUp(page.length, 128);
  return List.generate(numChunks, (i) {
    final start = i * 128;
    final end = (start + 128).clamp(0, page.length);
    return eccCalculate(Uint8List.sublistView(page, start, end));
  });
}

typedef EccPageResult = ({int status, Uint8List page, Uint8List spare});

/// Check and correct any single-bit errors in a PS2 memory card page.
EccPageResult eccCheckPage(Uint8List page, Uint8List spare) {
  final numChunks = divRoundUp(page.length, 128);

  // Extract mutable copies of each 128-byte chunk and its 3-byte ECC.
  final chunkData = List.generate(numChunks, (i) {
    final start = i * 128;
    final end = (start + 128).clamp(0, page.length);
    return Uint8List.fromList(page.sublist(start, end));
  });
  final chunkEcc = List.generate(numChunks, (i) {
    return [spare[i * 3], spare[i * 3 + 1], spare[i * 3 + 2]];
  });

  final results = List.generate(
      numChunks, (i) => eccCheck(chunkData[i], chunkEcc[i]));

  bool failed = results.contains(eccCheckFailed);
  bool corrected = results.contains(eccCheckCorrected);

  if (failed) {
    return (status: eccCheckFailed, page: page, spare: spare);
  }

  if (corrected) {
    // Rebuild page and spare from the corrected chunks.
    final newPage = Uint8List(page.length);
    final newSpare = Uint8List(spare.length);
    for (int i = 0; i < numChunks; i++) {
      final start = i * 128;
      final end = (start + 128).clamp(0, page.length);
      newPage.setRange(start, end, chunkData[i]);
      newSpare[i * 3] = chunkEcc[i][0];
      newSpare[i * 3 + 1] = chunkEcc[i][1];
      newSpare[i * 3 + 2] = chunkEcc[i][2];
    }
    return (status: eccCheckCorrected, page: newPage, spare: newSpare);
  }

  return (status: eccCheckOk, page: page, spare: spare);
}
