/// IdeTabOpener — global entry point for opening IDE tabs
/// from any widget, WITHOUT a fullscreen Navigator.push.
///
/// Used by marketplace/extensions/device_panel pages to stay
/// IN the IDE instead of navigating to a separate page.
///
/// Usage :
/// // In home.dart (initState):
///   IdeTabOpener.instance.register(
///     openFlutterDevice: () { _openFlutterDeviceTab(); },
///     openTerminal: () { _openTerminalTab(); },
///   );
///
/// // In panda_registry_page.dart / device_panel / etc:
///   IdeTabOpener.instance.openFlutterDevice();
library;
import 'package:material_ui/material_ui.dart';



class IdeTabOpener extends ChangeNotifier {
  IdeTabOpener._();
  static final IdeTabOpener instance = IdeTabOpener._();

  VoidCallback? _openFlutterDevice;
  VoidCallback? _openTerminal;
  VoidCallback? _openMarketplace;

  /// Recorded by home.dart at startup.
  void register({
    VoidCallback? openFlutterDevice,
    VoidCallback? openTerminal,
    VoidCallback? openMarketplace,
  }) {
    _openFlutterDevice = openFlutterDevice;
    _openTerminal = openTerminal;
    _openMarketplace = openMarketplace;
    notifyListeners();
  }

  void openFlutterDevice() => _openFlutterDevice?.call();
  void openTerminal() => _openTerminal?.call();
  void openMarketplace() => _openMarketplace?.call();
}
