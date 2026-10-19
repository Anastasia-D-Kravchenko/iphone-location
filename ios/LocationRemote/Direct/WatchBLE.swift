import CoreBluetooth
import Foundation
import idevice
import Network

// Experiment, step 1 of the Mac's own route to the Watch (seen in the Mac's remotepairingd log):
// Bluetooth LE → L2CAP channel PSM 0x85 → RemotePairing control channel (pair-verify) →
// tunnel bringup → the Watch advertises `_rp-tunnel._tcp` → TCP + TLS tunnel.
// This checks whether an ordinary app can do the first part: find the Watch, open the
// L2CAP channel and pass pair-verify over it (idevice talks to a local relay of the channel).

/// Opens the Watch's RemotePairing control channel (Bluetooth LE, L2CAP PSM 0x85) and exposes it
/// on 127.0.0.1 for idevice. Blocking: call off the main thread.
final class WatchBLEChannel: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    static let psm: CBL2CAPPSM = 0x85
    /// GATT services an Apple Watch may expose to its iPhone (Continuity, Nearby, device info…).
    static let services = ["D0611E78-BBB4-4591-A5F8-487910AE4366", "9FA480E0-4967-4542-9390-D343DC5D04AE",
                           "180A", "180F", "1805", "FE2C", "FD44"].map { CBUUID(string: $0) }

    private let log: (String) -> Void
    private var central: CBCentralManager!
    private var candidates: [CBPeripheral] = []
    private var tried = Set<UUID>()
    private var current: CBPeripheral?
    private var relay: L2CAPRelay?
    private var result: UInt16?
    private(set) var failure: String?
    private var signaled = false
    private let ready = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "com.kravchenko.locationremote.ble")

    init(log: @escaping (String) -> Void) {
        self.log = log
        super.init()
    }

    /// Local relay port of the control channel, or nil (see `failure`).
    func open(timeout: TimeInterval = 30) -> UInt16? {
        queue.sync { central = CBCentralManager(delegate: self, queue: queue) }
        if ready.wait(timeout: .now() + timeout) == .timedOut {
            queue.sync { fail("Watch not reachable over Bluetooth in \(Int(timeout)) s") }
        }
        return queue.sync { result }
    }

    func close() {
        queue.sync {
            central?.stopScan()
            if let current { central?.cancelPeripheralConnection(current) }
            relay?.close()
            relay = nil
        }
    }

    private func signal() {
        guard !signaled else { return }
        signaled = true
        central.stopScan()
        ready.signal()
    }

    private func fail(_ text: String) {
        guard !signaled else { return }
        failure = text
        log("✗ \(text)")
        signal()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            let connected = central.retrieveConnectedPeripherals(withServices: Self.services)
            let watches = connected.filter { ($0.name ?? "").localizedCaseInsensitiveContains("watch") }
            log("• Bluetooth: \(connected.map { $0.name ?? "?" }.joined(separator: ", "))")
            candidates = watches + connected.filter { !watches.contains($0) }
            if watches.isEmpty {
                central.scanForPeripherals(withServices: nil, options: nil)
                queue.asyncAfter(deadline: .now() + 6) { [weak self] in self?.tryNext() }
            } else {
                tryNext()
            }
        case .unauthorized:
            fail("Bluetooth not allowed for Location (iPhone Settings › Location › Bluetooth)")
        case .poweredOff:
            fail("Bluetooth is off")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String,
              name.localizedCaseInsensitiveContains("watch"),
              !candidates.contains(where: { $0.identifier == peripheral.identifier }) else { return }
        candidates.insert(peripheral, at: 0)
    }

    private func tryNext() {
        guard !signaled else { return }
        central.stopScan()
        guard let p = candidates.first(where: { !tried.contains($0.identifier) }) else {
            fail("no Apple Watch connected to this iPhone over Bluetooth")
            return
        }
        tried.insert(p.identifier)
        current = p
        p.delegate = self
        log("… Bluetooth: connecting to \(p.name ?? "?")")
        central.connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.openL2CAPChannel(Self.psm)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("• connect failed: \(error?.localizedDescription ?? "?")")
        tryNext()
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel, error == nil else {
            log("• L2CAP 0x85: \(error?.localizedDescription ?? "no channel")")
            central.cancelPeripheralConnection(peripheral)
            tryNext()
            return
        }
        let relay = L2CAPRelay(channel: channel)
        self.relay = relay
        guard let port = relay.start() else { fail("local relay failed"); return }
        log("✓ Bluetooth control channel open")
        result = port
        signal()
    }
}

