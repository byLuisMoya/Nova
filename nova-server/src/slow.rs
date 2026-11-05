//! Muestreo lento: sistemas de ficheros, Docker, servicios y eventos (cada 30 s) y SMART (cada 10 min).

use crate::model::{Container, Disk, Docker, Events, Filesystem, Service, ServiceConfig, Slow};
use crate::sys::{list_dir, now_secs, read, read_u64, run, statvfs};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::time::Duration;

const REAL_FS: &[&str] = &["ext4", "ext3", "xfs", "btrfs", "zfs", "f2fs", "ntfs", "ntfs3", "exfat", "fuseblk"];
const SKIP_PREFIXES: &[&str] = &["/boot", "/snap", "/var/lib/docker", "/run", "/proc", "/sys", "/dev"];

pub fn sample(services: &[ServiceConfig], ncpu: usize) -> Slow {
    Slow { filesystems: filesystems(), docker: docker(), services: check_services(services), events: events(ncpu) }
}

fn filesystems() -> Vec<Filesystem> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for line in read("/proc/mounts").unwrap_or_default().lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < 3 {
            continue;
        }
        let (device, mount, fstype) = (parts[0], parts[1].replace("\\040", " "), parts[2]);
        if !REAL_FS.contains(&fstype) || !seen.insert(device.to_string()) {
            continue;
        }
        if mount != "/" && SKIP_PREFIXES.iter().any(|p| mount.starts_with(p)) {
            continue;
        }
        let Some((total, free)) = statvfs(&mount) else { continue };
        if total == 0 {
            continue;
        }
        let label = if mount == "/" {
            "Disco".to_string()
        } else {
            let base = mount.trim_end_matches('/').rsplit('/').next().unwrap_or(&mount).to_string();
            let mut chars = base.chars();
            chars.next().map(|c| c.to_uppercase().collect::<String>() + chars.as_str()).unwrap_or(base)
        };
        out.push(Filesystem { label, mount, device: device.to_string(), total, used: total - free });
    }
    out.sort_by(|a, b| (a.mount != "/", &a.mount).cmp(&(b.mount != "/", &b.mount)));
    out
}

fn json_lines(out: &str) -> impl Iterator<Item = Value> + '_ {
    out.lines().filter_map(|l| serde_json::from_str::<Value>(l).ok())
}

fn text(v: &Value, key: &str) -> String {
    v.get(key).and_then(Value::as_str).unwrap_or("").to_string()
}

fn percent(v: &str) -> Option<f64> {
    v.trim().trim_end_matches('%').parse().ok()
}

fn bytes(v: &str) -> Option<u64> {
    let v = v.trim();
    let split = v.find(|c: char| c.is_ascii_alphabetic())?;
    let number: f64 = v[..split].trim().parse().ok()?;
    let factor = match v[split..].trim().to_ascii_lowercase().as_str() {
        "b" => 1.0,
        "kb" => 1e3,
        "mb" => 1e6,
        "gb" => 1e9,
        "tb" => 1e12,
        "kib" => 1024.0,
        "mib" => 1024f64.powi(2),
        "gib" => 1024f64.powi(3),
        "tib" => 1024f64.powi(4),
        _ => 1.0,
    };
    Some((number * factor) as u64)
}

fn docker() -> Docker {
    let Some((0, out)) = run(&["docker", "ps", "-a", "--no-trunc", "--format", "{{json .}}"], Duration::from_secs(15)) else {
        return Docker::default();
    };
    let mut containers: Vec<Container> = json_lines(&out)
        .map(|c| Container {
            name: text(&c, "Names"),
            image: text(&c, "Image"),
            state: text(&c, "State"),
            status: text(&c, "Status"),
            cpu: None,
            mem_bytes: None,
            mem_percent: None,
        })
        .collect();
    if let Some((0, out)) = run(&["docker", "stats", "--no-stream", "--format", "{{json .}}"], Duration::from_secs(25)) {
        let stats: HashMap<String, Value> = json_lines(&out).map(|s| (text(&s, "Name"), s)).collect();
        for c in &mut containers {
            if let Some(s) = stats.get(&c.name) {
                c.cpu = percent(&text(s, "CPUPerc"));
                c.mem_percent = percent(&text(s, "MemPerc"));
                c.mem_bytes = bytes(text(s, "MemUsage").split('/').next().unwrap_or(""));
            }
        }
    }
    let rank = |s: &str| match s {
        "running" => 0,
        "restarting" => 1,
        "paused" => 2,
        _ => 3,
    };
    containers.sort_by(|a, b| (rank(&a.state), &a.name).cmp(&(rank(&b.state), &b.name)));
    Docker { available: true, containers }
}

fn check_services(services: &[ServiceConfig]) -> Vec<Service> {
    services
        .iter()
        .map(|s| {
            let ok = if let Some(unit) = &s.unit {
                run(&["systemctl", "is-active", unit], Duration::from_secs(5)).map(|(_, out)| out.trim() == "active")
            } else if let Some(iface) = &s.interface {
                Some(matches!(read(&format!("/sys/class/net/{iface}/operstate")).as_deref(), Some("up" | "unknown")))
            } else if s.check.as_deref() == Some("ufw") {
                run(&["ufw", "status"], Duration::from_secs(5)).map(|(code, out)| code == 0 && out.contains("Status: active"))
            } else {
                None
            };
            Service { name: s.name.clone(), ok }
        })
        .collect()
}

