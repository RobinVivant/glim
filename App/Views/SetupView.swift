import HueKit
import SwiftUI

/// First run: find the bridge, then wait for the link button.
struct SetupView: View {
    @Environment(AppModel.self) private var model

    private enum Phase: Equatable {
        case searching
        case choose([BridgeInfo])
        case waitingForButton(BridgeInfo)
        case failed(String)
    }

    @State private var phase: Phase = .searching
    @State private var manualHost = ""
    @State private var isProbing = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "lightbulb.max.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.glow)
                .symbolEffect(.pulse, isActive: phase == .searching)

            switch phase {
            case .searching:
                Text("Looking for your Hue bridge").font(.title3.weight(.semibold))
                ProgressView()

            case .choose(let bridges):
                Text(bridges.isEmpty ? "No bridge found" : "Choose your bridge").font(.title3.weight(.semibold))
                VStack(spacing: 10) {
                    ForEach(bridges) { bridge in
                        Button {
                            phase = .waitingForButton(bridge)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(bridge.name).font(.headline)
                                    Text(bridge.host).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding()
                            .background(.quaternary, in: .rect(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }
                }
                manualEntry
                Button("Search again") { search() }

            case .waitingForButton(let bridge):
                Text("Press the button on top of \(bridge.name)").font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Glim connects as soon as you press it.")
                    .foregroundStyle(.secondary)
                ProgressView()
                Button("Cancel") { search() }
                    .task(id: bridge) { await waitForButton(bridge) }

            case .failed(let message):
                Text("Could not connect").font(.title3.weight(.semibold))
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                manualEntry
                Button("Search again") { search() }
            }
            Spacer()
            Spacer()
        }
        .padding(24)
        .task { search() }
    }

    private var manualEntry: some View {
        HStack {
            TextField("Bridge IP address", text: $manualHost)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(.quaternary, in: .rect(cornerRadius: 12))
            Button("Connect") { probeManualHost() }
                .buttonStyle(.borderedProminent)
                .disabled(manualHost.isEmpty || isProbing)
        }
    }

    private func search() {
        phase = .searching
        Task {
            #if DEBUG
            // Development: point the app at scripts/mock-bridge.py instead of searching the network.
            let environment = ProcessInfo.processInfo.environment
            if let host = environment["GLIM_BRIDGE_HOST"] {
                // With a key as well, skip the link button: for looking at a bridge that is already paired.
                if let key = environment["GLIM_BRIDGE_KEY"], let bridge = try? await Pairing.probe(host: host) {
                    return model.paired(
                        BridgeCredentials(
                            host: host, bridgeID: bridge.bridgeID, name: bridge.name, applicationKey: key,
                            certificatePin: bridge.certificatePin))
                }
                manualHost = host
                return probeManualHost()
            }
            #endif
            let bridges = await Discovery.bridges()
            guard phase == .searching else { return }
            phase = bridges.count == 1 ? .waitingForButton(bridges[0]) : .choose(bridges)
        }
    }

    private func probeManualHost() {
        isProbing = true
        Task {
            defer { isProbing = false }
            do {
                phase = .waitingForButton(try await Pairing.probe(host: manualHost.trimmingCharacters(in: .whitespaces)))
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func waitForButton(_ bridge: BridgeInfo) async {
        let deviceName = UIDevice.current.name
        while !Task.isCancelled {
            do {
                model.paired(try await Pairing.pair(with: bridge, deviceName: deviceName))
                return
            } catch HueError.linkButtonNotPressed {
                try? await Task.sleep(for: .milliseconds(1200))
            } catch {
                if Task.isCancelled { return }
                phase = .failed(error.localizedDescription)
                return
            }
        }
    }
}
