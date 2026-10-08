use crate::storage::{Result, Store};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    ffi::OsString,
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    process::{Child, Command},
    time::timeout,
};

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Quota {
    pub id: String,
    pub is_unlimited_entitlement: bool,
    pub entitlement_requests: f64,
    pub used_requests: f64,
    pub remaining_percentage: f64,
    pub reset_date: Option<String>,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    pub login: String,
    pub plan: Option<String>,
    pub quotas: Vec<Quota>,
    pub observed_at: f64,
    pub runtime_version: String,
}

#[derive(Clone, Default, PartialEq, Serialize)]
#[serde(tag = "status", rename_all = "camelCase")]
pub enum Authentication {
    #[default]
    Unknown,
    SignedOut,
    SignedIn {
        login: String,
        plan: Option<String>,
    },
}

impl Authentication {
    pub fn parse(value: &Value) -> Result<Self> {
        match value["isAuthenticated"].as_bool() {
            Some(false) => Ok(Self::SignedOut),
            Some(true) => Ok(Self::SignedIn {
                login: value["login"]
                    .as_str()
                    .filter(|login| !login.is_empty() && login.len() <= 100)
                    .ok_or("Copilot returned an unsupported account identity.")?
                    .into(),
                plan: value["copilotPlan"].as_str().map(str::to_owned),
            }),
            None => Err("Copilot returned an unsupported authentication status.".into()),
        }
    }
}

pub struct Snapshot {
    pub authentication: Authentication,
    pub quota: Result<Account>,
    /// True when the identity came from the user's own Copilot CLI sign-in
    /// rather than Tokenotch's private account home.
    pub shared: bool,
}

#[derive(Clone, Copy)]
enum Mode<'a> {
    Login,
    Private,
    Shared(&'a Path),
}

/// Ordered locations where the official Copilot CLI is commonly installed.
pub fn candidates(path: Option<OsString>, local: Option<PathBuf>) -> Vec<PathBuf> {
    let mut found = Vec::new();
    if let Some(path) = path {
        found.extend(std::env::split_paths(&path).map(|dir| dir.join("copilot.exe")));
    }
    if let Some(local) = local.filter(|v| v.is_absolute()) {
        let winget = local.join("Microsoft").join("WinGet");
        found.push(winget.join("Links").join("copilot.exe"));
        if let Ok(entries) = std::fs::read_dir(winget.join("Packages")) {
            let mut packages: Vec<_> = entries
                .flatten()
                .filter(|entry| {
                    entry
                        .file_name()
                        .to_string_lossy()
                        .to_ascii_lowercase()
                        .starts_with("github.copilot")
                })
                .map(|entry| entry.path().join("copilot.exe"))
                .collect();
            packages.sort();
            found.extend(packages);
        }
        found.push(local.join("Programs").join("copilot").join("copilot.exe"));
    }
    let mut unique = Vec::new();
    for path in found {
        if path.is_absolute() && !unique.contains(&path) {
            unique.push(path);
        }
    }
    unique
}

fn validate(executable: &Path) -> Result<()> {
    if !executable.is_absolute()
        || !executable.is_file()
        || cfg!(windows)
            && executable
                .extension()
                .is_none_or(|v| !v.eq_ignore_ascii_case("exe"))
    {
        return Err("Select an installed official Copilot CLI .exe, not a shell script.".into());
    }
    crate::storage::no_links(executable)
}

/// Finds the official Copilot CLI and confirms its identity with `--version`.
pub async fn detect_cli() -> Option<PathBuf> {
    for candidate in candidates(
        std::env::var_os("PATH"),
        std::env::var_os("LOCALAPPDATA").map(PathBuf::from),
    ) {
        if validate(&candidate).is_err() {
            continue;
        }
        let mut command = Command::new(&candidate);
        command
            .args(["--version"])
            .env_clear()
            .kill_on_drop(true)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        for name in [
            "SystemRoot",
            "WINDIR",
            "USERPROFILE",
            "LOCALAPPDATA",
            "APPDATA",
            "TEMP",
            "TMP",
        ] {
            if let Some(value) = std::env::var_os(name) {
                command.env(name, value);
            }
        }
        #[cfg(windows)]
        command.creation_flags(0x08000000);
        let Ok(Ok(output)) = timeout(Duration::from_secs(15), command.output()).await else {
            continue;
        };
        if output.status.success()
            && String::from_utf8_lossy(&output.stdout).contains("GitHub Copilot CLI")
        {
            return Some(candidate);
        }
    }
    None
}

