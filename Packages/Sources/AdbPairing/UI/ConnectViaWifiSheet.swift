import SwiftUI

/// The "Connect via Wi-Fi" sheet (spec §6, plan P3-07): four tabs, QR code first.
/// The app presents it with a `WifiConnectModel` and gets connected phones through
/// `model.onConnected`.
public struct ConnectViaWifiSheet: View {
    @ObservedObject var model: WifiConnectModel
    private let onClose: () -> Void

    public init(model: WifiConnectModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect via Wi-Fi").font(.title2.weight(.semibold))
            Text("The phone and this Mac must be on the same Wi-Fi network. On the phone, open Settings → Developer options → Wireless debugging and turn it on.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Method", selection: $model.tab) {
                ForEach(WifiConnectModel.Tab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch model.tab {
                case .qrCode: QrCodeTab(model: model)
                case .pairingCode: PairingCodeTab(model: model)
                case .manual: ManualTab(model: model)
                case .legacy: LegacyTab(model: model)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)

            StatusLine(status: model.status)

            HStack {
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

struct StatusLine: View {
    let status: WifiConnectModel.Status

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .working(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text)
            }
        case .succeeded(let text):
            Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}
