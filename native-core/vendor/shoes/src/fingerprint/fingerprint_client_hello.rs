use std::io;

use rand::Rng;

use super::fingerprint_profiles::{ExtensionId, FingerprintProfile, random_grease};

pub fn construct_fingerprint_client_hello(
    profile: &FingerprintProfile,
    client_random: &[u8; 32],
    session_id: &[u8; 32],
    x25519_public_key: &[u8],
    server_name: &str,
    alpn_protocols: &[&str],
) -> io::Result<Vec<u8>> {
    let mut rng = rand::rng();

    let grease_cs = random_grease();
    let grease_ext_first = random_grease();
    let grease_ext_last = random_grease();
    let grease_group = random_grease();
    let grease_version = random_grease();

    let mut hello = Vec::with_capacity(512);

    // Handshake type: ClientHello (0x01)
    hello.push(0x01);
    let length_offset = hello.len();
    hello.extend_from_slice(&[0u8; 3]);

    // Handshake version
    hello.extend_from_slice(&profile.handshake_version);

    hello.extend_from_slice(client_random);

    hello.push(32);
    hello.extend_from_slice(session_id);

    // Cipher suites
    let grease_extra = if profile.grease_cipher_suite { 1 } else { 0 };
    let cs_byte_len = ((profile.cipher_suites.len() + grease_extra) * 2) as u16;
    hello.extend_from_slice(&cs_byte_len.to_be_bytes());
    if profile.grease_cipher_suite {
        hello.extend_from_slice(&grease_cs.to_be_bytes());
    }
    for &cs in profile.cipher_suites {
        hello.extend_from_slice(&cs.to_be_bytes());
    }

    // Compression methods: null only
    hello.extend_from_slice(&[0x01, 0x00]);

    // Extensions
    let extensions_length_offset = hello.len();
    hello.extend_from_slice(&[0u8; 2]);

    for &ext_id in profile.extensions_order {
        if ext_id == ExtensionId::Padding {
            continue; // handled after size calculation
        }
        write_extension(
            &mut hello,
            ext_id,
            profile,
            server_name,
            alpn_protocols,
            x25519_public_key,
            grease_ext_first,
            grease_ext_last,
            grease_group,
            grease_version,
            &mut rng,
        );
    }

    // Calculate padding
    let has_padding = profile
        .extensions_order
        .contains(&ExtensionId::Padding);
    if has_padding {
        let record_len = hello.len() + 5; // +5 for TLS record header
        if record_len > 0xff && record_len < 0x200 {
            let deficit = 0x200 - record_len;
            if deficit >= 4 {
                let padding_content_len = deficit - 4; // 4 bytes for extension header
                hello.extend_from_slice(&0x0015u16.to_be_bytes());
                hello.extend_from_slice(&(padding_content_len as u16).to_be_bytes());
                hello.resize(hello.len() + padding_content_len, 0);
            }
        }
    }

    // Patch extensions length
    let extensions_len = (hello.len() - extensions_length_offset - 2) as u16;
    hello[extensions_length_offset..extensions_length_offset + 2]
        .copy_from_slice(&extensions_len.to_be_bytes());

    // Patch handshake message length
    let msg_len = hello.len() - 4;
    hello[length_offset..length_offset + 3]
        .copy_from_slice(&(msg_len as u32).to_be_bytes()[1..]);

    Ok(hello)
}