/// Knobs for the Watch link (set by the debug URL to compare variants).
enum WatchLinkConfig {
    /// Keep the Bluetooth control channel open while the tunnel is used.
    nonisolated(unsafe) static var keepBLE = true
    /// Allow AWDL (peer-to-peer) for the tunnel; false = only the normal Wi‑Fi network.
    nonisolated(unsafe) static var peerToPeer = true
    /// Last path the tunnel relay used (for logs).
    nonisolated(unsafe) static var lastPath = "?"
    /// Extra event log (headless check writes it to watchprobe.log).
    nonisolated(unsafe) static var debug: ((String) -> Void)?
    static func event(_ text: String) {
        NSLog("[Location] watch link: %@", text)
        debug?("  · \(text)")
    }
}

/// Finds the Watch's `_rp-tunnel._tcp` service for a port and exposes it on 127.0.0.1 through
/// Network.framework (peer-to-peer allowed: plain sockets in idevice can't use AWDL on iOS).
enum WatchTunnelFinder {
    /// The relay carrying the current Watch tunnel (kept open while the tunnel is used).
    nonisolated(unsafe) static var relay: TCPRelay?

    static func find(port: UInt16, log: (String) -> Void, timeout: TimeInterval = 12) -> Data? {
        let scanner = DispatchQueue.main.sync { () -> BonjourScanner in
            let s = BonjourScanner(types: ["_rp-tunnel._tcp."])
            s.start()
            return s
        }
        defer { DispatchQueue.main.async { scanner.stop() } }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let found = DispatchQueue.main.sync { scanner.found }
            if let s = found.first(where: { $0.addresses.contains { SocketAddress.port($0) == port } }) {
                log("• Watch tunnel service: \(s.addresses.map(SocketAddress.describe).joined(separator: " "))")
                let endpoint = NWEndpoint.service(name: s.name, type: "_rp-tunnel._tcp", domain: "local.", interface: nil)
                relay?.close()
                let r = TCPRelay(target: endpoint)
                relay = r
                guard let local = r.start() else { return nil }
                return SocketAddress.ipv4("127.0.0.1", port: local)
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        log("✗ Watch tunnel service for port \(port) not found")
        return nil
    }
}

/// 127.0.0.1 listener whose connections are piped to `target` with NWConnection (peer-to-peer on).
final class TCPRelay: @unchecked Sendable {
    private let target: NWEndpoint
    private var listener: NWListener?
    private var pipes: [(NWConnection, NWConnection)] = []
    private let queue = DispatchQueue(label: "com.kravchenko.locationremote.tcprelay")

    init(target: NWEndpoint) { self.target = target }

