import 'dart:typed_data';

/// One GIF frame: the changed rectangle of the picture, as straight RGBA. Pixels with alpha 0 are
/// "unchanged since the previous frame" and become transparent, so the previous frame shows through.
class GifFrame {
  final int x, y, width, height;
  final Uint8List rgba;
  int delayMs;
  GifFrame(this.x, this.y, this.width, this.height, this.rgba, this.delayMs);
}

/// A looping GIF89a from `frames` (the first one covers the whole picture). Pure Dart, so it runs the
/// same on every platform and in a background isolate: one global palette (median cut over every
/// frame's changed pixels), no dithering, each frame drawn over the last (disposal "do not dispose").
Uint8List encodeGif(int width, int height, List<GifFrame> frames) {
  final palette = _Palette.of(frames);
  final out = BytesBuilder(copy: false);
  void u16(int v) => out.add([v & 0xFF, (v >> 8) & 0xFF]);

  out.add('GIF89a'.codeUnits);
  u16(width);
  u16(height);
  out.add([0xF7, 0, 0]); // global table of 256 colours, background 0, square pixels
  out.add(palette.table);
  out.add([0x21, 0xFF, 0x0B, ...'NETSCAPE2.0'.codeUnits, 0x03, 0x01, 0x00, 0x00, 0x00]); // loop forever

  for (final f in frames) {
    final indices = Uint8List(f.width * f.height);
    var transparent = false;
    for (var i = 0, p = 0; i < indices.length; i++, p += 4) {
      if (f.rgba[p + 3] == 0) {
        indices[i] = _Palette.transparent;
        transparent = true;
      } else {
        indices[i] = palette.nearest(f.rgba[p], f.rgba[p + 1], f.rgba[p + 2]);
      }
    }
    final delay = (f.delayMs / 10).round().clamp(2, 0xFFFF); // centiseconds; under 2 gets slowed down by viewers
    out.add([0x21, 0xF9, 0x04, (1 << 2) | (transparent ? 1 : 0)]);
    u16(delay);
    out.add([_Palette.transparent, 0]);
    out.addByte(0x2C);
    u16(f.x);
    u16(f.y);
    u16(f.width);
    u16(f.height);
    out.addByte(0); // no local colour table, not interlaced
    out.addByte(8); // LZW minimum code size
    _lzw(indices, out);
    out.addByte(0);
  }
  out.addByte(0x3B);
  return out.takeBytes();
}

/// Up to 255 colours (index 255 is kept for transparency), from a 15-bit histogram.
class _Palette {
  static const transparent = 255;
  final List<int> colors; // 0xRRGGBB
  final Int16List _lut = Int16List(1 << 15)..fillRange(0, 1 << 15, -1);
  final Map<int, int>? _exact; // colour → index, when the picture has 255 colours or fewer
  _Palette(this.colors, [this._exact]);

  static int _key(int r, int g, int b) => ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);

  static _Palette of(List<GifFrame> frames) {
    final hist = Int32List(1 << 15);
    final sums = Float64List(3 << 15); // true colour totals per cell, so white stays 255 (not the cell's centre)
    Set<int>? exact = {};
    for (final f in frames) {
      final px = f.rgba;
      for (var p = 0; p < px.length; p += 4) {
        if (px[p + 3] == 0) continue;
        final k = _key(px[p], px[p + 1], px[p + 2]);
        hist[k]++;
        sums[k * 3] += px[p];
        sums[k * 3 + 1] += px[p + 1];
        sums[k * 3 + 2] += px[p + 2];
        if (exact != null && exact.add((px[p] << 16) | (px[p + 1] << 8) | px[p + 2]) && exact.length > 255) exact = null;
      }
    }
    if (exact != null && exact.isNotEmpty) {
      final list = exact.toList();
      return _Palette(list, {for (var i = 0; i < list.length; i++) list[i]: i});
    }
    final keys = [for (var k = 0; k < hist.length; k++) if (hist[k] > 0) k];
    if (keys.isEmpty) return _Palette([0]);
    // Median cut: keep splitting the busiest box with any spread along its widest channel
    final boxes = [_Box(keys, hist)];
    while (boxes.length < 255) {
      _Box? best;
      for (final b in boxes) {
        if (b.keys.length > 1 && (best == null || b.priority > best.priority)) best = b;
      }
      if (best == null) break;
      boxes.remove(best);
      boxes.addAll(best.split(hist));
    }
    return _Palette([for (final b in boxes) b.average(sums)]);
  }

  /// 768 bytes: the colours, padded to 256 entries.
  Uint8List get table {
    final t = Uint8List(768);
    for (var i = 0; i < colors.length; i++) {
      t[i * 3] = colors[i] >> 16;
      t[i * 3 + 1] = (colors[i] >> 8) & 0xFF;
      t[i * 3 + 2] = colors[i] & 0xFF;
    }
    return t;
  }

  int nearest(int r, int g, int b) {
    final exact = _exact;
    if (exact != null) return exact[(r << 16) | (g << 8) | b]!;
    final k = _key(r, g, b);
    final hit = _lut[k];
    if (hit >= 0) return hit;
    // Compare against the centre of the 15-bit cell, so the lookup is the same for every pixel in it
    final cr = (r & 0xF8) | 4, cg = (g & 0xF8) | 4, cb = (b & 0xF8) | 4;
    var best = 0, bestD = 1 << 30;
    for (var i = 0; i < colors.length; i++) {
      final c = colors[i];
      final dr = (c >> 16) - cr, dg = ((c >> 8) & 0xFF) - cg, db = (c & 0xFF) - cb;
      final d = 3 * dr * dr + 4 * dg * dg + 2 * db * db;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    _lut[k] = best;
    return best;
  }
}

