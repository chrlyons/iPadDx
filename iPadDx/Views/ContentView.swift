import CoreLocation
import SwiftUI

enum DetailView: Hashable {
    case dashboard
    case tests
    case reports
    case analytics
    case console
    case conductor
    case agent
}

/// Requests location permission needed for WiFi info (SSID/BSSID)
private class LocationDelegate: NSObject, CLLocationManagerDelegate {
    static let shared = LocationDelegate()
    private let manager = CLLocationManager()
    func requestIfNeeded() {
        manager.delegate = self
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }
}

struct ContentView: View {
    @Environment(BonjourService.self) private var service
    @State private var showNamePrompt = false
    @State private var editingName = ""
    @State private var detailSelection: DetailView = .dashboard

    private var needsName: Bool {
        UserDefaults.standard.string(forKey: "deviceName")?.isEmpty ?? true
    }

    var body: some View {
        NavigationSplitView {
            DeviceListView(detailSelection: $detailSelection)
        } detail: {
            NavigationStack {
                switch detailSelection {
                case .dashboard:
                    if let peer = service.connectedPeer {
                        DiagnosticDashboardView(peer: peer)
                    } else {
                        VStack(spacing: 20) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 60))
                                .foregroundStyle(.secondary)
                            Text("No Device Connected")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("Start scanning and tap a discovered device to connect.")
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                    }
                case .tests:
                    TestInfoView()
                case .console:
                    ConsoleLogView()
                case .reports:
                    ReportListView()
                case .analytics:
                    ReportAnalyticsView()
                case .conductor:
                    ConductorDashboardView()
                case .agent:
                    AgentStatusView()
                }
            }
        }
        .onAppear {
            LocationDelegate.shared.requestIfNeeded()
            if needsName {
                showNamePrompt = true
            } else {
                service.startAll()
            }
        }
        .onChange(of: service.appMode) { _, newMode in
            switch newMode {
            case .agent:
                detailSelection = .agent
            case .conductor:
                detailSelection = .conductor
            case .standalone:
                detailSelection = .dashboard
            }
        }
        .alert("Set Device Name", isPresented: $showNamePrompt) {
            TextField("e.g. Christian's iPad", text: $editingName)
            Button("Save") {
                let name = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    UserDefaults.standard.set(name, forKey: "deviceName")
                    service.startAll()
                }
            }
        } message: {
            Text("Choose a name for this device so the other iPad can identify it.")
        }
    }
}
