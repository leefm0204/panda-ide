// ═══════════════════════════════════════════════════════════════════════════
// WorkbenchTokens — single source of visual truth for Workbench Panda.
//
// Metrics carried from Microsoft/VS Code (MIT):
//   * src/vs/workbench/browser/parts/statusbar/media/statusbarpart.css
//       → barre 22px, police 12px, item max-width 40vw, paddings 2/3/5px
//   * src/vs/workbench/browser/parts/editor/media/multieditortabscontrol.css
// → tab height 35px, bottom border 1px, top accent 1px
//   * src/vs/workbench/browser/parts/sidebar/media/sidebarpart.css
// → title uppercase, title shares on the right
//   * src/vs/workbench/common/theme.ts → couleurs dark/light
//
// Adapted to the Panda theme (scaffoldBg 0xff181818): surfaces are derived from
// theme.ts but align with Panda Grey so that the whole thing remains
// homogeneous. Dark + Light covered.
// ═══════════════════════════════════════════════════════════════════════════
import 'package:material_ui/material_ui.dart';

/// Workbench Breakpoints (a single interface that compacts, never
/// a second "mobile" interface).
abstract final class WorkbenchBreakpoints {
  static const double phone = 600;
  static const double tablet = 1024;

  static bool isPhone(double width) => width < phone;
  static bool isTabletOrLarger(double width) => width >= tablet;
}

abstract final class WorkbenchTokens {
  // ── Bar metrics (theme.ts + statusbarpart.css) ──────────────────
  /// Height of the Title Bar / top bar.
  static const double titleBarHeight = 35;

  /// Tab Bar Height (VS Code: 35px).
  static const double tabBarHeight = 35;

  /// Status Bar Height (VS Code: 22px; 26px on touch screen).
  static const double statusBarHeight = 22;
  static const double statusBarHeightTouch = 26;

  /// Height of the header of the panels (sidebar / bottom panel).
  static const double panelHeaderHeight = 35;

  /// Activity Bar width (VS Code: 48px).
  static const double activityBarWidth = 48;

  /// Entry height of the Status Bar on the touch side.
  static const double statusItemMinTap = 28;

  // ── Rayons ──────────────────────────────────────────────────────────────
  // No radius "per panel": rounding the sidebar AND the editor produces two
  // surfaces facing each other ("SIDEBAR) (EDITOR"). The only radius of the
  // Workbench is that of the silhouette (shellRadius, below).

  // ── Workbench SILHOUETTE (a single external shape) ────────────────
  // The entire Workbench (Title Bar + Activity | Sidebar | Editor + Status Bar)
  // is cut by a SINGLE ClipRRect: only the OUTER corners are
  // rounded, all internal separations remain straight. It should therefore not
  // There should NEVER be any rounded corners specific to the editor sidebar, nor should the editor itself have rounded corners.
  // sidebar (no "SIDEBAR") (EDITOR").
  static const double shellRadius = 16;

  /// Margin between the edge of the screen and the shell. It makes the corners rounded.
  /// readable in both themes (in dark mode the surfaces and the scaffold are
  /// close: without margin + net, the silhouette would be invisible).
  static const double shellInset = 8;

  /// 1px line that traces the silhouette (and its corners) even in dark mode.
  static Color shellBorder(bool dark) =>
      dark ? const Color(0xff2f2f2f) : const Color(0xffdcdcdc);

  // ── Espacements ─────────────────────────────────────────────────────────
  static const double spaceXXS = 2;
  static const double spaceXS = 4;
  static const double spaceS = 6;
  static const double spaceM = 10;
  static const double spaceL = 14;

  /// Duration of micro-animations (VS Code remains an IDE: discrete).
  static const Duration fastAnim = Duration(milliseconds: 180);
  static const Duration panelAnim = Duration(milliseconds: 220);
  static const Curve panelCurve = Curves.easeOutCubic;

  // ── Accent Panda (active indicator / selection) ─────────────────────────
  static const Color accent = Color(0xff6366f1);

