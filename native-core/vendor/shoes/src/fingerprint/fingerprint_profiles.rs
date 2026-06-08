use crate::config::TlsFingerprint;
use rand::Rng;

pub const GREASE_VALUES: [u16; 16] = [
    0x0a0a, 0x1a1a, 0x2a2a, 0x3a3a, 0x4a4a, 0x5a5a, 0x6a6a, 0x7a7a, 0x8a8a, 0x9a9a, 0xaaaa,
    0xbaba, 0xcaca, 0xdada, 0xeaea, 0xfafa,
];

pub fn random_grease() -> u16 {
    let idx = rand::rng().random_range(0..GREASE_VALUES.len());
    GREASE_VALUES[idx]
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ExtensionId {
    Grease,
    GreaseWithByte,
    ServerName,
    ExtendedMasterSecret,
    RenegotiationInfo,
    SupportedGroups,
    EcPointFormats,
    SessionTicket,
    Alpn,
    StatusRequest,
    SignatureAlgorithms,
    SignedCertificateTimestamp,
    KeyShare,
    PskKeyExchangeModes,
    SupportedVersions,
    CompressCertificate,
    ApplicationSettings,
    Padding,
}

#[derive(Debug, Clone)]
pub struct FingerprintProfile {
    pub cipher_suites: &'static [u16],
    pub extensions_order: &'static [ExtensionId],
    pub supported_groups: &'static [u16],
    pub key_share_groups: &'static [u16],
    pub signature_algorithms: &'static [u16],
    pub supported_versions: &'static [u16],
    pub record_version: [u8; 2],
    pub handshake_version: [u8; 2],
    #[allow(dead_code)]
    pub padding_target: usize,
    pub grease_cipher_suite: bool,
    pub grease_supported_group: bool,
    pub grease_key_share: bool,
    pub grease_supported_version: bool,
}

// Chrome 133 cipher suites (without leading GREASE — inserted at build time)
static CHROME_133_CIPHER_SUITES: &[u16] = &[
    0x1301, // TLS_AES_128_GCM_SHA256
    0x1302, // TLS_AES_256_GCM_SHA384
    0x1303, // TLS_CHACHA20_POLY1305_SHA256
    0xc02b, // TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
    0xc02f, // TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
    0xc02c, // TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
    0xc030, // TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
    0xcca9, // TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256
    0xcca8, // TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
    0xc013, // TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA
    0xc014, // TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA
    0x009c, // TLS_RSA_WITH_AES_128_GCM_SHA256
    0x009d, // TLS_RSA_WITH_AES_256_GCM_SHA384
    0x002f, // TLS_RSA_WITH_AES_128_CBC_SHA
    0x0035, // TLS_RSA_WITH_AES_256_CBC_SHA
];

static CHROME_133_EXTENSIONS: &[ExtensionId] = &[
    ExtensionId::Grease,
    ExtensionId::ServerName,
    ExtensionId::ExtendedMasterSecret,
    ExtensionId::RenegotiationInfo,
    ExtensionId::SupportedGroups,
    ExtensionId::EcPointFormats,
    ExtensionId::SessionTicket,
    ExtensionId::Alpn,
    ExtensionId::StatusRequest,
    ExtensionId::SignatureAlgorithms,
    ExtensionId::SignedCertificateTimestamp,
    ExtensionId::KeyShare,
    ExtensionId::PskKeyExchangeModes,
    ExtensionId::SupportedVersions,
    ExtensionId::CompressCertificate,
    ExtensionId::ApplicationSettings,
    ExtensionId::GreaseWithByte,
    ExtensionId::Padding,
];

// Without leading GREASE — inserted at build time
static CHROME_133_GROUPS: &[u16] = &[
    0x001d, // X25519
    0x0017, // secp256r1 (P-256)
    0x0018, // secp384r1 (P-384)
];

static CHROME_133_KEY_SHARE_GROUPS: &[u16] = &[
    0x001d, // X25519 only (Chrome sends just X25519 key share)
];

static CHROME_133_SIG_ALGOS: &[u16] = &[
    0x0403, // ecdsa_secp256r1_sha256
    0x0804, // rsa_pss_rsae_sha256
    0x0401, // rsa_pkcs1_sha256
    0x0503, // ecdsa_secp384r1_sha384
    0x0805, // rsa_pss_rsae_sha384
    0x0501, // rsa_pkcs1_sha384
    0x0806, // rsa_pss_rsae_sha512
    0x0601, // rsa_pkcs1_sha512
];

// Without leading GREASE — inserted at build time
static CHROME_133_VERSIONS: &[u16] = &[
    0x0304, // TLS 1.3
    0x0303, // TLS 1.2
];

static CHROME_133: FingerprintProfile = FingerprintProfile {
    cipher_suites: CHROME_133_CIPHER_SUITES,
    extensions_order: CHROME_133_EXTENSIONS,
    supported_groups: CHROME_133_GROUPS,
    key_share_groups: CHROME_133_KEY_SHARE_GROUPS,
    signature_algorithms: CHROME_133_SIG_ALGOS,
    supported_versions: CHROME_133_VERSIONS,
    record_version: [0x03, 0x01],   // TLS 1.0 on the wire
    handshake_version: [0x03, 0x03], // TLS 1.2 in ClientHello
    padding_target: 512,
    grease_cipher_suite: true,
    grease_supported_group: true,
    grease_key_share: true,
    grease_supported_version: true,
};

pub fn get_profile(fingerprint: &TlsFingerprint) -> Option<&'static FingerprintProfile> {
    match fingerprint {
        TlsFingerprint::Chrome => Some(&CHROME_133),
        TlsFingerprint::Edge
        | TlsFingerprint::Firefox
        | TlsFingerprint::Safari
        | TlsFingerprint::Random => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grease_values_are_valid() {
        for &v in &GREASE_VALUES {
            assert_eq!(v & 0x0f0f, 0x0a0a);
            assert_eq!((v >> 8) as u8, (v & 0xff) as u8);
        }
    }

    #[test]
    fn random_grease_returns_valid_value() {
        for _ in 0..100 {
            let g = random_grease();
            assert!(GREASE_VALUES.contains(&g));
        }
    }

    #[test]
    fn chrome_profile_has_correct_cipher_suite_count() {
        assert_eq!(CHROME_133.cipher_suites.len(), 15);
    }

    #[test]
    fn chrome_profile_has_correct_extension_count() {
        assert_eq!(CHROME_133.extensions_order.len(), 18);
    }

    #[test]
    fn chrome_profile_starts_with_tls13_cipher_suites() {
        assert_eq!(CHROME_133.cipher_suites[0], 0x1301);
        assert_eq!(CHROME_133.cipher_suites[1], 0x1302);
        assert_eq!(CHROME_133.cipher_suites[2], 0x1303);
    }
}
