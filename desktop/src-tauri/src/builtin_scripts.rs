use crate::store::{Result, Settings, Store};
use serde::Serialize;
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    path::Path,
};

#[derive(Serialize)]
pub struct GeneratedCommand {
    pub command: String,
    pub note: String,
}

fn client_remote(address: IpAddr, port: u16) -> String {
    let remote_ip = match address {
        IpAddr::V4(address) if address.is_unspecified() => IpAddr::V4(Ipv4Addr::LOCALHOST),
        IpAddr::V6(address) if address.is_unspecified() => IpAddr::V6(Ipv6Addr::LOCALHOST),
        address => address,
    };
    format!("wss://{}/mcc/v1", SocketAddr::new(remote_ip, port))
}

pub fn wechat_login_command(store: &Store, source: &str) -> Result<GeneratedCommand> {
    let settings = store.settings()?;
    let host = &settings.host;
    if host.port == 0 {
        return Err("Host 端口无效，请保存有效的 Host 配置。".into());
    }
    let wildcard = host.address.is_unspecified();
    // Map a wildcard listener only to the same-family loopback client address.
    // TLS remains verified; the user may substitute the matching certificate SAN.
    let remote = client_remote(host.address, host.port);
    let mcc = settings.bin_dir.join("mcc");
    if !mcc.is_absolute() || !mcc.is_file() {
        return Err("所选构建包中未找到 MCC CLI，请在 Host 页选择并保存完整构建包目录。".into());
    }
    if !host.token_file.is_absolute() || !host.token_file.is_file() {
        return Err(
            "已保存的 Host token 文件不存在或路径无效，请在 Host 页选择有效文件并保存。".into(),
        );
    }

    let runner = store.materialize_wechat_login_runner(source)?;
    let remote_state = store.wechat_login_remote_state_dir()?;
    let ca = host
        .certificate
        .parent()
        .map(|parent| parent.join("host-ca.pem"))
        .filter(|path| path.is_file());
    let command = render_wechat_login_command(
        &settings,
        &remote,
        &mcc,
        &runner,
        ca.as_deref(),
        &remote_state,
    )?;
    let note = if ca.is_some() && wildcard {
        "默认命令仅输出 --plan。检查计划后才可在终端将 --plan 改为 --execute；Panel 不会运行流程。通配监听用本机回环地址作为客户端入口；若证书 SAN 不匹配，只将 --remote 改为证书中的主机名/IP，勿更改 Host 监听配置。"
    } else if ca.is_some() {
        "默认命令仅输出 --plan。检查计划后才可在终端将 --plan 改为 --execute；Panel 不会运行流程。若证书 SAN 与 --remote 不符，只将 --remote 改为证书中的主机名/IP，勿更改 Host 监听配置。"
    } else {
        "未找到 TLS 证书同目录的 host-ca.pem。命令保留系统 TLS 校验且默认只输出 --plan；先安全提供 CA 或配置系统信任，勿关闭证书校验。若 SAN 与 --remote 不符，只修改命令地址为证书中的主机名/IP，勿更改 Host 监听配置。检查计划后才可在终端改为 --execute。"
    };
    Ok(GeneratedCommand {
        command,
        note: note.into(),
    })
}

fn render_wechat_login_command(
    settings: &Settings,
    remote: &str,
    mcc: &Path,
    runner: &Path,
    ca: Option<&Path>,
    remote_state: &Path,
) -> Result<String> {
    if !mcc.is_absolute()
        || !runner.is_absolute()
        || !settings.host.token_file.is_absolute()
        || !remote_state.is_absolute()
        || ca.is_some_and(|path| !path.is_absolute())
    {
        return Err("生成 CLI 命令需要绝对路径。".into());
    }
    let mut args = vec![
        "python3".to_owned(),
        shell_quote(runner),
        "--mcc".into(),
        shell_quote(mcc),
        "--remote".into(),
        shell_quote(Path::new(remote)),
        "--step-delay".into(),
        "1.5".into(),
    ];
    if let Some(ca) = ca {
        args.extend(["--ca-cert".into(), shell_quote(ca)]);
    }
    args.extend([
        "--token-file".into(),
        shell_quote(&settings.host.token_file),
        "--remote-state-dir".into(),
        shell_quote(remote_state),
        "--plan".into(),
    ]);
    Ok(args.join(" "))
}

