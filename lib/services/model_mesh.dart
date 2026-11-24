import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'map_preview.dart' show AddonArchive;

/// Часть модели: треугольники и вершины по кадрам.
class MeshSurface {
  /// Вершин в кадре.
  final int verts;

  /// x, y, z каждой вершины каждого кадра (кадр за кадром).
  final Float32List xyz;

  /// Текстурные координаты вершин (0..1, могут выходить за края — повтор).
  final Float32List uv;

  /// Тройки номеров вершин.
  final Uint32List tris;

  const MeshSurface(this.verts, this.xyz, this.uv, this.tris);
}

/// Модель MD3 или MD2: части, имена кадров и размеры.
class ModelMesh {
  final List<MeshSurface> surfaces;
  final List<String> frameNames;

  const ModelMesh(this.surfaces, this.frameNames);

  int get frames => frameNames.length;
  int get triangles => surfaces.fold(0, (s, x) => s + x.tris.length ~/ 3);
  int get vertices => surfaces.fold(0, (s, x) => s + x.verts);

  /// Читает MD3 (`IDP3`) или MD2 (`IDP2`). FormatException — не модель.
  static ModelMesh parse(Uint8List b) {
    if (b.length >= 4 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x50) {
      if (b[3] == 0x33) return _md3(b);
      if (b[3] == 0x32) return _md2(b);
    }
    throw const FormatException('Not an MD3 or MD2 model');
  }

  static String _name(Uint8List b, int at, int len) {
    var end = at;
    while (end < at + len && end < b.length && b[end] != 0) {
      end++;
    }
    return latin1.decode(b.sublist(at, end), allowInvalid: true);
  }

  static void _check(Uint8List b, int at, int len) {
    if (at < 0 || len < 0 || at + len > b.length) throw const FormatException('Model data out of range');
  }

  static ModelMesh _md3(Uint8List b) {
    final d = ByteData.sublistView(b);
    int i32(int at) => d.getInt32(at, Endian.little);
    _check(b, 0, 108);
    final numFrames = i32(76), numSurfaces = i32(84);
    final ofsFrames = i32(92), ofsSurfaces = i32(100);
    if (numFrames <= 0 || numFrames > 4096 || numSurfaces < 0 || numSurfaces > 256) {
      throw const FormatException('Bad MD3 header');
    }
    _check(b, ofsFrames, numFrames * 56);
    final names = [for (var f = 0; f < numFrames; f++) _name(b, ofsFrames + f * 56 + 40, 16)];
    final surfaces = <MeshSurface>[];
    var o = ofsSurfaces;
    for (var s = 0; s < numSurfaces; s++) {
      _check(b, o, 108);
      final sFrames = i32(o + 72), nVerts = i32(o + 80), nTris = i32(o + 84);
      final ofsTris = i32(o + 88), ofsSt = i32(o + 96), ofsXyz = i32(o + 100), ofsEnd = i32(o + 104);
      if (nVerts < 0 || nTris < 0 || nVerts > 65536 || nTris > 200000 || sFrames < numFrames) {
        throw const FormatException('Bad MD3 surface');
      }
      _check(b, o + ofsTris, nTris * 12);
      _check(b, o + ofsSt, nVerts * 8);
      _check(b, o + ofsXyz, numFrames * nVerts * 8);
      final tris = Uint32List(nTris * 3);
      for (var t = 0; t < nTris * 3; t++) {
        final v = i32(o + ofsTris + t * 4);
        tris[t] = v < 0 || v >= nVerts ? 0 : v;
      }
      final uv = Float32List(nVerts * 2);
      for (var v = 0; v < nVerts * 2; v++) {
        uv[v] = d.getFloat32(o + ofsSt + v * 4, Endian.little);
      }
      final xyz = Float32List(numFrames * nVerts * 3);
      for (var f = 0; f < numFrames; f++) {
        for (var v = 0; v < nVerts; v++) {
          final at = o + ofsXyz + (f * nVerts + v) * 8;
          final out = (f * nVerts + v) * 3;
          xyz[out] = d.getInt16(at, Endian.little) / 64;
          xyz[out + 1] = d.getInt16(at + 2, Endian.little) / 64;
          xyz[out + 2] = d.getInt16(at + 4, Endian.little) / 64;
        }
      }
      surfaces.add(MeshSurface(nVerts, xyz, uv, tris));
      if (ofsEnd <= 0) break;
      o += ofsEnd;
    }
    return ModelMesh(surfaces, names);
  }

