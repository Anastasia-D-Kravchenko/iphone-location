import Foundation

struct Device: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let kind: String
    let paired: Bool
    var movable: Bool? = true
    var note: String?

    var canMove: Bool { movable ?? true }

    var icon: String {
        switch kind {
        case "watch": return "applewatch"
        case "group": return "ipod.and.applewatch"
        case "mac": return "laptopcomputer"
        case "airpods":
            if name.contains("Max") { return "airpods.max" }
            return name.contains("Pro") ? "airpods.pro" : "airpods"
        default: return "iphone"
        }
    }
}

private struct DeviceList: Codable { let devices: [Device] }
private struct Reply: Codable { let ok: Bool; let error: String?; let until: Double? }

struct Hold: Codable {
    let lat: Double
    let lon: Double
    let until: Double?
}

struct HoldStatus: Codable {
    let holds: [String: Hold]
}

enum APIError: LocalizedError {
    case badAddress
    case unreachable
    case http(Int)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .badAddress: return "Wrong Mac address in Settings"
        case .unreachable: return "Can't reach the Mac at home or over Tailscale"
        case .http(401): return "Wrong token in Settings"
        case .http(let code): return "Mac answered with error \(code)"
        case .message(let text): return text
        }
    }
}

/// Talks to server.py running with --lan on the Mac.
/// `host` can hold several addresses separated by commas (home network name, Tailscale IP);
/// the first one that answers is used and remembered for a minute.
struct API {
    var host: String
    var token: String

    private static var working: (host: String, at: Date)?

    /// "home Wi-Fi" or "Tailscale", for the status line.
    static var route: String? {
        guard let h = working?.host else { return nil }
        return h.hasPrefix("100.") ? "Tailscale" : "home Wi-Fi"
    }

    private var hosts: [String] {
        host.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func pickHost() async throws -> String {
        if let w = API.working, hosts.contains(w.host), Date().timeIntervalSince(w.at) < 60 { return w.host }
        var ordered = hosts
        if let w = API.working?.host, let i = ordered.firstIndex(of: w) { ordered.insert(ordered.remove(at: i), at: 0) }
        for h in ordered {
            guard let url = URL(string: "http://\(h)/api/status") else { continue }
            var probe = URLRequest(url: url, timeoutInterval: 3)
            probe.setValue(token, forHTTPHeaderField: "X-Token")
            if let result = try? await URLSession.shared.data(for: probe),
               let code = (result.1 as? HTTPURLResponse)?.statusCode, code == 200 || code == 401 {
                API.working = (h, Date())
                return h
            }
        }
        API.working = nil
        throw APIError.unreachable
    }

    private func request(_ path: String, body: [String: Any]? = nil) async throws -> URLRequest {
        let h = try await pickHost()
        guard let url = URL(string: "http://\(h)\(path)") else { throw APIError.badAddress }
        var r = URLRequest(url: url, timeoutInterval: body == nil ? 45 : 150)
        r.setValue(token, forHTTPHeaderField: "X-Token")
        if let body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    private func send<T: Decodable>(_ r: URLRequest) async throws -> T {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: r)
        } catch {
            API.working = nil  // try the other address next time
            throw error
        }
        if let h = response as? HTTPURLResponse, h.statusCode != 200 { throw APIError.http(h.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func devices() async throws -> [Device] {
        let list: DeviceList = try await send(await request("/api/devices"))
        return list.devices
    }

    /// Returns when the server will put the real location back (nil = no time limit).
    @discardableResult
    func move(_ device: String, lat: Double, lon: Double, minutes: Double) async throws -> Date? {
        let reply: Reply = try await send(await request("/api/set", body: ["device": device, "lat": lat, "lon": lon, "minutes": minutes]))
        if !reply.ok { throw APIError.message(reply.error ?? "Failed") }
        return reply.until.map { Date(timeIntervalSince1970: $0) }
    }

    @discardableResult
    func extend(_ device: String, minutes: Int) async throws -> Date? {
        let reply: Reply = try await send(await request("/api/extend", body: ["device": device, "minutes": minutes]))
        if !reply.ok { throw APIError.message(reply.error ?? "Failed") }
        return reply.until.map { Date(timeIntervalSince1970: $0) }
    }

    /// Moves the end of a running fake to an exact time.
    @discardableResult
    func setUntil(_ device: String, until: Date) async throws -> Date? {
        let reply: Reply = try await send(await request("/api/until", body: ["device": device, "until": until.timeIntervalSince1970]))
        if !reply.ok { throw APIError.message(reply.error ?? "Failed") }
        return reply.until.map { Date(timeIntervalSince1970: $0) }
    }

    func status() async throws -> [String: Hold] {
        let s: HoldStatus = try await send(await request("/api/status"))
        return s.holds
    }

    func reset(_ device: String) async throws {
        let reply: Reply = try await send(await request("/api/clear", body: ["device": device]))
        if !reply.ok { throw APIError.message(reply.error ?? "Failed") }
    }
}
