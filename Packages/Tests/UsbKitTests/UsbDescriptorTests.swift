import DroidCore
import Foundation
import IOKit
import Testing
@testable import UsbKit

@Suite("USB descriptors and classification")
struct UsbDescriptorTests {
    /// A Pixel in "File transfer + USB debugging": MTP (FF/FF/00 "MTP") and ADB (FF/42/01).
    static let pixelConfiguration: [UInt8] = [
        9, 2, 62, 0, 2, 1, 0, 0x80, 250,                 // configuration, wTotalLength 62
        9, 4, 0, 0, 3, 0xFF, 0xFF, 0x00, 5,              // interface 0: MTP, 3 endpoints
        7, 5, 0x81, 2, 0x00, 0x02, 0,                    // bulk IN 512
        7, 5, 0x01, 2, 0x00, 0x02, 0,                    // bulk OUT 512
        7, 5, 0x82, 3, 0x1C, 0x00, 6,                    // interrupt IN 28
        9, 4, 1, 0, 2, 0xFF, 0x42, 0x01, 6,              // interface 1: ADB
        7, 5, 0x83, 2, 0x00, 0x04, 0,                    // bulk IN 1024 (USB 3)
        7, 5, 0x02, 2, 0x00, 0x04, 0,                    // bulk OUT 1024
    ]

    @Test("parses interfaces and their endpoints")
    func parse() throws {
        let interfaces = try UsbDescriptors.interfaces(inConfiguration: Self.pixelConfiguration)
        #expect(interfaces.count == 2)
        let mtp = try #require(UsbEndpointSet(interfaces[0].endpoints))
        #expect(mtp.bulkIn == UsbEndpoint(address: 0x81, type: .bulk, maxPacketSize: 512))
        #expect(mtp.bulkOut.address == 0x01)
        #expect(mtp.interruptIn?.maxPacketSize == 28)
        let adb = try #require(UsbEndpointSet(interfaces[1].endpoints))
        #expect(adb.bulkIn.maxPacketSize == 1024)
        #expect(adb.interruptIn == nil)
        #expect(interfaces[1].interfaceSubclass == 0x42)
        #expect(interfaces[0].stringIndex == 5)
    }

    @Test("rejects truncated descriptor chains", arguments: [
        [9, 2, 0, 0, 0], [9, 4, 0, 0], [5, 4, 0, 0, 0], [0, 4, 0],
    ] as [[UInt8]])
    func malformed(bytes: [UInt8]) {
        #expect(throws: UsbDescriptors.ParseError.self) { try UsbDescriptors.interfaces(inConfiguration: bytes) }
    }

    @Test("an interface without a bulk pair has no endpoint set")
    func noBulkPair() {
        #expect(UsbEndpointSet([UsbEndpoint(address: 0x81, type: .interrupt, maxPacketSize: 8)]) == nil)
    }

    @Test("classifies Android interfaces and nothing else", arguments: [
        (0xFF, 0x42, 0x01, nil, AndroidInterfaceKind.adb),
        (0xFF, 0x42, 0x01, "ADB Interface", .adb),
        (0xFF, 0x42, 0x03, "fastboot", nil),
        (0xFF, 0xFF, 0x00, "MTP", .mtp),
        (0xFF, 0xFF, 0x00, "mtp", .mtp),
        (0x06, 0x01, 0x01, "MTP", .mtp),
        (0x06, 0x01, 0x01, nil, .ptp),
        (0x06, 0x01, 0x01, "PTP", .ptp),
        (0xFF, 0xFF, 0x00, "Vendor", nil),
        (0x03, 0x01, 0x02, "MTP", nil),   // a keyboard, whatever it calls itself
        (0x08, 0x06, 0x50, nil, nil),
    ] as [(Int, Int, Int, String?, AndroidInterfaceKind?)])
    func classify(c: Int, s: Int, p: Int, name: String?, expected: AndroidInterfaceKind?) {
        #expect(AndroidInterfaceKind.classify(interfaceClass: UInt8(c), subclass: UInt8(s), protocol: UInt8(p), name: name) == expected)
    }

    @Test("PTP-speaking kinds")
    func speaksPTP() {
        #expect(AndroidInterfaceKind.mtp.speaksPTP)
        #expect(AndroidInterfaceKind.ptp.speaksPTP)
        #expect(!AndroidInterfaceKind.adb.speaksPTP)
    }

