import DroidCore
import Foundation
@testable import MtpKit
import UsbKit

/// The device side of MTP, in memory, behaving like Android's MtpServer where it matters
/// (AOSP `MtpServer.cpp`, `MtpDatabase.java`): GetObjectPropList at depth 1 includes the
/// folder itself, handle 0 at depth 1 means the root of every storage, SendObjectInfo's
/// root parent is 0xFFFFFFFF while ParentObject and MoveObject use 0, a >4 GB data phase
/// has length 0xFFFFFFFF and ends at a short packet. It reads the host's data phases with
/// USB semantics and records every framing violation in `violations`.
actor FakeMtpDevice {
    struct Profile: Sendable {
        var propList = true
        var partial64 = true
        var partial32 = true
        var editOps = true
        var move = true
        var copy = true
        var setPropValue = true
        var propValue = true
        /// Forget the ZLP after a data container that ends on a packet boundary.
        var omitZLP = false
        var maxPacketSize = 512
        static let android = Profile()
        /// A minimal PTP-only device: no MTP property operations, no Android extensions.
        static let bare = Profile(propList: false, partial64: false, partial32: false, editOps: false, move: false,
                                  copy: false, setPropValue: false, propValue: false)
    }

    enum Content: Sendable {
        case bytes(Data)
        /// Large files are kept as "this many zero bytes" so 6 GB never sits in memory.
        case zeros(UInt64)

        var size: UInt64 {
            switch self {
            case .bytes(let d): UInt64(d.count)
            case .zeros(let n): n
            }
        }

        func slice(_ offset: UInt64, _ length: UInt64) -> Data {
            let end = min(size, offset + length)
            guard offset < end else { return Data() }
            switch self {
            case .bytes(let d): return d.subdata(in: Int(offset)..<Int(end))
            case .zeros: return Data(count: Int(end - offset))
            }
        }
    }

    struct Object: Sendable {
        var storage: UInt32
        var parent: UInt32 // 0 at the root
        var name: String
        var isDir: Bool
        var content: Content
        var modified: String
    }

    let profile: Profile
    let hostIn: MemoryUsbPipe      // device → host (bulk IN)
    let hostOut: MemoryUsbPipe     // host → device (bulk OUT)
    let interrupt: MemoryUsbPipe
    nonisolated let deviceInfo: PtpDeviceInfo
    var storages: [UInt32: PtpStorageInfo]
    var objects: [UInt32: Object] = [:]
    var nextHandle: UInt32 = 1
    var sessionOpen = false
    var pendingSend: (handle: UInt32, size: UInt32)?
    var editing: Set<UInt32> = []
    private(set) var violations: [String] = []
    private(set) var operations: [UInt16] = []
    private(set) var lastDataHeaderLength: UInt32?
    private var cancelRequested = false
    /// Responses forced for the next operation with this code (error tests).
    var forcedResponses: [UInt16: PtpResponseCode] = [:]
    static let largeThreshold = 64 << 20

    init(profile: Profile = .android, storages: [UInt32: PtpStorageInfo]? = nil) {
        self.profile = profile
        hostIn = MemoryUsbPipe(maxPacketSize: profile.maxPacketSize)
        hostOut = MemoryUsbPipe(maxPacketSize: profile.maxPacketSize, recordTransfers: false)
        interrupt = MemoryUsbPipe(maxPacketSize: 64)
        self.storages = storages ?? [
            0x0001_0001: PtpStorageInfo(maxCapacity: 128 << 30, freeSpace: 64 << 30, storageDescription: "Internal shared storage"),
        ]
        var info = PtpDeviceInfo()
        info.manufacturer = "Google"
        info.model = "Pixel 9"
        info.deviceVersion = "1.0"
        info.serialNumber = "MTPSERIAL"
        var ops: [PtpOperation] = [.getDeviceInfo, .openSession, .closeSession, .getStorageIDs, .getStorageInfo,
                                   .getObjectHandles, .getObjectInfo, .getObject, .deleteObject, .sendObjectInfo, .sendObject]
        if profile.propList { ops.append(.getObjectPropList) }
        if profile.propValue { ops.append(.getObjectPropValue) }
        if profile.setPropValue { ops.append(.setObjectPropValue) }
        if profile.partial64 { ops.append(.getPartialObject64) }
        if profile.partial32 { ops.append(.getPartialObject) }
        if profile.editOps { ops.append(contentsOf: PtpOperation.editOperations) }
        if profile.move { ops.append(.moveObject) }
        if profile.copy { ops.append(.copyObject) }
        info.operations = ops.map(\.rawValue)
        info.events = [0x4002, 0x4003, 0x4004, 0x4005, 0x4007]
        deviceInfo = info
    }

    nonisolated var channels: UsbInterfaceChannels {
        UsbInterfaceChannels(bulkIn: hostIn, bulkOut: hostOut, interruptIn: interrupt, control: FakeControl(device: self)) {
            await self.unplug()
        }
    }

    /// Starts answering. Returns the task so a test can stop it.
    func start() -> Task<Void, Never> {
        Task { await self.run() }
    }

    func unplug() async {
        await hostIn.close()
        await hostOut.close()
        await interrupt.close()
    }

    func violation(_ text: String) { violations.append(text) }

    // MARK: Phone-side actions (what the user does on the phone)

    @discardableResult
    func seed(_ path: String, storage: UInt32 = 0x0001_0001, contents: Content? = nil,
              modified: String = "20240102T030405") -> UInt32 {
        var parent: UInt32 = 0
        let parts = path.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            if let existing = child(named: part, of: parent, storage: storage) {
                parent = existing
                continue
            }
            let handle = nextHandle
            nextHandle += 1
            objects[handle] = Object(storage: storage, parent: parent, name: part, isDir: !(isLast && contents != nil),
                                     content: isLast ? (contents ?? .bytes(Data())) : .bytes(Data()), modified: modified)
            parent = handle
        }
        return parent
    }

    /// Creates `dir` at the storage root with `count` empty files, without the name
    /// lookups `seed` does (those are O(n) each).
    func seedFolder(_ dir: String, count: Int, storage: UInt32 = 0x0001_0001) {
        let folder = seed(dir, storage: storage)
        for i in 1...count {
            objects[nextHandle] = Object(storage: storage, parent: folder, name: String(format: "file-%05d.txt", i),
                                         isDir: false, content: .bytes(Data()), modified: "20240102T030405")
            nextHandle += 1
        }
    }

    /// The phone adds a file (a new photo) and announces it.
    func phoneAdds(_ path: String, contents: Data) async {
        let handle = seed(path, contents: .bytes(contents))
        await sendEvent(.objectAdded, handle)
    }

    func phoneRemoves(_ path: String) async {
        guard let handle = handle(for: path) else { return }
        removeTree(handle)
        await sendEvent(.objectRemoved, handle)
    }

    func sendEvent(_ code: PtpEventCode, _ parameter: UInt32) async {
        try? await interrupt.write(PtpEvent(code: code, parameters: [parameter]).encoded, timeout: nil)
    }

    func addStorage(_ id: UInt32, _ info: PtpStorageInfo) async {
        storages[id] = info
        await sendEvent(.storeAdded, id)
    }

    func handle(for path: String, storage: UInt32 = 0x0001_0001) -> UInt32? {
        var parent: UInt32 = 0
        for part in path.split(separator: "/").map(String.init) {
            guard let next = child(named: part, of: parent, storage: storage) else { return nil }
            parent = next
        }
        return parent
    }

    func object(at path: String) -> Object? { handle(for: path).flatMap { objects[$0] } }
    func names(in path: String) -> [String] {
        let parent = path.isEmpty ? 0 : (handle(for: path) ?? UInt32.max)
        return objects.values.filter { $0.parent == parent }.map(\.name).sorted()
    }

    func child(named name: String, of parent: UInt32, storage: UInt32) -> UInt32? {
        // Byte-exact, like ext4/f2fs: an NFD name and its NFC form are two files.
        objects.first { $0.value.parent == parent && $0.value.storage == storage && Array($0.value.name.utf8) == Array(name.utf8) }?.key
    }

    func children(of parent: UInt32, storage: UInt32?) -> [UInt32] {
        objects.filter { $0.value.parent == parent && (storage == nil || $0.value.storage == storage) }.keys.sorted()
    }

    func removeTree(_ handle: UInt32) {
        for child in objects.filter({ $0.value.parent == handle }).keys { removeTree(child) }
        objects[handle] = nil
    }

    // MARK: Cancel (control requests)

    func cancel() async {
        cancelRequested = true
        // Flush before abort: the aborted read resumes this actor, and must not find the
        // abandoned data still queued and take it for the next command.
        await hostOut.flush()
        await hostOut.abort()
    }

    /// Get Device Status: busy until the cancelled data phase has been abandoned.
    var isBusyCancelling: Bool { cancelRequested }

    /// Reads the OUT pipe in short slices so a cancel that raced with the read is seen.
    private func readOut(maxLength: Int) async throws -> Data {
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            if cancelRequested { throw UsbError.aborted }
            do {
                return try await hostOut.read(maxLength: maxLength, timeout: .milliseconds(50))
            } catch UsbError.timedOut where ContinuousClock.now < deadline {
                continue
            }
        }
    }

    // MARK: Main loop

    private func run() async {
        while true {
            let command: PtpParameterContainer
            do {
                let data = try await hostOut.read(maxLength: profile.maxPacketSize, timeout: nil)
                if data.isEmpty { continue }
                command = try PtpParameterContainer.decode(data)
            } catch UsbError.aborted {
                cancelRequested = false
                continue
            } catch let error as DeviceError {
                violation("garbage where a command was expected: \(error)")
                continue
            } catch {
                return
            }
            guard command.kind == .command else {
                violation("expected a command, got \(command.kind)")
                continue
            }
            operations.append(command.code)
            do {
                try await dispatch(command)
            } catch UsbError.aborted where cancelRequested {
                cancelRequested = false // the host cancelled: no response; Get Device Status turns OK
                continue
            } catch {
                if case UsbError.disconnected = error { return }
                violation("\(PtpOperation(rawValue: command.code)): \(error)")
            }
        }
    }

    func respond(_ command: PtpParameterContainer, _ code: PtpResponseCode, _ parameters: [UInt32] = []) async throws {
        let response = PtpParameterContainer(kind: .response, code: code.rawValue, transactionID: command.transactionID,
                                             parameters: parameters)
        try await hostIn.write(response.encoded, timeout: nil)
    }

    /// Sends a data container the way Android does: header and data together, whole
    /// packets per transfer, a ZLP when it ends on a packet boundary.
    func sendData(_ command: PtpParameterContainer, length: UInt64, chunks: (UInt64, UInt64) -> Data) async throws {
        let header = PtpContainerHeader.data(code: command.code, transactionID: command.transactionID, payloadLength: length)
        let mps = profile.maxPacketSize
        var pending = header.encoded
        var sent: UInt64 = 0
        let chunk: UInt64 = 1 << 20
        while sent < length {
            let piece = chunks(sent, min(chunk, length - sent))
            sent += UInt64(piece.count)
            pending.append(piece)
            if pending.count >= Int(chunk) {
                let whole = pending.count - pending.count % mps
                try await hostIn.write(pending.prefix(whole), timeout: nil)
                pending = Data(pending.dropFirst(whole))
            }
        }
        if !pending.isEmpty { try await hostIn.write(pending, timeout: nil) }
        if (UInt64(PtpContainerHeader.size) + length) % UInt64(mps) == 0 && !profile.omitZLP {
            try await hostIn.write(Data(), timeout: nil)
        }
    }

    func sendData(_ command: PtpParameterContainer, _ data: Data) async throws {
        try await sendData(command, length: UInt64(data.count)) { offset, length in
            data.subdata(in: Int(offset)..<Int(offset + length))
        }
    }

    /// Reads the host's data phase with USB semantics, handing payload chunks to `sink`.
    /// Returns the payload length.
    @discardableResult
    func receiveData(_ command: PtpParameterContainer, sink: (Data) -> Void) async throws -> UInt64 {
        let mps = profile.maxPacketSize
        // One packet first: a bigger read would swallow the ZLP of a one-packet container.
        var first = try await readOut(maxLength: mps)
        while first.isEmpty { first = try await readOut(maxLength: mps) }
        let header = try PtpContainerHeader.decode([UInt8](first.prefix(12)))
        lastDataHeaderLength = header.length
        guard header.kind == .data, header.transactionID == command.transactionID else {
            violation("bad data header \(header)")
            throw DeviceError.protocolError("bad data header")
        }
        var received = UInt64(first.count)
        sink(first.dropFirst(12))
        var lastShort = first.count % mps != 0
        if header.length == PtpContainerHeader.unknownLength {
            while !lastShort {
                let more = try await readOut(maxLength: 1 << 20)
                received += UInt64(more.count)
                if !more.isEmpty { sink(more) }
                lastShort = more.count % mps != 0 || more.isEmpty
            }
            return received - 12
        }
        let total = UInt64(header.length)
        while received < total {
            if lastShort {
                violation("short packet after \(received) of \(total) bytes")
                throw DeviceError.protocolError("incomplete")
            }
            let left = total - received
            let ask = Int(min(1 << 20, (left + UInt64(mps) - 1) / UInt64(mps) * UInt64(mps)))
            let more = try await readOut(maxLength: ask)
            received += UInt64(more.count)
            sink(more)
            lastShort = more.count % mps != 0 || more.isEmpty
        }
        if received > total { violation("data phase longer than its header: \(received) > \(total)") }
        if total % UInt64(mps) == 0 {
            // The host must end a whole-packet container with a ZLP.
            do {
                let zlp = try await hostOut.read(maxLength: mps, timeout: .seconds(2))
                if !zlp.isEmpty { violation("expected a ZLP after \(total) bytes, got \(zlp.count) bytes") }
            } catch UsbError.timedOut {
                violation("missing ZLP after a \(total)-byte container")
            }
        }
        return total - 12
    }

    func receiveDataCollecting(_ command: PtpParameterContainer) async throws -> Data {
        var data = Data()
        try await receiveData(command) { data.append($0) }
        return data
    }
}

/// Class requests: Cancel (0x64) and Get Device Status (0x67).
struct FakeControl: UsbControlChannel {
    let device: FakeMtpDevice

    func classRequestOut(_ request: UInt8, value: UInt16, data: Data, timeout: Duration) async throws {
        if request == 0x64 { await device.cancel() }
    }

    func classRequestIn(_ request: UInt8, value: UInt16, length: Int, timeout: Duration) async throws -> Data {
        await device.isBusyCancelling ? Data([4, 0, 0x19, 0x20]) : Data([4, 0, 0x01, 0x20])
    }
}
