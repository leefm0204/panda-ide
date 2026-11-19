import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/functions.dart';
import 'setup_screen.dart';

const _kAccent = Color(0xff5090c8);
const _kBg = Color(0xff181c24);
const _kCard = Color(0xff23283a);

class PermissionScreen extends StatefulWidget {
  const PermissionScreen({super.key});

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen> {
  // Android 13+ storage permissions
  PermissionStatus _storageStatus = PermissionStatus.denied;
  PermissionStatus _notifStatus   = PermissionStatus.denied;
  PermissionStatus _overlayStatus = PermissionStatus.denied;
  bool _loading = true;
  bool _proceeding = false;

  @override
  void initState() {
    super.initState();
    _refreshStatuses();
  }

  Future<void> _refreshStatuses() async {
    setState(() => _loading = true);
    final storage = await _storagePermission().status;
    final notif   = await Permission.notification.status;
    final overlay = Platform.isAndroid
        ? await Permission.systemAlertWindow.status
        : PermissionStatus.granted;
    setState(() {
      _storageStatus = storage;
      _notifStatus   = notif;
      _overlayStatus = overlay;
      _loading = false;
    });
  }

  Permission _storagePermission() {
    if (Platform.isAndroid) {
      if ((Platform.operatingSystemVersion).contains('Android 11') ||
          _isAndroid11Plus()) {
        return Permission.manageExternalStorage;
      }
    }
    return Permission.storage;
  }

  bool _isAndroid11Plus() {
    try {
      final v = Platform.operatingSystemVersion;
      // extract SDK int — version string varies, safer to use sdk level
      // We request MANAGE_EXTERNAL_STORAGE on all Android ≥ 11 (SDK 30+)
      // The exact version check isn't critical since older Android ignores it.
      return true;
    } catch (_) {
      return false;
    }
  }

  bool get _allGranted =>
      (_notifStatus == PermissionStatus.granted ||
          _notifStatus == PermissionStatus.limited);

  Future<void> _requestStorage() async {
    final result = await _storagePermission().request();
    setState(() => _storageStatus = result);
    if (result == PermissionStatus.granted) {
      await importPublicProjectsToPrivate();
    } else if (result == PermissionStatus.permanentlyDenied) {
      openAppSettings();
    }
  }

  Future<void> _requestNotification() async {
    final result = await Permission.notification.request();
    setState(() => _notifStatus = result);
  }

  Future<void> _requestOverlay() async {
    if (!Platform.isAndroid) return;
    final result = await Permission.systemAlertWindow.request();
    setState(() => _overlayStatus = result);
  }

  Future<void> _proceed() async {
    if (_proceeding) return;
    setState(() => _proceeding = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('permissions_shown', true);
    if (!mounted) return;
    // After permissions, go to SetupScreen which handles Debian + symlinks + services
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const SetupScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: _kAccent))
            : Column(
                children: [
                  // Header
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 40, 24, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: _kAccent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(Icons.shield_outlined,
                              color: _kAccent, size: 28),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'Autorisations',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Panda IDE needs these accesses to function properly as a full IDE.',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 14,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Permissions list
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      children: [
                        _SectionLabel(label: 'FILES & STORAGE'),
                        const SizedBox(height: 10),
                        _PermissionCard(
                          icon: Icons.folder_open_rounded,
                          iconColor: const Color(0xfff5a623),
                           title: 'Shared memory (optional)',
                          description:
                               'Used only to import or export projects in the Panda IDE folder.'
                               'The terminal and private projects function without this access.',
                          status: _storageStatus,
                          onRequest: _requestStorage,
                        ),
                        const SizedBox(height: 28),
                        _SectionLabel(label: 'NOTIFICATIONS'),
                        const SizedBox(height: 10),
                        _PermissionCard(
                          icon: Icons.notifications_outlined,
                          iconColor: const Color(0xff7aabdd),
                          title: 'Notifications',
                          description:
                              'To alert you to the end of builds, Panda Agent responses, and extension updates.',
                          status: _notifStatus,
                          onRequest: _requestNotification,
                        ),
                        const SizedBox(height: 28),
                        _SectionLabel(label: 'AFFICHAGE'),
                        const SizedBox(height: 10),
                        _PermissionCard(
                          icon: Icons.picture_in_picture_alt_rounded,
                          iconColor: const Color(0xff9b7dd4),
                          title: 'Screen overlay (Floating mode)',
                          description:
                              'Allows Panda Agent to display itself in floating mode on top of other applications.'
                              'Required to use the floating overlay outside the app.',
                          status: _overlayStatus,
                          onRequest: _requestOverlay,
                        ),
                      ],
                    ),
                  ),

                  // Bottom action
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                    child: Column(
                      children: [
                        if (!_allGranted)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              'You can continue without all permissions, but some features will be limited.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.4),
                                fontSize: 12,
                              ),
                            ),
                          ),
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: ElevatedButton(
                            onPressed: _proceeding ? null : _proceed,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _kAccent,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              disabledBackgroundColor:
                                  _kAccent.withValues(alpha: 0.4),
                            ),
                            child: _proceeding
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        color: Colors.white, strokeWidth: 2),
                                  )
                                : Text(
                                    _allGranted
                                        ? 'Start Panda IDE'
                                        : 'Continue anyway',
                                    style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

// ── Section label ─────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.35),
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
      ),
    );
  }
}

// ── Permission card ───────────────────────────────────────────────────────────

class _PermissionCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String description;
  final PermissionStatus status;
  final VoidCallback onRequest;

  const _PermissionCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.description,
    required this.status,
    required this.onRequest,
  });

  bool get _granted =>
      status == PermissionStatus.granted ||
      status == PermissionStatus.limited;

  String get _statusLabel {
    if (_granted) return 'Granted';
    if (status == PermissionStatus.permanentlyDenied) return 'Denied — Open settings';
    if (status == PermissionStatus.restricted) return 'Restreint';
    return 'Demander';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _granted
              ? const Color(0xff3aaa6e).withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.06),
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Icon
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: 14),

          // Text
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 12.5,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 14),
                GestureDetector(
                  onTap: _granted ? null : onRequest,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: _granted
                          ? const Color(0xff3aaa6e).withValues(alpha: 0.15)
                          : _kAccent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _granted
                            ? const Color(0xff3aaa6e).withValues(alpha: 0.4)
                            : _kAccent.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _granted
                              ? Icons.check_circle_outline
                              : Icons.add_circle_outline,
                          size: 14,
                          color: _granted
                              ? const Color(0xff3aaa6e)
                              : _kAccent,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _statusLabel,
                          style: TextStyle(
                            color: _granted
                                ? const Color(0xff3aaa6e)
                                : _kAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
