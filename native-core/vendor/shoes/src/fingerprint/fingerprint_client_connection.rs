use std::io::{self, Read, Write};

use aws_lc_rs::{agreement, digest};
use rand::RngCore;

use crate::config::TlsFingerprint;
use crate::reality::common::{
    ALERT_DESC_CLOSE_NOTIFY, ALERT_LEVEL_WARNING, CIPHERTEXT_READ_BUF_CAPACITY,
    CONTENT_TYPE_ALERT, CONTENT_TYPE_APPLICATION_DATA, CONTENT_TYPE_CHANGE_CIPHER_SPEC,
    CONTENT_TYPE_HANDSHAKE, HANDSHAKE_TYPE_CERTIFICATE, HANDSHAKE_TYPE_CERTIFICATE_VERIFY,
    HANDSHAKE_TYPE_FINISHED, OUTGOING_BUFFER_LIMIT,
    PLAINTEXT_READ_BUF_CAPACITY, TLS_MAX_RECORD_SIZE, TLS_RECORD_HEADER_SIZE,
};
use crate::reality::reality_aead::{AeadKey, decrypt_handshake_message};
use crate::reality::reality_cipher_suite::CipherSuite;
use crate::reality::reality_io_state::RealityIoState;
use crate::reality::reality_reader_writer::{RealityReader, RealityWriter};
use crate::reality::reality_records::{RecordDecryptor, RecordEncryptor};
use crate::reality::reality_tls13_keys::{
    compute_finished_verify_data, derive_application_secrets, derive_handshake_keys,
    derive_traffic_keys,
};
use crate::reality::reality_tls13_messages::construct_finished;
use crate::reality::reality_util::{extract_server_cipher_suite, extract_server_public_key};
use crate::slide_buffer::SlideBuffer;
use crate::util::allocate_vec;

use super::fingerprint_cert_verify::{
    extract_cert_verify_info, extract_certificate_chain, verify_certificate_chain,
    verify_certificate_fingerprint, verify_certificate_verify_signature,
};
use super::fingerprint_client_hello::construct_fingerprint_client_hello;
use super::fingerprint_profiles::get_profile;

#[derive(Clone, Debug)]
pub struct FingerprintTlsClientConfig {
    pub fingerprint: TlsFingerprint,
    pub server_name: String,
    pub verify: bool,
    pub server_fingerprints: Vec<String>,
    pub alpn_protocols: Vec<String>,
}

enum HandshakeState {
    AwaitingServerHello {
        client_hello_bytes: Vec<u8>,
        client_private_key: [u8; 32],
    },
    ProcessingHandshake {
        client_handshake_traffic_secret: Vec<u8>,
        server_handshake_traffic_secret: Vec<u8>,
        master_secret: Vec<u8>,
        cipher_suite: CipherSuite,
        handshake_transcript_bytes: Vec<u8>,
        handshake_seq: u64,
        accumulated_plaintext: Vec<u8>,
        messages_found: u8,
        cert_chain: Option<Vec<Vec<u8>>>,
        cert_verify_offset: Option<usize>,
        finished_offset: Option<usize>,
    },
    Complete,
}

pub struct FingerprintTlsClientConnection {
    config: FingerprintTlsClientConfig,
    handshake_state: HandshakeState,

    app_read_key: Option<AeadKey>,
    app_read_iv: Option<Vec<u8>>,
    app_write_key: Option<AeadKey>,
    app_write_iv: Option<Vec<u8>>,
    read_seq: u64,
    write_seq: u64,
    cipher_suite: Option<CipherSuite>,

    tls_read_buffer: Box<[u8]>,
    ciphertext_read_buf: SlideBuffer,
    ciphertext_write_buf: Vec<u8>,
    plaintext_read_buf: SlideBuffer,
    plaintext_write_buf: Vec<u8>,

    received_close_notify: bool,
    fatal_error: Option<io::ErrorKind>,
}

