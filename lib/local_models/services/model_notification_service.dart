/// ModelNotificationService — Android notifications for model downloads.
///
/// Use flutter_local_notifications to:
/// • Persistent progress notification during download.
/// • Success notification with "Load model" action.
/// • Error notification with "Retry" button.
/// • Dedicated Android channel: panda_models (HIGH importance).
library;
import 'dart:async';
import 'dart:ui' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../services/model_download_manager.dart';



// ── Notification IDs ───────────────────────────────────────────────────────────

const _kProgressChannelId   = 'panda_models_progress';
const _kProgressChannelName = 'Downloading AI models';
const _kCompleteChannelId   = 'panda_models_complete';
const _kCompleteChannelName = 'AI models ready';
const _kBaseProgressId      = 5000; // IDs 5000-5099 for progressions
const _kBaseCompleteId      = 5100; // IDs 5100+ for successes/errors

// ── Service ───────────────────────────────────────────────────────────────────

class ModelNotificationService {
  ModelNotificationService._();
  static final ModelNotificationService instance = ModelNotificationService._();

  final _plugin      = FlutterLocalNotificationsPlugin();
  bool  _initialized = false;

  // Mapping taskId → notifId for update / deletion
  final Map<String, int> _taskNotifIds = {};
  int _nextCompleteId = _kBaseCompleteId;

  StreamSubscription<DownloadTask>? _sub;

  // ── Initialisation ────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await _plugin.initialize(initSettings);

    // Creates Android channels
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          _kProgressChannelId,
          _kProgressChannelName,
          description: 'Progress of downloading local AI models',
          importance: Importance.low, // LOW to avoid the sound on each update
          showBadge: false,
          playSound: false,
          enableVibration: false,
        ));

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          _kCompleteChannelId,
          _kCompleteChannelName,
          description: 'AI model downloaded and ready to use',
          importance: Importance.high,
        ));

    // Subscribes to DownloadManager updates
    _sub = ModelDownloadManager.instance.updates.listen(_onTaskUpdate);
  }

  void dispose() {
    _sub?.cancel();
  }

  // ── Handler principal ─────────────────────────────────────────────────────

  void _onTaskUpdate(DownloadTask task) {
    switch (task.status) {
      case DownloadStatus.downloading:
      case DownloadStatus.verifying:
        _showProgress(task);
        break;
      case DownloadStatus.completed:
        _dismissProgress(task.taskId);
        _showSuccess(task);
        break;
      case DownloadStatus.failed:
        _dismissProgress(task.taskId);
        _showError(task);
        break;
      case DownloadStatus.cancelled:
        _dismissProgress(task.taskId);
        break;
      default:
        break;
    }
  }

  // ── Progress Notification ──────────────────────────────────────────────

  Future<void> _showProgress(DownloadTask task) async {
    final notifId = _notifIdForTask(task.taskId);
    final pct     = (task.progress * 100).toInt();
    final dlTitle = task.status == DownloadStatus.verifying
        ? 'Verification in progress…'
        : 'Downloading in progress';

    final speedStr = task.speedMbps > 0
        ? '${task.speedMbps.toStringAsFixed(1)} MB/s · '
        : '';
    final progressStr =
        '${(task.bytesDownloaded / (1024 * 1024 * 1024)).toStringAsFixed(2)} /'
        ' ${task.totalSizeGb.toStringAsFixed(2)} GB';

    final androidDetails = AndroidNotificationDetails(
      _kProgressChannelId,
      _kProgressChannelName,
      channelDescription: 'Progress of downloading local AI models',
      importance:          Importance.low,
      priority:            Priority.low,
      ongoing:             true,
      autoCancel:          false,
      showProgress:        true,
      maxProgress:         100,
      progress:            pct,
      indeterminate:       task.status == DownloadStatus.verifying,
      subText:             '$speedStr$progressStr',
      icon:                '@mipmap/ic_launcher',
      // Cancel button
      actions: [
        const AndroidNotificationAction(
          'cancel_download',
          'Annuler',
          cancelNotification: true,
          showsUserInterface: false,
        ),
      ],
    );

    await _plugin.show(
      notifId,
      dlTitle,
      _modelLabel(task),
      NotificationDetails(android: androidDetails),
      payload: 'download:${task.taskId}',
    );
  }

  // ── Success Notification ────────────────────────────────────────────────────

  Future<void> _showSuccess(DownloadTask task) async {
    final notifId = _nextCompleteId++;

    final androidDetails = AndroidNotificationDetails(
      _kCompleteChannelId,
      _kCompleteChannelName,
      channelDescription: 'AI model downloaded and ready to use',
      importance:         Importance.high,
      priority:           Priority.high,
      autoCancel:         true,
      icon:               '@mipmap/ic_launcher',
      color:              const Color(0xFF7C4DFF), // violet Panda
      actions: [
        const AndroidNotificationAction(
          'load_model',
          'Load the model',
          showsUserInterface: true,
        ),
      ],
    );

    await _plugin.show(
      notifId,
      '✅ Ready-made model',
      '${_modelLabel(task)} is downloaded and ready to use',
      NotificationDetails(android: androidDetails),
      payload: 'ready:${task.taskId}',
    );
  }

  // ── Error notification ─────────────────────────────────────────────────

  Future<void> _showError(DownloadTask task) async {
    final notifId = _nextCompleteId++;

    final androidDetails = AndroidNotificationDetails(
      _kCompleteChannelId,
      _kCompleteChannelName,
      channelDescription: 'AI model downloaded and ready to use',
      importance:         Importance.defaultImportance,
      priority:           Priority.defaultPriority,
      autoCancel:         true,
      icon:               '@mipmap/ic_launcher',
      actions: [
        const AndroidNotificationAction(
          'retry_download',
          'Try again',
          showsUserInterface: true,
        ),
      ],
    );

    final errorMsg = task.errorMessage ?? 'Unknown error';
    await _plugin.show(
      notifId,
      '❌ Download failed',
      '${_modelLabel(task)} — $errorMsg',
      NotificationDetails(android: androidDetails),
      payload: 'error:${task.taskId}',
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  int _notifIdForTask(String taskId) {
    if (!_taskNotifIds.containsKey(taskId)) {
      _taskNotifIds[taskId] = _kBaseProgressId + _taskNotifIds.length;
    }
    return _taskNotifIds[taskId]!;
  }

  Future<void> _dismissProgress(String taskId) async {
    final id = _taskNotifIds.remove(taskId);
    if (id != null) await _plugin.cancel(id);
  }

  String _modelLabel(DownloadTask task) =>
      '${task.modelId.replaceAll("-", " ")} ${task.quantLevel}';

  /// Cancels all active progress notifications.
  Future<void> cancelAll() async {
    for (final id in _taskNotifIds.values) {
      await _plugin.cancel(id);
    }
    _taskNotifIds.clear();
  }
}
