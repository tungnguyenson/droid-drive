import SwiftUI

/// Tab 1: scan a QR code (Android 11+). Pairing starts by itself once the phone has
/// scanned it.
struct QrCodeTab: View {
    @ObservedObject var model: WifiConnectModel

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Group {
                if let image = model.qrCode.image(scale: 8) {
                    Image(decorative: image, scale: 2)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .accessibilityLabel("QR code for wireless debugging pairing")
                } else {
                    Text("Could not draw the QR code.").frame(width: 200, height: 200)
                }
            }
            .padding(8)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 10) {
                Text("On the phone, under Wireless debugging, tap **Pair device with QR code** and scan this code.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("DroidDrive pairs and connects as soon as the phone has scanned it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("New code") { model.regenerateQrCode() }
            }
        }
    }
}

/// Tab 2: pick a phone that shows "Pair device with pairing code", type its 6 digits.
struct PairingCodeTab: View {
    @ObservedObject var model: WifiConnectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On the phone, tap **Pair device with pairing code**. It appears below; select it and type the six-digit code.")
                .fixedSize(horizontal: false, vertical: true)
            List(model.pairingServices, selection: $model.selectedServiceID) { service in
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.serialHint ?? service.name)
                    Text(service.host.map { "\($0):\(service.port.map(String.init) ?? "")" } ?? "Looking up address…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(service.id)
            }
            .frame(height: 140)
            .overlay {
                if model.pairingServices.isEmpty {
                    Text("Looking for phones…").foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("Six-digit code", text: $model.pairingCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onSubmit { if model.canPairSelected { model.pairSelected() } }
                Button("Pair") { model.pairSelected() }
                    .disabled(!model.canPairSelected)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Tab 3: when the phone does not show up (mDNS blocked on the network), type what the
/// pairing dialog shows.
struct ManualTab: View {
    @ObservedObject var model: WifiConnectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tap **Pair device with pairing code** on the phone and copy the IP address & port and the code shown there.")
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Pairing IP address & port", text: $model.manualAddress, prompt: Text("192.168.1.23:37123"))
                TextField("Pairing code", text: $model.manualCode, prompt: Text("123456"))
                TextField("Connect IP address & port (optional)", text: $model.manualConnectAddress,
                          prompt: Text("192.168.1.23:41234"))
            }
            Text("The connect address is the IP address & Port line on the Wireless debugging screen. Leave it empty if the phone shows up in the Pairing code tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Pair") { model.pairManually() }
                .disabled(!model.canPairManually)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Tab 4: Android 10 and earlier have no wireless debugging; adbd must be switched to
/// TCP mode first (plug in once and use "Switch to Wi-Fi", or `adb tcpip 5555`).
struct LegacyTab: View {
    @ObservedObject var model: WifiConnectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Android 10 and earlier: connect the phone with a cable once and choose **Switch to Wi-Fi** in the DroidDrive menu. If the phone is already in TCP mode, type its IP address.")
                .fixedSize(horizontal: false, vertical: true)
            Text("The IP address is under Settings → About phone → Status, or in the Wi-Fi network's details.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("IP address", text: $model.legacyAddress, prompt: Text("192.168.1.23"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { if model.canConnectLegacy { model.connectLegacy() } }
                Button("Connect") { model.connectLegacy() }
                    .disabled(!model.canConnectLegacy)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
