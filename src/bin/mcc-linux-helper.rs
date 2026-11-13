#[cfg(target_os = "linux")]
fn main() {
    if let Err(error) = copis_chrome::linux::run() {
        eprintln!("{}", error.code);
        std::process::exit(1);
    }
}
#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("mcc-linux-helper requires Linux");
    std::process::exit(1);
}
