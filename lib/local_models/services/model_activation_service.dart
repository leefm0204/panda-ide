/// ModelActivationService — registers a GGUF model installed as an AI provider.
///
/// Replaces the existing `GgufModel.registerGgufModelWithAI` (which hardcodes
/// threads=4, ctx=4096, gpuLayers=0) by a version that uses
/// InferenceConfigService for optimal values.
///
/// After activation, the model appears in the Panda agent and can be
/// selected as active chat/completion model.
library;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/ai_model_entry.dart';
import '../models/device_profile.dart';
import '../services/model_download_manager.dart';
import 'inference_config_service.dart';



// ── Activation Result ──────────────────────────────────────────────────────

class ActivationResult {
  final String modelId;           // key in aiConfig
  final bool   alreadyExisted;
  final InferenceConfig config;   // calculated parameters
  final bool   setAsDefault;      // if the model has been set as default chat

  const ActivationResult({
    required this.modelId,
    required this.alreadyExisted,
    required this.config,
    required this.setAsDefault,
  });
}

// ── Service ───────────────────────────────────────────────────────────────────

class ModelActivationService {

  /// Registers a model installed in the Panda AI configuration.
  ///
  /// [modelEntry] — model record (from the catalog)
  /// [quantLevel] — quantization selected
  /// [profile] — hardware profile for parameter calculation
  /// [setAsDefault] — if true, select this model as the default cat
  static Future<ActivationResult> activate({
    required AiModelEntry  modelEntry,
    required String        quantLevel,
    required DeviceProfile profile,
    bool setAsDefault = false,
  }) async {
    // Retrieves the path of the installed file
    final installed = ModelDownloadManager.instance
        .getInstalled(modelEntry.id)
        .firstWhere(
          (m) => m.quantLevel == quantLevel,
          orElse: () => throw StateError(
              'Model ${modelEntry.id} $quantLevel not installed'),
        );

    // Find the quantization sheet to calculate the configuration
    final quant = modelEntry.quantizations.firstWhere(
        (q) => q.level == quantLevel,
        orElse: () => throw StateError('Quantization $quantLevel not found'));

    final config = InferenceConfigService.compute(
      model:   modelEntry,
      quant:   quant,
      profile: profile,
    );

    final prefs = await SharedPreferences.getInstance();
    final aiConfigStr = prefs.getString('aiConfig') ?? '{}';
    final Map<String, dynamic> aiConfig =
        Map<String, dynamic>.from(jsonDecode(aiConfigStr) as Map);

    // Checks if this path already exists
    final existingEntry = aiConfig.entries.firstWhere(
      (e) =>
          e.value is Map &&
          (e.value as Map)['provider'] == 'LocalLlama' &&
          (e.value as Map)['modelPath'] == installed.filePath,
      orElse: () => const MapEntry('', null),
    );

    final bool alreadyExisted = existingEntry.key.isNotEmpty;
    final String modelId = alreadyExisted
        ? existingEntry.key
        : 'LocalLlama-${modelEntry.id}-${quantLevel.replaceAll("_", "").toLowerCase()}';

    // Built / updates the entry
    aiConfig[modelId] = {
      'provider':    'LocalLlama',
      'apiProvider': 'LocalLlama',
      'modelName':   '${modelEntry.name} $quantLevel',
      'model':       '${modelEntry.name} $quantLevel',
      'modelPath':   installed.filePath,
      ...config.toConfigMap(),
      // Additional metadata (not used by LocalLlamaBloc but
      // useful for the agent_settings UI)
      'pandaModelId':     modelEntry.id,
      'pandaModelAuthor': modelEntry.author,
      'pandaQuantLevel':  quantLevel,
    };

    await prefs.setString('aiConfig', jsonEncode(aiConfig));

    // Last used date update
    installed.lastUsedAt = DateTime.now();

    // Selection as default template (if requested or if it's the first one)
    final modelSelectedStr = prefs.getString('modelSelected') ?? '{}';
    final Map<String, dynamic> modelSelected =
        Map<String, dynamic>.from(jsonDecode(modelSelectedStr) as Map);

    bool setDefault = false;
    if (setAsDefault || (modelSelected['chat'] as String? ?? '').isEmpty) {
      modelSelected['chat'] = modelId;
      await prefs.setString('modelSelected', jsonEncode(modelSelected));
      setDefault = true;
    }

    return ActivationResult(
      modelId:       modelId,
      alreadyExisted: alreadyExisted,
      config:        config,
      setAsDefault:  setDefault,
    );
  }

  /// Checks if an installed model is already registered in the AI ​​config.
  static Future<bool> isActivated({
    required String modelId,
    required String quantLevel,
  }) async {
    final installed = ModelDownloadManager.instance
        .getInstalled(modelId)
        .where((m) => m.quantLevel == quantLevel)
        .toList();
    if (installed.isEmpty) return false;

    final prefs = await SharedPreferences.getInstance();
    final aiConfigStr = prefs.getString('aiConfig') ?? '{}';
    final Map<String, dynamic> aiConfig =
        Map<String, dynamic>.from(jsonDecode(aiConfigStr) as Map);

    return aiConfig.values.any(
      (v) =>
          v is Map &&
          v['provider'] == 'LocalLlama' &&
          v['modelPath'] == installed.first.filePath,
    );
  }

  /// Disables (removes) a model from the AI ​​configuration.
  static Future<void> deactivate({
    required String modelId,
    required String quantLevel,
  }) async {
    final installed = ModelDownloadManager.instance
        .getInstalled(modelId)
        .where((m) => m.quantLevel == quantLevel)
        .toList();
    if (installed.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final aiConfigStr = prefs.getString('aiConfig') ?? '{}';
    final Map<String, dynamic> aiConfig =
        Map<String, dynamic>.from(jsonDecode(aiConfigStr) as Map);

    aiConfig.removeWhere(
      (k, v) =>
          v is Map &&
          v['provider'] == 'LocalLlama' &&
          v['modelPath'] == installed.first.filePath,
    );

    await prefs.setString('aiConfig', jsonEncode(aiConfig));
  }
}
