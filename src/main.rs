use copis_chrome::args::{self, Command};
use copis_chrome::protocol::{response, Error, Result};
use serde_json::{json, Value};

fn main() {
    let parsed = std::env::args_os()
        .skip(1)
        .map(|arg| {
            arg.into_string()
                .map_err(|_| Error::invalid("参数必须为有效 UTF-8"))
        })
        .collect::<Result<Vec<_>>>()
        .and_then(args::parse);
    let result = match parsed {
        Ok(Command::Help) => {
            print!("{}", args::HELP);
            return;
        }
        Ok(Command::Version) => Ok(json!({"version":env!("CARGO_PKG_VERSION")})),
        Ok(command) => execute(command),
        Err(error) => Err(error),
    };
    let failed = result.is_err();
    println!("{}", response(result));
    if failed {
        std::process::exit(1);
    }
}
#[cfg(unix)]
fn execute(command: Command) -> Result<Value> {
    use copis_chrome::{
        daemon,
        runtime::{export_image, Runtime},
    };
    if !cfg!(target_os = "macos") {
        return Err(Error::new(
            "UNSUPPORTED_PLATFORM",
            "Chrome 桌面自动化仅支持 macOS 14 及以上版本",
        ));
    }
    let runtime = Runtime::from_env()?;
    match command {
        Command::Daemon(subcommand) => match subcommand.as_str() {
            "start" => daemon::start(&runtime),
            "stop" => daemon::stop(&runtime),
            "status" => daemon::status(&runtime),
            "run" => daemon::run(&runtime),
            _ => unreachable!(),
        },
        Command::Request { request, output } => {
            if request["action"] == "status" {
                return daemon::status(&runtime);
            }
            daemon::start(&runtime)?;
            let mut result = daemon::call(&runtime, request)?;
            if let Some(output) = output {
                let source = result["imagePath"]
                    .as_str()
                    .ok_or_else(|| Error::new("PROTOCOL_ERROR", "观察结果缺少截图路径"))?;
                result["imagePath"] = json!(export_image(std::path::Path::new(source), &output)?);
            }
            Ok(result)
        }
        Command::Help | Command::Version => unreachable!(),
    }
}
#[cfg(not(unix))]
fn execute(_: Command) -> Result<Value> {
    Err(Error::new(
        "UNSUPPORTED_PLATFORM",
        "Chrome 桌面自动化仅支持 macOS 14 及以上版本",
    ))
}
