import AdbKit
import DroidCore
import Foundation
import os

private let log = Logger(subsystem: "com.droiddrive.usb", category: "adb-link")

/// ADB packets over a pair of bulk pipes (plan P1-03, spike S0-b over USB), so the
/// existing `AdbConnection` runs over USB unchanged.
///
/// Framing follows adb's own USB code: the 24-byte header and the payload are separate
/// transfers (adbd's FunctionFS reader rejects a header transfer of any other length),
/// and a payload that fills whole packets is followed by a zero-length packet, as adb's
/// `zero_mask` logic does, so the device sees where it ends.
public actor UsbPacketLink: AdbPacketLink {
    private let input: any UsbPipe
    private let output: any UsbPipe
    private let onClose: @Sendable () async -> Void
    private let sendLock = AsyncLock()
    private var checksumRequired = true
    private var closed = false
    /// Bytes read past a header (only when a device packs header and payload together).
    private var carry = Data()

    public init(input: any UsbPipe, output: any UsbPipe, onClose: @escaping @Sendable () async -> Void = {}) {
        self.input = input
        self.output = output
        self.onClose = onClose
    }

    public init(channels: UsbInterfaceChannels) {
        self.init(input: channels.bulkIn, output: channels.bulkOut, onClose: channels.close)
    }

    public func setChecksumRequired(_ required: Bool) { checksumRequired = required }

    public func send(_ message: AdbMessage) async throws {
        guard !closed else { throw DeviceError.disconnected }
        // AdbConnection sends from several streams at once; a header must never be
        // followed by another packet's payload.
        await sendLock.lock()
        do {
            try await write(message)
            await sendLock.unlock()
        } catch {
            await sendLock.unlock()
            log.error("USB send failed: \(String(describing: error), privacy: .public)")
            throw DeviceError.disconnected
        }
    }

    private func write(_ message: AdbMessage) async throws {
        try await output.write(message.encodedHeader(withChecksum: checksumRequired), timeout: nil)
        guard !message.payload.isEmpty else { return }
        try await output.write(message.payload, timeout: nil)
        if message.payload.count % output.maxPacketSize == 0 {
            try await output.write(Data(), timeout: nil)
        }
    }

    public func receive() async throws -> AdbMessage {
        do {
            let headerBytes = try await readHeader()
            let header = try AdbMessage.decodeHeader([UInt8](headerBytes.prefix(AdbMessage.headerSize)))
            var payload = Data(headerBytes.dropFirst(AdbMessage.headerSize))
            let length = Int(header.payloadLength)
            if payload.count > length {
                carry = Data(payload.dropFirst(length))
                payload = Data(payload.prefix(length))
            }
            while payload.count < length {
                // Exactly what is missing: asking for more could swallow the next header.
                payload.append(try await input.read(maxLength: length - payload.count, timeout: nil))
            }
            return AdbMessage(header.command, header.arg0, header.arg1, payload)
        } catch let error as DeviceError where error != .disconnected {
            throw error
        } catch {
            throw DeviceError.disconnected
        }
    }

    /// One header transfer. Reads a whole packet's worth so a header-sized short packet
    /// ends it; zero-length packets between messages are skipped.
    private func readHeader() async throws -> Data {
        var bytes = carry
        carry = Data()
        while bytes.count < AdbMessage.headerSize {
            guard !closed else { throw DeviceError.disconnected }
            let room = max(input.maxPacketSize, AdbMessage.headerSize)
            bytes.append(try await input.read(maxLength: room, timeout: nil))
        }
        return bytes
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        await input.abort()
        await output.abort()
        await onClose()
    }
}
