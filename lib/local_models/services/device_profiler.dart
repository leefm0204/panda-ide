/// DeviceProfiler — detects Android hardware to recommend models.
///
/// Lit /proc/cpuinfo and /proc/meminfo (still available on Android),
/// examines storage via dart:io, and calculates an overall performance score.
/// The result is cached in SharedPreferences.
library;
import 'dart:io';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/device_profile.dart';



class DeviceProfiler {
  static const _kPrefsKey = 'panda_device_profile_v1';

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Loads from cache or starts a new scan.
  static Future<DeviceProfile> load() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_kPrefsKey);
    if (cached != null) {
      try {
        return DeviceProfile.fromJson(
            Map<String, dynamic>.from(jsonDecode(cached) as Map));
      } catch (_) {/* cache corrompu → re-scan */}
    }
    return scan();
  }

  /// Launches a full scan and caches the result.
  static Future<DeviceProfile> scan() async {
    final results = await Future.wait([
      _readCpuInfo(),
      _readMemInfo(),
      _readStorageInfo(),
    ]);

    final cpu     = results[0] as _CpuInfo;
    final mem     = results[1] as _MemInfo;
    final storage = results[2] as _StorageInfo;

    final gpuHint = _guessGpu();
    final vulkan  = _likelyVulkan(cpu.arch);
    final score   = _calcScore(cpu, mem);

    final profile = DeviceProfile(
      cpuArch:        cpu.arch,
      cpuCores:       cpu.cores,
      cpuFreqMHz:     cpu.freqMHz,
      cpuFeatures:    cpu.features,
      totalRamMb:     mem.totalMb,
      availableRamMb: mem.availableMb,
      internalFreeGb: storage.internalFreeGb,
      sdCardFreeGb:   storage.sdFreeGb,
      sdCardWritable: storage.sdWritable,
      gpuHint:        gpuHint,
      vulkanSupported: vulkan,
      performanceScore: score,
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefsKey, jsonEncode(profile.toJson()));
    return profile;
  }

  /// Forces a new scan (useful from the settings).
  static Future<DeviceProfile> rescan() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kPrefsKey);
    return scan();
  }

  // ── CPU ────────────────────────────────────────────────────────────────────

  static Future<_CpuInfo> _readCpuInfo() async {
    try {
      final raw = await File('/proc/cpuinfo').readAsString();
      return _parseCpuInfo(raw);
    } catch (_) {
      return _CpuInfo(
        arch: _detectArch(),
        cores: Platform.numberOfProcessors,
        freqMHz: 1800,
        features: [],
      );
    }
  }

  static _CpuInfo _parseCpuInfo(String raw) {
    final lines = raw.split('\n');
    int cores = 0;
    int freqMHz = 0;
    final featureSet = <String>{};
    String arch = _detectArch();

    for (final line in lines) {
      final parts = line.split(':');
      if (parts.length < 2) continue;
      final key   = parts[0].trim().toLowerCase();
      final value = parts.sublist(1).join(':').trim().toLowerCase();

      if (key == 'processor') cores++;

      if (key == 'features' || key == 'flags') {
        featureSet.addAll(
          value.split(RegExp(r'\s+')).where((f) =>
            ['neon', 'sve', 'sve2', 'sme', 'dotprod', 'i8mm',
             'asimd', 'asimddp', 'asimdhp', 'fp16', 'fphp']
            .contains(f)),
        );
      }

      // "cpu max frequency" or "cpu mhz"
      if (key.contains('mhz') || key.contains('bogomips')) {
        final mhz = double.tryParse(value.split(' ').first);
        if (mhz != null && mhz > freqMHz) freqMHz = mhz.toInt();
      }
    }

    if (cores == 0) cores = Platform.numberOfProcessors;
    if (freqMHz == 0) freqMHz = 1800;

    return _CpuInfo(
      arch: arch,
      cores: cores,
      freqMHz: freqMHz,
      features: featureSet.toList(),
    );
  }

  static String _detectArch() {
    // dart:io Platform.version contains the arch on some platforms
    if (Platform.isAndroid) {
      // heuristic: if dart:ffi is available and we are on Android 64-bit
      return 'arm64-v8a';
    }
    return 'unknown';
  }

  // ── RAM ───────────────────────────────────────────────────────────────────

  static Future<_MemInfo> _readMemInfo() async {
    try {
      final raw = await File('/proc/meminfo').readAsString();
      return _parseMemInfo(raw);
    } catch (_) {
      return _MemInfo(totalMb: 4096, availableMb: 1500);
    }
  }

  static _MemInfo _parseMemInfo(String raw) {
    int totalKb = 0;
    int availKb = 0;
    int freeKb  = 0;
    int cachedKb = 0;

    for (final line in raw.split('\n')) {
      final parts = line.split(RegExp(r':\s*'));
      if (parts.length < 2) continue;
      final key = parts[0].trim();
      final kb  = int.tryParse(parts[1].split(' ').first) ?? 0;

      switch (key) {
        case 'MemTotal':     totalKb  = kb; break;
        case 'MemFree':      freeKb   = kb; break;
        case 'MemAvailable': availKb  = kb; break;
        case 'Cached':       cachedKb = kb; break;
      }
    }

    final available = availKb > 0 ? availKb : freeKb + cachedKb;
    return _MemInfo(
      totalMb:     (totalKb / 1024).round(),
      availableMb: (available / 1024).round(),
    );
  }

  // ── Stockage ──────────────────────────────────────────────────────────────

  static Future<_StorageInfo> _readStorageInfo() async {
    int internalFreeGb = 8;
    int sdFreeGb = 0;
    bool sdWritable = false;

    try {
      // Stockage interne
      final stat = await FileStat.stat('/data/data/com.panda.ide');
      // FileStat does not directly show free space on Android
      // We read /proc/mounts and statfs via directory size is insufficient
      // Approximation via the home folder
      final internalDir = Directory('/storage/emulated/0');
      if (await internalDir.exists()) {
        // Free space on /storage/emulated/0 via df
        try {
          final result = await Process.run('df', ['-k', '/storage/emulated/0']);
          final lines = (result.stdout as String).split('\n');
          if (lines.length > 1) {
            final cols = lines[1].split(RegExp(r'\s+'));
            if (cols.length >= 4) {
              final freeKb = int.tryParse(cols[3]) ?? 0;
              internalFreeGb = (freeKb / (1024 * 1024)).round();
            }
          }
        } catch (_) {
          internalFreeGb = 8;
        }
      }
    } catch (_) {}

    // SD card
    try {
      final sdDirs = [
        '/storage/sdcard1',
        '/storage/extSdCard',
      ];
      for (final path in sdDirs) {
        final d = Directory(path);
        if (await d.exists()) {
          try {
            final f = File('$path/.panda_test_${DateTime.now().millisecondsSinceEpoch}');
            await f.writeAsString('test');
            await f.delete();
            sdWritable = true;

            final result = await Process.run('df', ['-k', path]);
            final lines = (result.stdout as String).split('\n');
            if (lines.length > 1) {
              final cols = lines[1].split(RegExp(r'\s+'));
              if (cols.length >= 4) {
                final freeKb = int.tryParse(cols[3]) ?? 0;
                sdFreeGb = (freeKb / (1024 * 1024)).round();
              }
            }
            break;
          } catch (_) {}
        }
      }
    } catch (_) {}

    return _StorageInfo(
      internalFreeGb: internalFreeGb,
      sdFreeGb: sdFreeGb,
      sdWritable: sdWritable,
    );
  }

  // ── GPU heuristique ───────────────────────────────────────────────────────

  static String _guessGpu() {
    // Without native code, we cannot read the GPU precisely.
    // On Qualcomm (ARM64 dominant) → Adreno
    // On MediaTek → Mali
    // We return a heuristic based on the arch
    if (!Platform.isAndroid) return 'unknown';
    // The majority of flagship Android phones are based on Qualcomm
    return 'adreno';
  }

  static bool _likelyVulkan(String arch) {
    // Vulkan is available since Android 7 on arm64
    return arch.contains('arm64') || arch.contains('x86_64');
  }

  // ── Score ─────────────────────────────────────────────────────────────────

  static int _calcScore(_CpuInfo cpu, _MemInfo mem) {
    int score = 0;

    // RAM (40 pts)
    final ramGb = mem.totalMb / 1024;
    if (ramGb >= 16) {
      score += 40;
    } else if (ramGb >= 12) score += 35;
    else if (ramGb >= 8)  score += 28;
    else if (ramGb >= 6)  score += 20;
    else if (ramGb >= 4)  score += 12;
    else score += 5;

    // CPU cores (30 pts)
    if (cpu.cores >= 8) {
      score += 30;
    } else if (cpu.cores >= 6) score += 22;
    else if (cpu.cores >= 4) score += 15;
    else score += 8;

    // CPU features (20 pts)
    if (cpu.features.contains('sve2') || cpu.features.contains('sme')) {
      score += 20;
    } else if (cpu.features.contains('sve'))  score += 15;
    else if (cpu.features.contains('i8mm')) score += 12;
    else if (cpu.features.contains('neon')) score += 8;
    else score += 4;

    // Frequency (10 points)
    if (cpu.freqMHz >= 3000) {
      score += 10;
    } else if (cpu.freqMHz >= 2500) score += 8;
    else if (cpu.freqMHz >= 2000) score += 6;
    else score += 3;

    return score.clamp(0, 100);
  }
}

// ── Private Data Classes ───────────────────────────────────────────────────────────

class _CpuInfo {
  final String arch;
  final int cores;
  final int freqMHz;
  final List<String> features;
  const _CpuInfo({
    required this.arch,
    required this.cores,
    required this.freqMHz,
    required this.features,
  });
}

class _MemInfo {
  final int totalMb;
  final int availableMb;
  const _MemInfo({required this.totalMb, required this.availableMb});
}

class _StorageInfo {
  final int internalFreeGb;
  final int sdFreeGb;
  final bool sdWritable;
  const _StorageInfo({
    required this.internalFreeGb,
    required this.sdFreeGb,
    required this.sdWritable,
  });
}