fn shell_quote(path: &Path) -> String {
    format!("'{}'", path.to_string_lossy().replace('\'', "'\"'\"'"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::HostConfig;
    use std::{
        net::{IpAddr, Ipv4Addr, Ipv6Addr},
        path::PathBuf,
    };

    fn settings(address: IpAddr) -> Settings {
        Settings {
            bin_dir: PathBuf::from("/opt/MCC/bin"),
            host: HostConfig {
                address,
                port: 8765,
                certificate: PathBuf::from("/config/tls/host-cert.pem"),
                private_key: PathBuf::from("/config/tls/host-key.pem"),
                token_file: PathBuf::from("/config/host.token"),
            },
        }
    }

    #[test]
    fn command_uses_configured_binary_endpoint_ca_token_and_private_state() {
        let settings = settings(IpAddr::V4(Ipv4Addr::new(192, 168, 1, 8)));
        let ca = PathBuf::from("/config/tls/host-ca.pem");
        let command = render_wechat_login_command(
            &settings,
            "wss://192.168.1.8:8765/mcc/v1",
            Path::new("/opt/MCC/bin/mcc"),
            Path::new("/config/control-panel/builtins/wechat-channels-login.py"),
            Some(&ca),
            Path::new("/config/control-panel/remote-state/wechat-channels-login"),
        )
        .unwrap();
        assert!(command.starts_with("python3 "));
        assert!(command.contains("--mcc '/opt/MCC/bin/mcc'"));
        assert!(command.contains("--remote 'wss://192.168.1.8:8765/mcc/v1'"));
        assert!(command.contains("--ca-cert '/config/tls/host-ca.pem'"));
        assert!(command.contains("--token-file '/config/host.token'"));
        assert!(command.contains("--step-delay 1.5"));
        assert!(command.contains(
            "--remote-state-dir '/config/control-panel/remote-state/wechat-channels-login'"
        ));
        assert!(command.ends_with("--plan"));
        assert!(!command.contains("token-secret"));
    }

    #[test]
    fn command_shell_quotes_paths_and_keeps_default_tls_verification() {
        let mut settings = settings(IpAddr::V4(Ipv4Addr::LOCALHOST));
        settings.host.token_file = PathBuf::from("/Users/sisu/token's file");
        let command = render_wechat_login_command(
            &settings,
            "wss://127.0.0.1:8765/mcc/v1",
            Path::new("/Applications/MCC user's bin/mcc"),
            Path::new("/tmp/built-in's runner.py"),
            None,
            Path::new("/tmp/panel/remote state"),
        )
        .unwrap();
        assert!(command.contains("'/tmp/built-in'\"'\"'s runner.py'"));
        assert!(command.contains(r#"'/Applications/MCC user'"'"'s bin/mcc'"#));
        assert!(command.contains("'/Users/sisu/token'\"'\"'s file'"));
        assert!(!command.contains("--ca-cert"));
        assert!(!command.contains("insecure"));
        assert!(command.ends_with("--plan"));
        assert!(!command.contains("--execute"));
    }

    #[test]
    fn wildcard_bind_uses_local_client_address_without_changing_host_settings() {
        for (bind, expected) in [
            (
                IpAddr::V4(Ipv4Addr::UNSPECIFIED),
                "wss://127.0.0.1:8765/mcc/v1",
            ),
            (IpAddr::V6(Ipv6Addr::UNSPECIFIED), "wss://[::1]:8765/mcc/v1"),
        ] {
            let settings = settings(bind);
            assert_eq!(
                client_remote(settings.host.address, settings.host.port),
                expected
            );
            assert_eq!(
                settings.host.address, bind,
                "Host binding must remain unchanged"
            );
        }
    }

    #[test]
    fn socket_address_formats_ipv6_for_the_remote_url() {
        let endpoint = format!(
            "wss://{}/mcc/v1",
            SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), 8765)
        );
        assert_eq!(endpoint, "wss://[::1]:8765/mcc/v1");
    }
}
