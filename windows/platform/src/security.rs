use crate::storage::Result;
use std::{
    ffi::c_void,
    fs::File,
    os::windows::{ffi::OsStrExt, io::AsRawHandle},
    path::Path,
};
use windows::{
    core::{PCWSTR, PWSTR},
    Win32::{
        Foundation::{CloseHandle, LocalFree, HANDLE, HLOCAL},
        Security::{
            Authorization::{
                ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
                GetNamedSecurityInfoW, GetSecurityInfo, SE_FILE_OBJECT,
            },
            EqualSid, GetAce, GetTokenInformation, TokenUser, ACCESS_ALLOWED_ACE, ACL,
            DACL_SECURITY_INFORMATION, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID,
            SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER,
        },
        Storage::FileSystem::{
            CreateDirectoryW, GetFileInformationByHandle, MoveFileExW, BY_HANDLE_FILE_INFORMATION,
            MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
        },
        System::{
            Pipes::GetNamedPipeServerProcessId,
            Threading::{
                GetCurrentProcess, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
            },
        },
    },
};

fn wide(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain(Some(0)).collect()
}

pub fn user_sid() -> Result<String> {
    process_user_sid(unsafe { GetCurrentProcess() })
}

fn process_user_sid(process: HANDLE) -> Result<String> {
    unsafe {
        let mut token = HANDLE::default();
        OpenProcessToken(process, TOKEN_QUERY, &mut token)
            .map_err(|_| "Windows user identity is unavailable.")?;
        let mut needed = 0;
        let _ = GetTokenInformation(token, TokenUser, None, 0, &mut needed);
        let mut buffer = vec![0usize; (needed as usize).div_ceil(std::mem::size_of::<usize>())];
        let result = GetTokenInformation(
            token,
            TokenUser,
            Some(buffer.as_mut_ptr().cast()),
            needed,
            &mut needed,
        );
        let _ = CloseHandle(token);
        result.map_err(|_| "Windows user identity is unavailable.")?;
        let user = &*(buffer.as_ptr().cast::<TOKEN_USER>());
        let mut text = PWSTR::null();
        ConvertSidToStringSidW(user.User.Sid, &mut text)
            .map_err(|_| "Windows user identity is unavailable.")?;
        let value = text
            .to_string()
            .map_err(|_| "Windows user identity is invalid.");
        LocalFree(Some(HLOCAL(text.0.cast())));
        value.map_err(str::to_owned)
    }
}

pub fn check_pipe_server(pipe: &impl AsRawHandle, expected_sid: &str) -> Result<()> {
    let server_sid = unsafe {
        let mut pid = 0;
        GetNamedPipeServerProcessId(HANDLE(pipe.as_raw_handle()), &mut pid)
            .map_err(|_| "The local event pipe server identity could not be verified.")?;
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
            .map_err(|_| "The local event pipe server process could not be verified.")?;
        let sid = process_user_sid(process);
        let _ = CloseHandle(process);
        sid?
    };
    if server_sid != expected_sid {
        return Err(
            "The local event pipe belongs to another Windows user. No event was sent.".into(),
        );
    }
    Ok(())
}

pub struct Descriptor(PSECURITY_DESCRIPTOR);
impl Descriptor {
    pub fn private() -> Result<Self> {
        let sid = user_sid()?;
        let text: Vec<u16> = format!("O:{sid}D:P(A;OICI;FA;;;{sid})")
            .encode_utf16()
            .chain(Some(0))
            .collect();
        let mut descriptor = PSECURITY_DESCRIPTOR::default();
        unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                PCWSTR(text.as_ptr()),
                1,
                &mut descriptor,
                None,
            )
        }
        .map_err(|_| "Private Windows permissions could not be created.")?;
        Ok(Self(descriptor))
    }
    pub fn attributes(&self) -> SECURITY_ATTRIBUTES {
        SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: self.0 .0,
            bInheritHandle: false.into(),
        }
    }
}
impl Drop for Descriptor {
    fn drop(&mut self) {
        unsafe {
            LocalFree(Some(HLOCAL(self.0 .0)));
        }
    }
}

