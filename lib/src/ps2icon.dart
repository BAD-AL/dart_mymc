// ps2icon.dart
//
// Parses PS2 save icon (.ico/.icn) files and exposes typed data ready for
// WebGL upload.  See PS2_IconWebRender.md for format details and
// ps2mc-browser/packages/ps2mc-core/src/ps2mc/icon.py for the reference impl.

import 'dart:typed_data';
import 'ps2save.dart' show IconSys;

// ---------------------------------------------------------------------------
// Ps2IconData — value type returned to library consumers
// ---------------------------------------------------------------------------

/// Parsed PS2 3D icon ready for WebGL rendering.
///
/// All int16 coordinates are pre-divided by [fixedPointFactor] (4096.0) and
/// stored as float32.  Texture is decoded A1B5G5R5 → RGB (3 bytes/pixel).
class Ps2IconData {
  static const double fixedPointFactor = 4096.0;
  static const int textureWidth  = 128;
  static const int textureHeight = 128;

  final int vertexCount;

  /// Number of morph-target animation shapes (frames).
  final int animationShapes;

  /// Per-shape vertex positions: [animationShapes] lists, each [vertexCount×3] floats (x,y,z).
  final List<Float32List> positions;

  /// Static vertex normals: [vertexCount×3] floats (nx,ny,nz).
  final Float32List normals;

  /// Static UV coordinates: [vertexCount×2] floats (u,v).
  final Float32List uvs;

  /// Static per-vertex colors: [vertexCount×4] bytes (RGBA).
  final Uint8List vertexColors;

  /// Decoded texture: 128×128 pixels, RGB (3 bytes/pixel), or null if absent.
  final Uint8List? texture;

  // --- Animation header ---
  final int    frameLength;
  final double animSpeed;
  final int    playOffset;
  final int    frameCount;

  // --- Lighting (from icon.sys) ---
  /// Background transparency, 0–128 (divide by 128.0 to get 0..1 alpha).
  final int bgTransparency;

  /// Four corner background colors as 16 uint32 values (4 corners × [R,G,B,A], each 0–255).
  final List<int> bgColors;

  final List<double> lightDir1;
  final List<double> lightDir2;
  final List<double> lightDir3;
  final List<double> lightColor1;
  final List<double> lightColor2;
  final List<double> lightColor3;
  final List<double> ambient;

  const Ps2IconData({
    required this.vertexCount,
    required this.animationShapes,
    required this.positions,
    required this.normals,
    required this.uvs,
    required this.vertexColors,
    required this.texture,
    required this.frameLength,
    required this.animSpeed,
    required this.playOffset,
    required this.frameCount,
    required this.bgTransparency,
    required this.bgColors,
    required this.lightDir1,
    required this.lightDir2,
    required this.lightDir3,
    required this.lightColor1,
    required this.lightColor2,
    required this.lightColor3,
    required this.ambient,
  });
}

// ---------------------------------------------------------------------------
// parseIconFile
// ---------------------------------------------------------------------------

