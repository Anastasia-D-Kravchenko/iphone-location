import Foundation
import idevice
import SwiftUI
import UIKit

// Experimental: fake the Apple Watch's location without the Mac (watchOS 27).
// The Mac reaches the Watch over Wi‑Fi with "manualPairing" (a code shown on the Watch),
// so the app does the same: find the Watch over Bonjour, pair with that code
// (idevice rppairing_pair_network), then open a tunnel to its _remotepairing._tcp.

/// One Bonjour service seen on the network.
struct FoundService: Identifiable, Hashable {
    let type: String
    let name: String
    let hostName: String
    let addresses: [Data]
    let txt: [String: String]

    var id: String { type + "|" + name }
    var looksLikeWatch: Bool { hostName.localizedCaseInsensitiveContains("watch") }
    var isPairingService: Bool { type.contains("manual-pairing") }
    var bestAddress: Data? { BonjourScanner.pickAddress(addresses) }
}

/// NetServiceBrowser gives host names, sockaddr bytes and TXT in one go (and can use peer-to-peer).
@MainActor
final class BonjourScanner: NSObject, ObservableObject {
    let types: [String]

    init(types: [String] = ["_remotepairing._tcp.", "_remotepairing-manual-pairing._tcp."]) {
        self.types = types
        super.init()
    }

    @Published private(set) var found: [FoundService] = []
    @Published private(set) var running = false

    private var browsers: [NetServiceBrowser] = []
    private var pending: [NetService] = []

    func start() {
        stop()
        found = []
        running = true
        for type in types {
            let b = NetServiceBrowser()
            b.includesPeerToPeer = true
            b.delegate = self
            b.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(b)
        }
    }

    func stop() {
        browsers.forEach { $0.stop() }
        browsers = []
        pending.forEach { $0.stop() }
        pending = []
        running = false
    }

    /// Prefer a normal IPv4 address, then a routable IPv6, then link-local IPv6 (has the scope id).
    nonisolated static func pickAddress(_ list: [Data]) -> Data? {
        func rank(_ d: Data) -> Int {
            let text = SocketAddress.describe(d)
            if SocketAddress.family(d) == AF_INET { return text.hasPrefix("169.254.") ? 2 : 0 }
            return text.hasPrefix("[fe80") ? 3 : 1
        }
        return list.min { rank($0) < rank($1) }
    }

    fileprivate func resolved(_ s: NetService) {
        var txt: [String: String] = [:]
        if let data = s.txtRecordData() {
            for (k, v) in NetService.dictionary(fromTXTRecord: data) { txt[k] = String(data: v, encoding: .utf8) ?? "" }
        }
        let item = FoundService(type: s.type, name: s.name, hostName: s.hostName ?? "?",
                                addresses: s.addresses ?? [], txt: txt)
        found.removeAll { $0.id == item.id }
        found.append(item)
        found.sort { ($0.looksLikeWatch ? 0 : 1, $0.hostName) < ($1.looksLikeWatch ? 0 : 1, $1.hostName) }
        NSLog("[Location] found %@ %@ on %@ %@", s.type, s.name, item.hostName,
              item.addresses.map(SocketAddress.describe).joined(separator: " "))
    }
}

extension BonjourScanner: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated {
            service.delegate = self
            service.includesPeerToPeer = true
            pending.append(service)
            service.resolve(withTimeout: 8)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated {
            found.removeAll { $0.type == service.type && $0.name == service.name }
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated { resolved(sender) }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        NSLog("[Location] resolve failed %@ %@", sender.name, errorDict.description)
    }
}

/// Where the Watch pairing lives and how to find the Watch again.
@MainActor
final class WatchLink: ObservableObject {
    static let shared = WatchLink()