class _Box {
  final List<int> keys;
  late final int count, channel, spread;
  _Box(this.keys, Int32List hist) {
    var n = 0;
    final lo = [31, 31, 31], hi = [0, 0, 0];
    for (final k in keys) {
      n += hist[k];
      for (var c = 0; c < 3; c++) {
        final v = (k >> (10 - 5 * c)) & 31;
        if (v < lo[c]) lo[c] = v;
        if (v > hi[c]) hi[c] = v;
      }
    }
    count = n;
    var ch = 0;
    for (var c = 1; c < 3; c++) {
      if (hi[c] - lo[c] > hi[ch] - lo[ch]) ch = c;
    }
    channel = ch;
    spread = hi[ch] - lo[ch];
  }

  double get priority => count * (spread + 1).toDouble();

  List<_Box> split(Int32List hist) {
    final shift = 10 - 5 * channel;
    keys.sort((a, b) => ((a >> shift) & 31) - ((b >> shift) & 31));
    var half = 0, i = 0;
    while (i < keys.length - 1 && half + hist[keys[i]] <= count ~/ 2) {
      half += hist[keys[i++]];
    }
    final cut = i == 0 ? 1 : i;
    return [_Box(keys.sublist(0, cut), hist), _Box(keys.sublist(cut), hist)];
  }

  int average(Float64List sums) {
    var r = 0.0, g = 0.0, b = 0.0;
    for (final k in keys) {
      r += sums[k * 3];
      g += sums[k * 3 + 1];
      b += sums[k * 3 + 2];
    }
    return ((r / count).round() << 16) | ((g / count).round() << 8) | (b / count).round();
  }
}

/// GIF's variable-width LZW (8-bit symbols), in 255-byte sub-blocks. The classic hashed compressor.
void _lzw(Uint8List pixels, BytesBuilder out) {
  const initBits = 9, maxBits = 12, hsize = 5003, hshift = 4;
  const clearCode = 256, eofCode = 257;
  final htab = Int32List(hsize)..fillRange(0, hsize, -1);
  final codetab = Int32List(hsize);
  var nBits = initBits, maxCode = (1 << nBits) - 1, freeEnt = clearCode + 2;
  var clearFlag = false;

  final block = Uint8List(255);
  var blockLen = 0, acc = 0, accBits = 0;
  void flushByte(int b) {
    block[blockLen++] = b;
    if (blockLen == 255) {
      out.addByte(255);
      out.add(Uint8List.fromList(block));
      blockLen = 0;
    }
  }

  void output(int code) {
    acc |= code << accBits;
    accBits += nBits;
    while (accBits >= 8) {
      flushByte(acc & 0xFF);
      acc >>= 8;
      accBits -= 8;
    }
    if (freeEnt > maxCode || clearFlag) {
      if (clearFlag) {
        nBits = initBits;
        maxCode = (1 << nBits) - 1;
        clearFlag = false;
      } else {
        nBits++;
        maxCode = nBits == maxBits ? 1 << maxBits : (1 << nBits) - 1;
      }
    }
    if (code == eofCode) {
      while (accBits > 0) {
        flushByte(acc & 0xFF);
        acc >>= 8;
        accBits -= 8;
      }
      if (blockLen > 0) {
        out.addByte(blockLen);
        out.add(Uint8List.sublistView(block, 0, blockLen));
        blockLen = 0;
      }
    }
  }

  output(clearCode);
  if (pixels.isEmpty) {
    output(eofCode);
    return;
  }
  var ent = pixels[0];
  outer:
  for (var p = 1; p < pixels.length; p++) {
    final c = pixels[p];
    final fcode = (c << maxBits) + ent;
    var i = (c << hshift) ^ ent;
    if (htab[i] == fcode) {
      ent = codetab[i];
      continue;
    }
    if (htab[i] >= 0) {
      final disp = i == 0 ? 1 : hsize - i;
      do {
        i -= disp;
        if (i < 0) i += hsize;
        if (htab[i] == fcode) {
          ent = codetab[i];
          continue outer;
        }
      } while (htab[i] >= 0);
    }
    output(ent);
    ent = c;
    if (freeEnt < 1 << maxBits) {
      codetab[i] = freeEnt++;
      htab[i] = fcode;
    } else {
      htab.fillRange(0, hsize, -1);
      freeEnt = clearCode + 2;
      clearFlag = true;
      output(clearCode);
    }
  }
  output(ent);
  output(eofCode);
}
