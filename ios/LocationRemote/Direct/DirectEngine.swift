// Adapted from Locus (github.com/ChrisMack32/Locus), MIT License, Copyright (c) 2026 Locus contributors. See Vendor/LOCUS_LICENSE.
import Foundation
import idevice

enum DirectEngineError: LocalizedError {
    case invalidIP
    case pairingRead
    case tunnelCreate
    case remoteServer
    case simulationCreate
    case locationSet
    case locationClear
    case notActive

    var errorDescription: String? {
        switch self {
        case .invalidIP: return "Tunnel IP is invalid. Check Settings → Tunnel IP (usually 10.7.0.1)."
        case .pairingRead: return "Could not read the RPPairing file. Generate one with idevice_pair in RPPairing mode."
        case .tunnelCreate: return "Could not open the developer tunnel. Is LocalDevVPN on? On mobile data keep the Wi‑Fi switch ON (no network needed) or use Airplane Mode + Wi‑Fi."
        case .remoteServer: return "Connected to the tunnel but RemoteXPC handshake failed."
        case .simulationCreate: return "Could not open Apple’s location simulation service."
        case .locationSet: return "Failed to set simulated coordinates."
        case .locationClear: return "Failed to clear simulated location."
        case .notActive: return "No active simulation session."
        }
    }

    static func from(code: Int32) -> DirectEngineError {
        switch code {
        case 1: return .invalidIP
        case 2: return .pairingRead
        case 3: return .tunnelCreate
        case 9: return .remoteServer
        case 10: return .simulationCreate
        case 11: return .locationSet
        case 12: return .locationClear
        default: return .locationSet
        }
    }
}

/// Thin Swift wrapper around idevice’s DVT location simulation (injects into locationd).
/// One instance per device: `.phone` (this iPhone through LocalDevVPN) and `.watch`.
final class DirectEngine: @unchecked Sendable {
    static let phone = DirectEngine(label: "phone")
    static let watch: DirectEngine = {
        let e = DirectEngine(label: "watch", persistent: true)
        // The Watch link keeps a control session, a Bluetooth channel and a relay open: end them too.
        e.onCleanup = {
            tunnel_ble_release()
            WatchBLETunnel.heldChannel?.close()
            WatchBLETunnel.heldChannel = nil
            WatchTunnelFinder.relay?.close()
            WatchTunnelFinder.relay = nil
        }
        return e
    }()

    /// Extra teardown after the tunnel is freed.
    var onCleanup: (() -> Void)?

    private let queue: DispatchQueue

    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var remoteServer: OpaquePointer?
    private var locationSimulation: OpaquePointer?

    /// The last idevice error text, kept for the settings screen (evidence when something fails).
    private(set) var lastError: String?

    private let ok: Int32 = 0
    private let invalidIP: Int32 = 1
    private let pairingRead: Int32 = 2
    private let tunnelCreate: Int32 = 3
    private let remoteServerCode: Int32 = 9
    private let simulationCreate: Int32 = 10
    private let locationSet: Int32 = 11
    private let locationClear: Int32 = 12

    /// true: CoreDevice location service (like `devicectl simulate location`): the fake stays on the
    /// device after the tunnel closes, so each move/clear is connect → set/clear → disconnect.
    /// false: DVT location simulation, which needs the tunnel kept open (this iPhone via LocalDevVPN).
    let persistent: Bool

    private init(label: String, persistent: Bool = false) {
        self.persistent = persistent
        queue = DispatchQueue(label: "com.kravchenko.locationremote.direct.\(label)", qos: .userInitiated)
    }

    /// One-shot set (latitude/longitude) or clear (nil) for a persistent engine.
    func oneShot(_ coordinate: (Double, Double)?, pairingPath: String, connect: @escaping Connector) -> Result<Void, DirectEngineError> {
        queue.sync {
            var pairing: OpaquePointer?
            if let e = pairingPath.withCString({ rp_pairing_file_read($0, &pairing) }) {
                record(e, "read pairing")
                return .failure(.pairingRead)
            }
            guard let pairing else { return .failure(.pairingRead) }
            defer { rp_pairing_file_free(pairing) }
            if let e = connect(pairing, &adapter, &handshake) {
                lastError = "tunnel: \(e)"
                NSLog("[Location] %@", lastError ?? "")
                cleanup()
                return .failure(.tunnelCreate)
            }
            defer { cleanup() }
            if let (lat, lon) = coordinate {
                if let e = coredevice_location_set(adapter, handshake, lat, lon) { record(e, "set"); return .failure(.locationSet) }
            } else {
                if let e = coredevice_location_clear(adapter, handshake) { record(e, "clear"); return .failure(.locationClear) }
            }
            lastError = nil
            return .success(())
        }
    }

    var isSessionActive: Bool { locationSimulation != nil }

    /// Opens the developer tunnel: (pairing file, out adapter, out handshake) → error text or nil.
    typealias Connector = (OpaquePointer, inout OpaquePointer?, inout OpaquePointer?) -> String?

