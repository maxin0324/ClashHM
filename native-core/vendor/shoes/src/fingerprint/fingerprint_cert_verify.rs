use std::io;
use std::io::Write;
use std::sync::{Arc, OnceLock};

use aws_lc_rs::digest;
use aws_lc_rs::signature::{self, UnparsedPublicKey};
use rustls::client::danger::ServerCertVerifier;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use x509_parser::certificate::X509Certificate;
use x509_parser::extensions::GeneralName;
use x509_parser::prelude::FromDer;

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

pub struct CertVerifyInfo {
    pub sig_algorithm: u16,
    pub signature: Vec<u8>,
}

struct BoundedVecWriter {
    buf: Vec<u8>,
    limit: usize,
}

impl BoundedVecWriter {
    fn new(limit: usize) -> Self {
        Self {
            buf: Vec::with_capacity(limit),
            limit,
        }
    }

    fn into_inner(self) -> Vec<u8> {
        self.buf
    }
}

impl Write for BoundedVecWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if self.buf.len().saturating_add(bytes.len()) > self.limit {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Decompressed certificate length exceeds declared size",
            ));
        }
        self.buf.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn crypto_provider() -> Arc<rustls::crypto::CryptoProvider> {
    static INSTANCE: OnceLock<Arc<rustls::crypto::CryptoProvider>> = OnceLock::new();
    INSTANCE
        .get_or_init(|| Arc::new(rustls::crypto::aws_lc_rs::default_provider()))
        .clone()
}

fn root_cert_store() -> Arc<rustls::RootCertStore> {
    static INSTANCE: OnceLock<Arc<rustls::RootCertStore>> = OnceLock::new();
    INSTANCE
        .get_or_init(|| {
            Arc::new(rustls::RootCertStore {
                roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
            })
        })
        .clone()
}

pub fn extract_certificate_chain(certificate_message: &[u8]) -> io::Result<Vec<Vec<u8>>> {
    if certificate_message.len() < 4 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Certificate message too short",
        ));
    }

    let mut pos = 4;
    if pos >= certificate_message.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Certificate message truncated at context length",
        ));
    }
    let context_len = certificate_message[pos] as usize;
    pos += 1 + context_len;

    if pos + 3 > certificate_message.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Certificate message truncated at list length",
        ));
    }
    let list_len = u32::from_be_bytes([
        0,
        certificate_message[pos],
        certificate_message[pos + 1],
        certificate_message[pos + 2],
    ]) as usize;
    pos += 3;

    let list_end = pos.checked_add(list_len).ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidData, "Certificate list length overflow")
    })?;
    if list_end > certificate_message.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Certificate message truncated at certificate list",
        ));
    }

    let mut certs = Vec::new();
    while pos < list_end {
        if pos + 3 > list_end {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Certificate message truncated at cert length",
            ));
        }
        let cert_len = u32::from_be_bytes([
            0,
            certificate_message[pos],
            certificate_message[pos + 1],
            certificate_message[pos + 2],
        ]) as usize;
        pos += 3;
        if pos + cert_len > list_end {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Certificate message truncated at cert data",
            ));
        }
        certs.push(certificate_message[pos..pos + cert_len].to_vec());
        pos += cert_len;

        if pos + 2 > list_end {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Certificate message truncated at cert extensions length",
            ));
        }
        let ext_len = u16::from_be_bytes([certificate_message[pos], certificate_message[pos + 1]])
            as usize;
        pos += 2;
        if pos + ext_len > list_end {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Certificate message truncated at cert extensions",
            ));
        }
        pos += ext_len;
    }

    if certs.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Certificate chain is empty",
        ));
    }
    Ok(certs)
}

