pub mod backend;
pub mod protocol;
pub mod rodio_backend;
pub mod service;
pub mod transport;

pub const PROTOCOL_VERSION: u32 = 1;

pub fn version_banner() -> String {
    format!("aonsoku-playerd protocol v{PROTOCOL_VERSION}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reports_protocol_version() {
        assert_eq!(version_banner(), "aonsoku-playerd protocol v1");
    }
}
