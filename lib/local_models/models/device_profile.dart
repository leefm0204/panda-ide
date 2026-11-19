/// DeviceProfile — result of the Android device hardware scan.
///
/// Collected once on first launch (then cached in SharedPreferences).
/// Used by the catalog to filter and sort recommended models.
library;

class DeviceProfile {
  // ── CPU ────────────────────────────────────────────────────────────────────
  final String cpuArch;        // arm64-v8a, x86_64, armeabi-v7a
  final int    cpuCores;       // total number of cores
  final int    cpuFreqMHz;     // maximum detected frequency (MHz)
  final List<String> cpuFeatures; // neon, sve, sve2, sme, dotprod, i8mm…

  // ── RAM ───────────────────────────────────────────────────────────────────
  final int totalRamMb;        // RAM totale (MB)
  final int availableRamMb;    // RAM free at scan time

  // ── Stockage ──────────────────────────────────────────────────────────────
  final int internalFreeGb;    // stockage interne libre (GB)
  final int sdCardFreeGb;      // Free SD card (0 = no SD)
  final bool sdCardWritable;

  // ── GPU ───────────────────────────────────────────────────────────────────
  final String gpuHint;        // "adreno", "mali", "powervr", "unknown"
  final bool vulkanSupported;  // heuristique: Android 7+ arm64

  // ── Score global (0-100) ──────────────────────────────────────────────────
  final int performanceScore;

  const DeviceProfile({
    required this.cpuArch,
    required this.cpuCores,
    required this.cpuFreqMHz,
    required this.cpuFeatures,
    required this.totalRamMb,
    required this.availableRamMb,
    required this.internalFreeGb,
    required this.sdCardFreeGb,
    required this.sdCardWritable,
    required this.gpuHint,
    required this.vulkanSupported,
    required this.performanceScore,
  });

  factory DeviceProfile.unknown() => const DeviceProfile(
    cpuArch: 'unknown',
    cpuCores: 4,
    cpuFreqMHz: 1800,
    cpuFeatures: [],
    totalRamMb: 4096,
    availableRamMb: 1500,
    internalFreeGb: 8,
    sdCardFreeGb: 0,
    sdCardWritable: false,
    gpuHint: 'unknown',
    vulkanSupported: false,
    performanceScore: 30,
  );

  /// Total RAM in GB (capped towards standard size) — Android reports ~6-10%
  /// less than the nominal RAM (e.g., Samsung S21 8GB → ~7.3-7.5 GB in
  /// /proc/meminfo). We round up to the nearest whole number to avoid blocking models
  /// which would actually be remembered.
  int get totalRamGb {
    // Capped at the full GB, then snapped to the standard size ≥
    final gbCeil = (totalRamMb / 1024).ceil();
    for (final s in const [2, 3, 4, 6, 8, 10, 12, 16, 24, 32]) {
      if (gbCeil <= s) return s;
    }
    return gbCeil;
  }

  /// Indicates whether GPU offload is likely available
  bool get gpuOffloadAvailable => vulkanSupported && gpuHint != 'unknown';

  /// Maximum recommended model size based on total RAM
  int get recommendedMaxModelSizeGb {
    if (totalRamGb >= 16) return 8;
    if (totalRamGb >= 12) return 6;
    if (totalRamGb >= 8)  return 4;
    if (totalRamGb >= 6)  return 2;
    return 1;
  }

  /// Quantization recommended by default
  String get recommendedQuant {
    if (totalRamGb >= 12) return 'Q4_K_M';
    if (totalRamGb >= 8)  return 'Q4_K_M';
    if (totalRamGb >= 6)  return 'Q4_K_S';
    return 'Q4_K_S';
  }

  /// Performance level friendly label
  String get performanceLabel {
    if (performanceScore >= 80) return 'Excellent ⚡';
    if (performanceScore >= 60) return 'Bon ✅';
    if (performanceScore >= 40) return 'Correct 🟡';
    return 'Limited 🔴';
  }

  Map<String, dynamic> toJson() => {
    'cpuArch': cpuArch,
    'cpuCores': cpuCores,
    'cpuFreqMHz': cpuFreqMHz,
    'cpuFeatures': cpuFeatures,
    'totalRamMb': totalRamMb,
    'availableRamMb': availableRamMb,
    'internalFreeGb': internalFreeGb,
    'sdCardFreeGb': sdCardFreeGb,
    'sdCardWritable': sdCardWritable,
    'gpuHint': gpuHint,
    'vulkanSupported': vulkanSupported,
    'performanceScore': performanceScore,
  };

  factory DeviceProfile.fromJson(Map<String, dynamic> j) => DeviceProfile(
    cpuArch:        j['cpuArch'] as String? ?? 'unknown',
    cpuCores:       j['cpuCores'] as int? ?? 4,
    cpuFreqMHz:     j['cpuFreqMHz'] as int? ?? 1800,
    cpuFeatures:    List<String>.from(j['cpuFeatures'] as List? ?? []),
    totalRamMb:     j['totalRamMb'] as int? ?? 4096,
    availableRamMb: j['availableRamMb'] as int? ?? 1500,
    internalFreeGb: j['internalFreeGb'] as int? ?? 8,
    sdCardFreeGb:   j['sdCardFreeGb'] as int? ?? 0,
    sdCardWritable: j['sdCardWritable'] as bool? ?? false,
    gpuHint:        j['gpuHint'] as String? ?? 'unknown',
    vulkanSupported:j['vulkanSupported'] as bool? ?? false,
    performanceScore: j['performanceScore'] as int? ?? 30,
  );
}
