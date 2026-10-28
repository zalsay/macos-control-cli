//! Isolated TLS identity and bearer-token provisioning. No network listeners.
use crate::{
    private_files,
    protocol::{Error, Result},
};
use rcgen::{
    BasicConstraints, CertificateParams, ExtendedKeyUsagePurpose, IsCa, Issuer, KeyPair,
    KeyUsagePurpose,
};
use ring::{
    digest,
    rand::{SecureRandom, SystemRandom},
};
use rustls::pki_types::{pem::PemObject, CertificateDer, PrivateKeyDer, ServerName};
use std::{
    ffi::CString,
    os::unix::{
        ffi::OsStrExt,
        fs::{DirBuilderExt, PermissionsExt},
    },
    path::{Path, PathBuf},
    sync::Arc,
};
use subtle::ConstantTimeEq;
use time::{Duration, OffsetDateTime};

const LIMIT: u64 = 64 * 1024;
fn invalid() -> Error {
    Error::new("REMOTE_CREDENTIALS_INVALID", "远程凭证无效或无法安全读写")
}

pub struct CertificateBundle {
    pub directory: PathBuf,
    pub ca_cert: PathBuf,
    pub certificate: PathBuf,
    pub private_key: PathBuf,
    pub ca_sha256: String,
    pub expires_at_unix: i64,
}

pub struct SecretToken([u8; 64]);
impl std::fmt::Debug for SecretToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SecretToken([REDACTED])")
    }
}
impl SecretToken {
    /// Returns the raw 64-character lowercase hex token, without a `Bearer ` prefix.
    pub fn header_value(&self) -> String {
        String::from_utf8(self.0.to_vec()).expect("validated ASCII token")
    }
    pub fn matches(&self, value: &[u8]) -> bool {
        bool::from(self.0.as_slice().ct_eq(value))
    }
}

fn checked_parent(path: &Path) -> Result<&Path> {
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .ok_or_else(invalid)?;
    let meta = std::fs::symlink_metadata(parent).map_err(|_| invalid())?;
    private_files::check_private(&meta, true).map_err(|_| invalid())?;
    if meta.permissions().mode() & 0o7777 != 0o700 || path.file_name().is_none() {
        return Err(invalid());
    }
    Ok(parent)
}
fn temp_path(parent: &Path) -> Result<PathBuf> {
    Ok(parent.join(format!(
        ".mcc-remote-{}",
        crate::protocol::random_id().map_err(|_| invalid())?
    )))
}
struct TempDir(PathBuf);
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
struct TempFile(PathBuf);
impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}
fn sync_dir(path: &Path) -> Result<()> {
    std::fs::File::open(path)
        .and_then(|f| f.sync_all())
        .map_err(|_| invalid())
}

