/**
 * Minimal React Native bridge module for iPadDx.
 * Headless — no UI. Registers a callable JS module so native can invoke
 * echo() via bridge.enqueueJSCall(), which then calls the native module
 * to complete the round-trip through the real RCTBridge pipeline.
 */
import { AppRegistry, NativeModules } from 'react-native';
import BatchedBridge from 'react-native/Libraries/BatchedBridge/BatchedBridge';

const App = () => null;
AppRegistry.registerComponent('RNBridge', () => App);

// Register a callable JS module so native can call:
//   bridge.enqueueJSCall("BridgeEchoModule", "echo", [base64, callId])
// This exercises the full native→JS→native round-trip through RCTBridge.
BatchedBridge.registerCallableModule('BridgeEchoModule', {
  echo: function(base64Data, callId) {
    // Call back into the native module — completes the round-trip
    NativeModules.BridgeEchoModule.echo(base64Data, callId);
  }
});

// Signal readiness to native
if (NativeModules.BridgeEchoModule) {
  NativeModules.BridgeEchoModule.ready();
}
