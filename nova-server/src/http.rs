//! Servidor HTTPS mínimo: solo `GET`, una petición por conexión, cabeceras de hasta 8 KB.
//! Las conexiones desde IPs públicas se cierran antes del saludo TLS.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{IpAddr, TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const MAX_HEAD: usize = 8 * 1024;
const MAX_CONNECTIONS: usize = 64;
/// Tope por IP, para que un solo cliente no ocupe todas las conexiones.
const MAX_PER_IP: usize = 4;
/// Tiempo total de una conexión, saludo TLS incluido. Es un plazo para toda la conexión y no por
/// lectura: un cliente que manda un byte cada pocos segundos no puede retener su hueco.
const CONNECTION_DEADLINE: Duration = Duration::from_secs(5);
/// Pausa ante un token incorrecto: con 256 bits no hay fuerza bruta posible, pero así un
/// cliente mal configurado no martillea el servidor.
const AUTH_FAILURE_DELAY: Duration = Duration::from_millis(500);

pub struct Request {
    pub path: String,
    pub query: String,
    pub authorization: Option<String>,
}

pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
}

/// LAN (RFC 1918), Tailscale/CGNAT (100.64.0.0/10), loopback, enlace local e IPv6 privadas.
pub fn is_private(ip: IpAddr) -> bool {
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

/// Comparación en tiempo constante del `Authorization` recibido con `Bearer <token>`.
pub fn authorized(header: Option<&str>, token: &str) -> bool {
    let expected = format!("Bearer {token}");
    let given = header.unwrap_or("").as_bytes();
    given.len() == expected.len() && given.iter().zip(expected.as_bytes()).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        405 => "Method Not Allowed",
        _ => "Error",
    }
}

fn parse(head: &str) -> Option<(String, Request)> {
    let mut lines = head.split("\r\n");
    let mut first = lines.next()?.split(' ');
    let method = first.next()?.to_string();
    let target = first.next()?;
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let authorization = lines
        .filter_map(|l| l.split_once(':'))
        .find(|(k, _)| k.trim().eq_ignore_ascii_case("authorization"))
        .map(|(_, v)| v.trim().to_string());
    Some((method, Request { path: path.to_string(), query: query.to_string(), authorization }))
}

/// Ajusta los timeouts del socket a lo que queda del plazo; error si ya se ha agotado.
fn arm(tcp: &TcpStream, deadline: Instant) -> std::io::Result<()> {
    let left = deadline.saturating_duration_since(Instant::now());
    if left.is_zero() {
        return Err(std::io::ErrorKind::TimedOut.into());
    }
    tcp.set_read_timeout(Some(left))?;
    tcp.set_write_timeout(Some(left))
}

fn handle<F>(tcp: TcpStream, tls: Arc<rustls::ServerConfig>, route: &F) -> std::io::Result<()>
where
    F: Fn(&Request) -> Response,
{
    let deadline = Instant::now() + CONNECTION_DEADLINE;
    let conn = rustls::ServerConnection::new(tls).map_err(std::io::Error::other)?;
    let mut stream = rustls::StreamOwned::new(conn, tcp);

    let mut head = Vec::new();
    let mut buf = [0u8; 1024];
    while !head.windows(4).any(|w| w == b"\r\n\r\n") {
        arm(&stream.sock, deadline)?;
        let n = stream.read(&mut buf)?;
        if n == 0 || head.len() + n > MAX_HEAD {
            return Ok(());
        }
        head.extend_from_slice(&buf[..n]);
    }
    let text = String::from_utf8_lossy(&head);
    let response = match parse(&text) {
        Some((method, _)) if method != "GET" => Response { status: 405, body: br#"{"error":"method not allowed"}"#.to_vec() },
        Some((_, request)) => route(&request),
        None => Response { status: 400, body: br#"{"error":"bad request"}"#.to_vec() },
    };
    if response.status == 401 {
        thread::sleep(AUTH_FAILURE_DELAY.min(deadline.saturating_duration_since(Instant::now())));
    }
    arm(&stream.sock, deadline)?;
    let header = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        response.status,
        reason(response.status),
        response.body.len()
    );
    stream.write_all(header.as_bytes())?;
    stream.write_all(&response.body)?;
    stream.conn.send_close_notify();
    stream.flush()
}

/// Conexiones abiertas en total y por IP. El hueco se libera al soltar el `Slot`, también si el
/// hilo de la conexión entra en pánico.
#[derive(Default)]
struct Slots {
    total: usize,
    per_ip: HashMap<IpAddr, usize>,
}

struct Slot {
    slots: Arc<Mutex<Slots>>,
    ip: IpAddr,
}

impl Slot {
    fn take(slots: &Arc<Mutex<Slots>>, ip: IpAddr) -> Option<Slot> {
        let mut s = slots.lock().unwrap_or_else(|e| e.into_inner());
        let mine = s.per_ip.get(&ip).copied().unwrap_or(0);
        if s.total >= MAX_CONNECTIONS || mine >= MAX_PER_IP {
            return None;
        }
        s.total += 1;
        s.per_ip.insert(ip, mine + 1);
        Some(Slot { slots: slots.clone(), ip })
    }
}

impl Drop for Slot {
    fn drop(&mut self) {
        let mut s = self.slots.lock().unwrap_or_else(|e| e.into_inner());
        s.total -= 1;
        match s.per_ip.get_mut(&self.ip) {
            Some(n) if *n > 1 => *n -= 1,
            _ => {
                s.per_ip.remove(&self.ip);
            }
        }
    }
}

/// Atiende conexiones para siempre; cada una en su hilo, con topes de conexiones simultáneas.
/// Si no puede seguir aceptando, termina el proceso para que systemd lo reinicie.
pub fn serve<F>(listener: TcpListener, tls: Arc<rustls::ServerConfig>, allow_public: bool, route: F)
where
    F: Fn(&Request) -> Response + Send + Sync + 'static,
{
    let route = Arc::new(route);
    let slots = Arc::new(Mutex::new(Slots::default()));
    for tcp in listener.incoming() {
        let tcp = match tcp {
            Ok(t) => t,
            Err(_) => {
                // p. ej. EMFILE: sin pausa, el bucle giraría al 100 % de CPU.
                thread::sleep(Duration::from_millis(100));
                continue;
            }
        };
        let Ok(peer) = tcp.peer_addr() else { continue };
        if !allow_public && !is_private(peer.ip()) {
            continue;
        }
        let Some(slot) = Slot::take(&slots, peer.ip()) else { continue };
        let (route, tls) = (route.clone(), tls.clone());
        let spawned = thread::Builder::new().spawn(move || {
            let _slot = slot;
            let _ = handle(tcp, tls, route.as_ref());
        });
        if spawned.is_err() {
            thread::sleep(Duration::from_millis(100));
        }
    }
    eprintln!("el servidor HTTPS dejó de aceptar conexiones");
    std::process::exit(1);
}