pub fn decompress_certificate_message(compressed_msg: &[u8]) -> io::Result<Vec<u8>> {
    if compressed_msg.len() < 4 + 8 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "CompressedCertificate message too short",
        ));
    }

    let body = &compressed_msg[4..];
    let handshake_len = u32::from_be_bytes([
        0,
        compressed_msg[1],
        compressed_msg[2],
        compressed_msg[3],
    ]) as usize;
    if handshake_len != body.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "CompressedCertificate handshake length mismatch",
        ));
    }

    let algorithm = u16::from_be_bytes([body[0], body[1]]);
    let uncompressed_length = u32::from_be_bytes([0, body[2], body[3], body[4]]) as usize;
    let compressed_len = u32::from_be_bytes([0, body[5], body[6], body[7]]) as usize;

    if 8 + compressed_len > body.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "CompressedCertificate data truncated",
        ));
    }
    if 8 + compressed_len != body.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "CompressedCertificate contains trailing data",
        ));
    }
    let compressed_data = &body[8..8 + compressed_len];

    if algorithm != 0x0002 {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            format!("Unsupported certificate compression algorithm: 0x{:04x}", algorithm),
        ));
    }

    if uncompressed_length > 1 << 22 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Uncompressed certificate length too large",
        ));
    }

    let mut decompressed = BoundedVecWriter::new(uncompressed_length);
    brotli::BrotliDecompress(&mut std::io::Cursor::new(compressed_data), &mut decompressed)
        .map_err(|e| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Brotli decompression failed: {}", e),
            )
        })?;
    let decompressed = decompressed.into_inner();

    if decompressed.len() != uncompressed_length {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "Decompressed length mismatch: expected {}, got {}",
                uncompressed_length,
                decompressed.len()
            ),
        ));
    }

    let cert_len = decompressed.len();
    let mut full_message = Vec::with_capacity(4 + cert_len);
    full_message.push(0x0b);
    full_message.push(((cert_len >> 16) & 0xff) as u8);
    full_message.push(((cert_len >> 8) & 0xff) as u8);
    full_message.push((cert_len & 0xff) as u8);
    full_message.extend_from_slice(&decompressed);

    Ok(full_message)
}

pub fn verify_certificate_chain(cert_chain: &[Vec<u8>], server_name: &str) -> io::Result<()> {
    let Some((leaf, intermediates)) = cert_chain.split_first() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Certificate chain is empty",
        ));
    };
    let leaf = CertificateDer::from(leaf.clone());
    let intermediates: Vec<CertificateDer<'static>> = intermediates
        .iter()
        .map(|cert| CertificateDer::from(cert.clone()))
        .collect();
    let server_name = ServerName::try_from(server_name.to_string()).map_err(|e| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("Invalid TLS server name '{}': {}", server_name, e),
        )
    })?;
    let verifier =
        rustls::client::WebPkiServerVerifier::builder_with_provider(root_cert_store(), crypto_provider())
            .build()
            .map_err(|e| io::Error::other(format!("Failed to build webpki verifier: {e}")))?;
    verifier
        .verify_server_cert(
            &leaf,
            &intermediates,
            &server_name,
            &[],
            UnixTime::now(),
        )
        .map(|_| ())
        .map_err(|e| {
            io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!("Certificate chain verification failed: {e}"),
            )
        })
}

pub fn extract_cert_verify_info(cert_verify_message: &[u8]) -> io::Result<CertVerifyInfo> {
    if cert_verify_message.len() < 8 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "CertificateVerify message too short",
        ));
    }

    if cert_verify_message[0] != 0x0f {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "Expected CertificateVerify (0x0f), got 0x{:02x}",
                cert_verify_message[0]
            ),
        ));
    }

    let sig_algorithm =
        u16::from_be_bytes([cert_verify_message[4], cert_verify_message[5]]);
    let sig_len =
        u16::from_be_bytes([cert_verify_message[6], cert_verify_message[7]]) as usize;

    let sig_start = 8;
    if sig_start + sig_len > cert_verify_message.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "CertificateVerify signature truncated",
        ));
    }

    Ok(CertVerifyInfo {
        sig_algorithm,
        signature: cert_verify_message[sig_start..sig_start + sig_len].to_vec(),
    })
}

