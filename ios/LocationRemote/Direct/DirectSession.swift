import CoreLocation
import Foundation
import UIKit
import UserNotifications

/// Where "Pair this iPhone" saves the RPPairing file.
final class DirectPairingStore {
    static let shared = DirectPairingStore()

    var pairingURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pairing/rp_pairing_file.plist")
    }

    var hasPairingFile: Bool { FileManager.default.fileExists(atPath: pairingURL.path) }
}

struct DirectError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

/// What differs between faking this iPhone (LocalDevVPN loopback) and the Apple Watch (over Wi‑Fi).
struct DirectTarget {
    let id: String
    let name: String
    let kind: String
    let key: String
    let engine: DirectEngine
    let pairingURL: URL
    let readyNote: String
    let pairFirst: String
    /// How to open the tunnel; `refresh` = after a failure (look the device up / reopen relays).
    let connector: @MainActor (_ refresh: Bool) async -> DirectEngine.Connector?
    /// Turns a failed first move into a helpful message.
    let explain: @MainActor (Error) -> Error

    static let phone = DirectTarget(
        id: "direct", name: "This iPhone (no Mac)", kind: "iphone", key: "direct",
        engine: .phone, pairingURL: DirectPairingStore.shared.pairingURL,
        readyNote: "Works anywhere. Needs LocalDevVPN on and the Wi‑Fi switch on",
        pairFirst: "Pair this iPhone first: ⚙️ → Pair this iPhone.",
        connector: { _ in SocketAddress.ipv4(TunnelConfig.targetIP, port: 49152).map(DirectEngine.direct) },
        explain: { error in
            // The VPN check is only a hint; the real test is whether the tunnel opens.
            LocalDevVPN.isConnected ? error : DirectError("Connect LocalDevVPN first (⚙️ → Connect LocalDevVPN).")
        })

    static let watch = DirectTarget(
        id: "watch-direct", name: "Apple Watch (no Mac)", kind: "watch", key: "watchdirect",
        engine: .watch, pairingURL: WatchLink.pairingURL,
        readyNote: "Moves together with This iPhone (LocalDevVPN on). Watch near, Bluetooth on",
        pairFirst: "Connect it first: ⚙️ → Connect to the Watch through this iPhone.",
        connector: { refresh in
            // The Mac's way: Bluetooth control channel, then a TCP tunnel to the Watch.
            WatchBLETunnel.connector()
        },
        explain: { _ in
            DirectError("Watch not reachable: \(DirectEngine.watch.lastError ?? "not found on the network"). Keep the Watch near this iPhone with Bluetooth on.")
        })
}

/// Fakes a device's location without the Mac: a developer tunnel straight to the device
/// (this iPhone through LocalDevVPN, the Watch over the network). Keeps the tunnel open
/// (resend every 8 s, reconnect every 12 s) and runs in the background via location
/// updates, so the hold timer can put the real location back on time.
@MainActor
final class DirectSession: ObservableObject {
    static let shared = DirectSession(.phone)
    static let watch = DirectSession(.watch)
    static let all = [shared, watch]
    static let deviceID = DirectTarget.phone.id

    static func session(for id: String) -> DirectSession? { all.first { $0.target.id == id } }

    let target: DirectTarget

    var hasPairingFile: Bool { FileManager.default.fileExists(atPath: target.pairingURL.path) }

    var device: Device {
        Device(id: target.id, name: target.name, kind: target.kind, paired: true, movable: true,
               note: hasPairingFile ? target.readyNote : target.pairFirst)
    }

    @Published private(set) var fakeAt: CLLocationCoordinate2D?
    @Published private(set) var until: Date?
    @Published private(set) var dropped = false

    private var resendTimer: Timer?
    private var healthTimer: Timer?
    private var expiryTimer: Timer?
    private let keeper = BackgroundKeepAlive()
    private let defaults = UserDefaults.standard

    private init(_ target: DirectTarget) {
        self.target = target
        fakeAt = decodeCoordinate(defaults.string(forKey: "\(target.key).fake") ?? "")
        let u = defaults.double(forKey: "\(target.key).until")
        until = u > 0 ? Date(timeIntervalSince1970: u) : nil
    }

    var isActive: Bool { fakeAt != nil }

    /// After a relaunch: reopen the tunnel for a fake that should still run, or end an expired one.
    func resume() async {
        // Let a debug URL (locationremote://watchprobe) end the Watch fake first.
        if target.kind == "watch" { try? await Task.sleep(for: .seconds(3)) }
        guard let c = fakeAt else { return }
        if let until, until <= Date() {
            try? await stop()
        } else if target.engine.persistent {
            // The fake stays on the device by itself: only the end timer is needed.
            startTimers()
            keeper.start()
        } else if !target.engine.isSessionActive {
            if (try? await apply(c)) != nil { startTimers() } else { markDropped() }
        }
    }

    func move(to c: CLLocationCoordinate2D, minutes: Double) async throws {
        guard hasPairingFile else { throw DirectError(target.pairFirst) }
        do {
            try await apply(c)
        } catch {
            throw target.explain(error)
        }
        fakeAt = c
        until = minutes == 0 ? nil : Date().addingTimeInterval(minutes * 60)
        dropped = false
        startTimers()
        keeper.start()
        save()
    }

