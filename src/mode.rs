use crate::protocol::Scope;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Chrome,
    Desktop,
}

impl Mode {
    pub fn from_executable(path: &Path) -> Self {
        if path
            .file_name()
            .is_some_and(|name| name == "desktop-control" || name == "mcc")
        {
            Self::Desktop
        } else {
            Self::Chrome
        }
    }

    pub fn current_executable() -> Self {
        std::env::current_exe()
            .map(|path| Self::from_executable(&path))
            .unwrap_or(Self::Chrome)
    }

    pub fn scope(self) -> Scope {
        match self {
            Self::Chrome => Scope::Chrome,
            Self::Desktop => Scope::Desktop,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn given_binary_name_when_resolving_mode_then_only_desktop_entry_gets_generic_scope() {
        assert_eq!(
            Mode::from_executable(Path::new("/bin/desktop-control")),
            Mode::Desktop
        );
        assert_eq!(
            Mode::from_executable(Path::new("/bin/copis-chrome")),
            Mode::Chrome
        );
        assert_eq!(Mode::from_executable(Path::new("/bin/mcc")), Mode::Desktop);
        assert_eq!(Mode::from_executable(Path::new("/bin/other")), Mode::Chrome);
    }
}
