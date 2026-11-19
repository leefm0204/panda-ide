import 'package:material_ui/material_ui.dart';
import '../../core/broken_icons.dart';
import '../../utils/themes.dart';

/// VS Code-style title bar: centered workspace box + left nav buttons.
class PandaTitleBar extends StatelessWidget {
  final AppTheme appTheme;
  final String? currentWorkspaceName;
  final int sidebarState;
  final bool bottomPanelOpen;
  final bool rightPanelOpen;
  final bool fullScreen;
  final VoidCallback onCloseWorkspace;
  final VoidCallback onToggleSidebar;
  final VoidCallback onToggleBottomPanel;
  final VoidCallback onToggleRightPanel;
  final VoidCallback onToggleFullScreen;
  final VoidCallback onOpenAgentTab;
  final VoidCallback onShowWorkspaceMenu;
  final GlobalKey workspaceBoxKey;

  const PandaTitleBar({
    super.key,
    required this.appTheme,
    required this.currentWorkspaceName,
    required this.sidebarState,
    required this.bottomPanelOpen,
    required this.rightPanelOpen,
    required this.fullScreen,
    required this.onCloseWorkspace,
    required this.onToggleSidebar,
    required this.onToggleBottomPanel,
    required this.onToggleRightPanel,
    required this.onToggleFullScreen,
    required this.onOpenAgentTab,
    required this.onShowWorkspaceMenu,
    required this.workspaceBoxKey,
  });

  static const Color _kAccent = Color(0xff76b4ea);

  @override
  Widget build(BuildContext context) {
    final isDark = appTheme.isDark;
    final fg     = isDark ? Colors.grey[400]! : Colors.grey[700]!;
    final bg     = isDark ? _kActivityBgDark : _kActivityBgLight;
    final boxBg  = isDark ? const Color(0xff3a3a3a) : const Color(0xfff5f5f5);
    final boxBdr = isDark ? const Color(0xff666666) : const Color(0xffbbbbbb);

    return Container(
      height: 35,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          // ── CENTER: workspace box ────────────────────────────────
          Expanded(
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Builder(
                    builder: (ctx) => GestureDetector(
                      onTap: onShowWorkspaceMenu,
                      child: Semantics(
                        label:
                            'Workspace: ${currentWorkspaceName ?? 'No workspace'}',
                        button: true,
                        child: Container(
                          key: workspaceBoxKey,
                          constraints: BoxConstraints(
                              minWidth: 110,
                              maxWidth:
                                  MediaQuery.of(ctx).size.width * 0.42),
                          height: 26,
                          padding:
                              const EdgeInsets.symmetric(horizontal: 10),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: boxBg,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: boxBdr, width: 1),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Broken.folder_open,
                                  size: 13, color: fg),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  currentWorkspaceName ??
                                      'Workspace',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: currentWorkspaceName !=
                                              null
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                      color: isDark
                                          ? Colors.grey[300]!
                                          : Colors.grey[700]!),
                                ),
                              ),
                              if (currentWorkspaceName != null) ...[
                                const SizedBox(width: 5),
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: onCloseWorkspace,
                                  child: Padding(
                                    padding: const EdgeInsets.all(3),
                                    child: Tooltip(
                                      message: 'Close the project',
                                      child: Icon(Broken.close_circle,
                                          size: 15,
                                          color: Colors.red[400]),
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(width: 3),
                              Icon(Icons.keyboard_arrow_down,
                                  size: 14, color: fg),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── RIGHT: 4 buttons ─────────────────────────────────────
          _hdrBtn(
            Broken.sidebar_left,
            sidebarState == 2
                ? 'Close the left panel'
                : 'Open the left panel',
            sidebarState == 2 ? _kAccent : fg,
            onToggleSidebar,
          ),
          _hdrBtn(
            Broken.element_4,
            'Customize the layout',
            fg,
            () => _showLayoutMenu(context, isDark),
          ),
          _hdrBtn(
            Broken.sidebar_bottom,
            bottomPanelOpen
                ? 'Close the lower panel'
                : 'Open the lower panel (Terminal)',
            bottomPanelOpen ? _kAccent : fg,
            onToggleBottomPanel,
          ),
          _hdrBtn(
            Broken.sidebar_right,
            rightPanelOpen
                ? 'Close the right panel'
                : 'Open the right panel',
            rightPanelOpen ? _kAccent : fg,
            () {
              final bool isMobile =
                  MediaQuery.of(context).size.width < 600;
              if (isMobile) {
                onOpenAgentTab();
              } else {
                onToggleRightPanel();
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _hdrBtn(
          IconData icon, String tooltip, Color color, VoidCallback onTap) =>
      Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
            child: Icon(icon, size: 16, color: color),
          ),
        ),
      );

  void _showLayoutMenu(BuildContext ctx, bool isDark) {
    final fg = isDark ? Colors.grey[300]! : Colors.grey[800]!;
    final bg =
        isDark ? const Color(0xff252526) : const Color(0xfff3f3f3);
    double left = 8, top = 40;
    final wctx = workspaceBoxKey.currentContext;
    if (wctx != null) {
      final box = wctx.findRenderObject()! as RenderBox;
      final off = box.localToGlobal(Offset.zero);
      left = off.dx.clamp(0.0, MediaQuery.of(ctx).size.width - 60);
      top = off.dy + box.size.height + 2;
    }
    showMenu<String>(
      context: ctx,
      position: RelativeRect.fromLTRB(left, top, 12, 0),
      color: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      items: [
        _layoutMenuItem('sidebar_left', Broken.sidebar_left,
            'Left side panel', fg, bg,
            checked: sidebarState == 2),
        _layoutMenuItem('sidebar_right', Broken.sidebar_right,
            'Right side panel', fg, bg,
            checked: rightPanelOpen),
        _layoutMenuItem('panel_bottom', Broken.minus_square,
            'Bottom panel', fg, bg,
            checked: bottomPanelOpen),
        PopupMenuItem<String>(
          height: 1,
          enabled: false,
          child: Divider(
              color:
                  isDark ? const Color(0xff444444) : const Color(0xffcccccc),
              height: 1),
        ),
        _layoutMenuItem(
            'full_screen', Broken.maximize_3, 'Full screen', fg, bg),
      ],
    ).then((value) {
      if (value == null) return;
      if (value == 'sidebar_left') onToggleSidebar();
      if (value == 'sidebar_right') {
        final bool isMobile =
            MediaQuery.of(ctx).size.width < 600;
        if (isMobile) {
          onOpenAgentTab();
        } else {
          onToggleRightPanel();
        }
      }
      if (value == 'panel_bottom') onToggleBottomPanel();
      if (value == 'full_screen') onToggleFullScreen();
    });
  }

  PopupMenuItem<String> _layoutMenuItem(
      String value, IconData icon, String label, Color fg, Color bg,
      {bool checked = false}) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(children: [
        Icon(checked ? Broken.tick_square : icon,
            size: 16, color: checked ? _kAccent : fg),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(fontSize: 13, color: fg)),
      ]),
    );
  }
}

// Theme color constants for the title bar background
const Color _kActivityBgDark = Color(0xff252526);
const Color _kActivityBgLight = Color(0xff2c2c2c);
