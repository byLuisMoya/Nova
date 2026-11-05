//! nova-server: publica por HTTPS (TLS 1.3) las métricas de un servidor Linux para que Nova las muestre en el Mac.
//!
//! Solo lectura. Corre como root (systemd) para poder leer RAPL, SMART y Docker.
//! Rutas: `GET /health` (sin token), `GET /api/v1/snapshot` y `GET /api/v1/history?range=30m|24h`.

mod fast;
mod history;
mod http;
mod model;
mod slow;
mod sys;
mod tls;

use history::History;
use model::{Config, Disk, Fast, Slow, Snapshot};
use std::collections::BTreeMap;
use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

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

fn json(status: u16, body: &impl serde::Serialize) -> http::Response {
    http::Response { status, body: serde_json::to_vec(body).unwrap_or_else(|_| b"{}".to_vec()) }
}

fn route(request: &http::Request, state: &Shared, token: &str) -> http::Response {
    if request.path == "/health" {
        return json(200, &serde_json::json!({ "ok": true }));
    }
    if !http::authorized(request.authorization.as_deref(), token) {
        return json(401, &serde_json::json!({ "error": "unauthorized" }));
    }
    match request.path.as_str() {
        "/api/v1/snapshot" => json(200, &snapshot(state)),
        "/api/v1/history" => {
            let long = !request.query.split('&').any(|kv| kv == "range=30m");
            json(200, &lock(state).history.series(long))
        }
        _ => json(404, &serde_json::json!({ "error": "not found" })),
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
    if config.token.len() < 32 {
        return eprintln!("{config_path}: el token es demasiado corto (mínimo 32 caracteres)");
    }
    let _ = std::fs::create_dir_all(&state_dir);
    let identity = match tls::load_or_create(&state_dir) {
        Ok(i) => i,
        Err(e) => return eprintln!("certificado TLS: {e}"),
    };
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
    let listener = match TcpListener::bind(&addr) {
        Ok(l) => l,
        Err(e) => return eprintln!("no se pudo escuchar en {addr}: {e}"),
    };
    println!("nova-server escuchando en https://{addr} (huella {})", identity.fingerprint);
    {
        let state = state.clone();
        let token = config.token.clone();
        let tls_config = identity.config.clone();
        let allow_public = config.allow_public;
        thread::spawn(move || http::serve(listener, tls_config, allow_public, move |r| route(r, &state, &token)));
    }

    while !STOP.load(Ordering::SeqCst) {
        thread::sleep(Duration::from_millis(250));
    }
    lock(&state).history.save(&history_path);
}