pub fn parse(identity: &Value, quota: &Value, version: &str, now: f64) -> Result<Account> {
    if identity["isAuthenticated"] != true {
        return Err("Sign in to GitHub through the official Copilot CLI.".into());
    }
    let login = identity["login"]
        .as_str()
        .filter(|v| !v.is_empty() && v.len() <= 100)
        .ok_or("Copilot returned an unsupported account identity.")?;
    let snapshots = quota["quotaSnapshots"]
        .as_object()
        .filter(|v| v.len() <= 20)
        .ok_or("Copilot returned an unsupported quota response.")?;
    let mut quotas = Vec::new();
    for (id, value) in snapshots {
        if id.len() > 64 || !id.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_') {
            return Err("Copilot returned an unsupported quota identifier.".into());
        }
        let mut value = value.clone();
        value["id"] = json!(id);
        let quota: Quota = serde_json::from_value(value)
            .map_err(|_| "Copilot returned unsupported quota fields.")?;
        if !quota.used_requests.is_finite()
            || quota.used_requests < 0.0
            || !quota.entitlement_requests.is_finite()
            || quota.entitlement_requests
                < if quota.is_unlimited_entitlement {
                    -1.0
                } else {
                    0.0
                }
            || !quota.remaining_percentage.is_finite()
            || !(0.0..=100.0).contains(&quota.remaining_percentage)
        {
            return Err("Copilot returned invalid quota counts.".into());
        }
        quotas.push(quota);
    }
    quotas.sort_by_key(|q| (q.id != "premium_interactions", q.id.clone()));
    Ok(Account {
        login: login.into(),
        plan: identity["copilotPlan"].as_str().map(str::to_owned),
        quotas,
        observed_at: now,
        runtime_version: version.into(),
    })
}

fn child(executable: &Path, store: &Store, mode: Mode) -> Result<Child> {
    validate(executable)?;
    let login = matches!(mode, Mode::Login);
    let private = Store::open(store.root().join("account"))?;
    let gh = Store::open(private.root().join("gh-disabled"))?;
    let mut command = Command::new(executable);
    command.args(if login {
        vec![
            "--no-auto-update",
            "--log-level",
            "none",
            "login",
            "--web-flow",
        ]
    } else {
        vec![
            "--headless",
            "--stdio",
            "--no-auto-update",
            "--log-level",
            "none",
        ]
    });
    command
        .env_clear()
        .current_dir(private.root())
        .kill_on_drop(true)
        .stdin(if login { Stdio::null() } else { Stdio::piped() })
        .stdout(if login { Stdio::null() } else { Stdio::piped() })
        .stderr(Stdio::null());
    for name in [
        "SystemRoot",
        "WINDIR",
        "USERPROFILE",
        "LOCALAPPDATA",
        "APPDATA",
        "TEMP",
        "TMP",
        "PATH",
    ] {
        if let Some(value) = std::env::var_os(name) {
            command.env(name, value);
        }
    }
    if let Mode::Shared(home) = mode {
        // Read-only account RPCs against the user's own CLI sign-in; the CLI keeps
        // its credentials and Tokenotch never receives a token.
        crate::storage::no_links(home)?;
        command.env("COPILOT_HOME", home);
    } else {
        command
            .env("COPILOT_HOME", private.root())
            .env("GH_CONFIG_DIR", gh.root());
    }
    command.env("TERM", "dumb");
    #[cfg(windows)]
    command.creation_flags(0x08000000);
    command
        .spawn()
        .map_err(|_| "The selected Copilot CLI could not be started.".into())
}

pub async fn sign_in(executable: &Path, store: &Store) -> Result<()> {
    let mut process = child(executable, store, Mode::Login)?;
    let status = timeout(Duration::from_secs(180), process.wait())
        .await
        .map_err(|_| "GitHub sign-in timed out; retry from Connections.")?
        .map_err(|_| "GitHub sign-in could not complete.")?;
    if !status.success() {
        return Err("GitHub sign-in did not finish. Check the browser and retry.".into());
    }
    Ok(())
}

