import SwiftUI

/// Host app for the FSKit spike (S0-d). It only exists to carry the extension; macOS
/// discovers the extension when the app is launched once.
@main
struct HostApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text("DroidDrive FSKit spike").font(.headline)
                Text("Enable \"DroidSpikeFS\" in System Settings → General → Login Items & Extensions → File System Extensions, then mount with:")
                Text("mkdir -p /tmp/spike && mount -F -t droidspike 'droidspike://test?files=10000' /tmp/spike")
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            .padding(24)
            .frame(width: 560)
        }
    }
}
