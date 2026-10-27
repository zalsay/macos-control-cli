use copis_chrome::args::{self, Command};
use copis_chrome::mode::Mode;
use copis_chrome::protocol::{response_for, Error, Result, Scope};
use serde_json::{json, Value};

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
        Ok(command) => execute(command, scope),
        Err(error) => Err(error),
    };
    let failed = result.is_err();
    println!("{}", response_for(result, scope));
    if failed {
        std::process::exit(1);
    }
}
#[cfg(unix)]
fn execute(command: Command, scope: Scope) -> Result<Value> {
    use copis_chrome::{
        daemon,
        runtime::{export_image, Runtime},
    };
    if let Command::Config(args) = command {
        return copis_chrome::config::Store::from_env()?.execute(&args, std::io::stdin().lock());
    }
    if !cfg!(target_os = "macos") {
        return Err(Error::new(
            "UNSUPPORTED_PLATFORM",
            "桌面自动化仅支持 macOS 14 及以上版本",
        ));
    }
    let runtime = Runtime::from_env_for_scope(scope)?;
    match command {
        Command::Daemon(subcommand) => match subcommand.as_str() {
            "start" => daemon::start(&runtime),
            "stop" => daemon::stop(&runtime),
            "status" => daemon::status(&runtime),
            "run" => daemon::run(&runtime),
            _ => unreachable!(),
        },
        Command::Request {
            mut request,
            output,
        } => {
            if request["action"] == "click-target" {
                let model = copis_chrome::config::Store::from_env()?
                    .resolve_model(request.get("jevKey").and_then(Value::as_str))?;
                request["jevKey"] = json!(model.api_key);
                request["jevUrl"] = json!(model.url);
                request["jevModel"] = json!(model.model);
                request["jevProtocol"] = json!(copis_chrome::jev::DECISION_PROTOCOL);
            }
            if request["action"] == "chrome-start" {
                request["maxWidthPx"] =
                    json!(copis_chrome::config::Store::from_env()?.window_max_width()?);
            }
            if request["action"] == "status" {
                return daemon::status(&runtime);
            }
            daemon::start(&runtime)?;
            if request["action"] == "click-target"
                || request["action"] == "chrome-start"
                || request["action"] == "permissions"
            {
                // Reuse the version gate for new startup protocol, and authenticate
                // dynamic endpoint support before any per-call key is sent.
                let status = daemon::call(&runtime, json!({"action":"status"}))?;
                let incompatible_decisions = request["action"] == "click-target"
                    && (status["jev"]["protocol"] != copis_chrome::jev::DECISION_PROTOCOL
                        || status["jev"]["dynamicEndpoint"] != true);
                if status["version"] != env!("CARGO_PKG_VERSION") || incompatible_decisions {
                    return Err(Error::new("DAEMON_UPGRADE_REQUIRED", "现有 daemon 版本或动态 Decisions 配置契约不匹配；尚未发送密钥、请求授权或创建窗口，请仅结束自己持有的旧 daemon 后重新连接"));
                }
            }
            let mut result = daemon::call(&runtime, request)?;
            if let Some(output) = output {
                let source = result["imagePath"]
                    .as_str()
                    .ok_or_else(|| Error::new("PROTOCOL_ERROR", "观察结果缺少截图路径"))?;
                result["imagePath"] = json!(export_image(std::path::Path::new(source), &output)?);
            }
            Ok(result)
        }
        Command::Help | Command::Version | Command::Config(_) => unreachable!(),
    }
}
#[cfg(not(unix))]
fn execute(_: Command, _: Scope) -> Result<Value> {
    Err(Error::new(
        "UNSUPPORTED_PLATFORM",
        "桌面自动化仅支持 macOS 14 及以上版本",
    ))
}
