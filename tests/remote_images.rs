use copis_chrome::remote::images::{load_frame, save_frame};
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::PathBuf;
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let p = std::env::temp_dir().join(format!(
            "mcc-image-{}",
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
fn frame_roundtrip_rejects_tamper_and_conflicts() {
    let f = Fixture::new();
    let path = f.0.join("frame.jpg");
    // Minimal structurally framed JPEG: SOI, SOF (1x1), SOS, entropy byte, EOI.
    let jpeg = [
        0xff, 0xd8, 0xff, 0xc0, 0, 11, 8, 0, 1, 0, 1, 1, 1, 0x11, 0, 0xff, 0xda, 0, 8, 1, 1, 0, 0,
        63, 0, 0, 0xff, 0xd9,
    ];
    std::fs::write(&path, jpeg).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let (manifest, bytes) = load_frame(&f.0, "request", "frame").unwrap();
    let out = f.0.join("out.jpg");
    assert_eq!(
        save_frame(&manifest, &bytes, Some(out.clone()), &f.0).unwrap(),
        out
    );
    assert_eq!(
        std::fs::metadata(&out).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let error = save_frame(&manifest, &bytes, Some(out.clone()), &f.0).unwrap_err();
    assert_eq!(error.code, "OUTPUT_EXISTS");
    assert_eq!(std::fs::read(&out).unwrap(), bytes);
    let mut corrupt = bytes.clone();
    corrupt[10] ^= 1;
    assert!(save_frame(&manifest, &corrupt, Some(f.0.join("bad")), &f.0).is_err());
    assert!(!f.0.join("bad").exists());
    assert!(load_frame(&f.0, "request", "../frame").is_err());
    std::fs::hard_link(&path, f.0.join("hard")).unwrap();
    assert!(load_frame(&f.0, "request", "frame").is_err());
    std::fs::remove_file(f.0.join("hard")).unwrap();
    std::fs::remove_file(&path).unwrap();
    symlink(&out, &path).unwrap();
    assert!(load_frame(&f.0, "request", "frame").is_err());
}
#[test]
fn rejects_invalid_data_size_and_permissions() {
    let f = Fixture::new();
    let path = f.0.join("f.jpg");
    for data in [vec![0; 20], vec![0; 1024 * 1024]] {
        std::fs::write(&path, data).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(load_frame(&f.0, "r", "f").is_err());
    }
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(load_frame(&f.0, "r", "f").is_err());
}
#[test]
fn rejects_invalid_manifest_truncation_and_insecure_directories() {
    let f = Fixture::new();
    let path = f.0.join("f.jpg");
    let jpeg = [
        0xff, 0xd8, 0xff, 0xc0, 0, 11, 8, 0, 1, 0, 1, 1, 1, 0x11, 0, 0xff, 0xda, 0, 8, 1, 1, 0, 0,
        63, 0, 0, 0xff, 0xd9,
    ];
    std::fs::write(&path, jpeg).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let (mut manifest, bytes) = load_frame(&f.0, "r", "f").unwrap();
    let cached = save_frame(&manifest, &bytes, None, &f.0).unwrap();
    assert!(cached.starts_with(&f.0));
    assert!(save_frame(
        &manifest,
        &bytes[..bytes.len() - 1],
        Some(f.0.join("partial")),
        &f.0
    )
    .is_err());
    assert!(!f.0.join("partial").exists());
    manifest.sha256 = "0".repeat(64);
    assert!(save_frame(&manifest, &bytes, None, &f.0).is_err());
    std::fs::set_permissions(&f.0, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(load_frame(&f.0, "r", "f").is_err());
    std::fs::set_permissions(&f.0, std::fs::Permissions::from_mode(0o700)).unwrap();
    let link = f.0.join("dir-link");
    symlink(&f.0, &link).unwrap();
    assert!(load_frame(&link, "r", "f").is_err());
}

#[test]
fn rejects_oversize_jpeg_dimensions_and_structurally_broken_data() {
    let f = Fixture::new();
    let path = f.0.join("f.jpg");
    let mut jpeg = [
        0xff, 0xd8, 0xff, 0xc0, 0, 11, 8, 0, 1, 0, 1, 1, 1, 0x11, 0, 0xff, 0xda, 0, 8, 1, 1, 0, 0,
        63, 0, 0, 0xff, 0xd9,
    ];
    jpeg[9] = 6;
    jpeg[10] = 65; // width 1601
    std::fs::write(&path, jpeg).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert!(load_frame(&f.0, "r", "f").is_err());
    jpeg[9] = 0;
    jpeg[10] = 1;
    jpeg[26] = 0;
    std::fs::write(&path, jpeg).unwrap();
    assert!(load_frame(&f.0, "r", "f").is_err());
}
