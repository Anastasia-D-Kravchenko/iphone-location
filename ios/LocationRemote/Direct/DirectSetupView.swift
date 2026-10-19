import SwiftUI

/// Settings section for the no-Mac mode: LocalDevVPN status and on-iPhone pairing (iOS 27).
struct DirectSetupSection: View {
    @StateObject private var pairing = DirectPairing()
    @State private var paired = DirectPairingStore.shared.hasPairingFile
    @State private var vpnOn = LocalDevVPN.isConnected

    var body: some View {
        Section {
            row("Paired with this iPhone", ok: paired)
            row("LocalDevVPN connected", ok: vpnOn)

            Button(vpnOn ? "Open LocalDevVPN" : "Connect LocalDevVPN") { LocalDevVPN.openOrInstall() }

            switch pairing.phase {
            case .idle, .succeeded:
                Button(paired ? "Pair again" : "Pair this iPhone") {
                    pairing.start(outputURL: DirectPairingStore.shared.pairingURL)
                }
            case .advertising, .deviceConnected:
                VStack(alignment: .leading, spacing: 6) {
                    HStack { ProgressView(); Text("Waiting for the iPhone…") }
                    Text("Now open Settings › Privacy & Security › Developer Mode › Pair with Host, tap **Location** → Pair and enter your passcode. Keep this app open in the background.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("Cancel", role: .cancel) { pairing.resetToIdle() }
            case .awaitingPIN(let pin):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Type this code in Settings:").font(.footnote)
                    Text(pin).font(.system(size: 40, weight: .bold, design: .monospaced))
                }
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(.red)
                Button("Try again") { pairing.acknowledgeFailure() }
            }
        } header: {
            Text("This iPhone (no Mac)")
        } footer: {
            Text("Moves this iPhone's location without the Mac, also on mobile data. Needs LocalDevVPN connected and the Wi‑Fi switch ON (it doesn't have to join a network). If it says the connection is lost: Airplane Mode on, Wi‑Fi on, wait 10 s, Airplane Mode off.")
        }
        .onChange(of: pairing.phase) {
            if pairing.phase == .succeeded { paired = true }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            vpnOn = LocalDevVPN.isConnected
            paired = DirectPairingStore.shared.hasPairingFile
        }
    }

    private func row(_ title: String, ok: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .secondary)
        }
    }
}