impl FingerprintTlsClientConnection {
    pub fn new(config: FingerprintTlsClientConfig) -> io::Result<Self> {
        let mut conn = FingerprintTlsClientConnection {
            config,
            handshake_state: HandshakeState::AwaitingServerHello {
                client_hello_bytes: Vec::new(),
                client_private_key: [0u8; 32],
            },
            app_read_key: None,
            app_read_iv: None,
            app_write_key: None,
            app_write_iv: None,
            read_seq: 0,
            write_seq: 0,
            cipher_suite: None,
            tls_read_buffer: allocate_vec(TLS_MAX_RECORD_SIZE).into_boxed_slice(),
            ciphertext_read_buf: SlideBuffer::new(CIPHERTEXT_READ_BUF_CAPACITY),
            ciphertext_write_buf: Vec::with_capacity(OUTGOING_BUFFER_LIMIT),
            plaintext_read_buf: SlideBuffer::new(PLAINTEXT_READ_BUF_CAPACITY),
            plaintext_write_buf: Vec::with_capacity(OUTGOING_BUFFER_LIMIT),
            received_close_notify: false,
            fatal_error: None,
        };
        conn.generate_client_hello()?;
        Ok(conn)
    }

    fn generate_client_hello(&mut self) -> io::Result<()> {
        let mut rng = rand::rng();

        let mut our_private_bytes = [0u8; 32];
        rng.fill_bytes(&mut our_private_bytes);

        let our_private_key =
            agreement::PrivateKey::from_private_key(&agreement::X25519, &our_private_bytes)
                .map_err(|_| io::Error::other("Failed to create X25519 key"))?;
        let our_public_key_bytes = our_private_key
            .compute_public_key()
            .map_err(|_| io::Error::other("Failed to compute public key"))?;

        let mut client_random = [0u8; 32];
        rng.fill_bytes(&mut client_random);

        let mut session_id = [0u8; 32];
        rng.fill_bytes(&mut session_id);

        let profile = get_profile(&self.config.fingerprint).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::Unsupported,
                format!(
                    "unsupported TLS client fingerprint {:?}; only chrome is implemented",
                    self.config.fingerprint
                ),
            )
        })?;
        let alpn_refs: Vec<&str> = self.config.alpn_protocols.iter().map(|s| s.as_str()).collect();

        let client_hello = construct_fingerprint_client_hello(
            profile,
            &client_random,
            &session_id,
            our_public_key_bytes.as_ref(),
            &self.config.server_name,
            &alpn_refs,
        )?;

        // Build TLS record with profile-specific record version
        let mut record = Vec::with_capacity(5 + client_hello.len());
        record.push(CONTENT_TYPE_HANDSHAKE);
        record.extend_from_slice(&profile.record_version);
        record.extend_from_slice(&(client_hello.len() as u16).to_be_bytes());
        record.extend_from_slice(&client_hello);
        self.ciphertext_write_buf.extend_from_slice(&record);

        self.handshake_state = HandshakeState::AwaitingServerHello {
            client_hello_bytes: client_hello,
            client_private_key: our_private_bytes,
        };

        Ok(())
    }

    pub fn read_tls(&mut self, rd: &mut dyn Read) -> io::Result<usize> {
        if self.ciphertext_read_buf.remaining_capacity() < TLS_MAX_RECORD_SIZE {
            self.ciphertext_read_buf.compact();
        }
        let n = rd.read(&mut self.tls_read_buffer[..])?;
        if n > 0 {
            self.ciphertext_read_buf
                .extend_from_slice(&self.tls_read_buffer[..n]);
        }
        Ok(n)
    }

    pub fn process_new_packets(&mut self) -> io::Result<RealityIoState> {
        if let Some(error_kind) = self.fatal_error {
            return Err(io::Error::new(error_kind, "connection previously failed"));
        }
        if self.received_close_notify {
            return Ok(RealityIoState::new(self.plaintext_read_buf.len()));
        }

        let result = self.process_new_packets_inner();
        if let Err(ref e) = result {
            match e.kind() {
                io::ErrorKind::InvalidData
                | io::ErrorKind::PermissionDenied
                | io::ErrorKind::ConnectionAborted => {
                    self.fatal_error = Some(e.kind());
                }
                _ => {}
            }
        }
        result
    }

    fn process_new_packets_inner(&mut self) -> io::Result<RealityIoState> {
        loop {
            match &self.handshake_state {
                HandshakeState::AwaitingServerHello { .. } => {
                    if !self.process_server_hello()? {
                        break;
                    }
                }
                HandshakeState::ProcessingHandshake { .. } => {
                    if !self.process_encrypted_handshake()? {
                        break;
                    }
                }
                HandshakeState::Complete => {
                    self.process_application_data()?;
                    break;
                }
            }
        }
        Ok(RealityIoState::new(self.plaintext_read_buf.len()))
    }

    fn process_server_hello(&mut self) -> io::Result<bool> {
        let HandshakeState::AwaitingServerHello {
            client_hello_bytes,
            client_private_key,
        } = &self.handshake_state
        else {
            unreachable!()
        };

        if self.ciphertext_read_buf.len() < TLS_RECORD_HEADER_SIZE {
            return Ok(false);
        }

        let record_len = self
            .ciphertext_read_buf
            .get_u16_be(3)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "Buffer too short"))?
            as usize;

        let total_record_len = TLS_RECORD_HEADER_SIZE + record_len;
        if self.ciphertext_read_buf.len() < total_record_len {
            return Ok(false);
        }

        let client_hello_bytes = client_hello_bytes.clone();
        let client_private_key = *client_private_key;

        let record: Vec<u8> = self.ciphertext_read_buf[..total_record_len].to_vec();
        self.ciphertext_read_buf.consume(total_record_len);
        let server_hello = &record[TLS_RECORD_HEADER_SIZE..];

        let server_public_key = extract_server_public_key(&record)?;
        let cipher_suite_id = extract_server_cipher_suite(&record)?;
        let cipher_suite = CipherSuite::from_id(cipher_suite_id).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Unsupported cipher suite: 0x{:04x}", cipher_suite_id),
            )
        })?;

        let mut full_transcript = digest::Context::new(cipher_suite.digest_algorithm());
        full_transcript.update(&client_hello_bytes);
        full_transcript.update(server_hello);
        let server_hello_hash = full_transcript.finish();
        let server_hello_hash_vec: Vec<u8> = server_hello_hash.as_ref().to_vec();

        let client_hello_hash_vec: Vec<u8> = {
            let mut ctx = digest::Context::new(cipher_suite.digest_algorithm());
            ctx.update(&client_hello_bytes);
            ctx.finish().as_ref().to_vec()
        };

        let peer_public_key =
            agreement::UnparsedPublicKey::new(&agreement::X25519, &server_public_key);
        let my_private_key =
            agreement::PrivateKey::from_private_key(&agreement::X25519, &client_private_key)
                .map_err(|_| io::Error::other("Failed to create private key"))?;

        let mut tls_shared_secret = [0u8; 32];
        agreement::agree(
            &my_private_key,
            peer_public_key,
            io::Error::other("ECDH failed"),
            |key_material| {
                tls_shared_secret.copy_from_slice(key_material);
                Ok(())
            },
        )?;

        let hs_keys = derive_handshake_keys(
            cipher_suite,
            &tls_shared_secret,
            &client_hello_hash_vec,
            &server_hello_hash_vec,
        )?;

        let mut transcript_bytes = Vec::new();
        transcript_bytes.extend_from_slice(&client_hello_bytes);
        transcript_bytes.extend_from_slice(server_hello);

        self.handshake_state = HandshakeState::ProcessingHandshake {
            client_handshake_traffic_secret: hs_keys.client_handshake_traffic_secret.clone(),
            server_handshake_traffic_secret: hs_keys.server_handshake_traffic_secret.clone(),
            master_secret: hs_keys.master_secret.clone(),
            cipher_suite,
            handshake_transcript_bytes: transcript_bytes,
            handshake_seq: 0,
            accumulated_plaintext: Vec::new(),
            messages_found: 0,
            cert_chain: None,
            cert_verify_offset: None,
            finished_offset: None,
        };

        Ok(true)
    }

    fn process_encrypted_handshake(&mut self) -> io::Result<bool> {
        let HandshakeState::ProcessingHandshake {
            server_handshake_traffic_secret,
            cipher_suite,
            handshake_seq: _,
            ..
        } = &self.handshake_state
        else {
            unreachable!()
        };

        let (server_hs_key, server_hs_iv) =
            derive_traffic_keys(server_handshake_traffic_secret, *cipher_suite)?;

        if self.ciphertext_read_buf.len() < TLS_RECORD_HEADER_SIZE {
            return Ok(false);
        }

        let record_type = self.ciphertext_read_buf[0];
        let record_len = self
            .ciphertext_read_buf
            .get_u16_be(3)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "Buffer too short"))?
            as usize;

        let total_record_len = TLS_RECORD_HEADER_SIZE + record_len;
        if self.ciphertext_read_buf.len() < total_record_len {
            return Ok(false);
        }

        if record_type == CONTENT_TYPE_CHANGE_CIPHER_SPEC {
            self.ciphertext_read_buf.consume(total_record_len);
            return self.process_encrypted_handshake();
        }

        if record_type != CONTENT_TYPE_APPLICATION_DATA {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Expected Application Data, got 0x{:02x}", record_type),
            ));
        }

        // Clone fields needed for mutation
        let HandshakeState::ProcessingHandshake {
            client_handshake_traffic_secret,
            server_handshake_traffic_secret,
            master_secret,
            cipher_suite,
            handshake_transcript_bytes,
            handshake_seq,
            accumulated_plaintext,
            messages_found,
            cert_chain,
            cert_verify_offset,
            finished_offset,
        } = &self.handshake_state
        else {
            unreachable!()
        };

        let client_hs_secret = client_handshake_traffic_secret.clone();
        let server_hs_secret = server_handshake_traffic_secret.clone();
        let master_secret = master_secret.clone();
        let transcript_bytes = handshake_transcript_bytes.clone();
        let mut accumulated_plaintext = accumulated_plaintext.clone();
        let cipher_suite = *cipher_suite;
        let mut handshake_seq = *handshake_seq;
        let mut messages_found = *messages_found;
        let mut cert_chain = cert_chain.clone();
        let mut cert_verify_offset = *cert_verify_offset;
        let mut finished_offset = *finished_offset;

        let ciphertext: Vec<u8> =
            self.ciphertext_read_buf[TLS_RECORD_HEADER_SIZE..total_record_len].to_vec();
        self.ciphertext_read_buf.consume(total_record_len);

        let plaintext = decrypt_handshake_message(
            cipher_suite,
            &server_hs_key,
            &server_hs_iv,
            handshake_seq,
            &ciphertext,
            record_len as u16,
        )?;

        handshake_seq += 1;

        let prev_accumulated_len = accumulated_plaintext.len();
        accumulated_plaintext.extend_from_slice(&plaintext);

        let mut offset = prev_accumulated_len;
        while offset < accumulated_plaintext.len() && messages_found < 4 {
            if offset + 4 > accumulated_plaintext.len() {
                break;
            }

            let msg_type = accumulated_plaintext[offset];
            let msg_len = u32::from_be_bytes([
                0,
                accumulated_plaintext[offset + 1],
                accumulated_plaintext[offset + 2],
                accumulated_plaintext[offset + 3],
            ]) as usize;

            if offset + 4 + msg_len > accumulated_plaintext.len() {
                break;
            }

            if msg_type == HANDSHAKE_TYPE_CERTIFICATE {
                let chain = extract_certificate_chain(
                    &accumulated_plaintext[offset..offset + 4 + msg_len],
                )?;
                cert_chain = Some(chain);
            }

            if msg_type == HANDSHAKE_TYPE_CERTIFICATE_VERIFY {
                cert_verify_offset = Some(offset);
            }

            if msg_type == HANDSHAKE_TYPE_FINISHED {
                finished_offset = Some(offset);
            }

            messages_found += 1;
            offset += 4 + msg_len;
        }

        if messages_found < 4 {
            self.handshake_state = HandshakeState::ProcessingHandshake {
                client_handshake_traffic_secret: client_hs_secret,
                server_handshake_traffic_secret: server_hs_secret,
                master_secret,
                cipher_suite,
                handshake_transcript_bytes: transcript_bytes,
                handshake_seq,
                accumulated_plaintext,
                messages_found,
                cert_chain,
                cert_verify_offset,
                finished_offset,
            };
            return Ok(true);
        }

        // All 4 messages received — verify certificate and CertificateVerify

        let cert_chain = cert_chain.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "Certificate message not received",
            )
        })?;
        let cert_der = cert_chain.first().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, "Certificate chain is empty")
        })?;

        // Optional server fingerprint pinning
        if !self.config.server_fingerprints.is_empty() {
            verify_certificate_fingerprint(cert_der, &self.config.server_fingerprints)?;
        }

        // Full webpki chain and server name verification when verify is enabled
        if self.config.verify {
            verify_certificate_chain(&cert_chain, &self.config.server_name)?;
        }

        // CertificateVerify signature verification (always performed, even with verify=false)
        let cv_offset = cert_verify_offset.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "CertificateVerify message not received",
            )
        })?;

        let cv_msg_len = u32::from_be_bytes([
            0,
            accumulated_plaintext[cv_offset + 1],
            accumulated_plaintext[cv_offset + 2],
            accumulated_plaintext[cv_offset + 3],
        ]) as usize;
        let cv_message = &accumulated_plaintext[cv_offset..cv_offset + 4 + cv_msg_len];

        let cv_info = extract_cert_verify_info(cv_message)?;

        // Transcript up to (not including) CertificateVerify
        let mut cv_transcript = digest::Context::new(cipher_suite.digest_algorithm());
        cv_transcript.update(&transcript_bytes);
        cv_transcript.update(&accumulated_plaintext[..cv_offset]);
        let cv_transcript_hash = cv_transcript.finish();

        verify_certificate_verify_signature(
            cert_der,
            cv_info.sig_algorithm,
            &cv_info.signature,
            cv_transcript_hash.as_ref(),
        )?;

        // Verify server Finished
        let fin_offset = finished_offset.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "Finished message not received",
            )
        })?;

        let fin_msg_len = u32::from_be_bytes([
            0,
            accumulated_plaintext[fin_offset + 1],
            accumulated_plaintext[fin_offset + 2],
            accumulated_plaintext[fin_offset + 3],
        ]) as usize;
        let server_verify_data = &accumulated_plaintext[fin_offset + 4..fin_offset + 4 + fin_msg_len];

        // Transcript up to (not including) Finished
        let mut fin_transcript = digest::Context::new(cipher_suite.digest_algorithm());
        fin_transcript.update(&transcript_bytes);
        fin_transcript.update(&accumulated_plaintext[..fin_offset]);
        let fin_transcript_hash = fin_transcript.finish();

        let expected_verify_data = compute_finished_verify_data(
            cipher_suite,
            &server_hs_secret,
            fin_transcript_hash.as_ref(),
        )?;

        if server_verify_data != expected_verify_data.as_slice() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Server Finished verify_data mismatch",
            ));
        }

        // Full transcript hash (including Finished) for application key derivation
        let mut handshake_transcript = digest::Context::new(cipher_suite.digest_algorithm());
        handshake_transcript.update(&transcript_bytes);
        handshake_transcript.update(&accumulated_plaintext);
        let handshake_hash = handshake_transcript.finish();
        let handshake_hash_vec: Vec<u8> = handshake_hash.as_ref().to_vec();

        // Send client Finished
        let client_verify_data =
            compute_finished_verify_data(cipher_suite, &client_hs_secret, &handshake_hash_vec)?;
        let client_finished = construct_finished(&client_verify_data)?;

        let (client_hs_key, client_hs_iv) = derive_traffic_keys(&client_hs_secret, cipher_suite)?;
        let mut client_hs_seq = 0u64;
        let hs_aead_key = AeadKey::new(cipher_suite, &client_hs_key)?;
        {
            let mut encryptor =
                RecordEncryptor::new(&hs_aead_key, &client_hs_iv, &mut client_hs_seq);
            encryptor.encrypt_handshake(&client_finished, &mut self.ciphertext_write_buf)?;
        }

        // Derive application traffic keys
        let (client_app_secret, server_app_secret) =
            derive_application_secrets(cipher_suite, &master_secret, &handshake_hash_vec)?;

        let (client_app_key_bytes, client_app_iv) =
            derive_traffic_keys(&client_app_secret, cipher_suite)?;
        let (server_app_key_bytes, server_app_iv) =
            derive_traffic_keys(&server_app_secret, cipher_suite)?;

        self.app_read_key = Some(AeadKey::new(cipher_suite, &server_app_key_bytes)?);
        self.app_read_iv = Some(server_app_iv);
        self.app_write_key = Some(AeadKey::new(cipher_suite, &client_app_key_bytes)?);
        self.app_write_iv = Some(client_app_iv);
        self.read_seq = 0;
        self.write_seq = 0;
        self.cipher_suite = Some(cipher_suite);
        self.handshake_state = HandshakeState::Complete;

        Ok(true)
    }

    fn process_application_data(&mut self) -> io::Result<()> {
        let (app_read_key, app_read_iv) = match (&self.app_read_key, &self.app_read_iv) {
            (Some(key), Some(iv)) => (key, iv),
            _ => unreachable!(),
        };

        while self.ciphertext_read_buf.len() >= TLS_RECORD_HEADER_SIZE {
            let record_len = self
                .ciphertext_read_buf
                .get_u16_be(3)
                .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "Buffer too short"))?
                as usize;

            let total_record_len = TLS_RECORD_HEADER_SIZE + record_len;
            if self.ciphertext_read_buf.len() < total_record_len {
                break;
            }

            let ciphertext_slice = self
                .ciphertext_read_buf
                .slice_mut(TLS_RECORD_HEADER_SIZE..total_record_len);
            let mut decryptor = RecordDecryptor::new(app_read_key, app_read_iv, &mut self.read_seq);
            let (content_type, plaintext) =
                decryptor.decrypt_record_in_place(ciphertext_slice, record_len as u16)?;

            match content_type {
                CONTENT_TYPE_APPLICATION_DATA => {
                    self.plaintext_read_buf.maybe_compact(4096);
                    self.plaintext_read_buf.extend_from_slice(plaintext);
                }
                CONTENT_TYPE_ALERT => {
                    if plaintext.len() >= 2 {
                        let alert_desc = plaintext[1];
                        if alert_desc == ALERT_DESC_CLOSE_NOTIFY {
                            self.received_close_notify = true;
                            return Ok(());
                        } else if plaintext[0] != ALERT_LEVEL_WARNING {
                            return Err(io::Error::new(
                                io::ErrorKind::ConnectionAborted,
                                format!("fatal alert: {}", alert_desc),
                            ));
                        }
                    }
                }
                _ => unreachable!(),
            }

            self.ciphertext_read_buf.consume(total_record_len);
        }

        Ok(())
    }

    pub fn reader(&mut self) -> RealityReader<'_> {
        self.plaintext_read_buf.maybe_compact(4096);
        RealityReader::new(&mut self.plaintext_read_buf, self.received_close_notify)
    }

    pub fn writer(&mut self) -> RealityWriter<'_> {
        RealityWriter::new(&mut self.plaintext_write_buf)
    }

    pub fn write_tls(&mut self, wr: &mut dyn Write) -> io::Result<usize> {
        if !matches!(self.handshake_state, HandshakeState::Complete) {
            let n = wr.write(&self.ciphertext_write_buf)?;
            self.ciphertext_write_buf.drain(..n);
            return Ok(n);
        }

        if !self.plaintext_write_buf.is_empty() {
            let (app_write_key, app_write_iv) = match (&self.app_write_key, &self.app_write_iv) {
                (Some(key), Some(iv)) => (key, iv),
                _ => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "Application keys not available",
                    ));
                }
            };

            let mut encryptor =
                RecordEncryptor::new(app_write_key, app_write_iv, &mut self.write_seq);
            encryptor.encrypt_app_data(
                &mut self.plaintext_write_buf,
                &mut self.ciphertext_write_buf,
            )?;
        }

        let n = wr.write(&self.ciphertext_write_buf)?;
        self.ciphertext_write_buf.drain(..n);
        Ok(n)
    }

    pub fn wants_write(&self) -> bool {
        !self.ciphertext_write_buf.is_empty() || !self.plaintext_write_buf.is_empty()
    }

    pub fn is_handshaking(&self) -> bool {
        !matches!(self.handshake_state, HandshakeState::Complete)
    }

    pub fn wants_read(&self) -> bool {
        if self.received_close_notify || self.fatal_error.is_some() {
            return false;
        }
        if self.is_handshaking() {
            return true;
        }
        self.plaintext_read_buf.is_empty()
    }

    pub fn send_close_notify(&mut self) {
        if !matches!(self.handshake_state, HandshakeState::Complete) {
            return;
        }
        let (app_write_key, app_write_iv) = match (&self.app_write_key, &self.app_write_iv) {
            (Some(key), Some(iv)) => (key, iv),
            _ => return,
        };
        let mut encryptor = RecordEncryptor::new(app_write_key, app_write_iv, &mut self.write_seq);
        let _ = encryptor.encrypt_close_notify(&mut self.ciphertext_write_buf);
    }
}

pub fn feed_fingerprint_client_connection(
    conn: &mut FingerprintTlsClientConnection,
    data: &[u8],
) -> io::Result<()> {
    let mut cursor = io::Cursor::new(data);
    let mut i = 0;
    while i < data.len() {
        let n = conn.read_tls(&mut cursor)?;
        i += n;
    }
    Ok(())
}