    func start() -> UInt16? {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: params) else { return nil }
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] inbound in
            guard let self else { return }
            let p = NWParameters.tcp
            p.includePeerToPeer = WatchLinkConfig.peerToPeer
            if let tcp = p.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcp.enableKeepalive = true
                tcp.keepaliveIdle = 5
                tcp.noDelay = true
            }
            let outbound = NWConnection(to: self.target, using: p)
            outbound.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let path = outbound.currentPath
                    WatchLinkConfig.lastPath = "\(path?.availableInterfaces.first?.name ?? "?") \(path?.remoteEndpoint.map { "\($0)" } ?? "")"
                    NSLog("[Location] watch relay ready via %@", WatchLinkConfig.lastPath)
                case .failed(let e): WatchLinkConfig.event("tunnel TCP failed: \(e)"); inbound.cancel()
                case .cancelled: WatchLinkConfig.event("tunnel TCP cancelled")
                case .waiting(let e): WatchLinkConfig.event("tunnel TCP waiting: \(e)")
                default: break
                }
            }
            self.pipes.append((inbound, outbound))
            inbound.start(queue: self.queue)
            outbound.start(queue: self.queue)
            Self.pump(inbound, outbound)
            Self.pump(outbound, inbound)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        return listener.port?.rawValue
    }

    func close() {
        listener?.cancel()
        for (a, b) in pipes { a.cancel(); b.cancel() }
        pipes = []
    }

    private static func pump(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { e in
                    if e == nil && !complete { pump(from, to) } else {
                        WatchLinkConfig.event("relay stop after send (complete=\(complete) error=\(String(describing: e)) from \(from.endpoint))")
                        to.cancel()
                    }
                })
            } else if complete || error != nil {
                WatchLinkConfig.event("relay end from \(from.endpoint) complete=\(complete) error=\(String(describing: error))")
                to.cancel()
            } else {
                pump(from, to)
            }
        }
    }
}

/// Watch tunnel the Mac's way: Bluetooth control channel → pair-verify → tunnel listener →
/// TCP + TLS to the Watch's `_rp-tunnel._tcp` (Wi‑Fi or peer-to-peer).
enum WatchBLETunnel {
    /// Control channel kept open while its tunnel is used (see `WatchLinkConfig.keepBLE`).
    nonisolated(unsafe) static var heldChannel: WatchBLEChannel?

    static func connector(box: CodeBox? = nil, log: @escaping (String) -> Void = { NSLog("[Location] watch: %@", $0) })
        -> DirectEngine.Connector {
        { pairing, adapter, handshake in
            tunnel_ble_release()
            heldChannel?.close()
            heldChannel = nil
            let channel = WatchBLEChannel(log: log)
            defer { if WatchLinkConfig.keepBLE { heldChannel = channel } else { channel.close() } }
            guard let port = channel.open(), let address = SocketAddress.ipv4("127.0.0.1", port: port) else {
                return channel.failure ?? "Watch not reachable over Bluetooth"
            }
            let logBox = LogBox(log)
            let err = withExtendedLifetime(logBox) { address.withUnsafeBytes { raw in
                tunnel_create_rppairing_ble(raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(address.count),
                                            "Location", pairing,
                                            codeTrampoline, box.map { Unmanaged.passUnretained($0).toOpaque() },
                                            resolveTrampoline, Unmanaged.passUnretained(logBox).toOpaque(), &adapter, &handshake)
            } }
            if let err { return DirectEngine.text(err) }
            log("✓ tunnel to the Watch via \(WatchLinkConfig.lastPath)")
            return nil
        }
    }
}

/// Lets a C callback reach a Swift log closure.
final class LogBox {
    let log: (String) -> Void
    init(_ log: @escaping (String) -> Void) { self.log = log }
}

private func resolveTrampoline(port: UInt16, context: UnsafeMutableRawPointer?, out: UnsafeMutablePointer<UInt8>?, cap: UInt) -> UInt {
    let log = context.map { Unmanaged<LogBox>.fromOpaque($0).takeUnretainedValue().log } ?? { _ in }
    guard let out, let a = WatchTunnelFinder.find(port: port, log: log), a.count <= Int(cap) else { return 0 }
    a.copyBytes(to: out, count: a.count)
    NSLog("[Location] watch tunnel at %@", SocketAddress.describe(a))
    return UInt(a.count)
}

/// Exposes an L2CAP channel as a one-shot TCP server on 127.0.0.1 (idevice speaks TCP).
final class L2CAPRelay: NSObject, StreamDelegate, @unchecked Sendable {
    private let channel: CBL2CAPChannel
    private var listener: NWListener?
    private var connection: NWConnection?
    private var thread: Thread?
    private var pendingOut = Data()
    private let lock = NSLock()

