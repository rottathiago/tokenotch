use crate::storage::{no_links, Result};
use std::{
    ffi::OsString,
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::{process::Command, time::timeout};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Edition {
    Stable,
    Insiders,
}

impl Edition {
    pub fn link(self) -> &'static str {
        match self {
            Self::Stable => "vscodeSetup",
            Self::Insiders => "vscodeInsidersSetup",
        }
    }
}

/// Ordered VS Code command-line launchers. Stable is preferred over Insiders.
pub fn candidates(
    path: Option<OsString>,
    local: Option<PathBuf>,
    program_files: Option<PathBuf>,
) -> Vec<(Edition, PathBuf)> {
    let mut found = Vec::new();
    for (edition, folder, launcher) in [
        (Edition::Stable, "Microsoft VS Code", "code.cmd"),
        (
            Edition::Insiders,
            "Microsoft VS Code Insiders",
            "code-insiders.cmd",
        ),
    ] {
        if let Some(local) = local.as_ref().filter(|v| v.is_absolute()) {
            found.push((
                edition,
                local
                    .join("Programs")
                    .join(folder)
                    .join("bin")
                    .join(launcher),
            ));
        }
        if let Some(root) = program_files.as_ref().filter(|v| v.is_absolute()) {
            found.push((edition, root.join(folder).join("bin").join(launcher)));
        }
        if let Some(path) = &path {
            found.extend(
                std::env::split_paths(path)
                    .filter(|dir| dir.is_absolute())
                    .map(|dir| (edition, dir.join(launcher))),
            );
        }
    }
    let mut unique: Vec<(Edition, PathBuf)> = Vec::new();
    for item in found {
        if !unique.iter().any(|(_, path)| *path == item.1) {
            unique.push(item);
        }
    }
    unique
}

pub fn locate() -> Option<(Edition, PathBuf)> {
    candidates(
        std::env::var_os("PATH"),
        std::env::var_os("LOCALAPPDATA").map(PathBuf::from),
        std::env::var_os("ProgramFiles").map(PathBuf::from),
    )
    .into_iter()
    .find(|(_, path)| path.is_file() && no_links(path).is_ok())
}

/// Installs (or updates) the bundled setup companion into the user's VS Code.
pub async fn install_companion(vsix: &Path) -> Result<Edition> {
    no_links(vsix)?;
    if !vsix.is_file() {
        return Err("The bundled VS Code companion is missing. Reinstall Tokenotch.".into());
    }
    let (edition, launcher) = locate().ok_or(
        "VS Code was not found. Install VS Code, or install the bundled companion manually.",
    )?;
    let mut command = Command::new(&launcher);
    command
        .args([
            OsString::from("--install-extension"),
            vsix.into(),
            "--force".into(),
        ])
        .env_clear()
        .kill_on_drop(true)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    for name in [
        "SystemRoot",
        "WINDIR",
        "ComSpec",
        "PATHEXT",
        "PATH",
        "USERPROFILE",
        "HOMEDRIVE",
        "HOMEPATH",
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
    let status = timeout(Duration::from_secs(120), command.status())
        .await
        .map_err(|_| "Installing the VS Code companion timed out.")?
        .map_err(|_| "VS Code could not be started to install the companion.")?;
    if !status.success() {
        return Err(
            "VS Code did not install the Tokenotch companion. Install the bundled VSIX manually."
                .into(),
        );
    }
    Ok(edition)
}
