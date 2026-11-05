//! Certificado TLS propio de cada servidor. Se genera la primera vez (ECDSA P-256) y Nova lo fija
//! por su huella SHA-256, que el Mac obtiene por SSH al emparejar: no hace falta ninguna CA.

use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use std::fs;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::sync::Arc;

pub struct Identity {
    pub config: Arc<rustls::ServerConfig>,
    pub fingerprint: String,
}

/// Escribe en un temporal recién creado con `mode` (nunca reutiliza uno previo, que podría tener
/// permisos más abiertos) y lo renombra al destino.
fn write_file(path: &str, data: &[u8], mode: u32) -> std::io::Result<()> {
    let tmp = format!("{path}.tmp");
    let _ = fs::remove_file(&tmp);
    let mut f = fs::OpenOptions::new().write(true).create_new(true).mode(mode).open(&tmp)?;
    f.write_all(data)?;
    f.sync_all()?;
    fs::rename(&tmp, path)
}

/// Huella en el formato que guarda `servers.json`: SHA-256 del certificado DER, en hexadecimal.
pub fn fingerprint(cert_der: &[u8]) -> String {
    ring::digest::digest(&ring::digest::SHA256, cert_der).as_ref().iter().map(|b| format!("{b:02x}")).collect()
}

/// Carga el certificado de `dir` o crea uno nuevo, y deja su huella en `dir/fingerprint` (legible
/// por todos: no es secreta) para que el emparejamiento la lea sin `sudo`.
pub fn load_or_create(dir: &str) -> Result<Identity, String> {
    let cert_path = format!("{dir}/cert.der");
    let key_path = format!("{dir}/key.der");
    let (cert, key) = match (fs::read(&cert_path), fs::read(&key_path)) {
        (Ok(cert), Ok(key)) => (cert, key),
        _ => {
            let key_pair = rcgen::KeyPair::generate().map_err(|e| format!("generar clave: {e}"))?;
            let mut params = rcgen::CertificateParams::new(vec!["nova-server".to_string()])
                .map_err(|e| format!("parámetros del certificado: {e}"))?;
            params.distinguished_name = rcgen::DistinguishedName::new();
            params.distinguished_name.push(rcgen::DnType::CommonName, "nova-server");
            params.extended_key_usages = vec![rcgen::ExtendedKeyUsagePurpose::ServerAuth];
            let now = std::time::SystemTime::now();
            params.not_before = (now - std::time::Duration::from_secs(86_400)).into();
            params.not_after = (now + std::time::Duration::from_secs(10 * 365 * 86_400)).into();
            let cert = params.self_signed(&key_pair).map_err(|e| format!("firmar certificado: {e}"))?;
            let key = key_pair.serialize_der();
            write_file(&key_path, &key, 0o600).map_err(|e| format!("{key_path}: {e}"))?;
            write_file(&cert_path, cert.der(), 0o644).map_err(|e| format!("{cert_path}: {e}"))?;
            (cert.der().to_vec(), key)
        }
    };
    let fingerprint = fingerprint(&cert);
    write_file(&format!("{dir}/fingerprint"), format!("{fingerprint}\n").as_bytes(), 0o644)
        .map_err(|e| format!("{dir}/fingerprint: {e}"))?;

    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = rustls::ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(|e| format!("TLS: {e}"))?
        .with_no_client_auth()
        .with_single_cert(
            vec![CertificateDer::from(cert)],
            PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key)),
        )
        .map_err(|e| format!("certificado no válido: {e}"))?;
    Ok(Identity { config: Arc::new(config), fingerprint })
}
