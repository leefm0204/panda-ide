/// ModelDownloadManager — robust downloading of GGUF models.
///
/// Features:
/// • Resumption after interruption via HTTP Range headers.
/// • Download in 8 MB chunks with real-time progress.
/// • SHA256 verification at the end of the download (if hash provided).
/// • Queue: multiple models can be queued.
/// • Instant cancellation by template.
library;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../../utils/constants.dart';
import '../models/ai_model_entry.dart';



// ── Constantes ────────────────────────────────────────────────────────────────

final _kModelsDir = '$appDir/models';
const _kChunkSize = 8 * 1024 * 1024; // 8 MB
const _kInstalledKey = 'panda_installed_models_v1';

// ── Download Status ──────────────────────────────────────────────────────

enum DownloadStatus {
  queued,
  downloading,
  paused,
  verifying,
  completed,
  failed,
  cancelled,
}

class DownloadTask {
  final String  taskId;       // modelId + '_' + quantLevel
  final String  modelId;
  final String  quantLevel;
  final String  url;
  final String  filename;
  final double  totalSizeGb;
  final String  sha256;
  final String  storage;      // "internal" | "sdcard"

  DownloadStatus status;
  double         progress;    // 0.0 – 1.0
  double         speedMbps;
  String?        errorMessage;
  int            bytesDownloaded;
  int            totalBytes;

  // Internal control
  bool _cancelRequested = false;
  Completer<void>? _pauseCompleter;

  DownloadTask({
    required this.taskId,
    required this.modelId,
    required this.quantLevel,
    required this.url,
    required this.filename,
    required this.totalSizeGb,
    required this.sha256,
    required this.storage,
  })  : status          = DownloadStatus.queued,
        progress        = 0.0,
        speedMbps       = 0.0,
        bytesDownloaded = 0,
        totalBytes      = (totalSizeGb * 1024 * 1024 * 1024).toInt();

  String get destDir => storage == 'sdcard'
      ? '/storage/sdcard1/Android/data/com.panda.ide/models'
      : _kModelsDir;

  String get destPath => '$destDir/$filename';
  String get tempPath => '$destDir/$filename.part';
}

// ── Singleton ─────────────────────────────────────────────────────────────────

class ModelDownloadManager {
  ModelDownloadManager._();
  static final ModelDownloadManager instance = ModelDownloadManager._();

  final Map<String, DownloadTask> _tasks      = {};
  final Map<String, List<InstalledModel>> _installed = {};

  // Broadcast stream for progress updates
  final _controller = StreamController<DownloadTask>.broadcast();
  Stream<DownloadTask> get updates => _controller.stream;

  bool _initialized = false;

