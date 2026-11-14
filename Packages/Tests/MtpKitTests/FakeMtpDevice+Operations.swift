import DroidCore
import Foundation
@testable import MtpKit
import UsbKit

/// Operation handlers of the fake device.
extension FakeMtpDevice {
    func dispatch(_ c: PtpParameterContainer) async throws {
        let op = PtpOperation(rawValue: c.code)
        let p = c.parameters + [0, 0, 0, 0, 0]
        if let forced = forcedResponses.removeValue(forKey: c.code) {
            if [PtpOperation.sendObjectInfo, .sendObject, .setObjectPropValue, .sendPartialObject].contains(op) {
                try await receiveData(c) { _ in }
            }
            return try await respond(c, forced)
        }
        guard deviceInfo.supports(op) else { return try await respond(c, .operationNotSupported) }
        if !sessionOpen && op != .getDeviceInfo && op != .openSession { return try await respond(c, .sessionNotOpen) }
        switch op {
        case .getDeviceInfo:
            try await sendData(c, try deviceInfo.encoded())
            try await respond(c, .ok)
        case .openSession:
            if sessionOpen { return try await respond(c, .sessionAlreadyOpen) }
            sessionOpen = true
            try await respond(c, .ok)
        case .closeSession:
            sessionOpen = false
            try await respond(c, .ok)
        case .getStorageIDs:
            var w = PtpWriter()
            w.u32Array(storages.keys.sorted())
            try await sendData(c, w.data)
            try await respond(c, .ok)
        case .getStorageInfo:
            guard let info = storages[p[0]] else { return try await respond(c, .invalidStorageID) }
            try await sendData(c, try info.encoded())
            try await respond(c, .ok)
        case .getObjectHandles:
            let parent = p[2] == PtpHandle.root ? 0 : p[2]
            if parent != 0 && objects[parent] == nil { return try await respond(c, .invalidParentObject) }
            var w = PtpWriter()
            w.u32Array(children(of: parent, storage: p[0] == PtpHandle.allStorages ? nil : p[0]))
            try await sendData(c, w.data)
            try await respond(c, .ok)
        case .getObjectInfo:
            guard let object = objects[p[0]] else { return try await respond(c, .invalidObjectHandle) }
            try await sendData(c, try objectInfo(object).encoded())
            try await respond(c, .ok)
        case .getObjectPropList:
            try await getObjectPropList(c, handle: p[0], depth: p[4], group: p[3])
        case .getObjectPropValue:
            guard let object = objects[p[0]] else { return try await respond(c, .invalidObjectHandle) }
            guard let element = props(p[0], object).first(where: { $0.property == UInt16(p[1]) }) else {
                return try await respond(c, .objectPropNotSupported)
            }
            var w = PtpWriter()
            try w.value(element.value, type: element.dataType)
            try await sendData(c, w.data)
            try await respond(c, .ok)
        case .setObjectPropValue:
            let data = try await receiveDataCollecting(c)
            guard objects[p[0]] != nil else { return try await respond(c, .invalidObjectHandle) }
            guard UInt16(p[1]) == PtpObjectProperty.objectFileName else { return try await respond(c, .objectPropNotSupported) }
            var r = PtpReader(data)
            let name = try r.string()
            let object = objects[p[0]]!
            if child(named: name, of: object.parent, storage: object.storage) != nil { return try await respond(c, .generalError) }
            objects[p[0]]!.name = name
            try await respond(c, .ok)
        case .getObject:
            guard let object = objects[p[0]], !object.isDir else { return try await respond(c, .invalidObjectHandle) }
            try await sendData(c, length: object.content.size) { object.content.slice($0, $1) }
            try await respond(c, .ok)
        case .getPartialObject, .getPartialObject64:
            guard let object = objects[p[0]], !object.isDir else { return try await respond(c, .invalidObjectHandle) }
            let offset = op == .getPartialObject64 ? UInt64(p[1]) | UInt64(p[2]) << 32 : UInt64(p[1])
            let length = UInt64(op == .getPartialObject64 ? p[3] : p[2])
            let count = offset >= object.content.size ? 0 : min(length, object.content.size - offset)
            try await sendData(c, length: count) { object.content.slice(offset + $0, $1) }
            try await respond(c, .ok, [UInt32(count)])
        case .deleteObject:
            guard objects[p[0]] != nil else { return try await respond(c, .invalidObjectHandle) }
            removeTree(p[0])
            try await respond(c, .ok)
            await sendEvent(.objectRemoved, p[0])
        case .sendObjectInfo:
            try await sendObjectInfo(c, storage: p[0], parent: p[1])
        case .sendObject:
            try await sendObject(c)
        case .moveObject, .copyObject:
            try await moveOrCopy(c, op: op, handle: p[0], storage: p[1], parent: p[2])
        case .beginEditObject:
            guard objects[p[0]] != nil else { return try await respond(c, .invalidObjectHandle) }
            editing.insert(p[0])
            try await respond(c, .ok)
        case .endEditObject:
            editing.remove(p[0])
            try await respond(c, .ok)
        case .truncateObject:
            guard editing.contains(p[0]), let object = objects[p[0]] else { return try await respond(c, .generalError) }
            let size = UInt64(p[1]) | UInt64(p[2]) << 32
            objects[p[0]]!.content = resized(object.content, to: size)
            try await respond(c, .ok)
        case .sendPartialObject:
            let offset = UInt64(p[1]) | UInt64(p[2]) << 32
            let data = try await receiveDataCollecting(c)
            guard editing.contains(p[0]), let object = objects[p[0]] else { return try await respond(c, .generalError) }
            objects[p[0]]!.content = written(object.content, data, at: offset)
            try await respond(c, .ok)
        default:
            try await respond(c, .operationNotSupported)
        }
    }

