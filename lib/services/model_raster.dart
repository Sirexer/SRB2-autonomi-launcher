import 'dart:math' as math;
import 'dart:typed_data';

import 'model_mesh.dart';

/// Текстура для отрисовки: RGBA, ширина × высота.
class RasterTexture {
  final int width, height;
  final Uint8List rgba;
  const RasterTexture(this.width, this.height, this.rgba);
}

/// Рисует кадр [frame] модели в картинку [width]×[height] (RGBA) с
/// проверкой глубины по пикселям — как игра (OpenGL): мелкие детали поверх
/// поверхности (зрачки, эмблемы) не пропадают ни с какого ракурса.
///
/// Камера: модель вращается вокруг вертикали на [yaw] и наклоняется на
/// [pitch]; проекция ортографическая; [bounds] (minX, minY, minZ, maxX,
/// maxY, maxZ) задают центр и масштаб, [zoom] — приближение.
/// Пиксели текстуры с прозрачностью меньше половины не рисуются. Модель с
/// текстурой не затеняется (цвета как в файле); без текстуры — серая со
/// светом по граням, чтобы была видна форма.
Uint8List rasterizeModel(
  ModelMesh mesh,
  int frame,
  RasterTexture? texture,
  int width,
  int height, {
  int? nextFrame,
  double interp = 0,
  double panX = 0,
  double panY = 0,
  required double yaw,
  required double pitch,
  required double zoom,
  required List<double> bounds,
}) {
  final color = Uint32List(width * height);
  if (width <= 0 || height <= 0) return color.buffer.asUint8List();
  final depth = Float32List(width * height)..fillRange(0, width * height, double.infinity);
  final cx = (bounds[0] + bounds[3]) / 2, cy = (bounds[1] + bounds[4]) / 2, cz = (bounds[2] + bounds[5]) / 2;
  final extent = [bounds[3] - bounds[0], bounds[4] - bounds[1], bounds[5] - bounds[2]].reduce(math.max);
  if (extent <= 0) return color.buffer.asUint8List();
  final scale = math.min(width, height) * 0.8 / extent * zoom;
  // Почти совпадающие по глубине — побеждает нарисованный позже (как
  // GL_LEQUAL при порядке треугольников в модели): наклейки поверх.
  final eps = extent * 1e-4;
  final cosY = math.cos(yaw), sinY = math.sin(yaw), cosP = math.cos(pitch), sinP = math.sin(pitch);
  final tw = texture?.width ?? 1, th = texture?.height ?? 1;
  final tex = texture == null ? null : Uint32List.view(texture.rgba.buffer, texture.rgba.offsetInBytes, tw * th);

  for (final s in mesh.surfaces) {
    final last = s.verts == 0 ? 0 : s.xyz.length ~/ (3 * s.verts) - 1;
    final f = frame < 0 ? 0 : (frame > last ? last : frame);
    final nf = nextFrame == null ? f : (nextFrame < 0 ? 0 : (nextFrame > last ? last : nextFrame));
    final t = nf == f ? 0.0 : interp.clamp(0.0, 1.0);
    // Вершины кадра на экране: x, y и глубина (дальше — больше).
    final n = s.verts;
    final px = Float32List(n), py = Float32List(n), pz = Float32List(n);
    final vx = Float32List(n), vy = Float32List(n), vz = Float32List(n);
    final base = f * n * 3;
    final nextBase = nf * n * 3;
    for (var i = 0; i < n; i++) {
      // Ось Y — наоборот: игра ставит модель в мир как (x, z, −y) при мире
      // (x, z, y) (r_opengl.c, DrawModelEx), так что в игре модель отражена
      // относительно файла; иначе надписи и асимметрия выходят зеркально.
      final idx = base + i * 3;
      final nIdx = nextBase + i * 3;
      final mx = t == 0.0 ? s.xyz[idx] : s.xyz[idx] + (s.xyz[nIdx] - s.xyz[idx]) * t;
      final my = t == 0.0 ? s.xyz[idx + 1] : s.xyz[idx + 1] + (s.xyz[nIdx + 1] - s.xyz[idx + 1]) * t;
      final mz = t == 0.0 ? s.xyz[idx + 2] : s.xyz[idx + 2] + (s.xyz[nIdx + 2] - s.xyz[idx + 2]) * t;
      final x = mx - cx, y = cy - my, z = mz - cz;
      final rx = x * cosY - y * sinY;
      final ry = x * sinY + y * cosY;
      final ry2 = ry * cosP - z * sinP;
      final rz2 = ry * sinP + z * cosP;
      vx[i] = rx;
      vy[i] = ry2;
      vz[i] = rz2;
      px[i] = width / 2 + panX + rx * scale;
      py[i] = height / 2 + panY - rz2 * scale;
      pz[i] = ry2;
    }
    for (var t = 0; t + 2 < s.tris.length; t += 3) {
      final a = s.tris[t], b = s.tris[t + 1], c = s.tris[t + 2];
      final x0 = px[a], y0 = py[a], x1 = px[b], y1 = py[b], x2 = px[c], y2 = py[c];
      final area = (x1 - x0) * (y2 - y0) - (y1 - y0) * (x2 - x0);
      if (area.abs() < 1e-9) continue;
      // Свет — только у модели без текстуры (иначе плоский серый силуэт);
      // с текстурой цвета как в файле, без затенения.
      final ax = vx[b] - vx[a], ay = vy[b] - vy[a], az = vz[b] - vz[a];
      final bx = vx[c] - vx[a], by = vy[c] - vy[a], bz = vz[c] - vz[a];
      final nx = ay * bz - az * by, ny = az * bx - ax * bz, nz = ax * by - ay * bx;
      final len = math.sqrt(nx * nx + ny * ny + nz * nz);
      final d = len == 0 ? 0.0 : ((-ny * 0.6 + nz * 0.5 + nx * 0.2) / len).abs();
      final light = tex != null ? 256 : ((0.45 + 0.55 * d.clamp(0.0, 1.0)) * 256).round();

      final minX = math.max(0, math.min(x0, math.min(x1, x2)).floor());
      final maxX = math.min(width - 1, math.max(x0, math.max(x1, x2)).ceil());
      final minY = math.max(0, math.min(y0, math.min(y1, y2)).floor());
      final maxY = math.min(height - 1, math.max(y0, math.max(y1, y2)).ceil());
      if (minX > maxX || minY > maxY) continue;
      final z0 = pz[a], z1 = pz[b], z2 = pz[c];
      final u0 = s.uv[a * 2] * tw, u1 = s.uv[b * 2] * tw, u2 = s.uv[c * 2] * tw;
      final v0 = s.uv[a * 2 + 1] * th, v1 = s.uv[b * 2 + 1] * th, v2 = s.uv[c * 2 + 1] * th;
      final inv = 1 / area;
      // Барицентрические веса: w0 у вершины a, w1 у b; шаг по x.
      final dx0 = -(y2 - y1) * inv, dx1 = -(y0 - y2) * inv;
      for (var yy = minY; yy <= maxY; yy++) {
        final sy = yy + 0.5;
        final sx = minX + 0.5;
        var w0 = ((x2 - x1) * (sy - y1) - (y2 - y1) * (sx - x1)) * inv;
        var w1 = ((x0 - x2) * (sy - y2) - (y0 - y2) * (sx - x2)) * inv;
        var idx = yy * width + minX;
        for (var xx = minX; xx <= maxX; xx++, idx++, w0 += dx0, w1 += dx1) {
          final w2 = 1 - w0 - w1;
          if (w0 < -1e-6 || w1 < -1e-6 || w2 < -1e-6) continue;
          final z = w0 * z0 + w1 * z1 + w2 * z2;
          if (z > depth[idx] + eps) continue;
          int r, g, bl;
          if (tex != null) {
            var tu = (w0 * u0 + w1 * u1 + w2 * u2).floor() % tw;
            var tv = (w0 * v0 + w1 * v1 + w2 * v2).floor() % th;
            if (tu < 0) tu += tw;
            if (tv < 0) tv += th;
            final texel = tex[tv * tw + tu];
            if ((texel >>> 24) < 128) continue; // прозрачный — сквозь него видно
            r = texel & 0xFF;
            g = (texel >> 8) & 0xFF;
            bl = (texel >> 16) & 0xFF;
          } else {
            r = g = bl = 0xB0;
          }
          depth[idx] = z;
          color[idx] =
              0xFF000000 |
              (math.min(255, bl * light >> 8) << 16) |
              (math.min(255, g * light >> 8) << 8) |
              math.min(255, r * light >> 8);
        }
      }
    }
  }
  return color.buffer.asUint8List();
}