    nonisolated static var pairingURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pairing/watch_pairing.plist")
    }

    private let defaults = UserDefaults.standard

    /// Bonjour host name of the Watch (e.g. "Someones-Apple-Watch.local.").
    @Published var hostName: String? {
        didSet { defaults.set(hostName, forKey: "watch.host") }
    }
    @Published private(set) var lastAddress: Data? {
        didSet { defaults.set(lastAddress, forKey: "watch.address") }
    }
    /// "name · model · udid" the Watch reported while pairing.
    @Published var peerInfo: String? {
        didSet { defaults.set(peerInfo, forKey: "watch.peer") }
    }

    private init() {
        hostName = defaults.string(forKey: "watch.host")
        lastAddress = defaults.data(forKey: "watch.address")
        peerInfo = defaults.string(forKey: "watch.peer")
    }

    var hasPairing: Bool { FileManager.default.fileExists(atPath: Self.pairingURL.path) }

    func use(_ service: FoundService) {
        hostName = service.hostName
        if service.type.hasPrefix("_remotepairing._tcp"), let a = service.bestAddress { lastAddress = a }
    }

    func forget() {
        try? FileManager.default.removeItem(at: Self.pairingURL)
        hostName = nil
        lastAddress = nil
        peerInfo = nil
    }

    /// Address of the Watch's `_remotepairing._tcp` (the service that can carry a tunnel).
    func address(refresh: Bool) async -> Data? {
        if !refresh, let lastAddress { return lastAddress }
        guard let hostName else { return lastAddress }
        let scanner = BonjourScanner()
        scanner.start()
        defer { scanner.stop() }
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(500))
            if let s = scanner.found.first(where: { $0.hostName == hostName && $0.type.hasPrefix("_remotepairing._tcp") }),
               let a = s.bestAddress {
                lastAddress = a
                return a
            }
        }
        return lastAddress
    }
}