// A directory cannot be hard-linked; use the platform's exclusive rename operation.
fn rename_exclusive(from: &Path, to: &Path) -> Result<()> {
    let from = CString::new(from.as_os_str().as_bytes()).map_err(|_| invalid())?;
    let to = CString::new(to.as_os_str().as_bytes()).map_err(|_| invalid())?;
    #[cfg(target_os = "macos")]
    let result = unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_EXCL) };
    #[cfg(target_os = "linux")]
    let result = unsafe {
        libc::renameat2(
            libc::AT_FDCWD,
            from.as_ptr(),
            libc::AT_FDCWD,
            to.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    let result = -1;
    if result == 0 {
        Ok(())
    } else {
        Err(invalid())
    }
}
fn write_file(path: &Path, data: &[u8]) -> Result<()> {
    private_files::write_credential_new(path, data).map_err(|_| invalid())
}
fn hex(data: &[u8]) -> String {
    data.iter().map(|b| format!("{b:02x}")).collect()
}
fn valid_token(bytes: &[u8]) -> bool {
    bytes.len() == 64
        && bytes
            .iter()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
        && !(1..=32).any(|period| {
            bytes
                .iter()
                .enumerate()
                .all(|(i, b)| *b == bytes[i % period])
        })
}

pub fn initialize_tls(sans: &[String], directory: &Path) -> Result<CertificateBundle> {
    if sans.is_empty() || sans.len() > 8 {
        return Err(invalid());
    }
    for san in sans {
        if san.contains('*')
            || san.parse::<std::net::IpAddr>().is_err()
                && ServerName::try_from(san.as_str()).is_err()
        {
            return Err(invalid());
        }
    }
    let parent = checked_parent(directory)?;
    // Reject early without relying on this check for atomicity.
    match std::fs::symlink_metadata(directory) {
        Ok(_) => return Err(invalid()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err(invalid()),
    }
    let now = OffsetDateTime::now_utc();
    let mut ca_params = CertificateParams::new(Vec::<String>::new()).map_err(|_| invalid())?;
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    ca_params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
    ca_params.not_before = now;
    ca_params.not_after = now + Duration::days(365);
    let ca_key = KeyPair::generate().map_err(|_| invalid())?;
    let ca_cert = ca_params.self_signed(&ca_key).map_err(|_| invalid())?;
    let mut leaf_params = CertificateParams::new(sans.to_vec()).map_err(|_| invalid())?;
    leaf_params.not_before = now;
    leaf_params.not_after = now + Duration::days(90);
    leaf_params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
    leaf_params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
    leaf_params.use_authority_key_identifier_extension = true;
    let leaf_key = KeyPair::generate().map_err(|_| invalid())?;
    let issuer = Issuer::from_params(&ca_params, &ca_key);
    let leaf_cert = leaf_params
        .signed_by(&leaf_key, &issuer)
        .map_err(|_| invalid())?;
    let fingerprint = hex(digest::digest(&digest::SHA256, ca_cert.der().as_ref()).as_ref());
    let temp = temp_path(parent)?;
    let mut builder = std::fs::DirBuilder::new();
    builder.mode(0o700);
    builder.create(&temp).map_err(|_| invalid())?;
    let guard = TempDir(temp.clone());
    std::fs::set_permissions(&temp, std::fs::Permissions::from_mode(0o700))
        .map_err(|_| invalid())?;
    write_file(&temp.join("host-ca.pem"), ca_cert.pem().as_bytes())?;
    write_file(
        &temp.join("host-ca-key.pem"),
        ca_key.serialize_pem().as_bytes(),
    )?;
    write_file(&temp.join("host-cert.pem"), leaf_cert.pem().as_bytes())?;
    write_file(
        &temp.join("host-key.pem"),
        leaf_key.serialize_pem().as_bytes(),
    )?;
    sync_dir(&temp)?;
    rename_exclusive(&temp, directory)?;
    drop(guard);
    sync_dir(parent)?;
    Ok(CertificateBundle {
        directory: directory.to_path_buf(),
        ca_cert: directory.join("host-ca.pem"),
        certificate: directory.join("host-cert.pem"),
        private_key: directory.join("host-key.pem"),
        ca_sha256: fingerprint,
        expires_at_unix: leaf_params.not_after.unix_timestamp(),
    })
}

pub fn initialize_token(path: &Path) -> Result<serde_json::Value> {
    let parent = checked_parent(path)?;
    let mut bytes = [0u8; 32];
    SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| invalid())?;
    let value = hex(&bytes);
    if !valid_token(value.as_bytes()) {
        return Err(invalid());
    }
    let tmp = temp_path(parent)?;
    write_file(&tmp, value.as_bytes())?;
    let guard = TempFile(tmp.clone());
    // hard_link is an atomic create-if-absent; it never replaces a target.
    std::fs::hard_link(&tmp, path).map_err(|_| invalid())?;
    std::fs::remove_file(&tmp).map_err(|_| invalid())?;
    drop(guard);
    sync_dir(parent)?;
    Ok(serde_json::json!({"created": true, "path": path}))
}
pub fn read_token(path: &Path) -> Result<SecretToken> {
    let bytes = private_files::read_credential(path, 64).map_err(|_| invalid())?;
    if !valid_token(&bytes) {
        return Err(invalid());
    }
    let mut token = [0; 64];
    token.copy_from_slice(&bytes);
    Ok(SecretToken(token))
}
fn read_certs(path: &Path) -> Result<Vec<CertificateDer<'static>>> {
    let bytes = private_files::read_public_cert(path, LIMIT).map_err(|_| invalid())?;
    let certs = CertificateDer::pem_slice_iter(&bytes)
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|_| invalid())?;
    if certs.is_empty() {
        return Err(invalid());
    }
    Ok(certs)
}
// Check at configuration load time; rustls still verifies peer chains, signatures,
// identities and leaf validity during each handshake.
fn check_validity(cert: &CertificateDer<'_>) -> Result<()> {
    let (remainder, parsed) =
        x509_parser::parse_x509_certificate(cert.as_ref()).map_err(|_| invalid())?;
    if !remainder.is_empty() || !parsed.validity().is_valid() {
        return Err(invalid());
    }
    Ok(())
}
pub fn server_config(cert: &Path, key: &Path) -> Result<Arc<rustls::ServerConfig>> {
    let certs = read_certs(cert)?;
    check_validity(&certs[0])?;
    let key_bytes = private_files::read_credential(key, LIMIT).map_err(|_| invalid())?;
    let key = PrivateKeyDer::from_pem_slice(&key_bytes).map_err(|_| invalid())?;
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = rustls::ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|_| invalid())?
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(|_| invalid())?;
    Ok(Arc::new(config))
}
pub fn client_config(ca: Option<&Path>) -> Result<Arc<rustls::ClientConfig>> {
    let certs = match ca {
        Some(path) => {
            let certs = read_certs(path)?;
            for cert in &certs {
                check_validity(cert)?;
            }
            certs
        }
        None => {
            let roots = rustls_native_certs::load_native_certs();
            if !roots.errors.is_empty() {
                return Err(invalid());
            }
            roots.certs
        }
    };
    let mut store = rustls::RootCertStore::empty();
    for cert in certs {
        store.add(cert).map_err(|_| invalid())?;
    }
    if store.is_empty() {
        return Err(invalid());
    }
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|_| invalid())?
        .with_root_certificates(store)
        .with_no_client_auth();
    Ok(Arc::new(config))
}
