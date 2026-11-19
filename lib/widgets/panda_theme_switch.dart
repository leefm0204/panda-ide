import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';

/// Theme transition by propagation (circular reveal).
///
/// The principle: just before applying the new theme, we capture a
/// image of the current frame. This image is then painted **above**
/// the tree already repainted with the new theme, then a circle is pierced in it which
/// grows from the origin point (the toggle button). Result: the
/// new theme "spreads" from the button instead of appearing all at once.
///
/// Usage :
/// ```dart
/// MaterialApp(
///   builder: (context, child) => ThemeSwitchScope(child: child!),
/// );
///
/// ThemeSwitchScope.propagateFrom(
/// context: context, // button context (gives the origin)
/// apply: () => block.add(...) // applies the new theme
/// );
/// ```
class ThemeSwitchScope extends StatefulWidget {
  const ThemeSwitchScope({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 620),
    this.curve = Curves.easeInOutCubic,
  });

  final Widget child;
  final Duration duration;
  final Curve curve;

  /// Most recent active state — allows a call from any
  /// descending context without going through an InheritedWidget.
  static ThemeSwitchScopeState? _current;

  static ThemeSwitchScopeState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<ThemeSwitchScopeState>() ?? _current;

  /// Triggers propagation from the widget associated with [context]
  /// (typically the theme toggle button).
  static Future<void> propagateFrom({
    required BuildContext context,
    required VoidCallback apply,
  }) async {
    final scope = maybeOf(context);
    Offset? origin;
    final ro = context.findRenderObject();
    if (ro is RenderBox && ro.hasSize) {
      origin = ro.localToGlobal(ro.size.center(Offset.zero));
    }
    if (scope == null) {
      apply();
      return;
    }
    await scope.run(origin: origin, apply: apply);
  }

  @override
  State<ThemeSwitchScope> createState() => ThemeSwitchScopeState();
}

class ThemeSwitchScopeState extends State<ThemeSwitchScope>
    with SingleTickerProviderStateMixin {
  final GlobalKey _boundaryKey = GlobalKey();

  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  ui.Image? _snapshot;
  Size _snapshotSize = Size.zero;
  Offset _origin = Offset.zero;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    ThemeSwitchScope._current = this;
  }

  @override
  void dispose() {
    if (ThemeSwitchScope._current == this) ThemeSwitchScope._current = null;
    _ctrl.dispose();
    _snapshot?.dispose();
    super.dispose();
  }

  /// Capture the current frame, apply [apply], then animate the propagation.
  Future<void> run({Offset? origin, required VoidCallback apply}) async {
    if (_running) {
      apply();
      return;
    }
    _running = true;
    try {
      final boundary =
          _boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      ui.Image? image;
      if (boundary != null && boundary.hasSize && !boundary.debugNeedsPaint) {
        try {
          image = await boundary.toImage(pixelRatio: 1.0);
          _snapshotSize = boundary.size;
        } catch (_) {
          image = null;
        }
      }

      if (image == null || !mounted) {
        // No capture possible (web/software renderer) → simple toggle.
        apply();
        return;
      }

      final Size size = _snapshotSize;
      _origin = origin ?? Offset(size.width - 24, size.height / 2);
      setState(() {
        _snapshot?.dispose();
        _snapshot = image;
      });

      // Leave one frame for the snapshot to be painted before changing the theme,
      // otherwise we would see a flash of the new theme across the entire surface.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      apply();

      await _ctrl.forward(from: 0.0);
      if (!mounted) return;
      setState(() {
        _snapshot?.dispose();
        _snapshot = null;
      });
    } finally {
      _running = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return Stack(
      children: [
        RepaintBoundary(key: _boundaryKey, child: widget.child),
        if (snapshot != null)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _ctrl,
                builder: (context, _) => CustomPaint(
                  painter: _RevealPainter(
                    image: snapshot,
                    imageSize: _snapshotSize,
                    origin: _origin,
                    progress: widget.curve.transform(_ctrl.value),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _RevealPainter extends CustomPainter {
  _RevealPainter({
    required this.image,
    required this.imageSize,
    required this.origin,
    required this.progress,
  });

  final ui.Image image;
  final Size imageSize;
  final Offset origin;
  final double progress;

  static double _maxRadius(Size size, Offset o) {
    final double dx = o.dx > size.width / 2 ? o.dx : size.width - o.dx;
    final double dy = o.dy > size.height / 2 ? o.dy : size.height - o.dy;
    return Offset(dx, dy).distance + 8;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final double radius = _maxRadius(size, origin) * progress;

    // Old frame, pierced by a growing circle → propagation.
    final Path hole = Path()
      ..addOval(Rect.fromCircle(center: origin, radius: radius));
    final Path outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      hole,
    );

    canvas.save();
    canvas.clipPath(outside);
    final Rect dst = Offset.zero & size;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      dst,
      Paint()..filterQuality = FilterQuality.low,
    );
    canvas.restore();

    // Soft border on the wavefront: makes the propagation readable.
    if (progress > 0.001 && progress < 0.999) {
      canvas.drawCircle(
        origin,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = Colors.white.withValues(alpha: 0.14 * (1 - progress))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
    }
  }

  @override
  bool shouldRepaint(_RevealPainter old) =>
      old.progress != progress ||
      old.image != image ||
      old.origin != origin;
}