/// Pairs with the Watch by typing the code it shows (same as Xcode's "Pair" for a nearby Watch).
@MainActor
final class WatchCodePairing: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting(String)
        case needCode
        case succeeded(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    let box = CodeBox()

    /// For the through-iPhone check: show the code field if the Watch asks for one.
    func watchForCode() {
        box.reset()
        box.owner = self
    }

    var isBusy: Bool {
        switch phase {
        case .connecting, .needCode: return true
        default: return false
        }
    }

    func pair(with service: FoundService) {
        guard let address = service.bestAddress else { return }
        pair(address: address, label: "\(service.hostName) \(SocketAddress.describe(address))") {
            WatchLink.shared.use(service)
        }
    }

    func pair(address: Data, label: String, onSuccess: @escaping @MainActor () -> Void) {
        guard !isBusy else { return }
        phase = .connecting(label)
        box.reset()
        box.owner = self
        let box = box
        let path = WatchLink.pairingURL.path
        let thread = Thread {
            let result = Self.run(address: address, outputPath: path, box: box)
            DispatchQueue.main.async {
                guard let owner = box.owner else { return }
                switch result {
                case .success(let info):
                    onSuccess()
                    WatchLink.shared.peerInfo = info
                    owner.phase = .succeeded(info)
                case .failure(let e):
                    owner.phase = .failed(e.localizedDescription)
                }
            }
        }
        thread.name = "location.watch-pair"
        thread.start()
    }

    func submit(code: String) {
        box.answer(code.trimmingCharacters(in: .whitespacesAndNewlines))
        phase = .connecting("Checking the code…")
    }

    func cancel() {
        box.answer("")
        phase = .idle
    }

    func acknowledge() { phase = .idle }

    fileprivate func askForCode() {
        phase = .needCode
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    nonisolated private static func run(address: Data, outputPath: String, box: CodeBox) -> Result<String, DirectError> {
        let dir = (outputPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        func text(_ err: UnsafeMutablePointer<IdeviceFfiError>) -> String {
            defer { idevice_error_free(err) }
            return err.pointee.message.map { String(cString: $0) } ?? "code \(err.pointee.code)"
        }

        var file: OpaquePointer?
        if let err = rp_pairing_file_generate("Location", &file) { return .failure(DirectError("generate: \(text(err))")) }
        guard let file else { return .failure(DirectError("generate: no file")) }
        defer { rp_pairing_file_free(file) }

        var peer: UnsafeMutablePointer<RpPairingPeerDeviceC>?
        let err = address.withUnsafeBytes { raw in
            rppairing_pair_network(
                raw.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                socklen_t(address.count),
                "Location",
                file,
                codeTrampoline,
                Unmanaged.passUnretained(box).toOpaque(),
                &peer
            )
        }
        if let err { return .failure(DirectError("pair: \(text(err))")) }
        defer { rppairing_peer_device_free(peer) }

        if let werr = outputPath.withCString({ rp_pairing_file_write(file, $0) }) {
            return .failure(DirectError("save: \(text(werr))"))
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputPath)

        guard let p = peer?.pointee else { return .success("paired (no new identity: pair-verify only)") }
        func s(_ c: UnsafeMutablePointer<CChar>?) -> String { c.map { String(cString: $0) } ?? "?" }
        return .success("\(s(p.name)) · \(s(p.model)) · \(s(p.udid))")
    }
}

/// Hands the code typed in the app to the blocked pairing thread.
final class CodeBox: @unchecked Sendable {
    weak var owner: WatchCodePairing?
    private let ready = DispatchSemaphore(value: 0)
    private var code: UnsafeMutablePointer<CChar>?

    func reset() {
        while ready.wait(timeout: .now()) == .success {}
        free(code)
        code = nil
    }

    func answer(_ value: String) {
        free(code)
        code = strdup(value)
        ready.signal()
    }

    /// Called on the pairing thread; blocks until the code is typed (max 5 min).
    func waitForCode() -> UnsafePointer<CChar>? {
        DispatchQueue.main.async { self.owner?.askForCode() }
        guard ready.wait(timeout: .now() + 300) == .success else { return nil }
        return UnsafePointer(code)
    }

    deinit { free(code) }
}

private func codeTrampoline(context: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
    guard let context else { return nil }
    return Unmanaged<CodeBox>.fromOpaque(context).takeUnretainedValue().waitForCode()
}

/// Settings section: find the Watch, pair it, show what happened (for the experiment).
struct WatchSetupSection: View {
    @StateObject private var codePairing = WatchCodePairing()
    @StateObject private var hostPairing = DirectPairing()
    @ObservedObject private var link = WatchLink.shared
    @State private var code = ""
    @State private var paired = WatchLink.shared.hasPairing
    @State private var lastError: String?
    @State private var probing = false
    @State private var probeLog: [String] = []

    private func probe() {
        probing = true
        probeLog = []
        codePairing.watchForCode()
        let box = codePairing.box
        Thread {
            let log: (String) -> Void = { line in DispatchQueue.main.async { probeLog.append(line) } }
            WatchProbe.run(connector: WatchBLETunnel.connector(box: box, log: log), log: log)
            DispatchQueue.main.async {
                probing = false
                codePairing.acknowledge()
                paired = WatchLink.shared.hasPairing
            }
        }.start()
    }

    var body: some View {
        Section {
            HStack {
                Text("Watch paired")
                Spacer()
                Image(systemName: paired ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(paired ? .green : .secondary)
            }
            if let info = link.peerInfo { Text(info).font(.caption).foregroundStyle(.secondary) }
            if let lastError { Text("Last error: \(lastError)").font(.caption).foregroundStyle(.red) }

            codePairingRows

            Button(probing ? "Connecting…" : "Connect to the Watch (test)") { probe() }
                .disabled(probing || codePairing.isBusy)
            ForEach(Array(probeLog.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced()).textSelection(.enabled)
            }

            hostPairingRows

            if paired {
                Button("Forget Watch pairing", role: .destructive) {
                    link.forget()
                    paired = false
                }
            }
        } header: {
            Text("Apple Watch (no Mac) · experiment")
        } footer: {
            Text("Moves the Watch without the Mac, the way Xcode does: Bluetooth to the Watch, then a network tunnel to it. Watch near this iPhone, Developer Mode on the Watch. First time: Show this app to the Watch, then on the Watch Settings › Privacy & Security › Developer Mode › pair with Location.")
        }
        .onChange(of: hostPairing.phase) {
            if hostPairing.phase == .succeeded { paired = true }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            paired = link.hasPairing
            lastError = DirectEngine.watch.lastError
        }
    }

    @ViewBuilder private var codePairingRows: some View {
        switch codePairing.phase {
        case .idle:
            EmptyView()
        case .connecting(let what):
            HStack { ProgressView(); Text("Pairing: \(what)").font(.footnote) }
            Button("Cancel", role: .cancel) { codePairing.cancel() }
        case .needCode:
            Text("Type the code shown on the Watch:").font(.footnote)
            TextField("Code", text: $code).keyboardType(.numberPad).font(.title2.monospaced())
            Button("Pair") { codePairing.submit(code: code); code = "" }.disabled(code.isEmpty)
            Button("Cancel", role: .cancel) { codePairing.cancel() }
        case .succeeded(let info):
            Text("Paired: \(info)").font(.footnote).foregroundStyle(.green)
                .onAppear { paired = true }
            Button("OK") { codePairing.acknowledge() }
        case .failed(let message):
            Text(message).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
            Button("OK") { codePairing.acknowledge() }
        }
    }

    @ViewBuilder private var hostPairingRows: some View {
        switch hostPairing.phase {
        case .idle, .succeeded:
            Button("Show this app to the Watch (pairing)") {
                hostPairing.start(outputURL: WatchLink.pairingURL)
            }
        case .advertising, .deviceConnected:
            HStack { ProgressView(); Text("Advertising \"Location\" as a pairing host…").font(.footnote) }
            Button("Cancel", role: .cancel) { hostPairing.resetToIdle() }
        case .awaitingPIN(let pin):
            Text("Type this code on the Watch:").font(.footnote)
            Text(pin).font(.system(size: 40, weight: .bold, design: .monospaced))
        case .failed(let message):
            Text(message).font(.footnote).foregroundStyle(.red)
            Button("Try again") { hostPairing.acknowledgeFailure() }
        }
    }
}

/// Step by step (no location change): Watch tunnel through this iPhone (pairing with the Watch's
/// code if it doesn't know this app yet) → RemoteXPC → location service.
enum WatchProbe {
    /// idevice debug log → Documents/idevice.log (read it with devicectl copy from the app container).
    private static let enableFileLog: () -> Void = {
        var done = false
        return {
            guard !done else { return }
            done = true
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("idevice.log")
            _ = url.path.withCString { idevice_init_logger(Disabled, Debug, UnsafeMutablePointer(mutating: $0)) }
        }
    }()

    /// Step by step, no location change: Watch tunnel (pairing with the Watch's code if needed)
    /// → RemoteXPC → location service.
    static func run(connector: DirectEngine.Connector, hold: TimeInterval = 0, log: @escaping (String) -> Void) {
        enableFileLog()
        let path = WatchLink.pairingURL.path
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        var pairing: OpaquePointer?
        if let e = path.withCString({ rp_pairing_file_read($0, &pairing) }) {
            idevice_error_free(e)
            if let e = rp_pairing_file_generate("Location", &pairing) { log("✗ new pairing file: \(DirectEngine.text(e))"); return }
            log("• no Watch pairing yet: the Watch will show a code")
        }
        guard let pairing else { return }
        defer { rp_pairing_file_free(pairing) }

        var adapter: OpaquePointer?, handshake: OpaquePointer?, server: OpaquePointer?, sim: OpaquePointer?
        defer {
            if let sim { location_simulation_free(sim) } else if let server { remote_server_free(server) }
            if let handshake { rsd_handshake_free(handshake) }
            if let adapter { adapter_free(adapter) }
        }
        if let e = connector(pairing, &adapter, &handshake) { log("✗ \(e)"); return }

        // pair-setup (if it ran) updated the file in place: keep it.
        if let e = path.withCString({ rp_pairing_file_write(pairing, $0) }) { log("✗ save pairing: \(DirectEngine.text(e))"); return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        if let e = remote_server_connect_rsd(adapter, handshake, &server) { log("✗ Watch RemoteXPC: \(DirectEngine.text(e))"); return }
        log("✓ Watch RemoteXPC")
        if let e = location_simulation_new(server, &sim) { log("✗ Watch location service: \(DirectEngine.text(e))"); return }
        log("✓ Watch location service open — moving the Watch works")
        // Link test without moving anything: "clear" every 8 s for `hold` seconds.
        let start = Date()
        while Date().timeIntervalSince(start) < hold {
            Thread.sleep(forTimeInterval: 8)
            let t = Date()
            if let e = location_simulation_clear(sim) {
                log("✗ link died after \(Int(Date().timeIntervalSince(start))) s: \(DirectEngine.text(e))")
                return
            }
            log("• +\(Int(Date().timeIntervalSince(start))) s ok (\(Int(Date().timeIntervalSince(t) * 1000)) ms)")
        }
    }
}
