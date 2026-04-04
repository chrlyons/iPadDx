import SwiftUI

@main
struct iPadDxApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var bonjourService = BonjourService()
    @State private var reportStore = ReportStore()

    init() {
        // Pre-warm bridge engines in the background so they're ready
        // before any bridge transport test needs them.
        Task { @MainActor in
            _ = await FlutterBridge.sharedEngine()
            _ = await CapacitorBridgeManager.shared()
            _ = await CordovaBridgeManager.shared()
            #if !targetEnvironment(simulator)
                _ = await ReactNativeBridgeManager.shared()
            #endif
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(bonjourService)
                .environment(reportStore)
                .onAppear {
                    bonjourService.onReportReceived = { [weak reportStore] data in
                        guard let store = reportStore,
                              let report = store.decodeFromSync(data)
                        else { return }
                        store.importRemoteReport(report)
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        // Clear stale mDNS cache when returning from background
                        bonjourService.restartBrowsing()
                    }
                }
        }
    }
}
