# How it works

iOS has no public API to change the device's location. Developers get one through the developer
services Xcode uses (Developer Mode must be on). This project drives those services in three ways.

## 1. Mac server
`server.py` calls `xcrun devicectl device simulate location coordinate --device … --latitude … --longitude …`
(and `… clear`). That goes through CoreDevice on the Mac to `dtlocationd` on the device. The fake stays
until it is cleared or the device restarts. The server keeps a hold timer in `.holds.json` and clears the
location when the time is up, even if the iPhone app is closed.

## 2. The iPhone moves itself (no Mac)
An app can't open a developer tunnel to the iPhone it runs on, unless the traffic leaves the
phone and comes back. **LocalDevVPN** gives exactly that: a VPN interface whose address `10.7.0.1` loops
back into the phone's own network stack.

1. **Pairing (iOS 27).** *Settings › Developer Mode › Pair with Host* lists hosts advertising
   `_remotepairing-pairable-host._tcp` over Bonjour. The app advertises itself as such a host
   (Network.framework `NWListener`), relays the connection to idevice's pairable-host implementation
   (`pairable_host_accept_ext`, added by our patch), and stores the resulting RPPairing file.
2. **Tunnel.** `tunnel_create_rppairing(10.7.0.1:49152, pairing)` → TLS-PSK → CDTunnel → a userspace TCP/IP
   stack (idevice's adapter) → RemoteServiceDiscovery (RSD).
3. **Location.** DVT `com.apple.instruments.dtservicehub` → `LocationSimulation`. This one reverts when the
   connection closes, so the app keeps the tunnel open (resends every 8 s, reconnects every 12 s) and stays
   alive in the background with location updates.

## 3. The Apple Watch (no Mac)
Found by watching what the Mac's `remotepairingd` does while `devicectl` talks to a Watch
(`log stream --predicate 'process == "remotepairingd"'`):

```
Mac/app ──BLE──► Watch   CoreBluetooth: connect, open L2CAP channel PSM 0x85
        ◄──────►         RemotePairing control channel (same "RPPairing" framing as over TCP):
                         pair-verify  →  createListener
        ◄─Bonjour─       Watch advertises <uuid>._rp-tunnel._tcp with that port (Wi‑Fi and/or AWDL)
        ──TCP/TLS─►      TLS-PSK with the session key → CDTunnel → RSD
        ──────────►      com.apple.coredevice.locationservice:
                         action setsimulatedlocation {latitude, longitude} / clearsimulatedlocation
```

In the app:
- `WatchBLEChannel` finds the Watch with `retrieveConnectedPeripherals`, opens the L2CAP channel and
  exposes it on `127.0.0.1` (`L2CAPRelay`) so idevice can use it like a TCP socket.
- `tunnel_create_rppairing_ble` (our patch) runs pair-verify and `createListener`, then calls back into Swift
  to find the `_rp-tunnel._tcp` service for that port.
- `TCPRelay` connects to that service with **Network.framework** (`includePeerToPeer = true`): plain BSD
  sockets can't use AWDL on iOS. idevice talks TLS through the relay on `127.0.0.1`.
- `coredevice_location_set/clear` (our patch; action names from `CoreDeviceUtilities.framework`) set or
  clear the location, then everything is closed.

Pairing uses the same iOS 27 *pair with host* flow as the iPhone: the app advertises
`_remotepairing-pairable-host._tcp` and the Watch connects to it from its Developer Mode screen.

### Things that turned out to matter
| Observation | Consequence |
|---|---|
| The Watch never advertises `_remotepairing._tcp` on Wi‑Fi | the network-only route used for iPhones doesn't work; Bluetooth is needed |
| The iPhone's `companion_proxy` forwards Watch ports, but RPPairing (49152) and RSD (58783) behind them never answer | the "through the iPhone" route is a dead end |
| The Watch stops answering the tunnel about 8 s after it opens (no TCP ACKs, on Wi‑Fi and AWDL) — the Mac's own Watch tunnels are also closed after ~13 s | don't keep a session open: connect → set/clear → disconnect (~3 s) |
| DVT location simulation reverts when its connection closes; CoreDevice's location service does not | the Watch uses the CoreDevice service |
| A Watch near its iPhone takes the iPhone's location — a Watch-only fake jumps back, also when set from a Mac | the app always moves the iPhone and the Watch together |

### Debug hooks
The app answers a few URLs, handy with `devicectl device process launch --payload-url …`:
- `locationremote://watchprobe?hold=60` — full Watch check without moving anything; writes `Documents/watchprobe.log`
- `locationremote://watchset?lat=…&lon=…&min=5` / `locationremote://watchclear`
- idevice's own debug log goes to `Documents/idevice.log`.

`tools/watch_probe.rs` is the Mac-side tool used during the research (tunnel to an iPhone over the
cable, companion-proxy experiments, CoreDevice location set/clear). Build it inside an idevice checkout
as a `tools/` binary.

## The idevice patch
`ios/Vendor/idevice/IDEVICE_PATCH.diff` on top of idevice `3854a5d`:

| Function | Purpose |
|---|---|
| `pairable_host_accept_ext` | iOS 27 pairable-host flow; reports port + TXT values so Swift does the Bonjour advertising |
| `tunnel_create_rppairing_ble`, `tunnel_ble_release` | Watch tunnel over a Bluetooth control channel |
| `coredevice_location_set`, `coredevice_location_clear` | CoreDevice location service (persists after disconnect) |
| `rppairing_bringup_probe`, `tunnel_create_rppairing_companion` | research helpers (createListener probe, companion-proxy attempt) |

`ios/Vendor/build_idevice.sh` clones idevice, applies the patch and builds the static library for
`aarch64-apple-ios`.
