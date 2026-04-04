import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Headless Flutter module that echoes data through the real
/// FlutterMethodChannel bridge. No UI — this exists purely to
/// put real MethodChannel serialization + thread dispatch overhead
/// in the measurement path.
void main() {
  // Ensure the binding is initialized so we can receive platform messages
  // before any frame is scheduled.
  WidgetsFlutterBinding.ensureInitialized();

  final channel = MethodChannel('com.ipadconn/bridge');

  channel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'echo':
        // Return the payload as-is. The round trip through
        // StandardMethodCodec encode → Dart VM → decode → re-encode → return
        // is the real overhead we're measuring.
        return call.arguments;
      case 'ping':
        return 'pong';
      default:
        throw PlatformException(
          code: 'UNSUPPORTED',
          message: 'Unknown method: ${call.method}',
        );
    }
  });
}