  // ── Initialisation ─────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await _ensureModelsDir();
    await _loadInstalledIndex();
  }

  Future<void> _ensureModelsDir() async {
    final dir = Directory(_kModelsDir);
    if (!await dir.exists()) await dir.create(recursive: true);
  }

  // ── Download ───────────────────────────────────────────────────────────────

  Future<void> startDownload({
    required AiModelEntry model,
    required ModelQuant   quant,
    required String       storage,
  }) async {
    await init();

    final taskId = '${model.id}_${quant.level}';
    if (_tasks.containsKey(taskId) &&
        _tasks[taskId]!.status == DownloadStatus.downloading) {
      return; // already in progress
    }

    // HuggingFace download URL
    final url = 'https://huggingface.co/${model.hfRepo}/resolve/main/${quant.hfFilename}';

    final task = DownloadTask(
      taskId:      taskId,
      modelId:     model.id,
      quantLevel:  quant.level,
      url:         url,
      filename:    quant.hfFilename,
      totalSizeGb: quant.sizeGb,
      sha256:      quant.sha256,
      storage:     storage,
    );
    _tasks[taskId] = task;
    _notify(task);

    _runDownload(task);
  }

  Future<void> _runDownload(DownloadTask task) async {
    task.status = DownloadStatus.downloading;
    _notify(task);

    try {
      final destDir = Directory(task.destDir);
      if (!await destDir.exists()) await destDir.create(recursive: true);

      final tempFile = File(task.tempPath);
      int startByte  = 0;

      // Resume: if a partial file exists, resume from there
      if (await tempFile.exists()) {
        startByte = await tempFile.length();
        task.bytesDownloaded = startByte;
        task.progress = task.totalBytes > 0
            ? startByte / task.totalBytes
            : 0.0;
        _notify(task);
      }

      final client = http.Client();
      try {
        final request = http.Request('GET', Uri.parse(task.url));
        if (startByte > 0) {
          request.headers['Range'] = 'bytes=$startByte-';
        }

        final response = await client.send(request);
        if (response.statusCode != 200 && response.statusCode != 206) {
          throw Exception('HTTP ${response.statusCode}');
        }

        // Some mirrors ignore Range and return the entire file with 200.
        // Appending that response to the partial file would corrupt the GGUF.
        // Restart from zero in that case; keep append mode only for 206.
        final resumeAccepted = startByte > 0 && response.statusCode == 206;
        if (startByte > 0 && !resumeAccepted) {
          startByte = 0;
          task.bytesDownloaded = 0;
          task.progress = 0;
          await tempFile.delete().catchError((_) {});
        }

        // Total size from Content-Range or Content-Length
        final contentLength = response.contentLength;
        if (contentLength != null && contentLength > 0) {
          task.totalBytes = startByte + contentLength;
        }

        final sink = tempFile.openWrite(
            mode: resumeAccepted ? FileMode.append : FileMode.write);

        final stopwatch = Stopwatch()..start();
        int bytesThisWindow = 0;
        int lastSpeedUpdate = 0;

        await for (final chunk in response.stream) {
          if (task._cancelRequested) {
            await sink.close();
            client.close();
            await tempFile.delete().catchError((_) {});
            task.status = DownloadStatus.cancelled;
            _notify(task);
            return;
          }

          sink.add(chunk);
          task.bytesDownloaded += chunk.length;
          bytesThisWindow      += chunk.length;

          if (task.totalBytes > 0) {
            task.progress = task.bytesDownloaded / task.totalBytes;
          }

          // Speed ​​update every 500ms
          final now = stopwatch.elapsedMilliseconds;
          if (now - lastSpeedUpdate >= 500) {
            final elapsed = (now - lastSpeedUpdate) / 1000.0;
            task.speedMbps = (bytesThisWindow / (1024 * 1024)) / elapsed;
            bytesThisWindow = 0;
            lastSpeedUpdate = now;
            _notify(task);
          }
        }

        await sink.close();
        client.close();

      } finally {
        client.close();
      }

      // SHA256 verification if available
      if (task.sha256.isNotEmpty) {
        task.status = DownloadStatus.verifying;
        task.speedMbps = 0;
        _notify(task);

        final valid = await _verifySha256(task.tempPath, task.sha256);
        if (!valid) {
          await tempFile.delete().catchError((_) {});
          task.status = DownloadStatus.failed;
          task.errorMessage = 'SHA256 verification failed. File corrupted.';
          _notify(task);
          return;
        }
      }

      // Moves the temp file to the final destination
      final destFile = File(task.destPath);
      if (await destFile.exists()) await destFile.delete();
      await tempFile.rename(task.destPath);

      // Saves to index
      await _registerInstalled(task);

      task.status   = DownloadStatus.completed;
      task.progress = 1.0;
      _notify(task);

    } catch (e) {
      task.status       = DownloadStatus.failed;
      task.errorMessage = e.toString();
      _notify(task);
    }
  }

  // ── Control ───────────────────────────────────────────────────────────────────────

  void cancelDownload(String taskId) {
    final task = _tasks[taskId];
    if (task != null) task._cancelRequested = true;
  }

  Future<void> retryDownload(String taskId) async {
    final task = _tasks[taskId];
    if (task == null) return;
    task._cancelRequested = false;
    task.status           = DownloadStatus.queued;
    _notify(task);
    _runDownload(task);
  }

  void removeTask(String taskId) {
    _tasks.remove(taskId);
  }

  // ── SHA256 ─────────────────────────────────────────────────────────────────

  Future<bool> _verifySha256(String path, String expectedHex) async {
    try {
      final file   = File(path);
      final digest = await _computeSha256Stream(file.openRead());
      return digest.toString() == expectedHex.toLowerCase();
    } catch (_) {
      return false;
    }
  }

  Future<Digest> _computeSha256Stream(Stream<List<int>> stream) async {
    final chunks = <List<int>>[];
    await for (final chunk in stream) {
      chunks.add(chunk);
    }
    final bytes = chunks.expand((c) => c).toList();
    return sha256.convert(bytes);
  }

  // ── Index of installed models ───────────────────────────────────────────────

  Future<void> _loadInstalledIndex() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_kInstalledKey);
    if (raw == null) return;
    try {
      final list = List<Map<String, dynamic>>.from(
          (jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e as Map)));
      for (final j in list) {
        final m = InstalledModel.fromJson(j);
        _installed.putIfAbsent(m.modelId, () => []).add(m);
      }
    } catch (_) {}
  }

  Future<void> _registerInstalled(DownloadTask task) async {
    final model = InstalledModel(
      modelId:    task.modelId,
      quantLevel: task.quantLevel,
      filePath:   task.destPath,
      sizeGb:     task.totalSizeGb,
      storage:    task.storage,
      installedAt: DateTime.now(),
      lastUsedAt:  DateTime.now(),
    );
    _installed.putIfAbsent(task.modelId, () => []).add(model);
    await _saveInstalledIndex();
  }

  Future<void> _saveInstalledIndex() async {
    final prefs = await SharedPreferences.getInstance();
    final list  = _installed.values
        .expand((l) => l)
        .map((m) => m.toJson())
        .toList();
    await prefs.setString(_kInstalledKey, jsonEncode(list));
  }

  /// Publicly exposed so that LruCacheService can persist after
  /// updating `lastUsedAt` on an InstalledModel.
  Future<void> persistInstalledIndex() => _saveInstalledIndex();

  Future<void> deleteModel(String modelId, String quantLevel) async {
    final list = _installed[modelId];
    if (list == null) return;
    final model = list.firstWhere(
        (m) => m.quantLevel == quantLevel,
        orElse: () => throw StateError('not found'));
    try {
      await File(model.filePath).delete();
    } catch (_) {}
    list.removeWhere((m) => m.quantLevel == quantLevel);
    if (list.isEmpty) _installed.remove(modelId);
    await _saveInstalledIndex();
  }

  // ── Getters ────────────────────────────────────────────────────────────────

  List<InstalledModel> getInstalled(String modelId) =>
      _installed[modelId] ?? [];

  bool isInstalled(String modelId, String quantLevel) =>
      (_installed[modelId] ?? []).any((m) => m.quantLevel == quantLevel);

  List<InstalledModel> get allInstalled =>
      _installed.values.expand((l) => l).toList();

  DownloadTask? getTask(String taskId) => _tasks[taskId];

  List<DownloadTask> get activeTasks =>
      _tasks.values
          .where((t) => t.status == DownloadStatus.downloading ||
                        t.status == DownloadStatus.queued      ||
                        t.status == DownloadStatus.verifying)
          .toList();

  // ── Helper ─────────────────────────────────────────────────────────────────

  void _notify(DownloadTask task) {
    if (!_controller.isClosed) _controller.add(task);
  }

  void dispose() => _controller.close();
}
