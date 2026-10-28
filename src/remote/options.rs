use std::net::SocketAddr;
use std::path::PathBuf;

#[derive(Clone, Debug)]
pub struct HostOptions {
    pub listen: SocketAddr,
    pub tls_cert: PathBuf,
    pub tls_key: PathBuf,
    pub token_file: PathBuf,
    pub state_dir: Option<PathBuf>,
    pub allowed_file_roots: Vec<PathBuf>,
}
#[derive(Clone)]
pub struct ClientOptions {
    pub url: String,
    pub ca_cert: Option<PathBuf>,
    pub token_file: PathBuf,
    pub state_dir: Option<PathBuf>,
}
#[derive(Clone, Debug)]
pub enum HostCommand {
    TlsInit {
        sans: Vec<String>,
        output_dir: PathBuf,
    },
    TokenInit {
        output: PathBuf,
    },
    Start(HostOptions),
    Recover {
        state_dir: Option<PathBuf>,
    },
}

impl std::fmt::Debug for ClientOptions {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ClientOptions")
            .field("url", &"[REDACTED]")
            .field("ca_cert", &self.ca_cert)
            .field("token_file", &self.token_file)
            .field("state_dir", &self.state_dir)
            .finish()
    }
}