    @Test("device snapshot from IORegistry properties")
    func deviceInfo() throws {
        let mtp = UsbInterfaceInfo(registryID: 11, properties: [
            "bInterfaceNumber": 0, "bInterfaceClass": 255, "bInterfaceSubClass": 255, "bInterfaceProtocol": 0,
            "kUSBString": "MTP", "UsbExclusiveOwner": "pid 2100, ptpcamerad",
        ])
        let adb = UsbInterfaceInfo(registryID: 12, properties: [
            "bInterfaceNumber": 1, "bInterfaceClass": 255, "bInterfaceSubClass": 66, "bInterfaceProtocol": 1,
            "USB Interface Name": "ADB Interface",
        ])
        let device = UsbDeviceInfo(registryID: 10, properties: [
            "idVendor": 0x18D1, "idProduct": 0x4EE7, "USB Serial Number": "35141FDJG000AB",
            "kUSBVendorString": "Google", "kUSBProductString": "Pixel 8", "locationID": 0x1430_0000,
        ], interfaces: [adb, mtp])
        #expect(device.interfaces.map(\.number) == [0, 1])
        #expect(device.adbInterface?.registryID == 12)
        #expect(device.mtpInterface?.registryID == 11)
        #expect(device.mtpInterface?.holder == UsbHolder(pid: 2100, processName: "ptpcamerad"))
        #expect(device.serial == "35141FDJG000AB")
        #expect(device.displayName == "Pixel 8")
        #expect(device.hasAndroidInterface)
        #expect(!device.looksLikeChargingPhone)
        #expect(device.locationID == 0x1430_0000)
    }

    @Test("a phone in charging-only mode, a keyboard, and a PTP-only phone")
    func otherDevices() {
        let charging = UsbDeviceInfo(registryID: 1, properties: ["idVendor": 0x04E8], interfaces: [])
        #expect(charging.looksLikeChargingPhone)
        #expect(charging.displayName == "Samsung device")
        let keyboard = UsbDeviceInfo(registryID: 2, properties: ["idVendor": 0x05AC, "USB Product Name": "Keyboard"],
                                     interfaces: [UsbInterfaceInfo(registryID: 3, properties: ["bInterfaceClass": 3])])
        #expect(!keyboard.hasAndroidInterface)
        #expect(!keyboard.looksLikeChargingPhone)
        #expect(!UsbWatcher.defaultFilter(keyboard))
        #expect(UsbWatcher.defaultFilter(charging))
        let ptp = UsbDeviceInfo(registryID: 4, properties: [:], interfaces: [
            UsbInterfaceInfo(registryID: 5, number: 0, interfaceClass: 6, interfaceSubclass: 1, interfaceProtocol: 1,
                             name: nil, exclusiveOwner: nil),
        ])
        #expect(ptp.mtpInterface?.kind == .ptp)
        #expect(ptp.displayName == "USB device")
    }
}

@Suite("Busy-interface holders and advice")
struct UsbHolderTests {
    @Test("parses process and driver owners", arguments: [
        ("pid 2100, ptpcamerad", UsbHolder(pid: 2100, processName: "ptpcamerad")),
        ("pid 77, Android File Transfer Agent", UsbHolder(pid: 77, processName: "Android File Transfer Agent")),
        ("AppleUSBHostCompositeDevice", UsbHolder(pid: nil, processName: "AppleUSBHostCompositeDevice")),
    ])
    func parse(text: String, expected: UsbHolder) {
        #expect(UsbHolder(ownerString: text) == expected)
    }

    @Test("rejects empty or broken owner strings", arguments: ["", "  ", "pid x, name", "pid 12,"])
    func rejects(text: String) {
        #expect(UsbHolder(ownerString: text) == nil)
    }

    @Test("recognises the apps that grab phones", arguments: [
        ("ptpcamerad", KnownHolder.ptpcamerad),
        ("Image Capture", .imageCapture),
        ("mscamerad-xpc", .imageCapture),
        ("PTPCamera", .imageCapture),
        ("Android File Transfer", .androidFileTransfer),
        ("OpenMTP", .openMTP),
        ("MacDroid", .macDroid),
        ("SmartSwitchMac", .smartSwitch),
        ("adb", .adbServer),
        ("Finder", .other),
    ])
    func known(name: String, expected: KnownHolder) {
        #expect(UsbHolder(pid: 1, processName: name).app == expected)
    }

    @Test("each holder gets advice; ptpcamerad offers a stop command and ADB")
    func advice() {
        let ptp = UsbHolder(pid: 5, processName: "ptpcamerad").advice
        #expect(ptp.stopCommand == ["/usr/bin/killall", "ptpcamerad"])
        #expect(ptp.suggestsADB)
        let driver = UsbHolder(ownerString: "SomeDriver")!
        #expect(driver.isDriver)
        #expect(driver.app == .driver)
        #expect(driver.advice.message.contains("SomeDriver"))
        for app in KnownHolder.allCases {
            let advice = app.advice(processName: "X")
            #expect(!advice.message.isEmpty)
            #expect(advice.stopCommand == nil || app == .ptpcamerad)
        }
        #expect(UsbHolder(pid: ProcessInfo.processInfo.processIdentifier, processName: "me").isCurrentProcess)
    }

    @Test("busy errors map to DeviceError.busy with the process name")
    func mapping() {
        #expect(UsbError.exclusiveAccess(UsbHolder(pid: 1, processName: "OpenMTP")).deviceError == .busy(by: "OpenMTP"))
        #expect(UsbError.exclusiveAccess(nil).deviceError == .busy(by: nil))
    }