  /// MD2: у вершины в треугольнике своя текстурная координата — каждый
  /// угол треугольника становится отдельной вершиной.
  static ModelMesh _md2(Uint8List b) {
    final d = ByteData.sublistView(b);
    int i32(int at) => d.getInt32(at, Endian.little);
    _check(b, 0, 68);
    final skinW = i32(8), skinH = i32(12), frameSize = i32(16);
    final nVerts = i32(24), nSt = i32(28), nTris = i32(32), nFrames = i32(40);
    final ofsSt = i32(48), ofsTris = i32(52), ofsFrames = i32(56);
    if (nFrames <= 0 || nFrames > 4096 || nTris < 0 || nTris > 200000 || nVerts <= 0) {
      throw const FormatException('Bad MD2 header');
    }
    _check(b, ofsSt, nSt * 4);
    _check(b, ofsTris, nTris * 12);
    _check(b, ofsFrames, nFrames * frameSize);
    final names = <String>[];
    final corners = nTris * 3;
    final xyz = Float32List(nFrames * corners * 3);
    final uv = Float32List(corners * 2);
    final tris = Uint32List.fromList(List.generate(corners, (i) => i));
    int vertOf(int t, int k) => d.getUint16(ofsTris + t * 12 + k * 2, Endian.little);
    int stOf(int t, int k) => d.getUint16(ofsTris + t * 12 + 6 + k * 2, Endian.little);
    for (var t = 0; t < nTris; t++) {
      for (var k = 0; k < 3; k++) {
        final st = stOf(t, k).clamp(0, math.max(0, nSt - 1)).toInt();
        uv[(t * 3 + k) * 2] = d.getInt16(ofsSt + st * 4, Endian.little) / math.max(1, skinW);
        uv[(t * 3 + k) * 2 + 1] = d.getInt16(ofsSt + st * 4 + 2, Endian.little) / math.max(1, skinH);
      }
    }
    for (var f = 0; f < nFrames; f++) {
      final fo = ofsFrames + f * frameSize;
      final sx = d.getFloat32(fo, Endian.little), sy = d.getFloat32(fo + 4, Endian.little), sz = d.getFloat32(fo + 8, Endian.little);
      final tx = d.getFloat32(fo + 12, Endian.little), ty = d.getFloat32(fo + 16, Endian.little), tz = d.getFloat32(fo + 20, Endian.little);
      names.add(_name(b, fo + 24, 16));
      for (var t = 0; t < nTris; t++) {
        for (var k = 0; k < 3; k++) {
          final v = vertOf(t, k).clamp(0, nVerts - 1).toInt();
          final at = fo + 40 + v * 4;
          if (at + 3 > b.length) throw const FormatException('Model data out of range');
          final out = (f * corners + t * 3 + k) * 3;
          xyz[out] = b[at] * sx + tx;
          xyz[out + 1] = b[at + 1] * sy + ty;
          xyz[out + 2] = b[at + 2] * sz + tz;
        }
      }
    }
    return ModelMesh([MeshSurface(corners, xyz, uv, tris)], names);
  }

  /// Анимации: имя → кадры по порядку. Имена кадров как в SRB2:
  /// `SPR2_STND+i00` — анимация STND (у SUPER — «SUPER STND»), иначе имя
  /// без `+i` и цифр в конце (`SPING07` — SPING).
  List<(String, List<int>)> animations() {
    final out = <String, List<int>>{};
    for (var i = 0; i < frameNames.length; i++) {
      (out[animationOf(frameNames[i])] ??= []).add(i);
    }
    return [for (final e in out.entries) (e.key, e.value)];
  }

  static String animationOf(String frame) {
    final n = frame.trim();
    if (n.length >= 9 && (n.startsWith('SPR2_') || n.startsWith('SUPER'))) {
      final name = n.substring(5, 9);
      return n.startsWith('SUPER') ? 'SUPER $name' : name;
    }
    final base = n.replaceAll('+i', '').replaceFirst(RegExp(r'\d+$'), '');
    return base.isEmpty ? n : base;
  }

