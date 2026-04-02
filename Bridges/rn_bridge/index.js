/**
 * Minimal React Native bridge module for iPadDx.
 * Headless — no UI. Just registers the app and signals readiness
 * so the native side knows the RCTBridge is fully initialized.
 *
 * The actual echo function is called from native via:
 *   bridge.enqueueJSCall("BridgeEchoModule", "echo", [base64, callId])
 * which invokes the registered callable module below.
 */
import { AppRegistry, NativeModules } from 'react-native';

const App = () => null;
AppRegistry.registerComponent('RNBridge', () => App);

// Signal to native that the JS bundle has loaded and modules are ready
if (NativeModules.BridgeEchoModule) {
  NativeModules.BridgeEchoModule.ready();
}
