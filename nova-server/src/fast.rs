//! Muestreo rápido (cada 5 s): CPU, temperatura, consumo, GPU, memoria y procesos.

use crate::model::{Cpu, Fast, Gpu, Memory, Power, Proc, Temp};
use crate::sys::{list_dir, now_f64, read, read_i64, read_u64, round1, run, sysconf};
use std::collections::HashMap;
use std::os::unix::fs::MetadataExt;
use std::time::Duration;

struct GpuInfo {
    slot: String,
    name: String,
    driver: Option<String>,
    integrated: bool,
}

pub struct FastSampler {
    ncpu: usize,
    clk: f64,
    page: u64,
    cpu_model: Option<String>,
    rapl: Vec<(bool, String)>,
    gpus: Vec<GpuInfo>,
    prev_cpu: Option<(u64, u64)>,
    prev_energy: HashMap<String, (u64, f64)>,
    prev_procs: HashMap<u32, (u64, u64)>,
    prev_proc_time: Option<f64>,
    users: HashMap<u32, String>,
    full_commands: bool,
}

impl FastSampler {
    pub fn new(full_commands: bool) -> Self {
        let ncpu = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1);
        FastSampler {
            ncpu,
            clk: sysconf(libc::_SC_CLK_TCK).max(1) as f64,
            page: sysconf(libc::_SC_PAGESIZE).max(4096),
            cpu_model: cpu_model(),
            rapl: rapl_domains(),
            gpus: gpus(),
            prev_cpu: None,
            prev_energy: HashMap::new(),
            prev_procs: HashMap::new(),
            prev_proc_time: None,
            users: HashMap::new(),
            full_commands,
        }
    }

    pub fn cores(&self) -> usize {
        self.ncpu
    }

    pub fn sample(&mut self) -> Fast {
        let now = now_f64();
        let percent = self.cpu_percent();
        let (temp, fan) = temps();
        let (watts, cpu_watts) = self.power(now);
        Fast {
            cpu: Cpu { percent, mhz: self.cpu_mhz(), cores: self.ncpu, model: self.cpu_model.clone() },
            temp: Temp { cpu: temp, fan_rpm: fan },
            power: Power { watts, cpu_watts, available: !self.rapl.is_empty() },
            gpu: self.gpu_states(),
            memory: memory(),
            load: loadavg(),
            uptime_s: read("/proc/uptime")
                .and_then(|s| s.split_whitespace().next().and_then(|v| v.parse::<f64>().ok()))
                .unwrap_or(0.0) as u64,
            processes: self.processes(now),
        }
    }

    fn cpu_percent(&mut self) -> Option<f64> {
        let line = read("/proc/stat")?;
        let vals: Vec<u64> = line.lines().next()?.split_whitespace().skip(1).take(8).filter_map(|v| v.parse().ok()).collect();
        if vals.len() < 5 {
            return None;
        }
        let total: u64 = vals.iter().sum();
        let idle = vals[3] + vals[4];
        let pct = self.prev_cpu.map(|(pt, pi)| {
            let dt = total.saturating_sub(pt) as f64;
            let di = idle.saturating_sub(pi) as f64;
            if dt > 0.0 { round1(100.0 * (dt - di) / dt) } else { 0.0 }
        });
        self.prev_cpu = Some((total, idle));
        pct
    }

    fn cpu_mhz(&self) -> Option<u64> {
        let freqs: Vec<u64> = (0..self.ncpu)
            .filter_map(|i| read_u64(&format!("/sys/devices/system/cpu/cpu{i}/cpufreq/scaling_cur_freq")))
            .collect();
        if freqs.is_empty() {
            return None;
        }
        Some((freqs.iter().sum::<u64>() as f64 / freqs.len() as f64 / 1000.0).round() as u64)
    }

    fn power(&mut self, now: f64) -> (Option<f64>, Option<f64>) {
        let mut package: Option<f64> = None;
        let mut core: Option<f64> = None;
        for (is_package, path) in &self.rapl {
            let Some(energy) = read_u64(&format!("{path}/energy_uj")) else { continue };
            let prev = self.prev_energy.insert(path.clone(), (energy, now));
            let Some((prev_energy, prev_time)) = prev else { continue };
            let mut delta = energy as i128 - prev_energy as i128;
            if delta < 0 {
                let Some(range) = read_u64(&format!("{path}/max_energy_range_uj")) else { continue };
                delta += range as i128;
            }
            let dt = now - prev_time;
            if dt <= 0.0 {
                continue;
            }
            let watts = delta as f64 / 1e6 / dt;
            let slot = if *is_package { &mut package } else { &mut core };
            *slot = Some(slot.unwrap_or(0.0) + watts);
        }
        (package.map(round1), core.map(round1))
    }

    fn gpu_states(&self) -> Vec<Gpu> {
        self.gpus
            .iter()
            .map(|g| {
                let status = read(&format!("/sys/bus/pci/devices/{}/power/runtime_status", g.slot));
                let state = match status.as_deref() {
                    Some("suspended") => "dormida",
                    Some("active") => "activa",
                    _ if g.integrated => "activa",
                    _ => "desconocido",
                };
                Gpu { name: g.name.clone(), driver: g.driver.clone(), integrated: g.integrated, state: state.into() }
            })
            .collect()
    }

    fn user(&mut self, uid: u32) -> String {
        if !self.users.contains_key(&uid) {
            for line in read("/etc/passwd").unwrap_or_default().lines() {
                let parts: Vec<&str> = line.split(':').collect();
                if let (Some(name), Some(id)) = (parts.first(), parts.get(2).and_then(|v| v.parse::<u32>().ok())) {
                    self.users.insert(id, name.to_string());
                }
            }
            self.users.entry(uid).or_insert_with(|| uid.to_string());
        }
        self.users[&uid].clone()
    }

    fn processes(&mut self, now: f64) -> Vec<Proc> {
        let dt = self.prev_proc_time.map(|p| now - p).filter(|d| *d > 0.0);
        let mut current = HashMap::new();
        let mut rows: Vec<(f64, u64, u32, String)> = Vec::new();
        for entry in list_dir("/proc") {
            let Ok(pid) = entry.parse::<u32>() else { continue };
            let Some(stat) = read(&format!("/proc/{pid}/stat")) else { continue };
            let (Some(open), Some(close)) = (stat.find('('), stat.rfind(')')) else { continue };
            let name = stat[open + 1..close].to_string();
            let fields: Vec<&str> = stat.get(close + 2..).unwrap_or("").split_whitespace().collect();
            if fields.len() < 22 {
                continue;
            }
            let num = |i: usize| fields[i].parse::<u64>().unwrap_or(0);
            let ticks = num(11) + num(12);
            let start = num(19);
            current.insert(pid, (ticks, start));
            let (Some(dt), Some(&(prev_ticks, prev_start))) = (dt, self.prev_procs.get(&pid)) else { continue };
            if prev_start != start {
                continue;
            }
            let cpu = ticks.saturating_sub(prev_ticks) as f64 / self.clk / dt / self.ncpu as f64 * 100.0;
            rows.push((cpu, num(21) * self.page, pid, name));
        }
        self.prev_procs = current;
        self.prev_proc_time = Some(now);
        rows.sort_by(|a, b| b.0.total_cmp(&a.0).then(b.1.cmp(&a.1)));
        let mut top = Vec::new();
        for (cpu, rss, pid, name) in rows.into_iter().take(25) {
            let Ok(meta) = std::fs::metadata(format!("/proc/{pid}")) else { continue };
            let raw = std::fs::read(format!("/proc/{pid}/cmdline")).unwrap_or_default();
            let command = if self.full_commands {
                String::from_utf8_lossy(&raw).replace('\0', " ").trim().to_string()
            } else {
                String::from_utf8_lossy(raw.split(|b| *b == 0).next().unwrap_or(&[])).trim().to_string()
            };
            let command: String = if command.is_empty() { format!("[{name}]") } else { command.chars().take(200).collect() };
            top.push(Proc { pid, user: self.user(meta.uid()), name, cpu: round1(cpu), mem_bytes: rss, command });
        }
        top
    }
}