    // MARK: Handlers

    private func getObjectPropList(_ c: PtpParameterContainer, handle: UInt32, depth: UInt32, group: UInt32) async throws {
        guard group == 0 else { return try await respond(c, .specificationByGroupUnsupported) }
        guard depth <= 1 else { return try await respond(c, .specificationByDepthUnsupported) }
        var list: [UInt32] = []
        var this: UInt32?
        if handle == 0xFFFF_FFFF {
            list = objects.keys.sorted()
        } else if handle != 0 {
            guard objects[handle] != nil else { return try await respond(c, .invalidObjectHandle) }
            this = handle
        }
        if handle == 0 || depth == 1 {
            // Android: handle 0 means the root of *every* storage.
            list = children(of: handle == 0xFFFF_FFFF ? 0 : handle, storage: nil)
        }
        if let this { list.append(this) } // Android adds the object itself at the end
        let elements = list.flatMap { props($0, objects[$0]!) }
        try await sendData(c, try PtpPropListElement.encode(elements))
        try await respond(c, .ok)
    }

    private func sendObjectInfo(_ c: PtpParameterContainer, storage: UInt32, parent rawParent: UInt32) async throws {
        let info = try PtpObjectInfo.decode(try await receiveDataCollecting(c))
        let parent = rawParent == PtpHandle.root ? 0 : rawParent
        if rawParent == 0 { violation("SendObjectInfo used parent 0 for the root") }
        guard storages[storage] != nil else { return try await respond(c, .invalidStorageID) }
        if parent != 0 && objects[parent]?.isDir != true { return try await respond(c, .invalidParentObject) }
        if child(named: info.filename, of: parent, storage: storage) != nil { return try await respond(c, .generalError) }
        if info.compressedSize > 0, let store = storages[storage], UInt64(info.compressedSize) > store.freeSpace {
            return try await respond(c, .storeFull)
        }
        let handle = nextHandle
        nextHandle += 1
        objects[handle] = Object(storage: storage, parent: parent, name: info.filename, isDir: info.isFolder,
                                 content: .bytes(Data()), modified: info.dateModified)
        if info.isFolder {
            pendingSend = nil
        } else {
            pendingSend = (handle, info.compressedSize)
        }
        try await respond(c, .ok, [storage, rawParent, handle])
        if info.isFolder { await sendEvent(.objectAdded, handle) }
    }

    private func sendObject(_ c: PtpParameterContainer) async throws {
        guard let pending = pendingSend else {
            try await receiveData(c) { _ in }
            return try await respond(c, .noValidObjectInfo)
        }
        pendingSend = nil
        var small = Data()
        var allZero = true
        var count: UInt64 = 0
        let zero = Data(count: 1 << 20)
        do {
            count = try await receiveData(c) { chunk in
                if small.count + chunk.count <= Self.largeThreshold { small.append(chunk) } else { small = Data() }
                if allZero {
                    allZero = chunk.withUnsafeBytes { raw in
                        zero.withUnsafeBytes { z in
                            var offset = 0
                            while offset < raw.count {
                                let n = min(z.count, raw.count - offset)
                                if memcmp(raw.baseAddress! + offset, z.baseAddress!, n) != 0 { return false }
                                offset += n
                            }
                            return true
                        }
                    }
                }
            }
        } catch {
            objects[pending.handle] = nil // cancelled: Android deletes the partial file
            throw error
        }
        if pending.size != 0xFFFF_FFFF && UInt64(pending.size) != count {
            violation("SendObject sent \(count) bytes, ObjectInfo said \(pending.size)")
        }
        objects[pending.handle]?.content = count <= UInt64(Self.largeThreshold) ? .bytes(small) : (allZero ? .zeros(count) : .zeros(0))
        if count > UInt64(Self.largeThreshold) && !allZero { violation("large non-zero upload cannot be stored") }
        try await respond(c, .ok)
        await sendEvent(.objectAdded, pending.handle)
    }

