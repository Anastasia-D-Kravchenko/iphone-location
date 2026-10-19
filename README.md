# iPhone Location

Move the GPS location of **your own** iPhone and Apple Watch anywhere on the map — from a Mac,
or with **no Mac at all**, straight from an iPhone app. Built on Apple's own developer services
(the same ones Xcode's *Simulate Location* and `devicectl` use), not on jailbreaks.

**Website:** https://anastasia-d-kravchenko.github.io/iphone-location/

| Mode | Moves | Needs |
|---|---|---|
| **Mac server** (`server.py` + web page) | iPhone, Apple Watch | Mac with Xcode, devices on the same Wi‑Fi or cable |
| **This iPhone (no Mac)** | the iPhone itself | the iOS app + [LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044), works on mobile data |
| **iPhone + Watch + AirPods (no Mac)** | iPhone and Apple Watch together (AirPods follow the iPhone) | the iOS app, Bluetooth, Wi‑Fi switch on |

Features: map + search, multi-device selection, a hold timer that puts the real location back by
itself, "+15 min" / "stop" from a notification, automatic 7-day re-signing for free Apple IDs.

> ⚠️ **Use it only on devices you own, for development and testing.** Many apps (games, banking,
> dating, workplace check-ins) forbid fake locations and can ban accounts. Don't use it to deceive people.

## How it works (short)
- **Mac:** `xcrun devicectl device simulate location coordinate …` (CoreDevice).
- **iPhone, no Mac:** the app pairs with its own iPhone (iOS 27 *Developer Mode › Pair with Host*),
  opens a developer tunnel to itself through LocalDevVPN's loopback and talks to the location
  simulation service with [idevice](https://github.com/jkcoxson/idevice) (engine adapted from
  [Locus](https://github.com/ChrisMack32/Locus)).
- **Apple Watch, no Mac:** the app does what a Mac does: Bluetooth LE L2CAP channel (PSM 0x85) →
  RemotePairing → the Watch opens a tunnel advertised as `_rp-tunnel._tcp` (Wi‑Fi or AWDL) →
  CoreDevice location service. A Watch near its iPhone takes the iPhone's location, so the two are
  always moved together.

Details and the research notes: [docs/how-it-works.md](docs/how-it-works.md).

## Requirements
- iPhone with **iOS 27** (the no-Mac pairing flow) and **Developer Mode** on; Apple Watch with
  **watchOS 27** and Developer Mode on (for the Watch).
- A Mac with **Xcode 26+**, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Rust (`rustup`)
  to build the app once. A free Apple ID is enough (the app is then re-signed every 7 days).

## Quick start
```bash
git clone https://github.com/Anastasia-D-Kravchenko/iphone-location.git
cd iphone-location/ios
cp local.env.example local.env      # your device IDs, team ID, bundle id
rustup target add aarch64-apple-ios
Vendor/build_idevice.sh             # builds the idevice library (~10 min the first time)
./build_install.sh                  # builds the app and installs it on the plugged-in iPhone
```
Then follow [docs/setup.md](docs/setup.md): trusting the developer profile, pairing the iPhone and the
Watch, LocalDevVPN, and the optional Mac server.

## Repository layout
```
server.py, index.html, start.command   Mac server + web page (port 8765)
ios/                                   iOS app "Location" (SwiftUI, XcodeGen: project.yml)
  LocationRemote/Direct/               no-Mac engine: iPhone tunnel, Watch over Bluetooth
  Vendor/                              idevice patch + build script, third-party licenses
  build_install.sh, auto_renew.*       build/install, automatic 7-day renewal
tools/watch_probe.rs                   Mac-side research tool (idevice) used while reverse-engineering
docs/                                  documentation + website (GitHub Pages)
```

## Credits
- [idevice](https://github.com/jkcoxson/idevice) by Jackson Coxson (MIT) — the Rust library that speaks Apple's device protocols.
- [Locus](https://github.com/ChrisMack32/Locus) (MIT) — the original on-device iPhone engine this app adapts.
- [LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044) — loopback VPN that lets an app reach its own iPhone.

## License
[MIT](LICENSE) © 2026 Anastasia Kravchenko. Third-party notices are in `LICENSE` and `ios/Vendor/`.
Not affiliated with Apple. Apple, iPhone, Apple Watch and AirPods are trademarks of Apple Inc.
