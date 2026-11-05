//! Lectura de ficheros de /proc y /sys y ejecución de comandos con límite de tiempo.

use std::fs;
use std::io::Read;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const PATH: &str = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

pub fn read(path: &str) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().to_string())
}

pub fn read_u64(path: &str) -> Option<u64> {
    read(path)?.parse().ok()
}

pub fn read_i64(path: &str) -> Option<i64> {
    read(path)?.parse().ok()
}

pub fn list_dir(path: &str) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(path)
        .map(|it| it.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()).collect())
        .unwrap_or_default();
    names.sort();
    names
}

pub fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

pub fn now_f64() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// Ejecuta un comando y devuelve (código de salida, stdout). `None` si no se pudo lanzar o superó el tiempo.
pub fn run(args: &[&str], timeout: Duration) -> Option<(i32, String)> {
    let mut child = Command::new(args[0])
        .args(&args[1..])
        .env("PATH", PATH)
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take()?;
    let reader = thread::spawn(move || {
        let mut out = String::new();
        let _ = stdout.read_to_string(&mut out);
        out
    });
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if started.elapsed() < timeout => thread::sleep(Duration::from_millis(50)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
        }
    };
    let out = reader.join().unwrap_or_default();
    status.map(|s| (s.code().unwrap_or(-1), out))
}

pub fn statvfs(path: &str) -> Option<(u64, u64)> {
    let c_path = std::ffi::CString::new(path).ok()?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c_path.as_ptr(), &mut st) } != 0 {
        return None;
    }
    let frsize = st.f_frsize as u64;
    Some((st.f_blocks as u64 * frsize, st.f_bavail as u64 * frsize))
}

pub fn sysconf(name: libc::c_int) -> u64 {
    let v = unsafe { libc::sysconf(name) };
    if v > 0 { v as u64 } else { 0 }
}

pub fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}
