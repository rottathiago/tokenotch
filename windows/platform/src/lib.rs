use serde::Serialize;

pub mod account;
pub mod archive;
pub mod attention;
pub mod broker;
pub mod calendar;
pub mod connections;
pub mod desktop;
pub mod display;
pub mod import;
pub mod navigation;
pub mod notifications;
pub mod preferences;
pub mod receiver;
pub mod runtime;
#[cfg(windows)]
pub mod security;
mod sqlite_import;
pub mod storage;
pub mod transport;
pub mod vscode;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Runtime {
    pub platform: &'static str,
    pub executable_architecture: &'static str,
    pub windows_build: Option<u32>,
}

pub fn runtime() -> Result<Runtime, &'static str> {
    Ok(Runtime {
        platform: std::env::consts::OS,
        executable_architecture: std::env::consts::ARCH,
        windows_build: windows_build()?,
    })
}

#[cfg(windows)]
fn windows_build() -> Result<Option<u32>, &'static str> {
    use windows::Win32::System::SystemInformation::OSVERSIONINFOW;
    #[link(name = "ntdll")]
    unsafe extern "system" {
        fn RtlGetVersion(version: *mut OSVERSIONINFOW) -> i32;
    }
    let mut version = OSVERSIONINFOW {
        dwOSVersionInfoSize: std::mem::size_of::<OSVERSIONINFOW>() as u32,
        ..Default::default()
    };
    // The fixed-size version buffer is initialized and owned for the entire call.
    if unsafe { RtlGetVersion(&mut version) } < 0 {
        return Err("Windows version could not be determined.");
    }
    Ok(Some(version.dwBuildNumber))
}

#[cfg(not(windows))]
fn windows_build() -> Result<Option<u32>, &'static str> {
    Ok(None)
}

#[cfg(test)]
mod tests {
    #[test]
    fn runtime_reports_actual_compiled_platform() {
        let runtime = super::runtime().unwrap();
        assert_eq!(runtime.platform, std::env::consts::OS);
        assert_eq!(runtime.executable_architecture, std::env::consts::ARCH);
        assert_eq!(runtime.windows_build.is_some(), cfg!(windows));
    }
}