    /// Frees an idevice error and returns its text.
    static func text(_ err: UnsafeMutablePointer<IdeviceFfiError>) -> String {
        defer { idevice_error_free(err) }
        return err.pointee.message.map { String(cString: $0) } ?? "code \(err.pointee.code)"
    }

    /// Plain RPPairing tunnel to `address` (raw sockaddr_in / sockaddr_in6, see `SocketAddress`).
    static func direct(_ address: Data) -> Connector {
        { pairing, adapter, handshake in
            let err = address.withUnsafeBytes { raw in
                tunnel_create_rppairing(raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(address.count),
                                        "LocationRemote", pairing, nil, nil, &adapter, &handshake)
            }
            return err.map(DirectEngine.text)
        }
    }

    func set(latitude: Double, longitude: Double, pairingPath: String, connect: @escaping Connector) -> Result<Void, DirectEngineError> {
        var result: Result<Void, DirectEngineError> = .failure(.locationSet)
        queue.sync {
            let code = setLocked(latitude: latitude, longitude: longitude, pairingPath: pairingPath, connect: connect)
            result = code == ok ? .success(()) : .failure(.from(code: code))
        }
        return result
    }

    func clear() -> Result<Void, DirectEngineError> {
        var result: Result<Void, DirectEngineError> = .failure(.notActive)
        queue.sync {
            let code = clearLocked()
            result = code == ok ? .success(()) : .failure(.from(code: code))
        }
        return result
    }

    /// Drops the tunnel without clearing the fake (e.g. before re-resolving the Watch address).
    func disconnect() {
        queue.sync { cleanup() }
    }

    private func record(_ err: UnsafeMutablePointer<IdeviceFfiError>, _ step: String) {
        let text = err.pointee.message.map { String(cString: $0) } ?? "code \(err.pointee.code)"
        lastError = "\(step): \(text)"
        NSLog("[Location] %@", lastError ?? "")
        idevice_error_free(err)
    }

    private func cleanup() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
            onCleanup?()
        }
    }

    private func setLocked(latitude: Double, longitude: Double, pairingPath: String, connect: Connector) -> Int32 {
        if let locationSimulation {
            if let err = location_simulation_set(locationSimulation, latitude, longitude) {
                record(err, "set (open session)")
                cleanup()
            } else {
                return ok
            }
        }

        var pairingHandle: OpaquePointer?
        if let pairingError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingHandle) }) {
            record(pairingError, "read pairing")
            return pairingRead
        }
        guard let pairingHandle else { return pairingRead }
        defer { rp_pairing_file_free(pairingHandle) }

        let providerError = connect(pairingHandle, &adapter, &handshake)
        if let providerError {
            lastError = "tunnel: \(providerError)"
            NSLog("[Location] %@", lastError ?? "")
            cleanup()
            return tunnelCreate
        }

        if let remoteServerError = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
            record(remoteServerError, "RemoteXPC")
            cleanup()
            return remoteServerCode
        }

        if let simError = location_simulation_new(remoteServer, &locationSimulation) {
            record(simError, "location service")
            cleanup()
            return simulationCreate
        }
        // location_simulation_new consumes/owns remote server lifecycle alongside handle
        remoteServer = nil

        if let setError = location_simulation_set(locationSimulation, latitude, longitude) {
            record(setError, "set")
            cleanup()
            return locationSet
        }
        lastError = nil
        return ok
    }

    private func clearLocked() -> Int32 {
        guard let locationSimulation else { return locationClear }
        let err = location_simulation_clear(locationSimulation)
        // Also drop a fake set through CoreDevice (e.g. by `devicectl simulate location` on the Mac),
        // so nothing older stays behind after the reset.
        if let e = coredevice_location_clear(adapter, handshake) { idevice_error_free(e) }
        cleanup()
        if let err {
            record(err, "clear")
            return locationClear
        }
        return ok
    }
}

/// Builds raw sockaddr bytes for the idevice FFI.
enum SocketAddress {
    static func ipv4(_ ip: String, port: UInt16) -> Data? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard ip.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Data($0) }
    }

    /// "1.2.3.4:49152" / "[fe80::1%en0]:49152" for display.
    static func describe(_ data: Data) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var serv = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let rc = data.withUnsafeBytes { raw in
            getnameinfo(raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(data.count),
                        &host, socklen_t(host.count), &serv, socklen_t(serv.count), NI_NUMERICHOST | NI_NUMERICSERV)
        }
        guard rc == 0 else { return "?" }
        let h = String(cString: host), p = String(cString: serv)
        return h.contains(":") ? "[\(h)]:\(p)" : "\(h):\(p)"
    }

    static func family(_ data: Data) -> Int32 {
        data.withUnsafeBytes { Int32($0.load(fromByteOffset: 1, as: UInt8.self)) }
    }
}

extension SocketAddress {
    static func port(_ data: Data) -> UInt16 {
        data.withUnsafeBytes { UInt16(bigEndian: $0.load(fromByteOffset: 2, as: UInt16.self)) }
    }
}