    @Test("BusyRetry retries while busy and gives up after the limit")
    func retry() async throws {
        let attempts = Attempts()
        let value = try await BusyRetry.run(interval: .milliseconds(5), limit: .seconds(5)) {
            if await attempts.next() < 3 { throw UsbError.exclusiveAccess(nil) }
            return "open"
        }
        #expect(value == "open")
        let seen = Attempts()
        await #expect(throws: UsbError.exclusiveAccess(UsbHolder(pid: 1, processName: "OpenMTP"))) {
            try await BusyRetry.run(interval: .milliseconds(10), limit: .milliseconds(35),
                                    onBusy: { _ in Task { await seen.bump() } }) {
                throw UsbError.exclusiveAccess(UsbHolder(pid: 1, processName: "OpenMTP"))
            }
        }
        await #expect(throws: UsbError.stalled) {
            try await BusyRetry.run(interval: .milliseconds(5), limit: .seconds(1)) { throw UsbError.stalled }
        }
    }

    actor Attempts {
        var count = 0
        func next() -> Int { count += 1; return count }
        func bump() { count += 1 }
    }
}

@Suite("UsbError mapping")
struct UsbErrorTests {
    @Test("IOReturn codes", arguments: [
        (kIOReturnAborted, UsbError.aborted), (kIOReturnTimeout, .timedOut), (kIOReturnOverrun, .overflow),
        (kIOReturnExclusiveAccess, .exclusiveAccess(nil)), (kIOReturnNoDevice, .disconnected),
        (kIOReturnNotResponding, .disconnected), (Int32(bitPattern: 0xE000_5000), .stalled),
        (kIOReturnBadArgument, .failed(kIOReturnBadArgument)),
    ])
    func ioReturn(status: Int32, expected: UsbError) {
        #expect(UsbError.from(ioReturn: status) == expected)
    }

    @Test("every case has a DeviceError")
    func deviceErrors() {
        #expect(UsbError.disconnected.deviceError == .disconnected)
        #expect(UsbError.aborted.deviceError == .disconnected)
        #expect(UsbError.notFound.deviceError == .disconnected)
        for error in [UsbError.timedOut, .stalled, .overflow, .failed(-1)] {
            guard case .protocolError = error.deviceError else { Issue.record("\(error)"); continue }
        }
        guard case .unsupported = UsbError.notAndroidInterface("x").deviceError else { Issue.record("unsupported"); return }
    }
}

/// Read-only IORegistry access: safe on any Mac, with or without a phone.
@Suite("IORegistry (read-only)")
struct UsbRegistryTests {
    @Test("enumerates devices without opening anything")
    func enumerate() {
        let devices = UsbRegistry.devices()
        for device in devices {
            #expect(UsbRegistry.device(registryID: device.registryID)?.vendorID == device.vendorID)
            for interface in device.interfaces {
                // Unregistered entries (some built-in devices) cannot be matched by id.
                if let found = UsbRegistry.interface(registryID: interface.registryID) {
                    #expect(found.number == interface.number)
                }
                _ = UsbRegistry.holder(ofInterface: interface.registryID)
            }
        }
        #expect(UsbRegistry.device(registryID: 0xDEAD_BEEF_0000) == nil)
        #expect(UsbRegistry.holder(ofInterface: 0xDEAD_BEEF_0000) == nil)
    }

    @Test("refuses to open anything that is not an Android interface")
    func refusesNonAndroid() {
        // Every interface on this Mac that is not ADB/MTP must be refused before IOUSBHost
        // is touched. With no phone attached, that is every interface.
        for device in UsbRegistry.devices() {
            for interface in device.interfaces where interface.kind == nil {
                #expect(throws: UsbError.self) { _ = try UsbInterfaceOpener.open(registryID: interface.registryID) }
                do {
                    _ = try UsbInterfaceOpener.open(registryID: interface.registryID)
                } catch {
                    // notFound: an unregistered entry IOKit will not match by id; refused as well.
                    switch error {
                    case .notAndroidInterface, .notFound: break
                    default: Issue.record("\(error)")
                    }
                }
            }
        }
        #expect(throws: UsbError.notFound) { _ = try UsbInterfaceOpener.open(registryID: 0xDEAD_BEEF_0000) }
    }

    @Test("the watcher starts, reports what is attached, and stops")
    func watcher() async throws {
        let stream = UsbWatcher.events { _ in true }
        let expected = UsbRegistry.devices().count
        var seen = 0
        let collector = Task {
            for await event in stream {
                if case .attached = event { seen += 1 }
                if seen >= expected { break }
            }
            return seen
        }
        let timeout = Task { try await Task.sleep(for: .seconds(5)); collector.cancel() }
        let count = await collector.value
        timeout.cancel()
        #expect(count >= min(expected, 1) || expected == 0)
    }
}