/// Queries Tokenotch's private sign-in and, when signed out there, the user's
/// existing Copilot CLI sign-in. `prefer_shared` reorders the attempts so the
/// usual source is queried first.
pub async fn snapshot(
    executable: &Path,
    store: &Store,
    shared_home: Option<&Path>,
    prefer_shared: bool,
) -> Result<Snapshot> {
    let Some(home) = shared_home else {
        return query(executable, store, Mode::Private).await;
    };
    let order = if prefer_shared {
        [Mode::Shared(home), Mode::Private]
    } else {
        [Mode::Private, Mode::Shared(home)]
    };
    let first = query(executable, store, order[0]).await;
    if first
        .as_ref()
        .is_ok_and(|v| v.authentication != Authentication::SignedOut)
    {
        return first;
    }
    match query(executable, store, order[1]).await {
        Ok(second) if second.authentication != Authentication::SignedOut => Ok(second),
        // Neither source is signed in: report Tokenotch's private state.
        second if prefer_shared => second.or(first),
        second => first.or(second),
    }
}

async fn query(executable: &Path, store: &Store, mode: Mode<'_>) -> Result<Snapshot> {
    let shared = matches!(mode, Mode::Shared(_));
    let mut process = child(executable, store, mode)?;
    let result = timeout(Duration::from_secs(25), async {
        let status = rpc(&mut process, 1, "status.get").await?;
        if ![Some(2), Some(3)].contains(&status["protocolVersion"].as_u64()) {
            return Err("This Copilot CLI uses an unsupported account protocol.".into());
        }
        let identity = rpc(&mut process, 2, "auth.getStatus").await?;
        let authentication = Authentication::parse(&identity)?;
        if authentication == Authentication::SignedOut {
            return Ok(Snapshot {
                authentication,
                quota: Err("Sign in to GitHub to display account quota.".into()),
                shared,
            });
        }
        let quota = rpc(&mut process, 3, "account.getQuota").await;
        let confirmed = rpc(&mut process, 4, "auth.getStatus").await?;
        if Authentication::parse(&confirmed)? != authentication {
            return Err("The account changed during refresh. Sign in again.".into());
        }
        Ok(Snapshot {
            authentication,
            shared,
            quota: quota.and_then(|quota| {
                parse(
                    &identity,
                    &quota,
                    status["version"]
                        .as_str()
                        .ok_or("Copilot runtime version is unavailable.")?,
                    crate::transport::now_ms(),
                )
            }),
        })
    })
    .await
    .map_err(|_| "Copilot quota refresh timed out.")?;
    process
        .kill()
        .await
        .map_err(|_| "Copilot account process could not be stopped.")?;
    result
}

async fn rpc(process: &mut Child, id: u32, method: &str) -> Result<Value> {
    let body = serde_json::to_vec(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":{}}))
        .map_err(|_| "Account request encoding failed.")?;
    let stdin = process
        .stdin
        .as_mut()
        .ok_or("Account input pipe unavailable.")?;
    stdin
        .write_all(format!("Content-Length: {}\r\n\r\n", body.len()).as_bytes())
        .await
        .map_err(|_| "Account request could not be sent.")?;
    stdin
        .write_all(&body)
        .await
        .map_err(|_| "Account request could not be sent.")?;
    let stdout = process
        .stdout
        .as_mut()
        .ok_or("Account output pipe unavailable.")?;
    for _ in 0..100 {
        let mut header = Vec::new();
        while !header.ends_with(b"\r\n\r\n") {
            if header.len() >= 1024 {
                return Err("Unsupported account response framing.".into());
            }
            header.push(
                stdout
                    .read_u8()
                    .await
                    .map_err(|_| "Copilot account connection closed.")?,
            );
        }
        let text = std::str::from_utf8(&header).map_err(|_| "Invalid account response header.")?;
        let lengths: Vec<_> = text
            .lines()
            .filter_map(|line| {
                line.split_once(':')
                    .filter(|(key, _)| key.eq_ignore_ascii_case("Content-Length"))
                    .map(|(_, value)| value.trim().parse::<usize>())
            })
            .collect();
        let length = if lengths.len() == 1 {
            lengths[0].as_ref().ok().copied()
        } else {
            None
        }
        .filter(|v| (1..=262_144).contains(v))
        .ok_or("Unsupported account response length.")?;
        let mut bytes = vec![0; length];
        stdout
            .read_exact(&mut bytes)
            .await
            .map_err(|_| "Incomplete account response.")?;
        let response: Value =
            serde_json::from_slice(&bytes).map_err(|_| "Invalid account response.")?;
        if response["id"].as_u64() != Some(u64::from(id)) {
            continue;
        }
        if !response["error"].is_null() {
            return Err(if response["error"]["code"] == -32601 {"This Copilot CLI does not support the account API."}
                else {"Copilot denied the account request. Check sign-in, connectivity and enterprise policy."}.into());
        }
        return response
            .get("result")
            .cloned()
            .ok_or("Missing account response.".into());
    }
    Err("Too many unrelated account messages.".into())
}
