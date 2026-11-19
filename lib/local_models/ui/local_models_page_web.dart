/// LocalModelsPage — Stub web (Android uniquement).
library;
import 'package:material_ui/material_ui.dart';



/// Stub displayed on web — local models require Android.
class LocalModelsPage extends StatelessWidget {
  // ignore: avoid_unused_constructor_parameters
  const LocalModelsPage({super.key, bool embedded = false});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.phone_android, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'Local Models',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              'Available only on Android.',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
