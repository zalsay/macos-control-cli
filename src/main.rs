use copis_chrome::args::{self, Command};
use copis_chrome::mode::Mode;
use copis_chrome::protocol::{response_for, Error, Result};
use copis_chrome::remote::{client, credentials, host, options::HostCommand};
use serde_json::json;

fn main() {
    let scope = Mode::current_executable().scope();
    let parsed = std::env::args_os()
        .skip(1)
        .map(|arg| {
            arg.into_string()
                .map_err(|_| Error::invalid("参数必须为有效 UTF-8"))
        })
        .collect::<Result<Vec<_>>>()
        .and_then(|args| args::parse_for_scope(args, scope));
    let result = match parsed {
        Ok(Command::Help) => {
            let executable = std::env::args_os().next().unwrap_or_default();
            let program = std::path::Path::new(&executable)
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or_default();
            print!("{}", args::help_text(scope, program));
            return;
        }
        Ok(Command::Version) => Ok(json!({"version":env!("CARGO_PKG_VERSION")})),
        Ok(Command::Host(command)) => match command {
            HostCommand::TlsInit { sans, output_dir } => credentials::initialize_tls(&sans, &output_dir).map(|bundle| json!({"directory":bundle.directory,"caCert":bundle.ca_cert,"certificate":bundle.certificate,"privateKey":bundle.private_key,"caSha256":bundle.ca_sha256,"expiresAtUnix":bundle.expires_at_unix})),
            HostCommand::TokenInit { output } => credentials::initialize_token(&output),
            HostCommand::Start(options) => host::run(options, scope),
            HostCommand::Recover { state_dir } => host::recover(state_dir, scope),
        },
        Ok(Command::Remote { options, command }) => match *command {
            Command::Request { request, output } => client::run(options, request, output, scope),
            _ => Err(Error::invalid("远程只允许请求命令")),
        },
        Ok(command) => copis_chrome::execution::execute_local(command, scope),
        Err(error) => Err(error),
    };
    let failed = result.is_err();
    println!("{}", response_for(result, scope));
    if failed {
        std::process::exit(1);
    }
}
