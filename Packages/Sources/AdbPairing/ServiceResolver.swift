import Foundation
import dnssd

/// Resolves one Bonjour instance to an IPv4 address and port with DNS-SD
/// (`DNSServiceResolve`, then `DNSServiceGetAddrInfo`). NWBrowser only reports names;
/// resolving through a connection would touch the phone's pairing port.
///
/// Lives on the discovery queue: start, callbacks and cancel all run there (hence
/// `@unchecked Sendable`).
final class ServiceResolver: @unchecked Sendable {
    private let service: WifiService
    private let queue: DispatchQueue
    private let done: (String?, UInt16?) -> Void
    private var resolveRef: DNSServiceRef?
    private var addressRef: DNSServiceRef?
    private var hostTarget: String?
    private var port: UInt16?
    private var finished = false
    /// Without an IPv4 answer in this time, report the `.local` host name instead.
    static let addressTimeout: TimeInterval = 3

    init(service: WifiService, queue: DispatchQueue, done: @escaping (String?, UInt16?) -> Void) {
        self.service = service
        self.queue = queue
        self.done = done
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        var ref: DNSServiceRef?
        let error = DNSServiceResolve(&ref, 0, service.interfaceIndex, service.name, service.kind.rawValue,
                                      service.domain, Self.resolveReply, context)
        guard error == kDNSServiceErr_NoError, let ref else { return }
        DNSServiceSetDispatchQueue(ref, queue)
        resolveRef = ref
    }

    func cancel() {
        finished = true
        if let resolveRef { DNSServiceRefDeallocate(resolveRef) }
        if let addressRef { DNSServiceRefDeallocate(addressRef) }
        resolveRef = nil
        addressRef = nil
    }

    private func resolved(hostTarget: String, port: UInt16, interface: UInt32) {
        guard !finished, self.port == nil else { return }
        self.hostTarget = hostTarget.hasSuffix(".") ? String(hostTarget.dropLast()) : hostTarget
        self.port = port
        let context = Unmanaged.passUnretained(self).toOpaque()
        var ref: DNSServiceRef?
        let error = DNSServiceGetAddrInfo(&ref, 0, interface, DNSServiceProtocol(kDNSServiceProtocol_IPv4),
                                          hostTarget, Self.addressReply, context)
        if error == kDNSServiceErr_NoError, let ref {
            DNSServiceSetDispatchQueue(ref, queue)
            addressRef = ref
        }
        queue.asyncAfter(deadline: .now() + Self.addressTimeout) { [weak self] in
            guard let self, !self.finished else { return }
            self.finish(host: self.hostTarget)
        }
    }

    private func gotAddress(_ address: String) {
        guard !finished else { return }
        finish(host: address)
    }

    private func finish(host: String?) {
        let port = self.port
        cancel()
        done(host, port)
    }

    private static let resolveReply: DNSServiceResolveReply = { _, _, interface, error, _, hostTarget, portBE, _, _, context in
        guard error == kDNSServiceErr_NoError, let context, let hostTarget else { return }
        let resolver = Unmanaged<ServiceResolver>.fromOpaque(context).takeUnretainedValue()
        resolver.resolved(hostTarget: String(cString: hostTarget), port: UInt16(bigEndian: portBE), interface: interface)
    }

    private static let addressReply: DNSServiceGetAddrInfoReply = { _, _, _, error, _, address, _, context in
        guard error == kDNSServiceErr_NoError, let context, let address, address.pointee.sa_family == sa_family_t(AF_INET) else {
            return
        }
        let resolver = Unmanaged<ServiceResolver>.fromOpaque(context).takeUnretainedValue()
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
            var addr = pointer.pointee.sin_addr
            _ = inet_ntop(AF_INET, &addr, &text, socklen_t(INET_ADDRSTRLEN))
        }
        resolver.gotAddress(String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
}