pub fn create_directory(path: &Path) -> Result<()> {
    let descriptor = Descriptor::private()?;
    unsafe { CreateDirectoryW(PCWSTR(wide(path).as_ptr()), Some(&descriptor.attributes())) }
        .map_err(|_| "Private Windows directory could not be created.".into())
}

unsafe fn verify_descriptor(
    _descriptor: PSECURITY_DESCRIPTOR,
    owner: PSID,
    acl: *mut ACL,
) -> Result<()> {
    let expected = Descriptor::private()?;
    let mut expected_owner = PSID::default();
    let mut defaulted = false.into();
    windows::Win32::Security::GetSecurityDescriptorOwner(
        expected.0,
        &mut expected_owner,
        &mut defaulted,
    )
    .map_err(|_| "Private Windows owner could not be checked.")?;
    if owner.0.is_null() || EqualSid(owner, expected_owner).is_err() || acl.is_null() {
        return Err("Tokenotch storage is not owned exclusively by this Windows user.".into());
    }
    if (*acl).AceCount == 0 {
        return Err("Private Windows permissions are invalid.".into());
    }
    for index in 0..(*acl).AceCount {
        let mut ace: *mut c_void = std::ptr::null_mut();
        GetAce(acl, index as u32, &mut ace)
            .map_err(|_| "Private Windows permissions could not be checked.")?;
        let allowed = &*(ace.cast::<ACCESS_ALLOWED_ACE>());
        if allowed.Header.AceType != 0
            || EqualSid(
                PSID((&allowed.SidStart as *const u32).cast_mut().cast()),
                expected_owner,
            )
            .is_err()
        {
            return Err("Private Windows storage grants access to another identity.".into());
        }
    }
    Ok(())
}

pub fn check_path(path: &Path) -> Result<()> {
    unsafe {
        let mut owner = PSID::default();
        let mut acl = std::ptr::null_mut();
        let mut descriptor = PSECURITY_DESCRIPTOR::default();
        GetNamedSecurityInfoW(
            PCWSTR(wide(path).as_ptr()),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            Some(&mut owner),
            None,
            Some(&mut acl),
            None,
            &mut descriptor,
        )
        .ok()
        .map_err(|_| "Private Windows permissions are unavailable.")?;
        let result = verify_descriptor(descriptor, owner, acl);
        LocalFree(Some(HLOCAL(descriptor.0)));
        result
    }
}

pub fn check_file(file: &File) -> Result<()> {
    unsafe {
        let handle = HANDLE(file.as_raw_handle());
        let mut info = BY_HANDLE_FILE_INFORMATION::default();
        GetFileInformationByHandle(handle, &mut info)
            .map_err(|_| "Private file could not be inspected.")?;
        if info.nNumberOfLinks != 1 || info.dwFileAttributes & 0x400 != 0 {
            return Err("Linked private files are not supported.".into());
        }
        let mut owner = PSID::default();
        let mut acl = std::ptr::null_mut();
        let mut descriptor = PSECURITY_DESCRIPTOR::default();
        GetSecurityInfo(
            handle,
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            Some(&mut owner),
            None,
            Some(&mut acl),
            None,
            Some(&mut descriptor),
        )
        .ok()
        .map_err(|_| "Private file permissions are unavailable.")?;
        let result = verify_descriptor(descriptor, owner, acl);
        LocalFree(Some(HLOCAL(descriptor.0)));
        result
    }
}

pub fn replace(from: &Path, to: &Path) -> Result<()> {
    unsafe {
        MoveFileExW(
            PCWSTR(wide(from).as_ptr()),
            PCWSTR(wide(to).as_ptr()),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    }
    .map_err(|_| "Private file replacement failed.".into())
}