fn cpu_model() -> Option<String> {
    read("/proc/cpuinfo")?
        .lines()
        .find(|l| l.starts_with("model name"))
        .and_then(|l| l.split_once(':'))
        .map(|(_, v)| v.split_whitespace().collect::<Vec<_>>().join(" "))
}

/// Dominios RAPL de Intel: (es_paquete, ruta). Solo `package-N` y `core`.
fn rapl_domains() -> Vec<(bool, String)> {
    let base = "/sys/class/powercap";
    list_dir(base)
        .into_iter()
        .filter(|e| e.starts_with("intel-rapl:"))
        .filter_map(|e| {
            let path = format!("{base}/{e}");
            let name = read(&format!("{path}/name"))?;
            if name.starts_with("package") {
                Some((true, path))
            } else if name == "core" {
                Some((false, path))
            } else {
                None
            }
        })
        .collect()
}

fn gpus() -> Vec<GpuInfo> {
    let mut names = HashMap::new();
    if let Some((0, out)) = run(&["lspci", "-mm"], Duration::from_secs(5)) {
        for line in out.lines() {
            let slot = line.split_whitespace().next().unwrap_or("").to_string();
            let quoted: Vec<&str> = line.split('"').skip(1).step_by(2).collect();
            if let Some(device) = quoted.get(2) {
                names.insert(slot, device.to_string());
            }
        }
    }
    let base = "/sys/bus/pci/devices";
    list_dir(base)
        .into_iter()
        .filter(|dev| read(&format!("{base}/{dev}/class")).is_some_and(|c| c.starts_with("0x03")))
        .map(|dev| {
            let driver = std::fs::read_link(format!("{base}/{dev}/driver"))
                .ok()
                .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()));
            let raw = dev.split_once(':').and_then(|(_, short)| names.get(short)).cloned().unwrap_or_default();
            let name = match (raw.find('['), raw.rfind(']')) {
                (Some(a), Some(b)) if b > a => raw[a + 1..b].to_string(),
                _ if !raw.is_empty() => raw.clone(),
                _ => dev.clone(),
            };
            let integrated = read(&format!("{base}/{dev}/boot_vga")).as_deref() == Some("1");
            GpuInfo { slot: dev, name, driver, integrated }
        })
        .collect()
}

