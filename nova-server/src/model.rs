//! Contrato JSON que consume Nova (`ServerModels.swift`). Los nombres de campo son los del JSON.

use serde::{Deserialize, Serialize};

#[derive(Serialize, Clone, Default)]
pub struct Cpu {
    pub percent: Option<f64>,
    pub mhz: Option<u64>,
    pub cores: usize,
    pub model: Option<String>,
}

#[derive(Serialize, Clone, Default)]
pub struct Temp {
    pub cpu: Option<f64>,
    pub fan_rpm: Option<u64>,
}

#[derive(Serialize, Clone, Default)]
pub struct Power {
    pub watts: Option<f64>,
    pub cpu_watts: Option<f64>,
    pub available: bool,
}

#[derive(Serialize, Clone)]
pub struct Gpu {
    pub name: String,
    pub driver: Option<String>,
    pub integrated: bool,
    pub state: String,
}

#[derive(Serialize, Clone, Default)]
pub struct Memory {
    pub total: u64,
    pub used: u64,
    pub swap_total: u64,
    pub swap_used: u64,
}

#[derive(Serialize, Clone)]
pub struct Proc {
    pub pid: u32,
    pub user: String,
    pub name: String,
    pub cpu: f64,
    pub mem_bytes: u64,
    pub command: String,
}

#[derive(Serialize, Clone, Default)]
pub struct Fast {
    pub cpu: Cpu,
    pub temp: Temp,
    pub power: Power,
    pub gpu: Vec<Gpu>,
    pub memory: Memory,
    pub load: [f64; 3],
    pub uptime_s: u64,
    pub processes: Vec<Proc>,
}

#[derive(Serialize, Clone)]
pub struct Filesystem {
    pub label: String,
    pub mount: String,
    pub device: String,
    pub total: u64,
    pub used: u64,
}

#[derive(Serialize, Clone)]
pub struct Container {
    pub name: String,
    pub image: String,
    pub state: String,
    pub status: String,
    pub cpu: Option<f64>,
    pub mem_bytes: Option<u64>,
    pub mem_percent: Option<f64>,
}

#[derive(Serialize, Clone, Default)]
pub struct Docker {
    pub available: bool,
    pub containers: Vec<Container>,
}

#[derive(Serialize, Clone)]
pub struct Service {
    pub name: String,
    pub ok: Option<bool>,
}

#[derive(Serialize, Clone, Default)]
pub struct Events {
    pub ecc_ce: Option<u64>,
    pub ecc_ue: Option<u64>,
    pub oom: Option<u64>,
    pub throttle: Option<u64>,
}

#[derive(Serialize, Clone, Default)]
pub struct Slow {
    pub filesystems: Vec<Filesystem>,
    pub docker: Docker,
    pub services: Vec<Service>,
    pub events: Events,
}

#[derive(Serialize, Clone, Default)]
pub struct Disk {
    pub name: String,
    pub model: Option<String>,
    pub rotational: Option<bool>,
    pub temp: Option<f64>,
    pub hours: Option<u64>,
    pub wear: Option<f64>,
    pub passed: Option<bool>,
    pub self_test: Option<String>,
    pub standby: bool,
    #[serde(skip)]
    pub checked_at: Option<u64>,
    pub checked_ago_s: Option<u64>,
}

#[derive(Serialize, Default)]
pub struct Series {
    pub t: Vec<u64>,
    pub cpu: Vec<Option<f64>>,
    pub temp: Vec<Option<f64>>,
    pub power: Vec<Option<f64>>,
}

#[derive(Serialize)]
pub struct Snapshot {
    pub host: String,
    pub ts: u64,
    #[serde(flatten)]
    pub fast: Option<Fast>,
    #[serde(flatten)]
    pub slow: Option<Slow>,
    pub disks: Vec<Disk>,
    pub history: Series,
}

#[derive(Deserialize, Clone)]
pub struct ServiceConfig {
    pub name: String,
    pub unit: Option<String>,
    pub interface: Option<String>,
    pub check: Option<String>,
}

#[derive(Deserialize)]
pub struct Config {
    pub token: String,
    #[serde(default = "default_port")]
    pub port: u16,
    #[serde(default = "default_bind")]
    pub bind: String,
    pub services: Option<Vec<ServiceConfig>>,
    /// Acepta peticiones desde IPs públicas. Por defecto solo LAN, Tailscale y loopback.
    #[serde(default)]
    pub allow_public: bool,
    /// Envía la línea de comandos completa de cada proceso. Por defecto solo el ejecutable,
    /// porque los argumentos pueden llevar secretos (`--password=…`) y el tráfico va sin cifrar.
    #[serde(default)]
    pub full_commands: bool,
}

fn default_port() -> u16 {
    8765
}

fn default_bind() -> String {
    "0.0.0.0".into()
}

/// Servicios que se vigilan si `config.json` no trae `services`: los conocidos que existan en
/// esta máquina (unidad systemd instalada, interfaz de red presente o comando disponible).
pub fn default_services() -> Vec<ServiceConfig> {
    let unit_exists = |unit: &str| {
        ["/etc/systemd/system", "/lib/systemd/system", "/usr/lib/systemd/system"]
            .iter()
            .any(|dir| std::path::Path::new(&format!("{dir}/{unit}.service")).exists())
    };
    let known_units = [
        ("Docker", "docker"),
        ("CasaOS", "casaos"),
        ("Samba", "smbd"),
        ("Nginx", "nginx"),
        ("Caddy", "caddy"),
        ("PostgreSQL", "postgresql"),
    ];
    let mut services: Vec<ServiceConfig> = known_units
        .iter()
        .filter(|(_, unit)| unit_exists(unit))
        .map(|(name, unit)| ServiceConfig { name: (*name).into(), unit: Some((*unit).into()), interface: None, check: None })
        .collect();
    if std::path::Path::new("/sys/class/net/tailscale0").exists() {
        services.push(ServiceConfig { name: "Tailscale".into(), unit: None, interface: Some("tailscale0".into()), check: None });
    }
    if ["/usr/sbin/ufw", "/sbin/ufw", "/usr/bin/ufw"].iter().any(|p| std::path::Path::new(p).exists()) {
        services.push(ServiceConfig { name: "Firewall".into(), unit: None, interface: None, check: Some("ufw".into()) });
    }
    services
}
