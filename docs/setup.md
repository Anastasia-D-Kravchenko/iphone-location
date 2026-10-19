# Setup

Everything below is done once. You need a Mac with Xcode 26+, an iPhone on iOS 27 and (optionally)
an Apple Watch on watchOS 27.

## 1. Build and install the app
```bash
brew install xcodegen
rustup target add aarch64-apple-ios
cd ios
cp local.env.example local.env   # fill in: IPHONE_UDID, WATCH_UDID, TEAM_ID, BUNDLE_ID
Vendor/build_idevice.sh          # builds the patched idevice library
./build_install.sh               # iPhone plugged in (or on the same Wi‑Fi after the first install)
```
- Device IDs: `xcrun devicectl list devices`.
- Team ID: Xcode › Settings › Accounts. A **free Apple ID** works; apps signed with it stop opening
  after 7 days — see *Automatic renewal* below.
- First launch only: iPhone **Settings › General › VPN & Device Management › Apple Development: your
  Apple ID › Trust**, then allow *Local Network* and *Bluetooth* when the app asks.

## 2. Developer Mode
- iPhone: **Settings › Privacy & Security › Developer Mode** → on (the phone restarts).
- Apple Watch: **Settings › Privacy & Security › Developer Mode** → on.

## 3. Move the iPhone without a Mac
1. Install **[LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044)** and connect it
   (the app has a *Connect LocalDevVPN* button in ⚙️).
2. In the app: ⚙️ › **Pair this iPhone**. Then open **Settings › Privacy & Security › Developer Mode ›
   Pair with Host**, tap **Location**, enter your passcode and the 6‑digit code the app shows.
3. Pick a place, choose **This iPhone (no Mac)** in *Devices*, tap **Move here**.

Works on mobile data too. Keep the **Wi‑Fi switch on** (it doesn't have to join a network). If it says the
connection was lost: Airplane Mode on → Wi‑Fi on → wait 10 s → Airplane Mode off.

## 4. Move the Apple Watch without a Mac
1. In the app: ⚙️ › **Show this app to the Watch (pairing)**.
2. On the Watch: **Settings › Privacy & Security › Developer Mode**, pair with **Location** and type the
   code the app shows.
3. *Devices* now has **iPhone + Watch + AirPods (no Mac)** (the default). Moving it moves the iPhone and
   the Watch together; AirPods report the location of the iPhone they're connected to.
4. ⚙️ › **Connect to the Watch (test)** shows each step if something doesn't work.

Why both at once: a Watch near its iPhone takes the iPhone's location, so a Watch-only fake jumps back
after a moment (the Mac has the same limit).

## 5. Optional: the Mac server
```bash
./install_login_agents.sh   # server on :8765 + automatic renewal, start at login
open http://127.0.0.1:8765
```
The iPhone app finds the Mac at the address written into it by `build_install.sh`
(`<Mac name>.local:8765`, plus the Tailscale IP if Tailscale is installed) and uses the token in `.token`
(keep it private — it lets anyone on your Wi‑Fi move your location).

## Automatic renewal (free Apple ID)
`<prefix>.locationrenew` runs `ios/auto_renew.sh` every 6 hours. When the signing has < 48 h left and the
iPhone is reachable (cable or same Wi‑Fi), it deletes the cached provisioning profile for your bundle id
(so Xcode issues a fresh 7‑day one) and reinstalls. Log: `ios/auto_renew.log`. Test: `FORCE=1 ios/auto_renew.sh`.

## Troubleshooting
- **Location looks stuck after Reset:** turn Location Services off and on, or restart the device.
- **Watch: "Watch not reachable over Bluetooth":** Watch on the wrist/unlocked and near the iPhone, Bluetooth on.
- **Debug from the Mac without touching the phone:**
  `xcrun devicectl device process launch --device <iPhone> --terminate-existing --payload-url "locationremote://watchprobe" <bundle id>`
  then copy `Documents/watchprobe.log` and `Documents/idevice.log` from the app container
  (`xcrun devicectl device copy from --domain-type appDataContainer …`).