/// Temperatura de CPU (sensor de paquete si existe) y RPM máximas de ventilador.
fn temps() -> (Option<f64>, Option<u64>) {
    let base = "/sys/class/hwmon";
    let mons: Vec<(String, String)> = list_dir(base)
        .into_iter()
        .map(|e| {
            let path = format!("{base}/{e}");
            (read(&format!("{path}/name")).unwrap_or_default(), path)
        })
        .collect();
    let mut cpu: Option<f64> = None;
    'names: for wanted in ["coretemp", "k10temp", "zenpower", "cpu_thermal", "acpitz"] {
        for (_, path) in mons.iter().filter(|(n, _)| n == wanted) {
            for f in list_dir(path).into_iter().filter(|f| f.starts_with("temp") && f.ends_with("_input")) {
                let label = read(&format!("{path}/{}", f.replace("_input", "_label"))).unwrap_or_default();
                let is_package = label.starts_with("Package") || label.starts_with("Tctl") || label.starts_with("Tdie");
                if cpu.is_none() || is_package {
                    if let Some(v) = read_i64(&format!("{path}/{f}")) {
                        cpu = Some(v as f64 / 1000.0);
                        if is_package {
                            break 'names;
                        }
                    }
                }
            }
        }
        if cpu.is_some() {
            break;
        }
    }
    let fan = mons
        .iter()
        .flat_map(|(_, path)| {
            list_dir(path)
                .into_iter()
                .filter(|f| f.starts_with("fan") && f.ends_with("_input"))
                .filter_map(move |f| read_u64(&format!("{path}/{f}")))
        })
        .max();
    (cpu.map(round1), fan)
}

fn memory() -> Memory {
    let mut info = HashMap::new();
    for line in read("/proc/meminfo").unwrap_or_default().lines() {
        if let Some((key, rest)) = line.split_once(':') {
            if let Some(v) = rest.split_whitespace().next().and_then(|v| v.parse::<u64>().ok()) {
                info.insert(key.to_string(), v * 1024);
            }
        }
    }
    let get = |k: &str| info.get(k).copied().unwrap_or(0);
    Memory {
        total: get("MemTotal"),
        used: get("MemTotal").saturating_sub(get("MemAvailable")),
        swap_total: get("SwapTotal"),
        swap_used: get("SwapTotal").saturating_sub(get("SwapFree")),
    }
}

fn loadavg() -> [f64; 3] {
    let raw = read("/proc/loadavg").unwrap_or_default();
    let mut it = raw.split_whitespace().map(|v| v.parse::<f64>().unwrap_or(0.0));
    [it.next().unwrap_or(0.0), it.next().unwrap_or(0.0), it.next().unwrap_or(0.0)]
}
