use crate::{
    storage::{home, no_links, random_id, Result, Store},
    transport::registration_name,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
};
use tokenotch_core::hook::{digest, Source};

const EXTENSION: &str = include_str!("../../../integrations/CopilotUsage/extension.mjs");

#[derive(Clone, Serialize, Deserialize)]
struct OwnedFile {
    path: PathBuf,
    digest: String,
    #[serde(default)]
    previous_digest: Option<String>,
}

#[derive(Clone, Serialize, Deserialize)]
struct Receipt {
    files: Vec<OwnedFile>,
}

pub struct Connections {
    pub store: Store,
    pub cli_home: PathBuf,
}

impl Connections {
    pub fn new(store: Store) -> Result<Self> {
        let cli_home = std::env::var_os("COPILOT_HOME")
            .map(PathBuf::from)
            .unwrap_or(home()?.join(".copilot"));
        if !cli_home.is_absolute() {
            return Err("COPILOT_HOME must be an absolute local path.".into());
        }
        Ok(Self { store, cli_home })
    }

    fn receipt_name(source: Source) -> &'static str {
        match source {
            Source::Cli => "cli-owned.json",
            Source::Vscode => "vscode-owned.json",
        }
    }

    pub fn configured(&self, source: Source) -> Result<bool> {
        if self.store.read(registration_name(source), 128)?.is_none() {
            return Ok(false);
        }
        let Some(receipt) = self.store.load::<Receipt>(Self::receipt_name(source))? else {
            return Ok(false);
        };
        if !self.store.path("TokenotchHook.exe")?.is_file() {
            return Ok(false);
        }
        for file in receipt.files {
            no_links(&file.path)?;
            if !file.path.is_file() {
                return Ok(false);
            }
            if file_digest(&file.path)? != file.digest {
                return Err(
                    "A Tokenotch integration file was edited. It was left unchanged.".into(),
                );
            }
            if file
                .path
                .file_name()
                .is_some_and(|name| name == "extension.mjs")
                && file.digest != digest(EXTENSION)
            {
                return Ok(false);
            }
        }
        if source == Source::Vscode {
            self.reconcile_vscode()?;
            let receipt = self.store.load::<Value>("vscode-settings.receipt.json")?;
            return Ok(self
                .store
                .load::<Value>("vscode-approved.json")?
                .is_some_and(|v| v["hooks"] == true)
                && receipt
                    .is_some_and(|v| v["hook"]["installed"] == true && v["owner"].is_object()));
        }
        Ok(true)
    }

    pub fn reconcile_vscode(&self) -> Result<()> {
        let Some(result) = self.store.load::<Value>("vscode-setup-result.json")? else {
            return Ok(());
        };
        let Some(pending) = self.store.load::<Value>("vscode-pending.json")? else {
            return Ok(());
        };
        let mut approved = self
            .store
            .load::<Value>("vscode-approved.json")?
            .unwrap_or(json!({"hooks":false,"metrics":false}));
        if result["nonce"] != pending["nonce"] || approved["nonce"] == result["nonce"] {
            return Ok(());
        }
        if result["status"] != "configured" && result["status"] != "removed" {
            return Ok(());
        }
        for key in ["hooks", "metrics"] {
            if pending[key] == true {
                approved[key] = json!(result["status"] == "configured");
            }
        }
        approved["nonce"] = result["nonce"].clone();
        self.store.save("vscode-approved.json", &approved)
    }
    pub fn install(&self, source: Source, helper: &Path) -> Result<()> {
        no_links(helper)?;
        let binary =
            fs::read(helper).map_err(|_| "The bundled Tokenotch helper is unavailable.")?;
        if binary.len() > 32 * 1_048_576 {
            return Err("The bundled helper is too large.".into());
        }
        let installed = self.store.path("TokenotchHook.exe")?;
        let config = configuration(source, &installed)?;
        let hook_path = if source == Source::Cli {
            self.cli_home.join("hooks").join("tokenotch-v1.json")
        } else {
            self.store
                .root()
                .join("vscode-hooks")
                .join("tokenotch-v1.json")
        };
        let mut files = vec![(
            hook_path,
            serde_json::to_vec_pretty(&config)
                .map_err(|_| "Hook configuration could not be encoded.")?,
        )];
        if source == Source::Cli {
            files.push((
                self.cli_home
                    .join("extensions")
                    .join("tokenotch-token-usage")
                    .join("extension.mjs"),
                EXTENSION.as_bytes().to_vec(),
            ));
        }
        let old = self.store.load::<Receipt>(Self::receipt_name(source))?;
        for (path, _) in &files {
            no_links(path)?;
            if path.exists()
                && !old.as_ref().is_some_and(|receipt| {
                    receipt.files.iter().any(|file| {
                        file.path == *path
                            && file_digest(path).is_ok_and(|hash| {
                                hash == file.digest || file.previous_digest.as_ref() == Some(&hash)
                            })
                    })
                })
            {
                return Err(
                    "An integration file is not owned by Tokenotch; no client files were replaced."
                        .into(),
                );
            }
        }
        self.store.write("TokenotchHook.exe", &binary)?;
        let receipt = Receipt {
            files: files
                .iter()
                .map(|(path, bytes)| OwnedFile {
                    path: path.clone(),
                    digest: tokenotch_core::hook::digest(&String::from_utf8_lossy(bytes)),
                    previous_digest: old
                        .as_ref()
                        .and_then(|receipt| receipt.files.iter().find(|file| file.path == *path))
                        .map(|file| file.digest.clone()),
                })
                .collect(),
        };
        self.store.save(Self::receipt_name(source), &receipt)?;
        for (path, bytes) in files {
            let parent = path.parent().ok_or("Invalid integration directory.")?;
            create_client_directories(parent)?;
            // Stage privately, then move without inheriting a client's wider ACL.
            let temporary = format!(".integration-{}", random_id()?);
            self.store.write(&temporary, &bytes)?;
            let staged = self.store.path(&temporary)?;
            #[cfg(windows)]
            crate::security::replace(&staged, &path)?;
            #[cfg(not(windows))]
            fs::rename(staged, path).map_err(|_| "Integration file could not be committed.")?;
        }
        self.store
            .write(registration_name(source), random_id()?.as_bytes())
    }

    pub fn remove(&self, source: Source) -> Result<()> {
        self.store.remove(registration_name(source))?;
        let Some(receipt) = self.store.load::<Receipt>(Self::receipt_name(source))? else {
            return Ok(());
        };
        for file in &receipt.files {
            no_links(&file.path)?;
            if file.path.exists() {
                let current = file_digest(&file.path)?;
                if current != file.digest && file.previous_digest.as_ref() != Some(&current) {
                    return Err("Collection is off. An edited integration file was preserved; restore it before retrying removal.".into());
                }
                fs::remove_file(&file.path).map_err(|_| {
                    "Collection is off, but an owned integration file could not be removed."
                })?;
            }
        }
        self.store.remove(Self::receipt_name(source))
    }

    pub fn request_vscode(
        &self,
        remove: bool,
        hooks: bool,
        metrics: bool,
        port: u16,
        token: &str,
    ) -> Result<()> {
        let request = json!({
            "version": 1, "nonce": random_id()?, "expiresAt": chrono::Utc::now().timestamp() + 600,
            "operation": if remove { "remove" } else { "configure" }, "hooks": hooks, "metrics": metrics,
            "endpoints": {
                "vscodeLocal": format!("http://127.0.0.1:{port}/{token}/vscodeLocal"),
                "vscodeCopilot": format!("http://127.0.0.1:{port}/{token}/vscodeCopilot")
            }
        });
        self.store.save("vscode-pending.json", &request)?;
        self.store.save("vscode-setup-request.json", &request)?;
        self.store.remove("vscode-setup-result.json")
    }

    pub fn vscode_setup(&self, now: f64) -> Result<Value> {
        let Some(pending) = self.store.load::<Value>("vscode-pending.json")? else {
            return Ok(json!({"status":"notRequested","canOpen":false}));
        };
        let request = self.store.load::<Value>("vscode-setup-request.json")?;
        let present = request
            .as_ref()
            .is_some_and(|request| request["nonce"] == pending["nonce"]);
        let fresh = pending["expiresAt"]
            .as_f64()
            .is_some_and(|expiry| expiry > now / 1000.0 && expiry <= now / 1000.0 + 600.0);
        let can_open = present && fresh;
        if let Some(result) = self.store.load::<Value>("vscode-setup-result.json")? {
            if result["nonce"] == pending["nonce"] {
                return Ok(
                    json!({"status":result["status"],"operation":pending["operation"],"canOpen":can_open}),
                );
            }
        }
        let status = if !present {
            "interrupted"
        } else if !fresh {
            "expired"
        } else {
            "pending"
        };
        Ok(json!({"status":status,"operation":pending["operation"],"canOpen":can_open}))
    }

    pub fn vscode_setup_url(&self, scheme: &str, now: f64) -> Result<String> {
        if !["vscode", "vscode-insiders"].contains(&scheme) {
            return Err("Choose a supported local VS Code application.".into());
        }
        if self.vscode_setup(now)?["canOpen"] != true {
            return Err("Create a fresh VS Code setup/removal request in Tokenotch first.".into());
        }
        let request = self
            .store
            .load::<Value>("vscode-setup-request.json")?
            .ok_or("The VS Code setup request is no longer available.")?;
        let nonce = request["nonce"]
            .as_str()
            .filter(|nonce| {
                nonce.len() == 64
                    && nonce
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            })
            .ok_or("The VS Code setup request is invalid.")?;
        Ok(format!(
            "{scheme}://rottathiago.tokenotch-vscode/setup?nonce={nonce}"
        ))
    }
}