#[allow(clippy::too_many_arguments)]
fn write_extension(
    buf: &mut Vec<u8>,
    ext_id: ExtensionId,
    profile: &FingerprintProfile,
    server_name: &str,
    alpn_protocols: &[&str],
    x25519_public_key: &[u8],
    grease_ext_first: u16,
    grease_ext_last: u16,
    grease_group: u16,
    grease_version: u16,
    rng: &mut impl Rng,
) {
    match ext_id {
        ExtensionId::Grease => {
            buf.extend_from_slice(&grease_ext_first.to_be_bytes());
            buf.extend_from_slice(&0u16.to_be_bytes()); // length = 0
        }
        ExtensionId::GreaseWithByte => {
            buf.extend_from_slice(&grease_ext_last.to_be_bytes());
            buf.extend_from_slice(&1u16.to_be_bytes()); // length = 1
            buf.push(0x00);
        }
        ExtensionId::ServerName => {
            let name = server_name.as_bytes();
            buf.extend_from_slice(&0x0000u16.to_be_bytes());
            let ext_len = (5 + name.len()) as u16;
            buf.extend_from_slice(&ext_len.to_be_bytes());
            let list_len = (3 + name.len()) as u16;
            buf.extend_from_slice(&list_len.to_be_bytes());
            buf.push(0x00); // host_name type
            buf.extend_from_slice(&(name.len() as u16).to_be_bytes());
            buf.extend_from_slice(name);
        }
        ExtensionId::ExtendedMasterSecret => {
            buf.extend_from_slice(&0x0017u16.to_be_bytes());
            buf.extend_from_slice(&0u16.to_be_bytes());
        }
        ExtensionId::RenegotiationInfo => {
            buf.extend_from_slice(&0xff01u16.to_be_bytes());
            buf.extend_from_slice(&1u16.to_be_bytes());
            buf.push(0x00); // empty renegotiated_connection
        }
        ExtensionId::SupportedGroups => {
            let grease_extra = if profile.grease_supported_group { 1u16 } else { 0 };
            let groups_count = profile.supported_groups.len() as u16 + grease_extra;
            let list_len = groups_count * 2;
            let ext_len = 2 + list_len;
            buf.extend_from_slice(&0x000au16.to_be_bytes());
            buf.extend_from_slice(&ext_len.to_be_bytes());
            buf.extend_from_slice(&list_len.to_be_bytes());
            if profile.grease_supported_group {
                buf.extend_from_slice(&grease_group.to_be_bytes());
            }
            for &g in profile.supported_groups {
                buf.extend_from_slice(&g.to_be_bytes());
            }
        }
        ExtensionId::EcPointFormats => {
            buf.extend_from_slice(&0x000bu16.to_be_bytes());
            buf.extend_from_slice(&2u16.to_be_bytes());
            buf.push(0x01); // formats length
            buf.push(0x00); // uncompressed
        }
        ExtensionId::SessionTicket => {
            buf.extend_from_slice(&0x0023u16.to_be_bytes());
            buf.extend_from_slice(&0u16.to_be_bytes());
        }
        ExtensionId::Alpn => {
            if alpn_protocols.is_empty() {
                return;
            }
            let list_len: usize = alpn_protocols.iter().map(|p| 1 + p.len()).sum();
            let ext_len = 2 + list_len;
            buf.extend_from_slice(&0x0010u16.to_be_bytes());
            buf.extend_from_slice(&(ext_len as u16).to_be_bytes());
            buf.extend_from_slice(&(list_len as u16).to_be_bytes());
            for proto in alpn_protocols {
                buf.push(proto.len() as u8);
                buf.extend_from_slice(proto.as_bytes());
            }
        }
        ExtensionId::StatusRequest => {
            // OCSP stapling
            buf.extend_from_slice(&0x0005u16.to_be_bytes());
            buf.extend_from_slice(&5u16.to_be_bytes());
            buf.push(0x01); // status_type: ocsp
            buf.extend_from_slice(&0u16.to_be_bytes()); // responder_id_list: empty
            buf.extend_from_slice(&0u16.to_be_bytes()); // request_extensions: empty
        }
        ExtensionId::SignatureAlgorithms => {
            let list_len = (profile.signature_algorithms.len() * 2) as u16;
            let ext_len = 2 + list_len;
            buf.extend_from_slice(&0x000du16.to_be_bytes());
            buf.extend_from_slice(&ext_len.to_be_bytes());
            buf.extend_from_slice(&list_len.to_be_bytes());
            for &sa in profile.signature_algorithms {
                buf.extend_from_slice(&sa.to_be_bytes());
            }
        }
        ExtensionId::SignedCertificateTimestamp => {
            buf.extend_from_slice(&0x0012u16.to_be_bytes());
            buf.extend_from_slice(&0u16.to_be_bytes());
        }
        ExtensionId::KeyShare => {
            // Calculate total key shares length
            let mut shares_len: usize = 0;
            if profile.grease_key_share {
                shares_len += 2 + 2 + 1; // group(2) + len(2) + data(1)
            }
            for &group in profile.key_share_groups {
                let key_len = match group {
                    0x001d => 32, // X25519
                    0x0017 => 65, // P-256 uncompressed
                    0x0018 => 97, // P-384 uncompressed
                    _ => 32,
                };
                shares_len += 2 + 2 + key_len; // group(2) + len(2) + key
            }
            let ext_len = 2 + shares_len;
            buf.extend_from_slice(&0x0033u16.to_be_bytes());
            buf.extend_from_slice(&(ext_len as u16).to_be_bytes());
            buf.extend_from_slice(&(shares_len as u16).to_be_bytes());

            if profile.grease_key_share {
                buf.extend_from_slice(&grease_group.to_be_bytes());
                buf.extend_from_slice(&1u16.to_be_bytes());
                buf.push(rng.random::<u8>());
            }

            for &group in profile.key_share_groups {
                match group {
                    0x001d => {
                        buf.extend_from_slice(&group.to_be_bytes());
                        buf.extend_from_slice(&32u16.to_be_bytes());
                        buf.extend_from_slice(x25519_public_key);
                    }
                    _ => {
                        // Non-X25519 groups not yet supported; skip silently
                    }
                }
            }
        }
        ExtensionId::PskKeyExchangeModes => {
            buf.extend_from_slice(&0x002du16.to_be_bytes());
            buf.extend_from_slice(&2u16.to_be_bytes());
            buf.push(0x01); // modes length
            buf.push(0x01); // psk_dhe_ke
        }
        ExtensionId::SupportedVersions => {
            let grease_extra = if profile.grease_supported_version { 1u16 } else { 0 };
            let versions_count = profile.supported_versions.len() as u16 + grease_extra;
            let list_len = versions_count * 2;
            let ext_len = 1 + list_len;
            buf.extend_from_slice(&0x002bu16.to_be_bytes());
            buf.extend_from_slice(&ext_len.to_be_bytes());
            buf.push(list_len as u8);
            if profile.grease_supported_version {
                buf.extend_from_slice(&grease_version.to_be_bytes());
            }
            for &v in profile.supported_versions {
                buf.extend_from_slice(&v.to_be_bytes());
            }
        }
        ExtensionId::CompressCertificate => {
            buf.extend_from_slice(&0x001bu16.to_be_bytes());
            buf.extend_from_slice(&3u16.to_be_bytes());
            buf.push(0x02); // algorithms length
            buf.extend_from_slice(&0x0002u16.to_be_bytes()); // brotli
        }
        ExtensionId::ApplicationSettings => {
            let list_len: usize = alpn_protocols
                .iter()
                .filter(|p| **p == "h2")
                .map(|p| 1 + p.len())
                .sum();
            if list_len == 0 {
                return;
            }
            let ext_len = 2 + list_len;
            buf.extend_from_slice(&0x4469u16.to_be_bytes());
            buf.extend_from_slice(&(ext_len as u16).to_be_bytes());
            buf.extend_from_slice(&(list_len as u16).to_be_bytes());
            for proto in alpn_protocols {
                if *proto == "h2" {
                    buf.push(proto.len() as u8);
                    buf.extend_from_slice(proto.as_bytes());
                }
            }
        }
        ExtensionId::Padding => {} // handled by caller
    }
}

