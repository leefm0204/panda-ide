// ═══════════════════════════════════════════════════════════════════════════
// WorkbenchPanelFrame — shared visual shell of all Workbench panels.
//
// Any view of the "Workbench panel" type (Explorer, Search, Git, Tunnel,
// Copilot, Outline, Timeline, Extensions, lower panel…) goes through this
// frame: a single system of radius / border / background / header / clipping.
//
// Principle VS Code: the header (uppercase title + actions + closing)
// belongs to the panel, a single visual structure — never a map
// rounded in a rounded map.
// ═══════════════════════════════════════════════════════════════════════════
import 'package:material_ui/material_ui.dart';
import '../../core/broken_icons.dart';
import 'workbench_tokens.dart';

class WorkbenchPanelFrame extends StatelessWidget {
  /// View content (already wrapped in its own scroll if needed).
  final Widget body;

  /// Uppercase title displayed in the header (ex: 'EXPLORER').
  final String title;

  /// View-specific actions, located to the right of the header.
  final List<Widget> actions;

  /// Panel closing callback; null masks the button.
  final VoidCallback? onClose;

  final bool isDark;

  /// Horizontal padding applied to the body (0 for full-width views)
  /// like the file tree).
  final EdgeInsets bodyPadding;

  const WorkbenchPanelFrame({
    super.key,
    required this.body,
    required this.title,
    required this.isDark,
    this.actions = const <Widget>[],
    this.onClose,
    this.bodyPadding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    final fg = WorkbenchTokens.sidebarHeaderFg(isDark);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Header : titre + actions + close (sidebarpart.css .title) ──────
        Container(
          height: WorkbenchTokens.panelHeaderHeight,
          padding: const EdgeInsets.symmetric(
            horizontal: WorkbenchTokens.spaceM,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: WorkbenchTokens.panelTitle(isDark),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              ...actions,
              if (onClose != null)
                _PanelCloseButton(onClose: onClose!, color: fg),
            ],
          ),
        ),
        // ── Body: same surface as the header, clean clip, no hidden content
        Expanded(
          child: ClipRect(
            child: Padding(padding: bodyPadding, child: body),
          ),
        ),
      ],
    );
  }
}

/// Discreet close button (VS Code: chevron/close 16px, subtle hover).
class _PanelCloseButton extends StatefulWidget {
  final VoidCallback onClose;
  final Color color;

  const _PanelCloseButton({required this.onClose, required this.color});

  @override
  State<_PanelCloseButton> createState() => _PanelCloseButtonState();
}

class _PanelCloseButtonState extends State<_PanelCloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Close the panel',
      child: Tooltip(
        message: 'Close the panel',
        child: InkWell(
          onTap: widget.onClose,
          onHover: (h) => setState(() => _hovered = h),
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(
              Broken.close_circle,
              size: 14,
              color: _hovered
                  ? widget.color.withValues(alpha: 1)
                  : widget.color.withValues(alpha: 0.75),
            ),
          ),
        ),
      ),
    );
  }
}
