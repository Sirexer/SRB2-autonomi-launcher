import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/services/model_mesh.dart';
import 'package:srb2_autonomi_launcher/services/model_raster.dart';
import 'package:srb2_autonomi_launcher/ui/model_viewer.dart';

/// MD3 с одной частью: треугольник, кадры с именами [frames] (в кадре f
/// вершины сдвинуты на f по X).
Uint8List md3(List<String> frames) {
  const nVerts = 3, nTris = 1;
  final nFrames = frames.length;
  const surfHeader = 108;
  final surfSize = surfHeader + nTris * 12 + nVerts * 8 + nFrames * nVerts * 8;
  final ofsFrames = 108, ofsSurfaces = ofsFrames + nFrames * 56;
  final b = ByteData(ofsSurfaces + surfSize);
  void name(int at, String s, int len) {
    final bytes = ascii.encode(s);
    for (var i = 0; i < bytes.length && i < len; i++) {
      b.setUint8(at + i, bytes[i]);
    }
  }

  name(0, 'IDP3', 4);
  b.setInt32(4, 15, Endian.little);
  b.setInt32(76, nFrames, Endian.little);
  b.setInt32(84, 1, Endian.little);
  b.setInt32(92, ofsFrames, Endian.little);
  b.setInt32(100, ofsSurfaces, Endian.little);
  for (var f = 0; f < nFrames; f++) {
    name(ofsFrames + f * 56 + 40, frames[f], 16);
  }
  final s = ofsSurfaces;
  name(s, 'IDP3', 4);
  b.setInt32(s + 72, nFrames, Endian.little);
  b.setInt32(s + 80, nVerts, Endian.little);
  b.setInt32(s + 84, nTris, Endian.little);
  const ofsTris = surfHeader, ofsSt = ofsTris + nTris * 12, ofsXyz = ofsSt + nVerts * 8;
  b.setInt32(s + 88, ofsTris, Endian.little);
  b.setInt32(s + 96, ofsSt, Endian.little);
  b.setInt32(s + 100, ofsXyz, Endian.little);
  b.setInt32(s + 104, surfSize, Endian.little);
  for (var k = 0; k < 3; k++) {
    b.setInt32(s + ofsTris + k * 4, k, Endian.little);
  }
  const uv = [0.0, 0.0, 1.0, 0.0, 0.0, 1.0];
  for (var i = 0; i < 6; i++) {
    b.setFloat32(s + ofsSt + i * 4, uv[i], Endian.little);
  }
  const pos = [
    [0, 0, 0],
    [1, 0, 0],
    [0, 0, 2],
  ];
  for (var f = 0; f < nFrames; f++) {
    for (var v = 0; v < nVerts; v++) {
      final at = s + ofsXyz + (f * nVerts + v) * 8;
      b.setInt16(at, (pos[v][0] + f) * 64, Endian.little);
      b.setInt16(at + 2, pos[v][1] * 64, Endian.little);
      b.setInt16(at + 4, pos[v][2] * 64, Endian.little);
    }
  }
  return b.buffer.asUint8List();
}

/// MD2: треугольник, текстура 64×32, один кадр (масштаб 0.5, сдвиг 1).
Uint8List md2() {
  const nVerts = 3, nSt = 3, nTris = 1, nFrames = 1;
  const frameSize = 40 + nVerts * 4;
  const ofsSt = 68, ofsTris = ofsSt + nSt * 4, ofsFrames = ofsTris + nTris * 12;
  final b = ByteData(ofsFrames + nFrames * frameSize);
  for (final (i, c) in 'IDP2'.codeUnits.indexed) {
    b.setUint8(i, c);
  }
  final header = [8, 64, 32, frameSize, 0, nVerts, nSt, nTris, 0, nFrames, 0, ofsSt, ofsTris, ofsFrames, 0, 0];
  for (var i = 0; i < header.length; i++) {
    b.setInt32(4 + i * 4, header[i], Endian.little);
  }
  const st = [0, 0, 32, 0, 0, 16];
  for (var i = 0; i < 6; i++) {
    b.setInt16(ofsSt + i * 2, st[i], Endian.little);
  }
  for (var k = 0; k < 3; k++) {
    b.setUint16(ofsTris + k * 2, k, Endian.little);
    b.setUint16(ofsTris + 6 + k * 2, k, Endian.little);
  }
  for (var k = 0; k < 3; k++) {
    b.setFloat32(ofsFrames + k * 4, 0.5, Endian.little);
    b.setFloat32(ofsFrames + 12 + k * 4, 1, Endian.little);
  }
  for (final (i, c) in 'stand01'.codeUnits.indexed) {
    b.setUint8(ofsFrames + 24 + i, c);
  }
  const verts = [
    [0, 0, 0],
    [2, 0, 0],
    [0, 0, 4],
  ];
  for (var v = 0; v < 3; v++) {
    for (var k = 0; k < 3; k++) {
      b.setUint8(ofsFrames + 40 + v * 4 + k, verts[v][k]);
    }
  }
  return b.buffer.asUint8List();
}

