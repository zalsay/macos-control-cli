use copis_chrome::remote::credentials::{initialize_tls, initialize_token, read_token};
use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};
use std::path::PathBuf;

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let p = std::env::temp_dir().join(format!(
            "mcc-remote-test-{}",
            copis_chrome::protocol::random_id().unwrap()
        ));
        std::fs::create_dir(&p).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o700)).unwrap();
        Self(p)
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn tls_rejects_existing_target_and_invalid_names_without_overwriting() {
    let f = Fixture::new();
    let target = f.0.join("existing");
    std::fs::write(&target, b"unchanged").unwrap();
    assert!(initialize_tls(&["127.0.0.1".into()], &target).is_err());
    assert_eq!(std::fs::read(&target).unwrap(), b"unchanged");
    assert!(initialize_tls(&[], &f.0.join("empty")).is_err());
    assert!(initialize_tls(&["bad name".into()], &f.0.join("invalid")).is_err());
    assert!(initialize_tls(&vec!["localhost".into(); 9], &f.0.join("many")).is_err());
}

#[test]
fn token_is_private_redacted_and_never_overwritten() {
    let f = Fixture::new();
    let path = f.0.join("token");
    let receipt = initialize_token(&path).unwrap();
    let token = read_token(&path).unwrap();
    let value = token.header_value();
    assert_eq!(value.len(), 64);
    assert!(token.matches(value.as_bytes()));
    let mut wrong = value.as_bytes().to_vec();
    wrong[0] = if wrong[0] == b'0' { b'1' } else { b'0' };
    assert!(!token.matches(&wrong));
    assert!(!token.matches(b"wrong"));
    let second = f.0.join("second-token");
    initialize_token(&second).unwrap();
    assert_ne!(value, read_token(&second).unwrap().header_value());
    assert_eq!(std::fs::metadata(&path).unwrap().uid(), unsafe {
        libc::geteuid()
    });
    assert!(!format!("{token:?}").contains(&value));
    assert!(!receipt.to_string().contains(&value));
    assert_eq!(
        std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert!(initialize_token(&path).is_err());
    assert_eq!(read_token(&path).unwrap().header_value(), value);
    let link = f.0.join("link");
    symlink(&path, &link).unwrap();
    assert!(read_token(&link).is_err());
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(read_token(&path).is_err());
}

#[test]
fn initialized_certificate_files_are_private_and_include_separate_keys() {
    let f = Fixture::new();
    let target = f.0.join("tls");
    let bundle = initialize_tls(&["127.0.0.1".into(), "localhost".into()], &target).unwrap();
    assert_eq!(bundle.directory, target);
    assert_eq!(
        std::fs::metadata(&target).unwrap().permissions().mode() & 0o777,
        0o700
    );
    for path in [
        &bundle.ca_cert,
        &bundle.certificate,
        &bundle.private_key,
        &target.join("host-ca-key.pem"),
    ] {
        let metadata = std::fs::symlink_metadata(path).unwrap();
        assert!(metadata.is_file());
        assert_eq!(metadata.uid(), unsafe { libc::geteuid() });
        assert_eq!(metadata.permissions().mode() & 0o077, 0);
    }
    assert_ne!(
        std::fs::read(&bundle.private_key).unwrap(),
        std::fs::read(target.join("host-ca-key.pem")).unwrap()
    );
    assert_eq!(bundle.ca_sha256.len(), 64);
    assert!(bundle.ca_sha256.bytes().all(|b| b.is_ascii_hexdigit()));
    assert!(bundle.expires_at_unix > 0);
}

#[test]
fn token_rejects_weak_oversized_symlink_fifo_and_permissive_parent() {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    unsafe extern "C" {
        fn mkfifo(path: *const std::ffi::c_char, mode: u32) -> i32;
    }
    let f = Fixture::new();
    let weak = f.0.join("weak");
    std::fs::write(&weak, b"short").unwrap();
    std::fs::set_permissions(&weak, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert!(read_token(&weak).is_err());
    std::fs::write(&weak, vec![b'a'; 1024 * 1024]).unwrap();
    assert!(read_token(&weak).is_err());
    let fifo = f.0.join("fifo");
    let fifo_c = CString::new(fifo.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { mkfifo(fifo_c.as_ptr(), 0o600) }, 0);
    assert!(read_token(&fifo).is_err());
    let link = f.0.join("missing-link");
    symlink(f.0.join("missing"), &link).unwrap();
    assert!(initialize_token(&link).is_err());
    let token = f.0.join("token");
    initialize_token(&token).unwrap();
    std::fs::set_permissions(&f.0, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(read_token(&token).is_err());
}

fn handshake(
    client: std::sync::Arc<rustls::ClientConfig>,
    server: std::sync::Arc<rustls::ServerConfig>,
    name: &str,
) -> Result<(), String> {
    use rustls::pki_types::ServerName;
    let name = ServerName::try_from(name.to_owned()).map_err(|_| "invalid name".to_owned())?;
    let mut c = rustls::ClientConnection::new(client, name).map_err(|e| e.to_string())?;
    let mut s = rustls::ServerConnection::new(server).map_err(|e| e.to_string())?;
    for _ in 0..32 {
        let mut data = Vec::new();
        c.write_tls(&mut data).map_err(|e| e.to_string())?;
        if !data.is_empty() {
            s.read_tls(&mut std::io::Cursor::new(data))
                .map_err(|e| e.to_string())?;
            s.process_new_packets().map_err(|e| e.to_string())?;
        }
        let mut data = Vec::new();
        s.write_tls(&mut data).map_err(|e| e.to_string())?;
        if !data.is_empty() {
            c.read_tls(&mut std::io::Cursor::new(data))
                .map_err(|e| e.to_string())?;
            c.process_new_packets().map_err(|e| e.to_string())?;
        }
        if !c.is_handshaking() && !s.is_handshaking() {
            return Ok(());
        }
    }
    Err("handshake did not complete within 32 rounds".into())
}

#[test]
fn tls_handshake_accepts_ip_and_dns_and_rejects_wrong_ca_name_and_key() {
    use copis_chrome::remote::credentials::{client_config, server_config};
    let f = Fixture::new();
    let good =
        initialize_tls(&["127.0.0.1".into(), "localhost".into()], &f.0.join("good")).unwrap();
    let other = initialize_tls(&["localhost".into()], &f.0.join("other")).unwrap();
    let server = server_config(&good.certificate, &good.private_key).unwrap();
    let client = client_config(Some(&good.ca_cert)).unwrap();
    assert!(handshake(client.clone(), server.clone(), "127.0.0.1").is_ok());
    assert!(handshake(client.clone(), server.clone(), "localhost").is_ok());
    assert!(handshake(client.clone(), server.clone(), "wrong.example").is_err());
    assert!(handshake(
        client_config(Some(&other.ca_cert)).unwrap(),
        server,
        "localhost"
    )
    .is_err());
    assert!(server_config(&good.certificate, &other.private_key).is_err());
}

#[test]
fn expired_certificate_is_rejected_by_real_tls_handshake() {
    use copis_chrome::remote::credentials::client_config;
    use rcgen::{
        BasicConstraints, CertificateParams, ExtendedKeyUsagePurpose, IsCa, Issuer, KeyPair,
        KeyUsagePurpose,
    };
    let f = Fixture::new();
    let now = time::OffsetDateTime::now_utc();
    let mut ca = CertificateParams::new(Vec::<String>::new()).unwrap();
    ca.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    ca.key_usages = vec![KeyUsagePurpose::KeyCertSign];
    ca.not_before = now - time::Duration::days(5);
    ca.not_after = now + time::Duration::days(5);
    let ca_key = KeyPair::generate().unwrap();
    let ca_cert = ca.self_signed(&ca_key).unwrap();
    let mut leaf = CertificateParams::new(vec!["localhost".into()]).unwrap();
    leaf.not_before = now - time::Duration::days(4);
    leaf.not_after = now - time::Duration::days(1);
    leaf.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
    let leaf_key = KeyPair::generate().unwrap();
    let leaf_cert = leaf
        .signed_by(&leaf_key, &Issuer::from_params(&ca, &ca_key))
        .unwrap();
    let ca_path = f.0.join("ca");
    let cert_path = f.0.join("cert");
    let key_path = f.0.join("key");
    for (path, data) in [
        (&ca_path, ca_cert.pem()),
        (&cert_path, leaf_cert.pem()),
        (&key_path, leaf_key.serialize_pem()),
    ] {
        std::fs::write(path, data).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
    // Construct this invalid server directly: the production loader must reject it,
    // but the client must still independently reject an expired peer at handshake.
    let provider = std::sync::Arc::new(rustls::crypto::ring::default_provider());
    let server = rustls::ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(
            vec![leaf_cert.der().clone()],
            rustls::pki_types::PrivatePkcs8KeyDer::from(leaf_key.serialize_der()).into(),
        )
        .unwrap();
    let result = handshake(
        client_config(Some(&ca_path)).unwrap(),
        std::sync::Arc::new(server),
        "localhost",
    );
    assert!(result.is_err());
    assert!(result.unwrap_err().to_lowercase().contains("expired"));
}

#[test]
fn concurrent_initialization_never_clobbers() {
    use std::sync::{Arc, Barrier};
    let f = Fixture::new();
    for is_tls in [false, true] {
        let target = f.0.join(if is_tls { "bundle-race" } else { "token-race" });
        let barrier = Arc::new(Barrier::new(8));
        let threads: Vec<_> = (0..8)
            .map(|_| {
                let path = target.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    if is_tls {
                        initialize_tls(&["localhost".into()], &path).is_ok()
                    } else {
                        initialize_token(&path).is_ok()
                    }
                })
            })
            .collect();
        assert_eq!(
            threads
                .into_iter()
                .map(|t| t.join().unwrap())
                .filter(|ok| *ok)
                .count(),
            1
        );
        if is_tls {
            assert!(copis_chrome::remote::credentials::server_config(
                &target.join("host-cert.pem"),
                &target.join("host-key.pem")
            )
            .is_ok());
        } else {
            assert!(read_token(&target).is_ok());
        }
    }
    assert!(std::fs::read_dir(&f.0).unwrap().all(|e| !e
        .unwrap()
        .file_name()
        .to_string_lossy()
        .starts_with(".mcc-remote-")));
}

#[test]
fn secret_input_and_errors_do_not_echo_data_and_hardlinks_are_rejected() {
    use copis_chrome::remote::credentials::{client_config, server_config};
    let f = Fixture::new();
    let token = f.0.join("token");
    initialize_token(&token).unwrap();
    let secret = read_token(&token).unwrap().header_value();
    let alias = f.0.join("alias");
    std::fs::hard_link(&token, &alias).unwrap();
    let error = read_token(&token).unwrap_err();
    assert!(!format!("{error:?} {error}").contains(&secret));
    let bad = f.0.join("bad");
    let sensitive = "-----BEGIN PRIVATE KEY-----\nSHOULD-NOT-LEAK\n-----END PRIVATE KEY-----";
    std::fs::write(&bad, sensitive).unwrap();
    std::fs::set_permissions(&bad, std::fs::Permissions::from_mode(0o600)).unwrap();
    let err = client_config(Some(&bad)).unwrap_err();
    assert!(!format!("{err:?} {err}").contains("SHOULD-NOT-LEAK"));
    assert!(server_config(&bad, &bad).is_err());
}

#[test]
fn obvious_weak_but_correct_length_tokens_are_rejected() {
    let f = Fixture::new();
    let path = f.0.join("weak-token");
    for value in ["0".repeat(64), "0123456789abcdef".repeat(4)] {
        std::fs::write(&path, value).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(read_token(&path).is_err());
    }
}

#[derive(Debug)]
struct FixedTime(u64);
impl rustls::time_provider::TimeProvider for FixedTime {
    fn current_time(&self) -> Option<rustls::pki_types::UnixTime> {
        Some(rustls::pki_types::UnixTime::since_unix_epoch(
            std::time::Duration::from_secs(self.0),
        ))
    }
}
#[test]
fn leaf_validity_is_90_days_from_issuance() {
    use copis_chrome::remote::credentials::{client_config, server_config};
    let f = Fixture::new();
    let start = time::OffsetDateTime::now_utc().unix_timestamp();
    let b = initialize_tls(&["localhost".into()], &f.0.join("tls")).unwrap();
    let end = time::OffsetDateTime::now_utc().unix_timestamp();
    assert!((start + 90 * 86400..=end + 90 * 86400).contains(&b.expires_at_unix));
    let base = client_config(Some(&b.ca_cert)).unwrap();
    let server = server_config(&b.certificate, &b.private_key).unwrap();
    let mut at_89 = (*base).clone();
    at_89.time_provider = std::sync::Arc::new(FixedTime((start + 89 * 86400) as u64));
    assert!(handshake(std::sync::Arc::new(at_89), server.clone(), "localhost").is_ok());
    let mut at_91 = (*base).clone();
    at_91.time_provider = std::sync::Arc::new(FixedTime((end + 91 * 86400) as u64));
    assert!(handshake(std::sync::Arc::new(at_91), server, "localhost").is_err());
}

#[test]
fn public_certificate_can_be_exported_with_public_read_permissions() {
    use copis_chrome::remote::credentials::{client_config, server_config};
    let f = Fixture::new();
    let b = initialize_tls(&["localhost".into()], &f.0.join("tls")).unwrap();
    let public = f.0.join("ca-export.pem");
    std::fs::copy(&b.ca_cert, &public).unwrap();
    std::fs::set_permissions(&public, std::fs::Permissions::from_mode(0o644)).unwrap();
    let client = client_config(Some(&public)).unwrap();
    assert!(handshake(
        client,
        server_config(&b.certificate, &b.private_key).unwrap(),
        "localhost"
    )
    .is_ok());
}

#[test]
fn generated_certificates_have_expected_ca_leaf_validity_and_extensions() {
    use rustls::pki_types::{pem::PemObject, CertificateDer};
    use x509_parser::prelude::*;
    let f = Fixture::new();
    let b = initialize_tls(&["127.0.0.1".into(), "localhost".into()], &f.0.join("tls")).unwrap();
    let ca_pem = std::fs::read(&b.ca_cert).unwrap();
    let leaf_pem = std::fs::read(&b.certificate).unwrap();
    let ca_der = CertificateDer::from_pem_slice(&ca_pem).unwrap();
    let leaf_der = CertificateDer::from_pem_slice(&leaf_pem).unwrap();
    let fingerprint = ring::digest::digest(&ring::digest::SHA256, ca_der.as_ref())
        .as_ref()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    assert_eq!(b.ca_sha256, fingerprint);
    let (_, ca) = parse_x509_certificate(ca_der.as_ref()).unwrap();
    let (_, leaf) = parse_x509_certificate(leaf_der.as_ref()).unwrap();
    assert_eq!(
        ca.validity().not_after.timestamp() - ca.validity().not_before.timestamp(),
        365 * 86400
    );
    assert_eq!(
        leaf.validity().not_after.timestamp() - leaf.validity().not_before.timestamp(),
        90 * 86400
    );
    assert!(ca.basic_constraints().unwrap().unwrap().value.ca);
    assert!(!leaf
        .basic_constraints()
        .unwrap()
        .map(|v| v.value.ca)
        .unwrap_or(false));
    assert!(
        leaf.extended_key_usage()
            .unwrap()
            .unwrap()
            .value
            .server_auth
    );
    let san = leaf.subject_alternative_name().unwrap().unwrap();
    assert!(san
        .value
        .general_names
        .iter()
        .any(|n| matches!(n, GeneralName::DNSName("localhost"))));
    assert!(san
        .value
        .general_names
        .iter()
        .any(|n| matches!(n, GeneralName::IPAddress(ip) if *ip == [127,0,0,1])));
}

#[test]
fn rejects_untrusted_file_types_parent_modes_and_preserves_existing_directory() {
    use copis_chrome::remote::credentials::{client_config, server_config};
    let f = Fixture::new();
    let existing = f.0.join("existing-dir");
    std::fs::create_dir(&existing).unwrap();
    std::fs::write(existing.join("marker"), "keep").unwrap();
    assert!(initialize_tls(&["localhost".into()], &existing).is_err());
    assert_eq!(std::fs::read(existing.join("marker")).unwrap(), b"keep");
    let link = f.0.join("linked-parent");
    symlink(&f.0, &link).unwrap();
    assert!(initialize_tls(&["localhost".into()], &link.join("tls")).is_err());
    assert!(initialize_token(&link.join("token")).is_err());
    let b = initialize_tls(&["localhost".into()], &f.0.join("tls")).unwrap();
    let alias = b.directory.join("cert-link");
    symlink(&b.certificate, &alias).unwrap();
    assert!(server_config(&alias, &b.private_key).is_err());
    let huge = b.directory.join("huge");
    std::fs::write(&huge, vec![b'x'; 65_537]).unwrap();
    std::fs::set_permissions(&huge, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert!(client_config(Some(&huge)).is_err());
    std::fs::set_permissions(&b.private_key, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(server_config(&b.certificate, &b.private_key).is_err());
}

fn time_shifted_self_signed(
    f: &Fixture,
    label: &str,
    ca: bool,
    before_days: i64,
    after_days: i64,
) -> (PathBuf, PathBuf) {
    use rcgen::{BasicConstraints, CertificateParams, IsCa, KeyPair, KeyUsagePurpose};
    let now = time::OffsetDateTime::now_utc();
    let mut params = CertificateParams::new(vec!["localhost".into()]).unwrap();
    params.not_before = now + time::Duration::days(before_days);
    params.not_after = now + time::Duration::days(after_days);
    if ca {
        params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        params.key_usages.push(KeyUsagePurpose::KeyCertSign);
    }
    let key = KeyPair::generate().unwrap();
    let cert = params.self_signed(&key).unwrap();
    let cert_path = f.0.join(format!("{label}-cert.pem"));
    let key_path = f.0.join(format!("{label}-key.pem"));
    for (path, data) in [(&cert_path, cert.pem()), (&key_path, key.serialize_pem())] {
        std::fs::write(path, data).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
    (cert_path, key_path)
}

#[test]
fn server_config_rejects_expired_leaf_before_listening() {
    let f = Fixture::new();
    let (cert, key) = time_shifted_self_signed(&f, "expired-leaf", false, -4, -1);
    let error = copis_chrome::remote::credentials::server_config(&cert, &key).unwrap_err();
    assert_eq!(error.code, "REMOTE_CREDENTIALS_INVALID");
    assert!(!format!("{error:?} {error}").contains("BEGIN"));
}
#[test]
fn server_config_rejects_not_yet_valid_leaf_before_listening() {
    let f = Fixture::new();
    let (cert, key) = time_shifted_self_signed(&f, "future-leaf", false, 1, 4);
    assert!(copis_chrome::remote::credentials::server_config(&cert, &key).is_err());
}
#[test]
fn client_config_rejects_expired_explicit_ca_before_use() {
    let f = Fixture::new();
    let (cert, _) = time_shifted_self_signed(&f, "expired-ca", true, -4, -1);
    let error = copis_chrome::remote::credentials::client_config(Some(&cert)).unwrap_err();
    assert_eq!(error.code, "REMOTE_CREDENTIALS_INVALID");
    assert!(!format!("{error:?} {error}").contains("BEGIN"));
}
#[test]
fn client_config_rejects_not_yet_valid_explicit_ca_before_use() {
    let f = Fixture::new();
    let (cert, _) = time_shifted_self_signed(&f, "future-ca", true, 1, 4);
    assert!(copis_chrome::remote::credentials::client_config(Some(&cert)).is_err());
}
