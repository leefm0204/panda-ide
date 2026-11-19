// ═══════════════════════════════════════════════════════════════════════════
// WorkbenchResponsive — breakpoints and responsive helpers.
//
// The Workbench remains THE SAME system on every screen: it compacts
// (hiding secondary elements, reducing padding) instead of
// switch to a second interface.
// ═══════════════════════════════════════════════════════════════════════════
import 'workbench_tokens.dart';

enum WorkbenchDevice { phone, tablet, desktop }

abstract final class WorkbenchResponsive {
  static WorkbenchDevice deviceOf(double width) {
    if (width < WorkbenchBreakpoints.phone) return WorkbenchDevice.phone;
    if (width < WorkbenchBreakpoints.tablet) return WorkbenchDevice.tablet;
    return WorkbenchDevice.desktop;
  }

  /// True on phone: secondary elements (encoding, indentation,
  /// line ends…) are masked before causing any overflow.
  static bool isCompact(double width) => width < WorkbenchBreakpoints.phone;

  /// The spacing is getting tighter on a phone.
  static double gutter(double width) =>
      isCompact(width) ? WorkbenchTokens.spaceXS : WorkbenchTokens.spaceM;

  /// Status Bar Height: 22px desktop, 26px on touchscreen.
  static double statusBarHeight(double width, bool isTouch) =>
      isTouch || isCompact(width)
          ? WorkbenchTokens.statusBarHeightTouch
          : WorkbenchTokens.statusBarHeight;
}
