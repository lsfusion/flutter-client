import 'dart:ui' as ui;

import 'package:flutter/services.dart';

// Windows has no system col-resize/row-resize cursors — Chromium draws its
// own bitmaps, which the flutter_inappwebview composition backend cannot map
// back to Flutter cursors (it only recognizes LoadCursor(IDC_*) handles), so
// lsFusion's splitters and grid column handles got a plain arrow. Instead of
// patching the plugin, the glyphs are recreated here and registered through
// the engine's built-in createCustomCursor/windows channel; main.dart applies
// them via an overlay MouseRegion driven by the CSS cursor the page reports.

class WindowsCustomCursor extends MouseCursor {
  const WindowsCustomCursor(this.name);

  final String name;

  @override
  MouseCursorSession createSession(int device) =>
      _WindowsCustomCursorSession(this, device);

  @override
  String get debugDescription => 'WindowsCustomCursor($name)';
}

class _WindowsCustomCursorSession extends MouseCursorSession {
  _WindowsCustomCursorSession(WindowsCustomCursor super.cursor, super.device);

  @override
  WindowsCustomCursor get cursor => super.cursor as WindowsCustomCursor;

  @override
  Future<void> activate() => SystemChannels.mouseCursor
      .invokeMethod('setCustomCursor/windows', {'name': cursor.name});

  @override
  void dispose() {}
}

// Pixel art and hotspots lifted verbatim from Chromium's
// ui/resources/cursors/{col,row}_resize.cur — what Chrome itself shows for
// these CSS values on Windows. The originals are screen-inverting (XOR),
// which the ARGB-only engine channel cannot express, so black and white
// variants are registered instead and the page reports which one to use.
// row-resize is not a rotation of col-resize in Chromium, hence two bitmaps.
const _colResizeGlyph = (
  hotX: 10,
  hotY: 8,
  pixels: [
    '.........#.#.........',
    '.........#.#.........',
    '.........#.#.........',
    '.........#.#.........',
    '.........#.#.........',
    '...#.....#.#.....#...',
    '..##.....#.#.....##..',
    '.##......#.#......##.',
    '#######..#.#..#######',
    '.##......#.#......##.',
    '..##.....#.#.....##..',
    '...#.....#.#.....#...',
    '.........#.#.........',
    '.........#.#.........',
    '.........#.#.........',
    '.........#.#.........',
    '.........#.#.........',
  ],
);

const _rowResizeGlyph = (
  hotX: 9,
  hotY: 10,
  pixels: [
    '........#........',
    '.......###.......',
    '......#####......',
    '.....##.#.##.....',
    '........#........',
    '........#........',
    '........#........',
    '.................',
    '.................',
    '#################',
    '.................',
    '#################',
    '.................',
    '.................',
    '........#........',
    '........#........',
    '........#........',
    '.....##.#.##.....',
    '......#####......',
    '.......###.......',
    '........#........',
  ],
);

/// Renders the col-resize (row-resize when [vertical]) glyph at the current
/// DPI — white when [forDarkBackground] — and registers it with the engine.
/// Falls back to the closest system cursor if the channel is unavailable.
Future<MouseCursor> registerResizeCursor(String name,
    {required bool vertical,
    required bool forDarkBackground,
    required double scale}) async {
  final glyph = vertical ? _rowResizeGlyph : _colResizeGlyph;
  try {
    final size = (32 * scale).ceil();
    final color =
        forDarkBackground ? const ui.Color(0xFFFFFFFF) : const ui.Color(0xFF000000);
    final buffer = await _renderGlyph(glyph.pixels, size, scale, color);
    await SystemChannels.mouseCursor
        .invokeMethod<String>('createCustomCursor/windows', {
      'name': name,
      'buffer': buffer,
      'hotX': glyph.hotX * scale,
      'hotY': glyph.hotY * scale,
      'width': size,
      'height': size,
    });
    return WindowsCustomCursor(name);
  } catch (_) {
    return vertical
        ? SystemMouseCursors.resizeRow
        : SystemMouseCursors.resizeColumn;
  }
}

Future<Uint8List> _renderGlyph(
    List<String> pixels, int size, double scale, ui.Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);

  // Glyph pixels are snapped to whole device pixels and drawn without
  // antialiasing — nearest-neighbor, the same way Windows scales a .cur.
  final glyph = ui.Path();
  for (var y = 0; y < pixels.length; y++) {
    for (var x = 0; x < pixels[y].length; x++) {
      if (pixels[y][x] == '#') {
        glyph.addRect(ui.Rect.fromLTRB(
            (x * scale).roundToDouble(),
            (y * scale).roundToDouble(),
            ((x + 1) * scale).roundToDouble(),
            ((y + 1) * scale).roundToDouble()));
      }
    }
  }

  canvas.drawPath(
      glyph,
      ui.Paint()
        ..color = color
        ..isAntiAlias = false);

  final image = await recorder.endRecording().toImage(size, size);
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final bytes = rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes);
  // The engine channel expects BGRA.
  for (var i = 0; i < bytes.length; i += 4) {
    final r = bytes[i];
    bytes[i] = bytes[i + 2];
    bytes[i + 2] = r;
  }
  return bytes;
}