  /// Границы кадра [frame]: (minX, minY, minZ, maxX, maxY, maxZ).
  List<double> bounds([int? frame]) {
    final lo = [double.infinity, double.infinity, double.infinity];
    final hi = [-double.infinity, -double.infinity, -double.infinity];
    for (final s in surfaces) {
      final from = frame == null ? 0 : frame * s.verts;
      final to = frame == null ? s.xyz.length ~/ 3 : from + s.verts;
      for (var v = from; v < to; v++) {
        for (var k = 0; k < 3; k++) {
          final x = s.xyz[v * 3 + k];
          if (x < lo[k]) lo[k] = x;
          if (x > hi[k]) hi[k] = x;
        }
      }
    }
    if (lo[0] == double.infinity) return [0, 0, 0, 0, 0, 0];
    return [...lo, ...hi];
  }
}

/// Перекраска текстуры по `_blend.png` в цвет игрока — как
/// HWR_CreateBlendedTexture в SRB2 (обычные цвета, без радуги и Metal Sonic).
/// [image], [blend] — RGBA одного размера; [ramp] — 16 номеров палитры
/// цвета; [palette] — 768 байт PLAYPAL.
Uint8List blendSkinColor(Uint8List image, Uint8List blend, List<int> ramp, Uint8List palette) {
  final translation = List.filled(16, 0);
  final cutoff = List.filled(16, 0);
  var translen = 0;
  var numdupes = 1;
  translation[0] = ramp[0];
  cutoff[0] = 255;
  for (var i = 1; i < 16; i++) {
    if (translation[translen] == ramp[i]) {
      numdupes++;
      continue;
    }
    if (translen > 0) cutoff[translen] = (cutoff[translen - 1] - (256 ~/ (16 ~/ numdupes))) & 0xFF;
    numdupes = 1;
    translen++;
    translation[translen] = ramp[i];
  }
  translen++;

  (int, int, int) color(int index) => (palette[index * 3], palette[index * 3 + 1], palette[index * 3 + 2]);
  final out = Uint8List.fromList(image);
  final n = math.min(image.length, blend.length) ~/ 4;
  for (var px = 0; px < n; px++) {
    final o = px * 4;
    final ba = blend[o + 3];
    if (ba == 0) continue;
    final brightness = (1063 * blend[o] ~/ 5000 + 3576 * blend[o + 1] ~/ 5000 + 361 * blend[o + 2] ~/ 5000) & 0xFF;
    var firsti = 0;
    for (var i = 1; i < translen; i++) {
      if (brightness >= cutoff[i]) break;
      firsti = i;
    }
    final secondi = firsti + 1;
    var mulmax = cutoff[firsti];
    if (secondi < translen) mulmax = (mulmax - cutoff[secondi]) & 0xFF;
    var mul = (cutoff[firsti] - brightness) & 0xFF;
    var (r, g, b) = color(translation[firsti]);
    if (secondi >= translen) mul = 0;
    if (mul > 0 && mulmax > 0) {
      final (nr, ng, nb) = color(translation[secondi]);
      r += (mul * (nr - r)) ~/ mulmax;
      g += (mul * (ng - g)) ~/ mulmax;
      b += (mul * (nb - b)) ~/ mulmax;
    }
    out[o] = math.min(255, image[o] * (255 - ba) ~/ 255 + r * ba ~/ 255);
    out[o + 1] = math.min(255, image[o + 1] * (255 - ba) ~/ 255 + g * ba ~/ 255);
    out[o + 2] = math.min(255, image[o + 2] * (255 - ba) ~/ 255 + b * ba ~/ 255);
  }
  return out;
}

/// Палитра (768 байт) из первых файлов игры, где есть PLAYPAL.
Uint8List? loadPlaypal(List<String> files) {
  for (final path in files) {
    final a = AddonArchive.open(path);
    if (a == null) continue;
    try {
      final e = a.findFirst('PLAYPAL');
      if (e == null) continue;
      final data = a.read(e);
      if (data.length >= 768) return Uint8List.fromList(data.sublist(0, 768));
    } catch (_) {
      // следующий файл
    } finally {
      a.close();
    }
  }
  return null;
}