    func extend(minutes: Int) {
        guard isActive, minutes > 0 else { return }
        until = max(Date(), until ?? Date()).addingTimeInterval(Double(minutes) * 60)
        scheduleExpiry()
        save()
    }

    /// Moves the end of a running fake to an exact time.
    func setUntil(_ date: Date) {
        guard isActive, date > Date() else { return }
        until = date
        scheduleExpiry()
        save()
    }

    func stop() async throws {
        stopTimers()
        if target.engine.persistent {
            do {
                try await oneShot(nil)
            } catch {
                startTimers()
                throw target.explain(error)
            }
            fakeAt = nil
            until = nil
            dropped = false
            keeper.stop()
            save()
            return
        }
        let previous = fakeAt
        let engine = target.engine
        var result = await Task.detached { engine.clear() }.value
        if case .failure(.locationClear) = result, !engine.isSessionActive, let previous {
            // The tunnel was gone (app restarted / dropped): reopen it just to clear.
            do {
                try await apply(previous)
                result = await Task.detached { engine.clear() }.value
            } catch let e as DirectEngineError {
                result = .failure(e)
            } catch {
                result = .failure(.tunnelCreate)
            }
        }
        if case .failure(let e) = result {
            // Keep the fake marked so the next try (or the health timer) can clear it.
            startTimers()
            throw e
        }
        fakeAt = nil
        until = nil
        dropped = false
        keeper.stop()
        save()
    }

    // MARK: - Tunnel upkeep

    /// Persistent engine: connect, set (or clear when nil), disconnect; one retry.
    private func oneShot(_ c: CLLocationCoordinate2D?) async throws {
        let path = target.pairingURL.path
        let engine = target.engine
        let coordinate = c.map { ($0.latitude, $0.longitude) }
        var result: Result<Void, DirectEngineError> = .failure(.tunnelCreate)
        for refresh in [false, true] {
            guard let connect = await target.connector(refresh) else { continue }
            result = await Task.detached { engine.oneShot(coordinate, pairingPath: path, connect: connect) }.value
            if case .success = result { return }
        }
        if case .failure(let e) = result { throw e }
    }

    private func apply(_ c: CLLocationCoordinate2D) async throws {
        if target.engine.persistent { return try await oneShot(c) }
        let path = target.pairingURL.path
        let engine = target.engine
        var result: Result<Void, DirectEngineError> = .failure(.invalidIP)
        // Second round looks the address up again (the Watch's Wi‑Fi address can change).
        for refresh in [false, true] {
            guard let connect = await target.connector(refresh) else { continue }
            if refresh, engine.isSessionActive { engine.disconnect() }
            result = await Task.detached {
                engine.set(latitude: c.latitude, longitude: c.longitude, pairingPath: path, connect: connect)
            }.value
            if case .success = result { return }
            if target.kind != "watch" { break }
        }
        if case .failure(let e) = result { throw e }
    }

    private func startTimers() {
        stopTimers()
        if target.engine.persistent {
            scheduleExpiry()
            return
        }
        resendTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let s = self, let c = s.fakeAt, !s.dropped else { return }
                if (try? await s.apply(c)) == nil { s.markDropped() }
            }
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let s = self, let c = s.fakeAt, s.dropped || !s.target.engine.isSessionActive else { return }
                if (try? await s.apply(c)) != nil {
                    s.dropped = false
                    s.changed()
                }
            }
        }
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        guard let until else { return }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: max(1, until.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let s = self else { return }
                do {
                    try await s.stop()
                } catch {
                    s.notify("\(s.target.name): couldn't restore the real location",
                             "Turn the Wi‑Fi switch on (no network needed) or restart the iPhone.")
                }
            }
        }
    }

    private func stopTimers() {
        resendTimer?.invalidate()
        healthTimer?.invalidate()
        expiryTimer?.invalidate()
        resendTimer = nil
        healthTimer = nil
        expiryTimer = nil
    }

    private func markDropped() {
        guard !dropped else { return }
        dropped = true
        changed()
        notify("\(target.name): fake location connection lost",
               target.kind == "watch"
               ? "Keep the Watch near this iPhone. It reconnects by itself."
               : "On mobile data turn the Wi‑Fi switch on (no network needed), or Airplane Mode + Wi‑Fi for a moment. It reconnects by itself.")
    }

    private func save() {
        defaults.set(fakeAt.map { "\($0.latitude),\($0.longitude)" } ?? "", forKey: "\(target.key).fake")
        defaults.set(until?.timeIntervalSince1970 ?? 0, forKey: "\(target.key).until")
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: .holdChanged, object: nil)
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "\(target.key).\(UUID().uuidString)", content: content, trigger: nil))
    }

    private func decodeCoordinate(_ text: String) -> CLLocationCoordinate2D? {
        let parts = text.split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? .init(latitude: parts[0], longitude: parts[1]) : nil
    }
}