    private func moveOrCopy(_ c: PtpParameterContainer, op: PtpOperation, handle: UInt32, storage: UInt32, parent: UInt32) async throws {
        guard let object = objects[handle] else { return try await respond(c, .invalidObjectHandle) }
        if parent == PtpHandle.root { violation("\(op) used 0xFFFFFFFF for the root") }
        if parent != 0 && objects[parent]?.isDir != true { return try await respond(c, .invalidParentObject) }
        if child(named: object.name, of: parent, storage: storage) != nil { return try await respond(c, .generalError) }
        if op == .moveObject {
            objects[handle]!.parent = parent
            objects[handle]!.storage = storage
            try await respond(c, .ok)
        } else {
            let copy = copyTree(handle, to: parent, storage: storage)
            try await respond(c, .ok, [copy])
        }
    }

    private func copyTree(_ handle: UInt32, to parent: UInt32, storage: UInt32) -> UInt32 {
        var object = objects[handle]!
        object.parent = parent
        object.storage = storage
        let new = nextHandle
        nextHandle += 1
        objects[new] = object
        for child in objects.filter({ $0.value.parent == handle }).keys.sorted() { _ = copyTree(child, to: new, storage: storage) }
        return new
    }

    // MARK: Datasets

    func objectInfo(_ object: Object) -> PtpObjectInfo {
        var info = PtpObjectInfo()
        info.storageID = object.storage
        info.format = object.isDir ? PtpObjectFormat.association : PtpObjectFormat.undefined
        info.compressedSize = object.content.size >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(object.content.size)
        info.parent = object.parent
        info.associationType = object.isDir ? PtpObjectFormat.genericFolder : 0
        info.filename = object.name
        info.dateCreated = object.modified
        info.dateModified = object.modified
        return info
    }

    func props(_ handle: UInt32, _ object: Object) -> [PtpPropListElement] {
        func e(_ property: UInt16, _ type: UInt16, _ value: PtpValue) -> PtpPropListElement {
            PtpPropListElement(handle: handle, property: property, dataType: type, value: value)
        }
        return [
            e(PtpObjectProperty.storageID, PtpDataType.uint32, .integer(UInt64(object.storage))),
            e(PtpObjectProperty.objectFormat, PtpDataType.uint16,
              .integer(UInt64(object.isDir ? PtpObjectFormat.association : PtpObjectFormat.undefined))),
            e(PtpObjectProperty.protectionStatus, PtpDataType.uint16, .integer(0)),
            e(PtpObjectProperty.objectSize, PtpDataType.uint64, .integer(object.isDir ? 0 : object.content.size)),
            e(PtpObjectProperty.objectFileName, PtpDataType.string, .string(object.name)),
            e(PtpObjectProperty.dateModified, PtpDataType.string, .string(object.modified)),
            e(PtpObjectProperty.dateCreated, PtpDataType.string, .string(object.modified)),
            e(PtpObjectProperty.parentObject, PtpDataType.uint32, .integer(UInt64(object.parent))),
            e(PtpObjectProperty.persistentUID, PtpDataType.uint128, .bytes(Data(count: 16))),
            e(PtpObjectProperty.name, PtpDataType.string, .string(object.name)),
        ]
    }

    private func resized(_ content: Content, to size: UInt64) -> Content {
        switch content {
        case .bytes(var d):
            if UInt64(d.count) > size { d = d.prefix(Int(size)) } else { d.append(Data(count: Int(size) - d.count)) }
            return .bytes(d)
        case .zeros: return .zeros(size)
        }
    }

    private func written(_ content: Content, _ data: Data, at offset: UInt64) -> Content {
        guard case .bytes(var d) = content else { return content }
        let end = Int(offset) + data.count
        if d.count < end { d.append(Data(count: end - d.count)) }
        d.replaceSubrange(Int(offset)..<end, with: data)
        return .bytes(d)
    }
}

extension PtpResponseCode {
    static let noValidObjectInfo = Self(rawValue: 0x2015)
}
