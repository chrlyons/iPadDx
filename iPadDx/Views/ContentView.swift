import CoreLocation
import SwiftUI
import UIKit

enum DetailView: Hashable {
    case dashboard
    case tests
    case bridges
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
                case .bridges:
                    BridgeInfoView()
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
                // This alert only appears at first launch, and `onAppear` will
                // not fire again — so saving must always end with the service
                // advertising and browsing. Fall back to the system device name
                // rather than leaving the app silent on the network.
                let typed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
                UserDefaults.standard.set(typed.isEmpty ? UIDevice.current.name : typed, forKey: "deviceName")
                service.startAll()
            }
            .disabled(editingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Choose a name for this device so the other iPad can identify it.")
        }
    }
}
