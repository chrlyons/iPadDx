import SwiftUI

@main
struct iPadDxApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var bonjourService = BonjourService()
    @State private var reportStore = ReportStore()

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