    init(channel: CBL2CAPChannel) {
        self.channel = channel
    }

    func start() -> UInt16? {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: params) else { return nil }
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 3)
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.channel.inputStream.delegate = self
            self.channel.outputStream.delegate = self
            self.channel.inputStream.schedule(in: .current, forMode: .default)
            self.channel.outputStream.schedule(in: .current, forMode: .default)
            self.channel.inputStream.open()
            self.channel.outputStream.open()
            while !Thread.current.isCancelled { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        }
        self.thread = thread
        thread.start()
        return listener.port?.rawValue
    }

    func close() {
        thread?.cancel()
        connection?.cancel()
        listener?.cancel()
        channel.inputStream?.close()
        channel.outputStream?.close()
    }

    private func accept(_ c: NWConnection) {
        connection?.cancel()
        connection = c
        c.start(queue: .global())
        receive(c)
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock(); self.pendingOut.append(data); self.lock.unlock()
                if let t = self.thread { self.perform(#selector(self.flush), on: t, with: nil, waitUntilDone: false) }
            }
            if !complete && error == nil { self.receive(c) } else {
                WatchLinkConfig.event("control session (idevice side) ended")
            }
        }
    }

    @objc private func flush() {
        guard let out = channel.outputStream else { return }
        lock.lock(); defer { lock.unlock() }
        while !pendingOut.isEmpty && out.hasSpaceAvailable {
            let n = pendingOut.withUnsafeBytes { out.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: pendingOut.count) }
            if n <= 0 { break }
            pendingOut.removeFirst(n)
        }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = channel.inputStream?.read(&buf, maxLength: buf.count) ?? 0
            if n > 0 { connection?.send(content: Data(buf[0..<n]), completion: .idempotent) }
        case .hasSpaceAvailable:
            flush()
        case .errorOccurred, .endEncountered:
            WatchLinkConfig.event("Bluetooth channel \(eventCode == .endEncountered ? "closed by the Watch" : "error \(String(describing: aStream.streamError))")")
            connection?.cancel()
        default:
            break
        }
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}

private func codeTrampoline(context: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
    guard let context else { return nil }
    return Unmanaged<CodeBox>.fromOpaque(context).takeUnretainedValue().waitForCode()
}

/// Runs the Watch check headless and appends every line to Documents/watchprobe.log.
enum WatchProbeRunner {
    /// One line into Documents/watchprobe.log.
    static func note(_ line: String) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("watchprobe.log")
        let stamped = "\(Date().formatted(date: .omitted, time: .standard)) === \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(stamped.utf8)); try? h.close()
        } else {
            try? Data(stamped.utf8).write(to: url)
        }
    }

    private static let box = CodeBox()

    static func runBLE(query: [String: String] = [:]) {
        WatchLinkConfig.keepBLE = query["keepble"] != "0"
        WatchLinkConfig.peerToPeer = query["p2p"] != "0"
        let hold = TimeInterval(query["hold"] ?? "") ?? 0
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("watchprobe.log")
        func write(_ line: String) {
            let stamped = "\(Date().formatted(date: .omitted, time: .standard)) \(line)\n"
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(stamped.utf8)); try? h.close()
            } else {
                try? Data(stamped.utf8).write(to: url)
            }
        }
        WatchLinkConfig.debug = { write($0) }
        write("=== Watch check keepBLE=\(WatchLinkConfig.keepBLE) p2p=\(WatchLinkConfig.peerToPeer) hold=\(Int(hold))")
        // A Watch code can't be typed headless: give up on it after a short wait.
        box.reset()
        DispatchQueue.global().asyncAfter(deadline: .now() + 50) { box.answer("") }
        Thread {
            WatchProbe.run(connector: WatchBLETunnel.connector(box: box, log: write), hold: hold, log: write)
            write("=== done")
        }.start()
    }
}