/// Parse a PS2 icon binary (`.ico` / `.icn`) and combine it with lighting
/// parameters from [iconSys].  Returns null if [bytes] is not a valid icon.
Ps2IconData? parseIconFile(Uint8List bytes, IconSys iconSys) {
  if (bytes.length < 20) return null;
  final bd = ByteData.sublistView(bytes);

  // --- Header (5 × uint32 = 20 bytes) ---
  final magic         = bd.getUint32(0, Endian.little);
  final animShapes    = bd.getUint32(4, Endian.little);
  final texType       = bd.getUint32(8, Endian.little);
  // bd.getUint32(12) = unknown, skip
  final vertexCount   = bd.getUint32(16, Endian.little);

  if (magic != 0x010000) return null;
  if (animShapes == 0 || vertexCount == 0) return null;

  int offset = 20;

  // --- Geometry (interleaved per vertex) ---
  // Per vertex i:
  //   animShapes × (int16 x,y,z + uint16 pad) = animShapes × 8 bytes  [positions]
  //   int16 nx,ny,nz + uint16 pad              = 8 bytes               [normal, static]
  //   int16 u,v                                = 4 bytes               [uv, static]
  //   uint8 r,g,b,a                            = 4 bytes               [color, static]

  final posArrays   = List.generate(animShapes, (_) => Float32List(vertexCount * 3));
  final normalsBuf  = Float32List(vertexCount * 3);
  final uvsBuf      = Float32List(vertexCount * 2);
  final colorsBuf   = Uint8List(vertexCount * 4);

  const scale = 1.0 / Ps2IconData.fixedPointFactor;
  final needed = vertexCount * (animShapes * 8 + 8 + 4 + 4);
  if (offset + needed > bytes.length) return null;

  for (int i = 0; i < vertexCount; i++) {
    for (int s = 0; s < animShapes; s++) {
      final base = i * 3;
      posArrays[s][base]     = bd.getInt16(offset,     Endian.little) * scale;
      posArrays[s][base + 1] = bd.getInt16(offset + 2, Endian.little) * scale;
      posArrays[s][base + 2] = bd.getInt16(offset + 4, Endian.little) * scale;
      offset += 8; // x,y,z (3×int16) + pad (uint16)
    }

    final nb = i * 3;
    normalsBuf[nb]     = bd.getInt16(offset,     Endian.little) * scale;
    normalsBuf[nb + 1] = bd.getInt16(offset + 2, Endian.little) * scale;
    normalsBuf[nb + 2] = bd.getInt16(offset + 4, Endian.little) * scale;
    offset += 8; // nx,ny,nz + pad

    final ub = i * 2;
    uvsBuf[ub]     = bd.getInt16(offset,     Endian.little) * scale;
    uvsBuf[ub + 1] = bd.getInt16(offset + 2, Endian.little) * scale;
    offset += 4;

    final cb = i * 4;
    colorsBuf[cb]     = bytes[offset];
    colorsBuf[cb + 1] = bytes[offset + 1];
    colorsBuf[cb + 2] = bytes[offset + 2];
    colorsBuf[cb + 3] = bytes[offset + 3];
    offset += 4;
  }

  // --- Animation header (uint32 + uint32 + float32 + uint32 + uint32 = 20 bytes) ---
  if (offset + 20 > bytes.length) return null;
  final animMagic   = bd.getUint32(offset,      Endian.little);
  final frameLength = bd.getUint32(offset +  4, Endian.little);
  final animSpeed   = bd.getFloat32(offset + 8, Endian.little);
  final playOffset  = bd.getUint32(offset + 12, Endian.little);
  final frameCount  = bd.getUint32(offset + 16, Endian.little);
  offset += 20;

  if (animMagic != 0x01) return null;

  // Skip frame key data (frame_count frames, each with 4×uint32 header + (key_count-1)×2×float32)
  for (int f = 0; f < frameCount; f++) {
    if (offset + 16 > bytes.length) return null;
    final keyCount = bd.getUint32(offset + 4, Endian.little);
    offset += 16; // 4 × uint32 frame_data
    offset += (keyCount - 1) * 8; // (key_count-1) × 2×float32
  }

  // --- Texture ---
  Uint8List? texture;
  final hasTexture    = (texType & 0x04) != 0;
  final isCompressed  = (texType & 0x08) != 0;

  if (hasTexture && offset < bytes.length) {
    final raw = isCompressed
        ? _decodeRle(bytes, bd, offset)
        : bytes.sublist(offset, (offset + 128 * 128 * 2).clamp(0, bytes.length));
    if (raw != null) texture = _decodeA1B5G5R5(raw);
  }

  return Ps2IconData(
    vertexCount:     vertexCount,
    animationShapes: animShapes,
    positions:       posArrays,
    normals:         normalsBuf,
    uvs:             uvsBuf,
    vertexColors:    colorsBuf,
    texture:         texture,
    frameLength:     frameLength,
    animSpeed:       animSpeed,
    playOffset:      playOffset,
    frameCount:      frameCount,
    bgTransparency:  iconSys.bgTransparency,
    bgColors:        iconSys.bgColors,
    lightDir1:       iconSys.lightDir1,
    lightDir2:       iconSys.lightDir2,
    lightDir3:       iconSys.lightDir3,
    lightColor1:     iconSys.lightColor1,
    lightColor2:     iconSys.lightColor2,
    lightColor3:     iconSys.lightColor3,
    ambient:         iconSys.ambient,
  );
}

// ---------------------------------------------------------------------------
// Texture helpers
// ---------------------------------------------------------------------------

/// Decode RLE-compressed texture to raw A1B5G5R5 bytes.
Uint8List? _decodeRle(Uint8List bytes, ByteData bd, int offset) {
  if (offset + 4 > bytes.length) return null;
  final compressedSize = bd.getUint32(offset, Endian.little);
  offset += 4;
  final out = BytesBuilder(copy: false);
  int rleOffset = 0;
  while (rleOffset < compressedSize) {
    if (offset + rleOffset + 2 > bytes.length) break;
    final code = bd.getUint16(offset + rleOffset, Endian.little);
    rleOffset += 2;
    if ((code & 0x8000) != 0) {
      final count = 0x8000 - (code ^ 0x8000);
      final end = (offset + rleOffset + count * 2).clamp(0, bytes.length);
      out.add(bytes.sublist(offset + rleOffset, end));
      rleOffset += count * 2;
    } else {
      if (code > 0) {
        if (offset + rleOffset + 2 > bytes.length) break;
        final pixel = bytes.sublist(offset + rleOffset, offset + rleOffset + 2);
        for (int t = 0; t < code; t++) out.add(pixel);
        rleOffset += 2;
      }
    }
  }
  return out.toBytes();
}

/// Decode A1B5G5R5 (16-bit LE) to RGB (3 bytes/pixel).
Uint8List _decodeA1B5G5R5(Uint8List raw) {
  final pixelCount = raw.length ~/ 2;
  final out = Uint8List(pixelCount * 3);
  final bd = ByteData.sublistView(raw);
  for (int i = 0; i < pixelCount; i++) {
    final p = bd.getUint16(i * 2, Endian.little);
    out[i * 3]     = (p & 0x1F) << 3;         // R
    out[i * 3 + 1] = ((p >> 5) & 0x1F) << 3;  // G
    out[i * 3 + 2] = ((p >> 10) & 0x1F) << 3; // B
  }
  return out;
}
