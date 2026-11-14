import Foundation

extension AdbServiceOpener {
    /// Runs one shell command and returns its output and exit code. Public for the
    /// Wi-Fi code in AdbPairing (reading the phone's IP before `tcpip`, plan P3-01).
    /// The command must not contain user input unless quoted (spec §5.4).
    public func runShell(_ command: String) async throws -> ShellResult {
        try await ShellRunner.run(command, on: self)
    }
}
