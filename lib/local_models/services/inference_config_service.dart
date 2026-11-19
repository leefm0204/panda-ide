/// InferenceConfigService — calculates the optimal parameters llama.cpp.
///
/// Replaces hard-coded values ​​(threads=4, ctx=4096, gpuLayers=0)
/// by values ​​adapted to the detected hardware.
///
/// Principe :
/// • threads → performance cores - 2 (min 1), to leave room for the UI
/// • contextSize → based on available RAM and model size
/// • gpuLayers → 0 (triggers LocalLlamaBloc GPU auto-detection)
/// • flashAttention → true if ARM SVE2 or Vulkan GPU available
library;
import '../models/ai_model_entry.dart';
import '../models/device_profile.dart';



// ── Calculated Configuration ──────────────────────────────────────────────────────────────────

class InferenceConfig {
  final int    threads;
  final int    contextSize;
  final int    gpuLayers;     // 0 = auto-detection via LlamaController.detectGpu()
  final bool   flashAttention;
  final int    batchSize;     // n_batch for prompt processing
  final String source;        // description of how the values ​​were chosen

  const InferenceConfig({
    required this.threads,
    required this.contextSize,
    required this.gpuLayers,
    required this.flashAttention,
    required this.batchSize,
    required this.source,
  });

  /// Converts to Map for storage in aiConfig (SharedPreferences)
  Map<String, dynamic> toConfigMap() => {
    'threads':     threads,
    'contextSize': contextSize,
    'gpuLayers':   gpuLayers,
    'batchSize':   batchSize,
  };

  @override
  String toString() =>
      'InferenceConfig(threads=$threads, ctx=$contextSize, '
      'gpuLayers=$gpuLayers, flash=$flashAttention, batch=$batchSize)';
}

// ── Service ───────────────────────────────────────────────────────────────────

class InferenceConfigService {

  /// Calculates the optimal configuration for a model on the device.
  static InferenceConfig compute({
    required AiModelEntry   model,
    required ModelQuant     quant,
    required DeviceProfile  profile,
  }) {
    final threads     = _calcThreads(profile);
    final contextSize = _calcContextSize(model, quant, profile);
    final flash       = _hasFlashAttention(profile);
    final batch       = _calcBatchSize(profile);

    final src = 'Auto: ${profile.cpuCores} cores → $threads threads, '
                '${profile.totalRamGb}GB RAM → ctx $contextSize'
                '${flash ? ", Flash Attention" : ""}';

    return InferenceConfig(
      threads:        threads,
      contextSize:    contextSize,
      gpuLayers:      0,   // 0 = auto via LlamaController.detectGpu()
      flashAttention: flash,
      batchSize:      batch,
      source:         src,
    );
  }

  // ── Threads ────────────────────────────────────────────────────────────────

  /// Allocates CPU cores to llama.cpp leaving 2 cores for the UI.
  ///
  /// On a modern ARM SoC (Snapdragon, Dimensity) there is typically
  /// 4 high-performance "big" cores + 4 efficient "little" ones.
  /// llama.cpp mainly benefits from big hearts → we take all except 2.
  static int _calcThreads(DeviceProfile profile) {
    final cores = profile.cpuCores;
    if (cores <= 2) return 1;
    if (cores <= 4) return cores - 1;   // 3 or 4 cores → we keep 1 for UI
    if (cores <= 6) return cores - 2;   // 4 threads
    return cores - 2;                    // 8 cores → 6 threads (good compromise)
  }

  // ── Contexte ───────────────────────────────────────────────────────────────

  /// Calculates the context size taking into account the available RAM.
  ///
  /// The KV cache occupies approximately: 2 * n_layers * n_kv_heads * head_dim * ctx * dtype_bytes
  /// Practical approximation: ~0.5 MB per 1K tokens for a 7B Q4 model.
  /// We target a maximum of 20% of available RAM for the KV cache.
  static int _calcContextSize(
      AiModelEntry model, ModelQuant quant, DeviceProfile profile) {

    final ramGb     = profile.totalRamGb;
    final modelGb   = quant.sizeGb;
    final freeAfter = (ramGb - modelGb).clamp(0.0, double.infinity);

    // Maximum context size supported by the model
    final modelMaxCtx = model.capabilities.contextLength;

    // Budget KV cache ≈ 20% of the RAM remaining after loading the model
    final kvBudgetMb = freeAfter * 1024 * 0.20;

    // ~0.5 MB / 1K tokens for a 7B Q4 (conservative heuristic)
    final maxCtxFromRam = (kvBudgetMb / 0.5 * 1024).toInt();

    // We return the smaller of the two, rounded to the nearest power of 2
    final target = maxCtxFromRam.clamp(512, modelMaxCtx);
    return _roundToPow2(target);
  }

  static int _roundToPow2(int value) {
    const options = [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072];
    int result = 512;
    for (final o in options) {
      if (o <= value) {
        result = o;
      } else {
        break;
      }
    }
    return result;
  }

  // ── Flash Attention ───────────────────────────────────────────────────────

  /// Flash Attention is useful on: Vulkan GPU, SVE2, i8mm.
  /// Reduces KV cache memory and speeds up long contexts.
  static bool _hasFlashAttention(DeviceProfile profile) {
    if (profile.vulkanSupported) return true;
    final f = profile.cpuFeatures;
    return f.contains('sve2') || f.contains('sme') || f.contains('i8mm');
  }

  // ── Batch size ────────────────────────────────────────────────────────────

  /// n_batch controls how many tokens are processed in parallel during
  /// the prefill (prompt processing). Larger = faster but more RAM.
  static int _calcBatchSize(DeviceProfile profile) {
    final ramGb = profile.totalRamGb;
    if (ramGb >= 12) return 1024;
    if (ramGb >= 8)  return 512;
    if (ramGb >= 6)  return 256;
    return 128;
  }

  // ── Readable Summary ──────────────────────────────────────────────────────────────

  /// Returns a summary of choices for display in the UI.
  static List<String> summary(InferenceConfig cfg, DeviceProfile profile) {
    return [
      '${cfg.threads} CPU threads (${profile.cpuCores} cores detected)',
      'Contexte : ${_ctxLabel(cfg.contextSize)}',
      'GPU layers : auto (LlamaController.detectGpu)',
      if (cfg.flashAttention) 'Flash Attention: enabled ✅',
      'Batch size : ${cfg.batchSize}',
    ];
  }

  static String _ctxLabel(int ctx) {
    if (ctx >= 65536)  return '${ctx ~/ 1024}K tokens';
    if (ctx >= 1024)   return '${ctx ~/ 1024}K tokens';
    return '$ctx tokens';
  }
}
