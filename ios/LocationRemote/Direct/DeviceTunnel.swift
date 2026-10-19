// Adapted from Locus (github.com/ChrisMack32/Locus), MIT License, Copyright (c) 2026 Locus contributors. See Vendor/LOCUS_LICENSE.
import Foundation

enum TunnelConfig {
    /// LocalDevVPN / SideStore-style loopback tunnel endpoint.
    static let defaultIP = "10.7.0.1"
    static let defaultsKey = "direct.targetDeviceIP"

    static var targetIP: String {
        let stored = UserDefaults.standard.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return defaultIP }
        return stored
    }

    static func setTargetIP(_ value: String) {
        UserDefaults.standard.set(value, forKey: defaultsKey)
    }
}