void main() {
  test('MD3: frames, vertices and texture coordinates', () {
    final m = ModelMesh.parse(md3(['SPR2_STND00', 'SPR2_WALK+i00', 'SPR2_WALK+i01', 'SUPERSTND00', 'SPING07']));
    expect((m.frames, m.triangles, m.vertices), (5, 1, 3));
    final s = m.surfaces.single;
    // Кадр 2: сдвиг на 2 по X.
    expect(s.xyz.sublist(2 * 9, 2 * 9 + 9), [2, 0, 0, 3, 0, 0, 2, 0, 2]);
    expect(s.uv, [0, 0, 1, 0, 0, 1]);
    final anims = m.animations();
    expect([for (final a in anims) a.$1], ['STND', 'WALK', 'SUPER STND', 'SPING']);
    expect([for (final a in anims) a.$2], [
      [0],
      [1, 2],
      [3],
      [4],
    ]);
    expect(m.bounds(0), [0, 0, 0, 1, 0, 2]);
    expect(m.bounds(), [0, 0, 0, 5, 0, 2]);
  });

  test('MD2: corners become vertices, coordinates scaled', () {
    final m = ModelMesh.parse(md2());
    expect((m.frames, m.triangles), (1, 1));
    expect(m.frameNames, ['stand01']);
    final s = m.surfaces.single;
    expect(s.xyz, [1, 1, 1, 2, 1, 1, 1, 1, 3]);
    expect(s.uv, [0, 0, 0.5, 0, 0, 0.5]);
    expect(m.animations().single.$1, 'stand');
  });

  test('depth per pixel: a small detail in front of a big face stays visible in any triangle order', () {
    // Большой красный треугольник и маленький синий перед ним; средняя
    // глубина большого — ближе, чем у маленького (рисование по средней
    // глубине прятало бы деталь, как зрачки Соника).
    ModelMesh mesh(bool detailFirst) {
      // Камера смотрит вдоль +Y: меньше Y — ближе. Лицо — наклонный
      // треугольник (y = -z/2): его центр (y ≈ -0.67) ближе детали (y = -0.1),
      // но в точке детали (x = 0, z = 0) лицо позади (y = 0).
      // Игра отражает ось Y модели (y → −y), растеризатор тоже: в файле
      // знаки глубины наоборот.
      final face = <double>[-6, -1, -2, 6, -1, -2, 0, 4, 8];
      final eye = <double>[-0.5, 0.1, -0.5, 0.5, 0.1, -0.5, 0, 0.1, 0.5];
      final parts = detailFirst ? [eye, face] : [face, eye];
      final xyz = Float32List.fromList([for (final p in parts) ...p]);
      final n = xyz.length ~/ 3;
      final uv = Float32List(n * 2);
      final colors = detailFirst ? [0.75, 0.25] : [0.25, 0.75]; // u: 0.25 — красный, 0.75 — синий
      var k = 0;
      for (final (i, p) in parts.indexed) {
        for (var v = 0; v < p.length ~/ 3; v++) {
          uv[k * 2] = colors[i];
          uv[k * 2 + 1] = 0.5;
          k++;
        }
      }
      return ModelMesh([MeshSurface(n, xyz, uv, Uint32List.fromList(List.generate(n, (i) => i)))], ['A']);
    }

    // Текстура 2×1: слева красный, справа синий.
    final tex = RasterTexture(2, 1, Uint8List.fromList([255, 0, 0, 255, 0, 0, 255, 255]));
    for (final detailFirst in [false, true]) {
      final m = mesh(detailFirst);
      final px = rasterizeModel(m, 0, tex, 64, 64, yaw: 0, pitch: 0, zoom: 1, bounds: m.bounds());
      // Центр вида — z = 3; деталь (z = 0) ниже центра на 3 × 64·0.8/12 ≈ 13 точек.
      final detail = (45 * 64 + 32) * 4;
      expect(px[detail + 2] > px[detail], isTrue, reason: 'detailFirst=$detailFirst: the blue detail is in front');
      final face = (20 * 64 + 32) * 4;
      // С текстурой — без затенения: цвет ровно как в текстуре.
      expect(px.sublist(face, face + 4), [255, 0, 0, 255]);
      expect(px.sublist(detail, detail + 4), [0, 0, 255, 255]);
    }
  });

  test('the model is mirrored like in the game: +Y of the file (its left) is on our left when it faces us', () {
    // Модель смотрит вдоль +X (на нас при yaw = -π/2); точка на +Y файла.
    final xyz = Float32List.fromList(<double>[0, 2, 0, 0, 2.5, 1, 0, 3, 0, 0, -3, 0, 0, -3, 0.01, 0, -3, 0.02]);
    final m = ModelMesh([
      MeshSurface(6, xyz, Float32List(12), Uint32List.fromList([0, 1, 2])),
    ], ['A']);
    final px = rasterizeModel(m, 0, null, 64, 64, yaw: -math.pi / 2, pitch: 0, zoom: 1, bounds: m.bounds());
    var left = 0, right = 0;
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 64; x++) {
        if (px[(y * 64 + x) * 4 + 3] == 0) continue;
        x < 32 ? left++ : right++;
      }
    }
    // Без отражения левая сторона модели (+Y в MD3) была бы справа от нас.
    expect(left > 0 && right == 0, isTrue, reason: 'left $left, right $right');
  });

  test('not a model, cut model', () {
    expect(() => ModelMesh.parse(Uint8List.fromList(utf8.encode('PNG..........'))), throwsFormatException);
    final cut = md3(['A']);
    expect(() => ModelMesh.parse(Uint8List.sublistView(cut, 0, cut.length - 20)), throwsFormatException);
  });

  test('skin color blending matches SRB2 (values from a port of HWR_CreateBlendedTexture)', () {
    final palette = Uint8List(768);
    for (var i = 0; i < 256; i++) {
      palette[i * 3] = i;
      palette[i * 3 + 1] = 255 - i;
      palette[i * 3 + 2] = (i * 7) % 256;
    }
    final image = Uint8List.fromList([10, 20, 30, 255, 200, 100, 50, 128, 0, 0, 0, 255, 50, 60, 70, 255]);
    final blend = Uint8List.fromList([0, 0, 0, 0, 255, 255, 255, 255, 128, 128, 128, 255, 40, 40, 40, 100]);
    expect(blendSkinColor(image, blend, List.generate(16, (i) => 96 + i), palette),
        [10, 20, 30, 255, 96, 159, 160, 128, 104, 151, 216, 255, 72, 93, 85, 255]);
    // Повторы в цвете (как у многих цветов SRB2) — другие ступени.
    expect(blendSkinColor(image, blend, [0, 0, 0, 0, 5, 5, 5, 5, 9, 9, 9, 9, 31, 31, 31, 31], palette),
        [10, 20, 30, 255, 0, 255, 0, 128, 9, 246, 63, 255, 39, 126, 108, 255]);
  });

  test('model interpolation blends vertex positions linearly between frames', () {
    // Треугольник перемещается по X: кадр 0 слева (-3..-2), кадр 1 справа (2..3).
    final xyz = Float32List.fromList(<double>[
      -3, 0, -0.5, -2, 0, -0.5, -2.5, 0, 0.5, // кадр 0
      2, 0, -0.5, 3, 0, -0.5, 2.5, 0, 0.5, // кадр 1
    ]);
    final m = ModelMesh(
      [MeshSurface(3, xyz, Float32List(6), Uint32List.fromList([0, 1, 2]))],
      ['WALK00', 'WALK01'],
    );
    const bounds = [-4.0, -1.0, -1.0, 4.0, 1.0, 1.0];

    List<int> xsFor(Uint8List px) {
      final xs = <int>[];
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          if (px[(y * 64 + x) * 4 + 3] > 0) xs.add(x);
        }
      }
      return xs;
    }

    final f0 = rasterizeModel(m, 0, null, 64, 64, yaw: 0, pitch: 0, zoom: 1, bounds: bounds);
    final f1 = rasterizeModel(m, 1, null, 64, 64, yaw: 0, pitch: 0, zoom: 1, bounds: bounds);
    final mid = rasterizeModel(m, 0, null, 64, 64, nextFrame: 1, interp: 0.5, yaw: 0, pitch: 0, zoom: 1, bounds: bounds);

    expect(rasterizeModel(m, 0, null, 64, 64, nextFrame: 1, interp: 0, yaw: 0, pitch: 0, zoom: 1, bounds: bounds), f0);
    expect(rasterizeModel(m, 0, null, 64, 64, nextFrame: 1, interp: 1, yaw: 0, pitch: 0, zoom: 1, bounds: bounds), f1);

    final midXs = xsFor(mid);
    expect(midXs, isNotEmpty);
    final avgX = midXs.reduce((a, b) => a + b) / midXs.length;
    expect(avgX, inInclusiveRange(30.0, 33.0));
  });

  test('rasterizeModel panX and panY shift rendered pixels', () {
    final xyz = Float32List.fromList(<double>[-1, 0, -1, 1, 0, -1, 0, 0, 1]);
    final m = ModelMesh([MeshSurface(3, xyz, Float32List(6), Uint32List.fromList([0, 1, 2]))], ['STND00']);
    const bounds = [-2.0, -1.0, -2.0, 2.0, 1.0, 2.0];

    (double, double) centroid(Uint8List px) {
      var sx = 0.0, sy = 0.0, n = 0;
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          if (px[(y * 64 + x) * 4 + 3] > 0) {
            sx += x;
            sy += y;
            n++;
          }
        }
      }
      return (sx / n, sy / n);
    }

    final base = centroid(rasterizeModel(m, 0, null, 64, 64, yaw: 0, pitch: 0, zoom: 1, bounds: bounds));
    final panned =
        centroid(rasterizeModel(m, 0, null, 64, 64, panX: 10, panY: -12, yaw: 0, pitch: 0, zoom: 1, bounds: bounds));
    expect(panned.$1 - base.$1, closeTo(10.0, 1.0));
    expect(panned.$2 - base.$2, closeTo(-12.0, 1.0));
  });

  testWidgets('ModelViewer pans on right-mouse drag and resets on double-tap', (tester) async {
    final xyz = Float32List.fromList(<double>[-1, 0, -1, 1, 0, -1, 0, 0, 1]);
    final m = ModelMesh([MeshSurface(3, xyz, Float32List(6), Uint32List.fromList([0, 1, 2]))], ['STND00']);

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(width: 120, height: 120, child: ModelViewer(mesh: m)),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();

    Future<(double, double)> renderedCentroid() async {
      final img = tester.widget<RawImage>(find.byType(RawImage)).image!;
      final bd = (await tester.runAsync(() => img.toByteData()))!;
      var sx = 0.0, sy = 0.0, n = 0;
      for (var y = 0; y < img.height; y++) {
        for (var x = 0; x < img.width; x++) {
          if (bd.getUint8((y * img.width + x) * 4 + 3) > 0) {
            sx += x;
            sy += y;
            n++;
          }
        }
      }
      return (sx / n, sy / n);
    }

    final initial = await renderedCentroid();
    final scale = tester.widget<RawImage>(find.byType(RawImage)).image!.width / 120.0;

    final g = await tester.startGesture(tester.getCenter(find.byType(ModelViewer)), buttons: kSecondaryMouseButton);
    await g.moveBy(const Offset(24, -16));
    await g.up();
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();

    final moved = await renderedCentroid();
    expect((moved.$1 - initial.$1) / scale, closeTo(24.0, 2.0));
    expect((moved.$2 - initial.$2) / scale, closeTo(-16.0, 2.0));

    final center = tester.getCenter(find.byType(ModelViewer));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();

    final reset = await renderedCentroid();
    expect(reset.$1, closeTo(initial.$1, 1.0));
    expect(reset.$2, closeTo(initial.$2, 1.0));
  });
}
