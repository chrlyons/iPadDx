import SwiftUI

@main
struct iPadDxApp: App {
    @State private var bonjourService = BonjourService()
    @State private var reportStore = ReportStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(bonjourService)
                .environment(reportStore)
        }
    }
}