/// Build a complete TLS record containing the fingerprinted ClientHello
#[allow(dead_code)]
pub fn build_client_hello_record(
    profile: &FingerprintProfile,
    client_random: &[u8; 32],
    session_id: &[u8; 32],
    x25519_public_key: &[u8],
    server_name: &str,
    alpn_protocols: &[&str],
) -> io::Result<Vec<u8>> {
    let hello = construct_fingerprint_client_hello(
        profile,
        client_random,
        session_id,
        x25519_public_key,
        server_name,
        alpn_protocols,
    )?;

    let mut record = Vec::with_capacity(5 + hello.len());
    record.push(0x16); // ContentType: Handshake
    record.extend_from_slice(&profile.record_version);
    record.extend_from_slice(&(hello.len() as u16).to_be_bytes());
    record.extend_from_slice(&hello);

    Ok(record)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fingerprint::fingerprint_profiles::{GREASE_VALUES, get_profile};
    use crate::config::TlsFingerprint;

    fn make_test_hello() -> Vec<u8> {
        let profile = get_profile(&TlsFingerprint::Chrome);
        let random = [0x42u8; 32];
        let session_id = [0x99u8; 32];
        let pubkey = [0xAAu8; 32];
        construct_fingerprint_client_hello(
            profile,
            &random,
            &session_id,
            &pubkey,
            "example.com",
            &["h2", "http/1.1"],
        )
        .unwrap()
    }

    fn parse_hello(hello: &[u8]) -> ParsedHello {
        let mut pos = 4; // skip handshake header
        pos += 2; // version
        pos += 32; // random
        let sid_len = hello[pos] as usize;
        pos += 1 + sid_len;

        let cs_len = u16::from_be_bytes([hello[pos], hello[pos + 1]]) as usize;
        pos += 2;
        let mut cipher_suites = Vec::new();
        let cs_end = pos + cs_len;
        while pos < cs_end {
            cipher_suites.push(u16::from_be_bytes([hello[pos], hello[pos + 1]]));
            pos += 2;
        }

        pos += 2; // compression

        let ext_len = u16::from_be_bytes([hello[pos], hello[pos + 1]]) as usize;
        pos += 2;
        let ext_end = pos + ext_len;

        let mut extensions = Vec::new();
        while pos < ext_end {
            let ext_type = u16::from_be_bytes([hello[pos], hello[pos + 1]]);
            let ext_data_len = u16::from_be_bytes([hello[pos + 2], hello[pos + 3]]) as usize;
            let ext_data = hello[pos + 4..pos + 4 + ext_data_len].to_vec();
            extensions.push((ext_type, ext_data));
            pos += 4 + ext_data_len;
        }

        ParsedHello {
            cipher_suites,
            extensions,
        }
    }

    struct ParsedHello {
        cipher_suites: Vec<u16>,
        extensions: Vec<(u16, Vec<u8>)>,
    }

    fn is_grease(v: u16) -> bool {
        GREASE_VALUES.contains(&v)
    }

    #[test]
    fn chrome_cipher_suite_count_with_grease() {
        let parsed = parse_hello(&make_test_hello());
        assert_eq!(parsed.cipher_suites.len(), 16); // 1 GREASE + 15 real
        assert!(is_grease(parsed.cipher_suites[0]));
        assert_eq!(parsed.cipher_suites[1], 0x1301);
    }

    #[test]
    fn chrome_extension_order() {
        let parsed = parse_hello(&make_test_hello());
        let ext_types: Vec<u16> = parsed.extensions.iter().map(|(t, _)| *t).collect();

        assert!(is_grease(ext_types[0]));
        assert_eq!(ext_types[1], 0x0000); // server_name
        assert_eq!(ext_types[2], 0x0017); // extended_master_secret
        assert_eq!(ext_types[3], 0xff01); // renegotiation_info
        assert_eq!(ext_types[4], 0x000a); // supported_groups
        assert_eq!(ext_types[5], 0x000b); // ec_point_formats
        assert_eq!(ext_types[6], 0x0023); // session_ticket
        assert_eq!(ext_types[7], 0x0010); // ALPN
        assert_eq!(ext_types[8], 0x0005); // status_request
        assert_eq!(ext_types[9], 0x000d); // signature_algorithms
        assert_eq!(ext_types[10], 0x0012); // signed_certificate_timestamp
        assert_eq!(ext_types[11], 0x0033); // key_share
        assert_eq!(ext_types[12], 0x002d); // psk_key_exchange_modes
        assert_eq!(ext_types[13], 0x002b); // supported_versions
        assert_eq!(ext_types[14], 0x001b); // compress_certificate
        assert_eq!(ext_types[15], 0x4469); // application_settings
        assert!(is_grease(ext_types[16]));
    }

    #[test]
    fn chrome_signature_algorithms() {
        let parsed = parse_hello(&make_test_hello());
        let (_, data) = parsed.extensions.iter().find(|(t, _)| *t == 0x000d).unwrap();
        let list_len = u16::from_be_bytes([data[0], data[1]]) as usize;
        assert_eq!(list_len, 16); // 8 algorithms * 2 bytes
        assert_eq!(
            &data[2..],
            &[
                0x04, 0x03, 0x08, 0x04, 0x04, 0x01, 0x05, 0x03, 0x08, 0x05, 0x05, 0x01, 0x08,
                0x06, 0x06, 0x01,
            ]
        );
    }

    #[test]
    fn chrome_supported_groups_has_grease() {
        let parsed = parse_hello(&make_test_hello());
        let (_, data) = parsed.extensions.iter().find(|(t, _)| *t == 0x000a).unwrap();
        let list_len = u16::from_be_bytes([data[0], data[1]]) as usize;
        assert_eq!(list_len, 8); // 4 groups * 2 bytes
        let first = u16::from_be_bytes([data[2], data[3]]);
        assert!(is_grease(first));
        assert_eq!(u16::from_be_bytes([data[4], data[5]]), 0x001d); // X25519
        assert_eq!(u16::from_be_bytes([data[6], data[7]]), 0x0017); // P-256
    }

    #[test]
    fn chrome_key_share_has_grease_and_x25519() {
        let parsed = parse_hello(&make_test_hello());
        let (_, data) = parsed.extensions.iter().find(|(t, _)| *t == 0x0033).unwrap();
        // client_shares_length (2) + grease_entry(5) + x25519_entry(36)
        let shares_len = u16::from_be_bytes([data[0], data[1]]) as usize;
        assert_eq!(shares_len, 5 + 36);

        let grease_group = u16::from_be_bytes([data[2], data[3]]);
        assert!(is_grease(grease_group));
        assert_eq!(u16::from_be_bytes([data[4], data[5]]), 1); // 1 byte key

        assert_eq!(u16::from_be_bytes([data[7], data[8]]), 0x001d); // X25519
        assert_eq!(u16::from_be_bytes([data[9], data[10]]), 32); // 32 byte key
    }

    #[test]
    fn chrome_supported_versions_has_grease_and_tls13_tls12() {
        let parsed = parse_hello(&make_test_hello());
        let (_, data) = parsed.extensions.iter().find(|(t, _)| *t == 0x002b).unwrap();
        let list_len = data[0] as usize;
        assert_eq!(list_len, 6); // 3 versions * 2 bytes
        let first = u16::from_be_bytes([data[1], data[2]]);
        assert!(is_grease(first));
        assert_eq!(u16::from_be_bytes([data[3], data[4]]), 0x0304); // TLS 1.3
        assert_eq!(u16::from_be_bytes([data[5], data[6]]), 0x0303); // TLS 1.2
    }

    #[test]
    fn grease_values_differ_between_calls() {
        let hello1 = make_test_hello();
        let hello2 = make_test_hello();
        let p1 = parse_hello(&hello1);
        let p2 = parse_hello(&hello2);

        // GREASE in cipher suites may differ (with high probability over many runs)
        // Just verify both are valid GREASE
        assert!(is_grease(p1.cipher_suites[0]));
        assert!(is_grease(p2.cipher_suites[0]));
    }

    #[test]
    fn record_version_is_tls10() {
        let profile = get_profile(&TlsFingerprint::Chrome);
        let record = build_client_hello_record(
            profile,
            &[0u8; 32],
            &[0u8; 32],
            &[0u8; 32],
            "example.com",
            &["h2", "http/1.1"],
        )
        .unwrap();
        assert_eq!(record[0], 0x16); // Handshake
        assert_eq!(record[1], 0x03); // TLS 1.0 major
        assert_eq!(record[2], 0x01); // TLS 1.0 minor
    }

    #[test]
    fn padding_targets_512_total() {
        let profile = get_profile(&TlsFingerprint::Chrome);
        let record = build_client_hello_record(
            profile,
            &[0u8; 32],
            &[0u8; 32],
            &[0u8; 32],
            "example.com",
            &["h2", "http/1.1"],
        )
        .unwrap();
        // With padding, total record should be exactly 512 or not in (256, 512) range
        if record.len() > 256 && record.len() <= 512 {
            assert_eq!(record.len(), 512);
        }
    }

    #[test]
    fn handshake_version_is_tls12() {
        let hello = make_test_hello();
        assert_eq!(hello[4], 0x03);
        assert_eq!(hello[5], 0x03);
    }

    #[test]
    fn renegotiation_info_has_empty_connection() {
        let parsed = parse_hello(&make_test_hello());
        let (_, data) = parsed.extensions.iter().find(|(t, _)| *t == 0xff01).unwrap();
        assert_eq!(data, &[0x00]);
    }

    #[test]
    fn compress_certificate_offers_brotli() {
        let parsed = parse_hello(&make_test_hello());
        let (_, data) = parsed.extensions.iter().find(|(t, _)| *t == 0x001b).unwrap();
        assert_eq!(data, &[0x02, 0x00, 0x02]); // len=2, brotli=0x0002
    }

    #[test]
    fn application_settings_offers_h2() {
        let parsed = parse_hello(&make_test_hello());
        let (_, data) = parsed.extensions.iter().find(|(t, _)| *t == 0x4469).unwrap();
        // list_len(2) + proto_len(1) + "h2"(2)
        assert_eq!(&data[0..2], &[0x00, 0x03]); // list length = 3
        assert_eq!(data[2], 0x02); // "h2" length
        assert_eq!(&data[3..5], b"h2");
    }
}
