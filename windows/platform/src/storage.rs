use serde::{de::DeserializeOwned, Serialize};
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::{Component, Path, PathBuf},
};

pub type Result<T> = std::result::Result<T, String>;

pub fn random_id() -> Result<String> {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).map_err(|_| "Secure randomness is unavailable.")?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

pub fn home() -> Result<PathBuf> {
    #[cfg(debug_assertions)]
    if let Some(path) = std::env::var_os("TOKENOTCH_TEST_HOME") {
        let path = PathBuf::from(path);
        if !path.is_absolute() || !path.is_dir() {
            return Err("The isolated test home is invalid.".into());
        }
        no_links(&path)?;
        return Ok(path);
    }
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .ok_or_else(|| "The user home directory is unavailable.".into())
}

pub fn no_links(path: &Path) -> Result<()> {
    for ancestor in path.ancestors() {
        match fs::symlink_metadata(ancestor) {
            Ok(info) => {
                #[cfg(windows)]
                let linked = {
                    use std::os::windows::fs::MetadataExt;
                    info.file_attributes() & 0x400 != 0
                };
                #[cfg(not(windows))]
                let linked = info.file_type().is_symlink();
                if linked {
                    return Err("Linked or redirected storage paths are not supported.".into());
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("Storage metadata could not be inspected.".into()),
        }
    }
    Ok(())
}

#[derive(Clone)]
pub struct Store {
    root: PathBuf,
}

impl Store {
    pub fn open(root: PathBuf) -> Result<Self> {
        no_links(&root)?;
        if !root.exists() {
            #[cfg(windows)]
            super::security::create_directory(&root)?;
            #[cfg(not(windows))]
            {
                use std::os::unix::fs::DirBuilderExt;
                fs::DirBuilder::new()
                    .mode(0o700)
                    .create(&root)
                    .map_err(|_| "Private storage could not be created.")?;
            }
        }
        let store = Self { root };
        store.check()?;
        Ok(store)
    }

    pub fn check(&self) -> Result<()> {
        no_links(&self.root)?;
        if !self.root.is_dir() {
            return Err("Private storage is not a directory.".into());
        }
        #[cfg(windows)]
        super::security::check_path(&self.root)?;
        #[cfg(not(windows))]
        {
            use std::os::unix::fs::PermissionsExt;
            if fs::metadata(&self.root)
                .map_err(|_| "Private storage is unavailable.")?
                .permissions()
                .mode()
                & 0o777
                != 0o700
            {
                return Err("Private storage permissions are unsafe.".into());
            }
        }
        Ok(())
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn path(&self, name: &str) -> Result<PathBuf> {
        let path = Path::new(name);
        if path.components().count() != 1
            || !matches!(path.components().next(), Some(Component::Normal(_)))
            || name.contains([':', '/', '\\'])
        {
            return Err("Unsupported private filename.".into());
        }
        self.check()?;
        let path = self.root.join(path);
        no_links(&path)?;
        Ok(path)
    }

    pub fn read(&self, name: &str, limit: usize) -> Result<Option<Vec<u8>>> {
        let path = self.path(name)?;
        let mut options = OpenOptions::new();
        options.read(true);
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            options.custom_flags(0x00200000).share_mode(1);
        }
        #[cfg(not(windows))]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NOFOLLOW);
        }
        let file = match options.open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err("Private file could not be opened.".into()),
        };
        let info = file
            .metadata()
            .map_err(|_| "Private file could not be inspected.")?;
        if !info.is_file() || info.len() > limit as u64 {
            return Err("Private file exceeds its supported size or type.".into());
        }
        #[cfg(windows)]
        super::security::check_file(&file)?;
        let mut bytes = Vec::new();
        file.take(limit as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "Private file could not be read.")?;
        if bytes.len() > limit {
            return Err("Private file is too large.".into());
        }
        Ok(Some(bytes))
    }

    pub fn load<T: DeserializeOwned>(&self, name: &str) -> Result<Option<T>> {
        self.read(name, 1_048_576)?
            .map(|bytes| {
                serde_json::from_slice(&bytes)
                    .map_err(|_| "Saved Tokenotch data is invalid; it was not overwritten.".into())
            })
            .transpose()
    }

    pub fn save<T: Serialize>(&self, name: &str, value: &T) -> Result<()> {
        self.write(
            name,
            &serde_json::to_vec(value).map_err(|_| "Data could not be encoded.")?,
        )
    }

    pub fn write(&self, name: &str, bytes: &[u8]) -> Result<()> {
        let path = self.path(name)?;
        if path.exists() {
            #[cfg(windows)]
            super::security::check_path(&path)?;
        }
        let temp = self.root.join(format!(".write-{}", random_id()?));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let result = (|| {
            let mut file = options
                .open(&temp)
                .map_err(|_| "Private file could not be created.")?;
            file.write_all(bytes)
                .and_then(|_| file.sync_all())
                .map_err(|_| "Private file could not be saved.")?;
            drop(file);
            no_links(&path)?;
            #[cfg(windows)]
            super::security::replace(&temp, &path)?;
            #[cfg(not(windows))]
            fs::rename(&temp, &path).map_err(|_| "Private file could not be committed.")?;
            Ok(())
        })();
        if temp.exists() {
            fs::remove_file(&temp).map_err(|_| "Temporary private file could not be removed.")?;
        }
        result
    }

    pub fn remove(&self, name: &str) -> Result<()> {
        let path = self.path(name)?;
        if path.exists() {
            #[cfg(windows)]
            super::security::check_path(&path)?;
            fs::remove_file(path).map_err(|_| "Private file could not be deleted.")?;
        }
        Ok(())
    }
}
