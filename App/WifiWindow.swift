import AdbPairing
import SwiftUI

/// Hosts AdbPairing's "Connect via Wi-Fi" sheet (spec §6, plan P3-07). The model needs
/// DroidDrive's ADB key, which may be created on first open, so it is made lazily.
struct WifiWindow: View {
    @ObservedObject var manager: DeviceManager
    @Environment(\.dismiss) private var dismiss
    @State private var model: WifiConnectModel?
    @State private var failure: String?

    var body: some View {
        Group {
            if let model {
                ConnectViaWifiSheet(model: model, onClose: { dismiss() })
            } else if let failure {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("Wi-Fi connections are unavailable").font(.headline)
                    Text(failure).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(32)
                .frame(width: 420)
            } else {
                ProgressView("Preparing…").padding(48)
            }
        }
        .task {
            guard model == nil else { return }
            do {
                model = try await manager.makeWifiModel()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