pub fn verify_certificate_verify_signature(
    cert_der: &[u8],
    sig_algorithm: u16,
    sig_bytes: &[u8],
    transcript_hash: &[u8],
) -> io::Result<()> {
    let (_, cert) = X509Certificate::from_der(cert_der).map_err(|e| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("Failed to parse certificate: {}", e),
        )
    })?;

    let spki = cert.public_key();
    let pubkey_data: &[u8] = &spki.subject_public_key.data;

    let mut signed_content = Vec::with_capacity(64 + 34 + transcript_hash.len());
    signed_content.extend_from_slice(&[0x20u8; 64]);
    signed_content.extend_from_slice(b"TLS 1.3, server CertificateVerify");
    signed_content.push(0x00);
    signed_content.extend_from_slice(transcript_hash);

    let result = match sig_algorithm {
        0x0403 => {
            // ecdsa_secp256r1_sha256
            let key = UnparsedPublicKey::new(&signature::ECDSA_P256_SHA256_ASN1, pubkey_data);
            key.verify(&signed_content, sig_bytes)
        }
        0x0503 => {
            // ecdsa_secp384r1_sha384
            let key = UnparsedPublicKey::new(&signature::ECDSA_P384_SHA384_ASN1, pubkey_data);
            key.verify(&signed_content, sig_bytes)
        }
        0x0804 => {
            // rsa_pss_rsae_sha256
            let key = UnparsedPublicKey::new(
                &signature::RSA_PSS_2048_8192_SHA256,
                pubkey_data,
            );
            key.verify(&signed_content, sig_bytes)
        }
        0x0805 => {
            // rsa_pss_rsae_sha384
            let key = UnparsedPublicKey::new(
                &signature::RSA_PSS_2048_8192_SHA384,
                pubkey_data,
            );
            key.verify(&signed_content, sig_bytes)
        }
        0x0806 => {
            // rsa_pss_rsae_sha512
            let key = UnparsedPublicKey::new(
                &signature::RSA_PSS_2048_8192_SHA512,
                pubkey_data,
            );
            key.verify(&signed_content, sig_bytes)
        }
        // RFC 8446 §4.4.3: PKCS#1 v1.5 (0x0401, 0x0501, 0x0601) MUST NOT be used in TLS 1.3 CertificateVerify
        0x0401 | 0x0501 | 0x0601 => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("PKCS#1 v1.5 signature (0x{:04x}) is forbidden in TLS 1.3 CertificateVerify", sig_algorithm),
            ));
        }
        0x0807 => {
            // ed25519
            let key = UnparsedPublicKey::new(&signature::ED25519, pubkey_data);
            key.verify(&signed_content, sig_bytes)
        }
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Unsupported signature algorithm: 0x{:04x}", sig_algorithm),
            ));
        }
    };

    result.map_err(|_| {
        io::Error::new(
            io::ErrorKind::PermissionDenied,
            "CertificateVerify signature verification failed",
        )
    })
}

pub fn verify_server_name(cert_der: &[u8], server_name: &str) -> io::Result<()> {
    let (_, cert) = X509Certificate::from_der(cert_der).map_err(|e| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("Failed to parse certificate: {}", e),
        )
    })?;

    if let Ok(Some(san_ext)) = cert.subject_alternative_name() {
        for name in &san_ext.value.general_names {
            match name {
                GeneralName::DNSName(dns) => {
                    if matches_hostname(dns, server_name) {
                        return Ok(());
                    }
                }
                GeneralName::IPAddress(ip_bytes) => {
                    let ip_str = match ip_bytes.len() {
                        4 => format!("{}.{}.{}.{}", ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3]),
                        16 => {
                            let parts: Vec<String> = ip_bytes
                                .chunks(2)
                                .map(|c| format!("{:02x}{:02x}", c[0], c[1]))
                                .collect();
                            parts.join(":")
                        }
                        _ => continue,
                    };
                    if ip_str == server_name {
                        return Ok(());
                    }
                }
                _ => {}
            }
        }
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("Certificate SAN does not match server name '{}'", server_name),
        ));
    }

    // Fall back to Common Name
    if let Some(cn) = cert.subject().iter_common_name().next() {
        if let Ok(cn_str) = cn.as_str() {
            if matches_hostname(cn_str, server_name) {
                return Ok(());
            }
        }
    }

    Err(io::Error::new(
        io::ErrorKind::PermissionDenied,
        format!("Certificate does not match server name '{}'", server_name),
    ))
}