fn events(ncpu: usize) -> Events {
    let oom = read("/proc/vmstat")
        .unwrap_or_default()
        .lines()
        .find_map(|l| l.strip_prefix("oom_kill ").and_then(|v| v.trim().parse().ok()));
    let mut throttle = 0;
    let mut found = false;
    let mut packages = HashSet::new();
    for i in 0..ncpu {
        let base = format!("/sys/devices/system/cpu/cpu{i}/thermal_throttle");
        if let Some(v) = read_u64(&format!("{base}/core_throttle_count")) {
            found = true;
            throttle += v;
        }
        let package = read(&format!("/sys/devices/system/cpu/cpu{i}/topology/physical_package_id"));
        if packages.insert(package) {
            throttle += read_u64(&format!("{base}/package_throttle_count")).unwrap_or(0);
        }
    }
    let edac = "/sys/devices/system/edac/mc";
    let (mut ce, mut ue) = (None, None);
    for mc in list_dir(edac).into_iter().filter(|m| m.starts_with("mc")) {
        ce = Some(ce.unwrap_or(0) + read_u64(&format!("{edac}/{mc}/ce_count")).unwrap_or(0));
        ue = Some(ue.unwrap_or(0) + read_u64(&format!("{edac}/{mc}/ue_count")).unwrap_or(0));
    }
    Events { ecc_ce: ce, ecc_ue: ue, oom, throttle: found.then_some(throttle) }
}

/// Lee SMART de cada disco sin despertarlo (`-n standby`); un disco dormido conserva su última lectura.
pub fn smart(disks: &mut BTreeMap<String, Disk>) {
    let Some((_, out)) = run(&["smartctl", "-j", "--scan"], Duration::from_secs(10)) else { return };
    let Ok(scan) = serde_json::from_str::<Value>(&out) else { return };
    let devices: Vec<(String, String)> = scan["devices"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|d| Some((d["name"].as_str()?.to_string(), d["type"].as_str().unwrap_or("auto").to_string())))
                .collect()
        })
        .unwrap_or_default();
    for (dev, kind) in devices {
        let base = dev.rsplit('/').next().unwrap_or(&dev).to_string();
        let name = if kind.contains(',') { format!("{base} ({kind})") } else { base };
        let args = ["smartctl", "-j", "-a", "-n", "standby", "-d", kind.as_str(), dev.as_str()];
        let Some((_, out)) = run(&args, Duration::from_secs(30)) else { continue };
        let Ok(j) = serde_json::from_str::<Value>(&out) else { continue };
        let standby = j["smartctl"]["messages"]
            .as_array()
            .is_some_and(|m| m.iter().any(|m| m["string"].as_str().is_some_and(|s| s.to_uppercase().contains("STANDBY"))));
        if standby {
            let entry = disks.entry(name.clone()).or_insert_with(|| Disk { name: name.clone(), ..Disk::default() });
            entry.standby = true;
            continue;
        }
        let Some(model) = j["model_name"].as_str() else { continue };
        let nvme = &j["nvme_smart_health_information_log"];
        disks.insert(
            name.clone(),
            Disk {
                name,
                model: Some(model.to_string()),
                rotational: Some(j["rotation_rate"].as_u64().unwrap_or(0) > 0),
                temp: j["temperature"]["current"].as_f64(),
                hours: j["power_on_time"]["hours"].as_u64(),
                wear: nvme["percentage_used"].as_f64(),
                passed: j["smart_status"]["passed"].as_bool(),
                self_test: last_self_test(&j),
                standby: false,
                checked_at: Some(now_secs()),
                checked_ago_s: None,
            },
        );
    }
}

fn last_self_test(j: &Value) -> Option<String> {
    let (kind, ok) = if let Some(e) = j["nvme_self_test_log"]["table"].as_array().and_then(|t| t.first()) {
        (e["self_test_code"]["string"].as_str().unwrap_or("").to_lowercase(), e["self_test_result"]["value"].as_u64() == Some(0))
    } else if let Some(e) = j["ata_smart_self_test_log"]["standard"]["table"].as_array().and_then(|t| t.first()) {
        (e["type"]["string"].as_str().unwrap_or("").to_lowercase(), e["status"]["passed"].as_bool().unwrap_or(false))
    } else {
        return None;
    };
    let label = [("short", "corto"), ("extended", "largo"), ("long", "largo"), ("conveyance", "de transporte")]
        .iter()
        .find(|(k, _)| kind.contains(k))
        .map(|(_, v)| v.to_string())
        .unwrap_or(kind);
    Some(format!("autotest {label} {}", if ok { "OK" } else { "FALLÓ" }).split_whitespace().collect::<Vec<_>>().join(" "))
}