  // ── Editor & Chrome Colors (theme.ts + Dark Modern) ──────────────────
  static Color editorBg(bool dark) => dark ? const Color(0xff1f1f1f) : Colors.white;
  static Color tabBarBg(bool dark) => dark ? const Color(0xff181818) : const Color(0xffececec);
  static Color tabActiveBg(bool dark) => dark ? const Color(0xff1f1f1f) : Colors.white;
  static Color tabInactiveFg(bool dark) => dark ? const Color(0xff9d9d9d) : const Color(0xff616161);
  static Color tabActiveFg(bool dark) => dark ? const Color(0xffcccccc) : const Color(0xff3b3b3b);

  /// 1px border below the Tab Bar (tabs-border-bottom).
  static Color tabBarBorder(bool dark) => dark ? const Color(0xff2b2b2b) : const Color(0xffdcdcdc);

  static Color activityBg(bool dark) => dark ? const Color(0xff181818) : const Color(0xffe8e8e8);
  static Color activityFg(bool dark) => dark ? const Color(0xff858585) : const Color(0xff616161);
  static Color activitySelectedFg(bool dark) => dark ? Colors.white : const Color(0xff1a1a1a);

  static Color sidebarBg(bool dark) => dark ? const Color(0xff202020) : const Color(0xfff3f3f3);
  static Color sidebarHeaderFg(bool dark) => dark ? const Color(0xffbbbbbb) : const Color(0xff616161);
  static Color titleBarBg(bool dark) => dark ? const Color(0xff181818) : const Color(0xffe8e8e8);
  static Color panelBg(bool dark) => dark ? const Color(0xff181818) : const Color(0xfff3f3f3);
  static Color panelBorderFg(bool dark) => dark ? const Color(0xff2b2b2b) : const Color(0xffdcdcdc);
  static Color inputBg(bool dark) => dark ? const Color(0xff313131) : Colors.white;

  /// Status Bar Background — VS Code : statusBar.background.
  static Color statusBarBg(bool dark) => dark ? const Color(0xff181818) : const Color(0xffe8e8e8);

  /// Status Bar text — reverse contrast with background.
  static Color statusBarFg(bool dark) => dark ? const Color(0xffcccccc) : const Color(0xff3b3b3b);

  /// statusBarItem.hoverBackground / activeBackground.
  static Color statusHover(bool dark) => dark ? Colors.white.withValues(alpha: 0.10) : Colors.black.withValues(alpha: 0.06);
  static Color statusActive(bool dark) => dark ? Colors.white.withValues(alpha: 0.16) : Colors.black.withValues(alpha: 0.10);

  /// Error / warning colors (theme.ts editorError/editorWarning).
  static const Color errorFg = Color(0xfff14c4c);
  static const Color warningFg = Color(0xffcca700);
  static const Color infoFg = Color(0xff3794ff);

  /// Indicateur AI/Copilot actif.
  static const Color aiActiveFg = Color(0xff4ec9b0);

  // ── Sidebar : largeur par breakpoints ───────────────────────────────────
  /// Desktop ≥1024px : 280–320px.
  static double sidebarWidthDesktop(double width) => (width * 0.22).clamp(280.0, 320.0);

  /// Tablette 600–1024px : 260–300px.
  static double sidebarWidthTablet(double width) => (width * 0.30).clamp(260.0, 300.0);

  /// Phone <600px: we reserve the shell (margin) first, then the Activity Bar
  /// and a usable editor width — the sidebar pushes the editor, it doesn't
  /// must never leave him 10px of space.
  static double sidebarWidthPhone(double width) {
    final available = width - (shellInset * 2) - activityBarWidth;
    return (available * 0.70).clamp(170.0, 285.0);
  }

  static double sidebarWidth(double width) {
    if (WorkbenchBreakpoints.isTabletOrLarger(width)) return sidebarWidthDesktop(width);
    if (WorkbenchBreakpoints.isPhone(width)) return sidebarWidthPhone(width);
    return sidebarWidthTablet(width);
  }

  // ── Header Typography (sidebarpart.css: uppercase, discreet) ─────
  static TextStyle panelTitle(bool dark) => TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.1,
        color: sidebarHeaderFg(dark),
      );

  static TextStyle statusText(bool dark) => TextStyle(
        fontSize: 12,
        height: 1.0,
        color: statusBarFg(dark),
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}
