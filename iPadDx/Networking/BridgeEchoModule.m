#import <React/RCTBridgeModule.h>
#import <React/RCTLog.h>

// Forward declaration — implemented in Swift, exposed via @objc(ReactNativeBridgeNotifier)
@interface ReactNativeBridgeNotifier : NSObject
+ (void)handleEchoResultWithCallId:(NSString *)callId payload:(NSString *)payload;
+ (void)markReady;
@end

@interface BridgeEchoModule : NSObject <RCTBridgeModule>
@end

@implementation BridgeEchoModule

RCT_EXPORT_MODULE();

/// Echo data back through the real RCTBridge pipeline.
/// JS calls: NativeModules.BridgeEchoModule.echo(payload, callId)
/// Data flows: JS → JSON serialize → MessageQueue batch → RCTBatchedBridge
///           → this method → resolve() → JSON serialize → JS callback
RCT_EXPORT_METHOD(echo:(NSString *)payload
                  callId:(NSString *)callId
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    resolve(payload);
    [ReactNativeBridgeNotifier handleEchoResultWithCallId:callId payload:payload];
}

/// Called from JS when the bundle has loaded and modules are ready.
RCT_EXPORT_METHOD(ready)
{
    RCTLogInfo(@"BridgeEchoModule ready signal received");
    [ReactNativeBridgeNotifier markReady];
}

+ (BOOL)requiresMainQueueSetup
{
    return NO;
}

@end
