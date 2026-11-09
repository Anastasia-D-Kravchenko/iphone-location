import SwiftUI

@main
struct LocationRemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Debug hook for the Watch experiment: `locationremote://watchprobe` (launched from the Mac
                // with devicectl) runs the Bluetooth check and writes Documents/watchprobe.log.
                .onOpenURL { url in
                    if url.host == "watchset" || url.host == "watchclear" {
                        let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                            .map { ($0.name, $0.value ?? "") }) { a, _ in a }
                        Task { @MainActor in
                            let t = Date()
                            do {
                                if url.host == "watchset", let lat = Double(q["lat"] ?? ""), let lon = Double(q["lon"] ?? "") {
                                    try await DirectSession.watch.move(to: .init(latitude: lat, longitude: lon),
                                                                       minutes: Double(q["min"] ?? "") ?? 5)
                                } else {
                                    try await DirectSession.watch.stop()
                                }
                                WatchProbeRunner.note("\(url.host!) ok in \(String(format: "%.1f", Date().timeIntervalSince(t))) s")
                            } catch {
                                WatchProbeRunner.note("\(url.host!) failed: \(error.localizedDescription)")
                            }
                        }
                    }
                    if url.host == "watchprobe" {
                        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }) { a, _ in a }
                        Task { @MainActor in
                            if DirectSession.watch.isActive { try? await DirectSession.watch.stop() }
                            WatchProbeRunner.runBLE(query: query)
                        }
                    }
                }
        }
    }
}
