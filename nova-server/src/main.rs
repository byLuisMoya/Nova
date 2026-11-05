//! nova-server: publica en HTTP+JSON las métricas de un servidor Linux para que Nova las muestre en el Mac.
//!
//! Solo lectura. Corre como root (systemd) para poder leer RAPL, SMART y Docker.
//! Rutas: `GET /health` (sin token), `GET /api/v1/snapshot` y `GET /api/v1/history?range=30m|24h`.

mod fast;
mod history;
mod model;
mod slow;
mod sys;

use history::History;
use model::{Config, Disk, Fast, Slow, Snapshot};
use std::collections::BTreeMap;
use std::net::IpAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use tiny_http::{Header, Response, Server};

const SAMPLE_EVERY: Duration = Duration::from_secs(5);
const SLOW_EVERY: Duration = Duration::from_secs(30);
const SMART_EVERY: Duration = Duration::from_secs(600);
const SAVE_EVERY: Duration = Duration::from_secs(300);

static STOP: AtomicBool = AtomicBool::new(false);

#[derive(Default)]
struct State {
    fast: Option<Fast>,
    slow: Option<Slow>,
    disks: BTreeMap<String, Disk>,
    history: History,
}

type Shared = Arc<Mutex<State>>;

extern "C" fn on_signal(_: libc::c_int) {
    STOP.store(true, Ordering::SeqCst);
}

fn lock(state: &Shared) -> std::sync::MutexGuard<'_, State> {
    state.lock().unwrap_or_else(|e| e.into_inner())
}

/// Repite `f` cada `every` hasta la señal de parada; un pánico puntual no detiene el bucle.
fn every(every: Duration, mut f: impl FnMut() + Send + 'static) {
    thread::spawn(move || {
        while !STOP.load(Ordering::SeqCst) {
            let started = Instant::now();
            if std::panic::catch_unwind(std::panic::AssertUnwindSafe(&mut f)).is_err() {
                eprintln!("fallo en un muestreo; se reintenta en el siguiente ciclo");
            }
            let wait = every.saturating_sub(started.elapsed()).max(Duration::from_millis(500));
            let deadline = Instant::now() + wait;
            while Instant::now() < deadline && !STOP.load(Ordering::SeqCst) {
                thread::sleep(Duration::from_millis(250));
            }
        }
    });
}

fn snapshot(state: &Shared) -> Snapshot {
    let now = sys::now_secs();
    let s = lock(state);
    let disks = s
        .disks
        .values()
        .cloned()
        .map(|mut d| {
            d.checked_ago_s = d.checked_at.map(|t| now.saturating_sub(t));
            d
        })
        .collect();
    Snapshot {
        host: sys::read("/proc/sys/kernel/hostname").unwrap_or_default(),
        ts: now,
        fast: s.fast.clone(),
        slow: s.slow.clone(),
        disks,
        history: s.history.series(false),
    }
}

fn authorized(header: Option<&str>, token: &str) -> bool {
    let expected = format!("Bearer {token}");
    let given = header.unwrap_or("").as_bytes();
    given.len() == expected.len() && given.iter().zip(expected.as_bytes()).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0
}

fn json_response(code: u16, body: &impl serde::Serialize) -> Response<std::io::Cursor<Vec<u8>>> {
    let payload = serde_json::to_vec(body).unwrap_or_else(|_| b"{}".to_vec());
    Response::from_data(payload)
        .with_status_code(code)
        .with_header(Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]).unwrap())
        .with_header(Header::from_bytes(&b"Cache-Control"[..], &b"no-store"[..]).unwrap())
}

/// LAN (RFC 1918), Tailscale/CGNAT (100.64.0.0/10), loopback, enlace local e IPv6 privadas.
fn is_private(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            v4.is_private() || v4.is_loopback() || v4.is_link_local() || (o[0] == 100 && (o[1] & 0xc0) == 64)
        }
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return is_private(IpAddr::V4(v4));
            }
            let first = v6.segments()[0];
            v6.is_loopback() || (first & 0xfe00) == 0xfc00 || (first & 0xffc0) == 0xfe80
        }
    }
}

