import SwiftUI

struct DeviceListView: View {
    @Environment(BonjourService.self) private var service
    @Binding var detailSelection: DetailView
    @State private var showRenameAlert = false
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "ipad")
                        .foregroundStyle(.blue)
                    Text(service.localDeviceName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                HStack {
                    Circle()
                        .fill(service.isAdvertising ? .green : .gray)
                        .frame(width: 8, height: 8)
                    Text(service.isAdvertising ? "Advertising" : "Not Advertising")
                        .font(.caption)
                }
                HStack {
                    Circle()
                        .fill(service.isBrowsing ? .green : .gray)
                        .frame(width: 8, height: 8)
                    Text(service.isBrowsing ? "Browsing" : "Not Browsing")
                        .font(.caption)
                }
                Text(service.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text("This Device")
            }

            if let connected = service.connectedPeer {
                Section {
                    Button {
                        detailSelection = .dashboard
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(connected.name)
                                    .font(.headline)
                                HStack(spacing: 4) {
                                    Text(connected.connectionState.rawValue)
                                    Text("·")
                                    Text(service.localRole.rawValue)
                                        .foregroundStyle(service.localRole == .controller ? .blue : .orange)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            ConnectionStatusBadge(state: connected.connectionState)
                            if detailSelection == .dashboard {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                } header: {
                    Text("Connected")
                }
            }

            Section {
                if service.discoveredPeers.isEmpty {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Searching for nearby iPads...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(service.discoveredPeers) { peer in
                        Button {
                            service.connectToPeer(peer)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(peer.name)
                                        .font(.headline)
                                    Text(peer.connectionState.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                ConnectionStatusBadge(state: peer.connectionState)
                            }
                        }
                        .disabled(service.connectedPeer != nil)
                    }
                }
            } header: {
                Text("Discovered Devices")
            }

            Section {
                Button {
                    detailSelection = .reports
                } label: {
                    HStack {
                        Image(systemName: "doc.text.magnifyingglass")
                            .foregroundStyle(.blue)
                        Text("Saved Reports")
                        Spacer()
                        if detailSelection == .reports {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                Button {
                    detailSelection = .analytics
                } label: {
                    HStack {
                        Image(systemName: "chart.bar.xaxis")
                            .foregroundStyle(.purple)
                        Text("Analytics")
                        Spacer()
                        if detailSelection == .analytics {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
            } header: {
                Text("Reports")
            }

            // Mode section
            Section {
                if service.appMode == .conductor {
                    Button {
                        detailSelection = .conductor
                    } label: {
                        HStack {
                            Image(systemName: "music.note.tv")
                                .foregroundStyle(.blue)
                            Text("Conductor Dashboard")
                            Spacer()
                            if detailSelection == .conductor {
                                Image(systemName: "checkmark").foregroundStyle(.blue)
                            }
                        }
                    }
                    Button {
                        service.disableConductorMode()
                        detailSelection = .dashboard
                    } label: {
                        HStack {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.red)
                            Text("Exit Conductor Mode")
                        }
                    }
                } else if service.appMode == .agent {
                    Button {
                        detailSelection = .agent
                    } label: {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.orange)
                            Text("Agent Status")
                            Spacer()
                            if detailSelection == .agent {
                                Image(systemName: "checkmark").foregroundStyle(.blue)
                            }
                        }
                    }
                } else {
                    Button {
                        service.enableConductorMode()
                        detailSelection = .conductor
                    } label: {
                        HStack {
                            Image(systemName: "music.note.tv")
                                .foregroundStyle(.blue)
                            Text("Enable Conductor Mode")
                        }
                    }
                }
            } header: {
                Text("Mode: \(service.appMode.rawValue)")
            }

            // Fleet section (conductor mode only)
            if service.appMode == .conductor {
                Section {
                    ForEach(service.discoveredPeers) { peer in
                        Button {
                            service.connectAgentFromConductor(peer)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(peer.name).font(.subheadline)
                                    Text("Tap to add to fleet").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle").foregroundStyle(.blue)
                            }
                        }
                    }
                } header: {
                    Text("Nearby Devices")
                }
            }
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(service.isAdvertising ? "Stop Advertising" : "Start Advertising") {
                        service.isAdvertising ? service.stopAdvertising() : service.startAdvertising()
                    }
                    Button(service.isBrowsing ? "Stop Browsing" : "Start Browsing") {
                        service.isBrowsing ? service.stopBrowsing() : service.startBrowsing()
                    }
                    Divider()
                    if service.connectedPeer != nil {
                        Button("Disconnect", role: .destructive) {
                            service.disconnect()
                        }
                    }
                    Divider()
                    Button("Change Device Name") {
                        newName = service.localDeviceName
                        showRenameAlert = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Change Device Name", isPresented: $showRenameAlert) {
            TextField("Device name", text: $newName)
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    UserDefaults.standard.set(name, forKey: "deviceName")
                    // Restart advertising with new name
                    service.stopAll()
                    service.startAll()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This name is visible to other devices.")
        }
    }
}