fn matches_hostname(pattern: &str, hostname: &str) -> bool {
    let pattern = pattern.to_ascii_lowercase();
    let hostname = hostname.to_ascii_lowercase();

    if pattern == hostname {
        return true;
    }

    if let Some(suffix) = pattern.strip_prefix("*.") {
        if let Some(pos) = hostname.find('.') {
            return &hostname[pos + 1..] == suffix;
        }
    }

    false
}

pub fn verify_certificate_fingerprint(
    cert_der: &[u8],
    expected_fingerprints: &[String],
) -> io::Result<()> {
    if expected_fingerprints.is_empty() {
        return Ok(());
    }

    let actual = digest::digest(&digest::SHA256, cert_der);
    let actual_hex = hex_encode(actual.as_ref());

    for fp in expected_fingerprints {
        let normalized = fp.replace(':', "").to_lowercase();
        if normalized == actual_hex {
            return Ok(());
        }
    }

    Err(io::Error::new(
        io::ErrorKind::PermissionDenied,
        format!(
            "Certificate fingerprint mismatch: got {}",
            actual_hex
        ),
    ))
}


#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn push_u24(out: &mut Vec<u8>, value: usize) {
        out.push(((value >> 16) & 0xff) as u8);
        out.push(((value >> 8) & 0xff) as u8);
        out.push((value & 0xff) as u8);
    }

    fn brotli_compress(bytes: &[u8]) -> Vec<u8> {
        let mut writer = brotli::CompressorWriter::new(Vec::new(), 4096, 5, 22);
        writer.write_all(bytes).unwrap();
        writer.into_inner()
    }

    fn compressed_certificate_message(
        algorithm: u16,
        uncompressed_length: usize,
        compressed_data: &[u8],
    ) -> Vec<u8> {
        let body_len = 8 + compressed_data.len();
        let mut msg = Vec::new();
        msg.push(0x19);
        push_u24(&mut msg, body_len);
        msg.extend_from_slice(&algorithm.to_be_bytes());
        push_u24(&mut msg, uncompressed_length);
        push_u24(&mut msg, compressed_data.len());
        msg.extend_from_slice(compressed_data);
        msg
    }

    fn certificate_body() -> Vec<u8> {
        let cert = [0x42u8];
        let cert_entry_len = 3 + cert.len() + 2;
        let mut body = Vec::new();
        body.push(0); // certificate_request_context length
        push_u24(&mut body, cert_entry_len);
        push_u24(&mut body, cert.len());
        body.extend_from_slice(&cert);
        body.extend_from_slice(&0u16.to_be_bytes()); // certificate extensions length
        body
    }

    #[test]
    fn extract_cert_verify_info_valid() {
        let mut msg = Vec::new();
        msg.push(0x0f); // type
        msg.extend_from_slice(&[0x00, 0x00, 0x48]); // length = 72
        msg.extend_from_slice(&[0x08, 0x04]); // rsa_pss_rsae_sha256
        msg.extend_from_slice(&[0x00, 0x40]); // sig_len = 64
        msg.extend_from_slice(&[0xAB; 64]); // signature

        let info = extract_cert_verify_info(&msg).unwrap();
        assert_eq!(info.sig_algorithm, 0x0804);
        assert_eq!(info.signature.len(), 64);
    }

    #[test]
    fn extract_cert_verify_info_wrong_type() {
        let msg = vec![0x0b; 72];
        assert!(extract_cert_verify_info(&msg).is_err());
    }

    #[test]
    fn verify_fingerprint_matches() {
        let cert_data = b"test certificate data";
        let hash = digest::digest(&digest::SHA256, cert_data);
        let hex_fp = hex_encode(hash.as_ref());

        let result =
            verify_certificate_fingerprint(cert_data, &[hex_fp]);
        assert!(result.is_ok());
    }

    #[test]
    fn verify_fingerprint_mismatch() {
        let cert_data = b"test certificate data";
        let wrong_fp = "00".repeat(32);

        let result =
            verify_certificate_fingerprint(cert_data, &[wrong_fp]);
        assert!(result.is_err());
    }

    #[test]
    fn verify_fingerprint_with_colons() {
        let cert_data = b"test certificate data";
        let hash = digest::digest(&digest::SHA256, cert_data);
        let hex_str = hex_encode(hash.as_ref());
        let with_colons: String = hex_str
            .as_bytes()
            .chunks(2)
            .map(|c| std::str::from_utf8(c).unwrap())
            .collect::<Vec<_>>()
            .join(":");

        let result =
            verify_certificate_fingerprint(cert_data, &[with_colons]);
        assert!(result.is_ok());
    }

    #[test]
    fn empty_fingerprints_passes() {
        let result = verify_certificate_fingerprint(b"anything", &[]);
        assert!(result.is_ok());
    }

    #[test]
    fn decompress_certificate_message_valid_brotli() {
        let body = certificate_body();
        let compressed = brotli_compress(&body);
        let msg = compressed_certificate_message(0x0002, body.len(), &compressed);

        let decompressed = decompress_certificate_message(&msg).unwrap();
        assert_eq!(decompressed[0], 0x0b);
        assert_eq!(&decompressed[4..], body.as_slice());

        let chain = extract_certificate_chain(&decompressed).unwrap();
        assert_eq!(chain, vec![vec![0x42]]);
    }

    #[test]
    fn decompress_certificate_message_rejects_unsupported_algorithm() {
        let body = certificate_body();
        let compressed = brotli_compress(&body);
        let msg = compressed_certificate_message(0x0001, body.len(), &compressed);

        assert!(decompress_certificate_message(&msg).is_err());
    }

    #[test]
    fn decompress_certificate_message_rejects_truncated_data() {
        let body = certificate_body();
        let compressed = brotli_compress(&body);
        let mut msg = compressed_certificate_message(0x0002, body.len(), &compressed);
        msg.pop();

        assert!(decompress_certificate_message(&msg).is_err());
    }

    #[test]
    fn decompress_certificate_message_rejects_trailing_data() {
        let body = certificate_body();
        let compressed = brotli_compress(&body);
        let mut msg = compressed_certificate_message(0x0002, body.len(), &compressed);
        let body_len = 8 + compressed.len() + 1;
        msg[1] = ((body_len >> 16) & 0xff) as u8;
        msg[2] = ((body_len >> 8) & 0xff) as u8;
        msg[3] = (body_len & 0xff) as u8;
        msg.push(0);

        assert!(decompress_certificate_message(&msg).is_err());
    }

    #[test]
    fn decompress_certificate_message_rejects_handshake_length_mismatch() {
        let body = certificate_body();
        let compressed = brotli_compress(&body);
        let mut msg = compressed_certificate_message(0x0002, body.len(), &compressed);
        msg[3] = msg[3].wrapping_add(1);

        assert!(decompress_certificate_message(&msg).is_err());
    }

    #[test]
    fn decompress_certificate_message_rejects_declared_length_mismatch() {
        let body = certificate_body();
        let compressed = brotli_compress(&body);
        let msg = compressed_certificate_message(0x0002, body.len() + 1, &compressed);

        assert!(decompress_certificate_message(&msg).is_err());
    }

    #[test]
    fn decompress_certificate_message_rejects_output_beyond_declared_length() {
        let body = vec![0x55; 4096];
        let compressed = brotli_compress(&body);
        let msg = compressed_certificate_message(0x0002, 1, &compressed);

        assert!(decompress_certificate_message(&msg).is_err());
    }

    #[test]
    fn decompress_certificate_message_rejects_oversized_declared_length() {
        let msg = compressed_certificate_message(0x0002, (1 << 22) + 1, &[]);

        assert!(decompress_certificate_message(&msg).is_err());
    }
}