fn serve(server: &Server, state: Shared, token: String, allow_public: bool) {
    for request in server.incoming_requests() {
        if !allow_public && !request.remote_addr().is_some_and(|a| is_private(a.ip())) {
            let _ = request.respond(json_response(403, &serde_json::json!({ "error": "forbidden" })));
            continue;
        }
        let url = request.url().to_string();
        let (path, query) = url.split_once('?').unwrap_or((&url, ""));
        let auth = request
            .headers()
            .iter()
            .find(|h| h.field.equiv("Authorization"))
            .map(|h| h.value.as_str().to_string());
        let response = if path == "/health" {
            json_response(200, &serde_json::json!({ "ok": true }))
        } else if !authorized(auth.as_deref(), &token) {
            json_response(401, &serde_json::json!({ "error": "unauthorized" }))
        } else if path == "/api/v1/snapshot" {
            json_response(200, &snapshot(&state))
        } else if path == "/api/v1/history" {
            let long = !query.split('&').any(|kv| kv == "range=30m");
            json_response(200, &lock(&state).history.series(long))
        } else {
            json_response(404, &serde_json::json!({ "error": "not found" }))
        };
        let _ = request.respond(response);
    }
}

fn main() {
    let config_path = std::env::var("NOVA_SERVER_CONFIG").unwrap_or_else(|_| "/etc/nova-server/config.json".into());
    let state_dir = std::env::var("NOVA_SERVER_STATE").unwrap_or_else(|_| "/var/lib/nova-server".into());
    let config: Config = match std::fs::read_to_string(&config_path).map(|s| serde_json::from_str(&s)) {
        Ok(Ok(c)) => c,
        Ok(Err(e)) => return eprintln!("{config_path}: JSON no válido: {e}"),
        Err(e) => return eprintln!("{config_path}: {e}"),
    };
    let _ = std::fs::create_dir_all(&state_dir);
    let history_path = format!("{state_dir}/history.json");
    let state: Shared = Arc::new(Mutex::new(State { history: History::load(&history_path), ..State::default() }));

    unsafe {
        libc::signal(libc::SIGTERM, on_signal as extern "C" fn(libc::c_int) as libc::sighandler_t);
        libc::signal(libc::SIGINT, on_signal as extern "C" fn(libc::c_int) as libc::sighandler_t);
    }

    let mut sampler = fast::FastSampler::new(config.full_commands);
    let ncpu = sampler.cores();
    {
        let state = state.clone();
        every(SAMPLE_EVERY, move || {
            let data = sampler.sample();
            let point = (sys::now_secs(), data.cpu.percent, data.temp.cpu, data.power.watts);
            let mut s = lock(&state);
            if point.1.is_some() {
                s.history.add(point);
            }
            s.fast = Some(data);
        });
    }
    {
        let state = state.clone();
        let services = config.services.clone().unwrap_or_else(model::default_services);
        let mut smart_at: Option<Instant> = None;
        every(SLOW_EVERY, move || {
            let data = slow::sample(&services, ncpu);
            if smart_at.is_none_or(|t| t.elapsed() >= SMART_EVERY) {
                smart_at = Some(Instant::now());
                let mut disks = lock(&state).disks.clone();
                slow::smart(&mut disks);
                lock(&state).disks = disks;
            }
            lock(&state).slow = Some(data);
        });
    }
    {
        let state = state.clone();
        let path = history_path.clone();
        let mut first = true;
        every(SAVE_EVERY, move || {
            if !std::mem::take(&mut first) {
                lock(&state).history.save(&path);
            }
        });
    }

    let addr = format!("{}:{}", config.bind, config.port);
    let server = match Server::http(&addr) {
        Ok(s) => s,
        Err(e) => return eprintln!("no se pudo escuchar en {addr}: {e}"),
    };
    println!("nova-server escuchando en {addr}");
    let server = Arc::new(server);
    {
        let server = server.clone();
        let state = state.clone();
        let token = config.token.clone();
        let allow_public = config.allow_public;
        thread::spawn(move || serve(&server, state, token, allow_public));
    }

    while !STOP.load(Ordering::SeqCst) {
        thread::sleep(Duration::from_millis(250));
    }
    lock(&state).history.save(&history_path);
    server.unblock();
}
