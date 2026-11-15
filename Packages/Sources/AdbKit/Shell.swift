import DroidCore
import Foundation

/// Quoting for paths that go into `sh -c` on the device (spec §5.4, "Shell
/// safety"). Every path is single-quoted with embedded quotes closed, escaped, reopened,
/// and every command puts `--` before its paths so a name starting with "-" is not an option.
public enum ShellQuote {
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func quote(_ path: RemotePath) -> String { quote(path.string) }
}

public struct ShellResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// shell protocol v2 packets: 1-byte id, UInt32 length, data.
enum ShellV2 {
    enum PacketId: UInt8 {
        case stdin = 0, stdout = 1, stderr = 2, exit = 3, closeStdin = 4, windowSize = 5
    }
}

/// Runs one command. Uses shell protocol v2 (exit code, separate stderr) when the device
/// has `shell_v2`, otherwise appends a marker to read the exit code from stdout.
enum ShellRunner {
    static let exitMarker = "\u{1F}DDEXIT:"

    static func run(_ command: String, on opener: any AdbServiceOpener) async throws -> ShellResult {
        if opener.features.contains("shell_v2") {
            return try await runV2(command, on: opener)
        }
        return try await runLegacy(command, on: opener)
    }

    private static func runV2(_ command: String, on opener: any AdbServiceOpener) async throws -> ShellResult {
        let stream = try await opener.open("shell,v2,raw:" + command)
        do {
            let result = try await readV2(stream)
            await stream.close()
            return result
        } catch {
            await stream.close()
            throw error
        }
    }

    private static func readV2(_ stream: any AdbByteStream) async throws -> ShellResult {
        let reader = StreamReader(stream)
        var stdout = Data()
        var stderr = Data()
        while true {
            let header = try await reader.readExactly(5)
            var r = ByteReader(header)
            let rawId: UInt8 = try r.read()
            let length: UInt32 = try r.read()
            guard length <= 16 << 20 else { throw DeviceError.protocolError("Shell packet too large") }
            let body = Data(try await reader.readExactly(Int(length)))
            switch ShellV2.PacketId(rawValue: rawId) {
            case .stdout: stdout.append(body)
            case .stderr: stderr.append(body)
            case .exit:
                return ShellResult(exitCode: Int32(body.first ?? 255), stdout: stdout, stderr: stderr)
            default: break
            }
        }
    }

    private static func runLegacy(_ command: String, on opener: any AdbServiceOpener) async throws -> ShellResult {
        // A subshell, so an `exit` in the command cannot skip the marker.
        let stream = try await opener.open("shell:(" + command + "\n); printf '\\037DDEXIT:%s' $?")
        let output: Data
        do {
            output = try await StreamReader(stream).readToEnd()
            await stream.close()
        } catch {
            await stream.close()
            throw error
        }
        let text = String(decoding: output, as: UTF8.self)
        guard let range = text.range(of: exitMarker, options: .backwards),
              let code = Int32(text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw DeviceError.protocolError("Could not read the shell exit code") }
        return ShellResult(exitCode: code, stdout: Data(text[..<range.lowerBound].utf8), stderr: Data())
    }
}