fn file_digest(path: &Path) -> Result<String> {
    let metadata = fs::metadata(path).map_err(|_| "Integration file metadata is unavailable.")?;
    if metadata.len() > 1_048_576 {
        return Err("Integration file is oversized.".into());
    }
    let text = fs::read_to_string(path).map_err(|_| "Integration file could not be read.")?;
    Ok(digest(&text))
}

fn create_client_directories(path: &Path) -> Result<()> {
    no_links(path)?;
    if path.is_dir() {
        return Ok(());
    }
    create_client_directories(path.parent().ok_or("Integration root is unavailable.")?)?;
    #[cfg(windows)]
    crate::security::create_directory(path)?;
    #[cfg(not(windows))]
    {
        fs::create_dir(path).map_err(|_| "Integration directory could not be created.")?;
    }
    Ok(())
}

pub fn configuration(source: Source, helper: &Path) -> Result<Value> {
    let helper = helper
        .to_str()
        .ok_or("The helper path cannot be encoded.")?;
    let mut hooks = serde_json::Map::new();
    if source == Source::Cli {
        for name in [
            "sessionStart",
            "userPromptSubmitted",
            "agentStop",
            "sessionEnd",
            "notification",
            "errorOccurred",
        ] {
            let mut entry =
                json!({"type": "command", "exec": helper, "args": ["cli", name], "timeoutSec": 2});
            if name == "notification" {
                entry["matcher"] = json!("permission_prompt|elicitation_dialog");
            }
            hooks.insert(name.into(), json!([entry]));
        }
    } else {
        let escaped = helper.replace('\'', "''");
        for name in ["SessionStart", "UserPromptSubmit", "Stop"] {
            hooks.insert(
                name.into(),
                json!([{"type": "command",
                "windows": format!("& '{escaped}' vscode {name}"), "timeout": 2}]),
            );
        }
    }
    Ok(json!({"version": 1, "hooks": hooks}))
}
