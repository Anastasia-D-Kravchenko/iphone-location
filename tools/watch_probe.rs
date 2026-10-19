// Experiment: reach the iPhone's paired Apple Watch through the iPhone's companion proxy.
// usage: watch_probe <pairing.plist> <iphone ip:port> <xpc|raw|rsd> [watch port]
use std::time::Duration;

use idevice::{
    IdeviceError, RemoteXpcClient, RsdService as _,
    companion_proxy::CompanionProxy,
    provider::RsdProvider as _,
    remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native},
    rsd::RsdHandshake,
    tcp::handle::AdapterHandle,
};

async fn timed<T>(
    name: &str,
    secs: u64,
    fut: impl std::future::Future<Output = Result<T, IdeviceError>>,
) -> Result<T, IdeviceError> {
    println!("… {name}");
    match tokio::time::timeout(Duration::from_secs(secs), fut).await {
        Ok(Ok(v)) => {
            println!("✓ {name}");
            Ok(v)
        }
        Ok(Err(e)) => {
            println!("✗ {name}: {e}");
            Err(e)
        }
        Err(_) => {
            println!("✗ {name}: no answer in {secs}s");
            Err(IdeviceError::InternalError(format!("{name}: timeout")))
        }
    }
}

async fn pin() -> String {
    // The Watch may show a code: write it to ./pin.txt
    println!("!! PIN requested: write the code shown on the Watch to pin.txt");
    for _ in 0..240 {
        if let Ok(s) = std::fs::read_to_string("pin.txt") {
            let s = s.trim().to_string();
            if !s.is_empty() {
                let _ = std::fs::remove_file("pin.txt");
                return s;
            }
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    "000000".into()
}

async fn adapter_from_tunnel<S: idevice::ReadWrite + 'static>(
    tunnel: idevice::remote_pairing::CdTunnel<S>,
) -> Result<(AdapterHandle, RsdHandshake), IdeviceError> {
    let client_ip: std::net::IpAddr = tunnel.info.client_address.parse().unwrap();
    let server_ip: std::net::IpAddr = tunnel.info.server_address.parse().unwrap();
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;
    let raw = tunnel.into_inner();
    let mut adapter = idevice::tcp::adapter::Adapter::new(Box::new(raw), client_ip, server_ip);
    adapter.set_mss(mtu.saturating_sub(60));
    let mut adapter = adapter.to_async_handle();
    let s = adapter.connect(rsd_port).await?;
    let hs = RsdHandshake::new(s).await?;
    Ok((adapter, hs))
}

struct Phone {
    adapter: AdapterHandle,
    hs: RsdHandshake,
    keep: Vec<CompanionProxy>,
}

impl Phone {
    async fn forward(&mut self, watch_port: u16) -> Result<u16, IdeviceError> {
        let mut cp = CompanionProxy::connect_rsd(&mut self.adapter, &mut self.hs).await?;
        let p = cp.start_forwarding_service_port(watch_port, None, None).await?;
        self.keep.push(cp);
        println!("  Watch :{watch_port} → iPhone :{p}");
        Ok(p)
    }
    async fn open(&mut self, watch_port: u16) -> Result<Box<dyn idevice::ReadWrite>, IdeviceError> {
        let p = self.forward(watch_port).await?;
        self.adapter.connect_to_service_port(p).await
    }
}

#[tokio::main]
async fn main() -> Result<(), IdeviceError> {
    tracing_subscriber::fmt()
        .with_env_filter(std::env::var("RUST_LOG").unwrap_or_else(|_| "warn".into()))
        .init();
    let args: Vec<String> = std::env::args().collect();
    let mut rpf = RpPairingFile::read_from_file(&args[1]).await?;
    let addr: std::net::SocketAddr = args[2].parse().unwrap();
    let mode = args.get(3).map(|s| s.as_str()).unwrap_or("xpc");

    // 1. Tunnel to the iPhone (same as the app).
    let (adapter, hs) = timed("tunnel to iPhone", 20, async {
        let stream = tokio::net::TcpStream::connect(addr).await?;
        let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), "LocationRemote");
        rpc.connect(&mut rpf, async || pin().await).await?;
        let port = rpc.create_tcp_listener().await?;
        let mut a = addr;
        a.set_port(port);
        let s = tokio::net::TcpStream::connect(a).await?;
        let t = connect_tls_psk_tunnel_native(s, rpc.encryption_key()).await?;
        adapter_from_tunnel(t).await
    })
    .await?;
    let mut phone = Phone { adapter, hs, keep: vec![] };

    let mut wpf = RpPairingFile::read_from_file(&args[1]).await?;

    match mode {
        "rsd" | "xpc" => {
            let port: u16 = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(58783);
            let s = timed("open Watch RSD", 20, phone.open(port)).await?;
            let rsd = timed("Watch RSD handshake", 20, RsdHandshake::new(s)).await?;
            let mut names: Vec<_> = rsd.services.iter().map(|(k, v)| format!("{k}:{}", v.port)).collect();
            names.sort();
            println!("Watch RSD services ({}):\n  {}", names.len(), names.join("\n  "));
            if mode == "rsd" {
                return Ok(());
            }
            let ts = rsd
                .services
                .get("com.apple.internal.dt.coredevice.untrusted.tunnelservice")
                .ok_or(IdeviceError::ServiceNotFound)?
                .port;
            let s = timed("open tunnelservice", 20, phone.open(ts)).await?;
            let mut conn = timed("XPC client", 20, RemoteXpcClient::new(s)).await?;
            timed("XPC handshake", 20, conn.do_handshake()).await?;
            let _ = timed("XPC root", 20, conn.recv_root()).await?;
            let mut rpc = RemotePairingClient::new(conn, "LocationRemote");
            timed("Watch pairing (verify, maybe PIN)", 150, rpc.connect(&mut wpf, async || pin().await)).await?;
            let _ = wpf.write_to_file("watch_pairing_new.plist").await;
            let lp = timed("Watch tunnel listener", 20, rpc.create_tcp_listener()).await?;
            let s = timed("open Watch tunnel port", 20, phone.open(lp)).await?;
            let t = timed("Watch TLS tunnel", 20, connect_tls_psk_tunnel_native(s, rpc.encryption_key())).await?;
            let (mut wa, mut whs) = timed("Watch adapter + RSD", 20, adapter_from_tunnel(t)).await?;
            println!("Watch tunnel RSD services: {}", whs.services.len());
            let mut rs = timed(
                "Watch RemoteXPC (dtservicehub)",
                20,
                idevice::dvt::remote_server::RemoteServerClient::connect_rsd(&mut wa, &mut whs),
            )
            .await?;
            timed("remote server read", 20, rs.read_message(0)).await.ok();
            let _ls = timed(
                "Watch location service",
                20,
                idevice::dvt::location_simulation::LocationSimulationClient::new(&mut rs),
            )
            .await?;
            println!("=== Watch location service open: SUCCESS");
        }
        "cdloc" => {
            // CoreDevice location service on the iPhone itself: set / clear.
            let what = args.get(4).map(|s| s.as_str()).unwrap_or("scenarios");
            let mut c = timed(
                "CoreDevice location service",
                20,
                idevice::core_device::LocationServiceClient::connect_rsd(&mut phone.adapter, &mut phone.hs),
            )
            .await?;
            match what {
                "set" => {
                    let lat: f64 = args[5].parse().unwrap();
                    let lon: f64 = args[6].parse().unwrap();
                    let r = timed("set", 20, c.set_simulated_location(lat, lon)).await?;
                    println!("{r:?}");
                }
                "clear" => {
                    let r = timed("clear", 20, c.clear_simulated_location()).await?;
                    println!("{r:?}");
                }
                _ => {
                    let r = timed("scenarios", 20, c.available_location_scenarios()).await?;
                    println!("{} scenarios", r.len());
                }
            }
            return Ok(());
        }
        "raw" => {
            let port: u16 = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(49152);
            let s = timed("open Watch raw", 20, phone.open(port)).await?;
            let mut rpc = RemotePairingClient::new(RpPairingSocket::new(s), "LocationRemote");
            timed("Watch pairing raw", 30, rpc.connect(&mut wpf, async || pin().await)).await?;
        }
        _ => {}
    }
    Ok(())
}
