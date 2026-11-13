//! Shared link core for apnum: Noise XX sessions, chunked framing and pairing helpers.
//! The wire format is specified in docs/link-protocol.md.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use blake2::{Blake2s256, Digest};
use percent_encoding::{percent_decode_str, utf8_percent_encode, NON_ALPHANUMERIC};
use std::sync::{Mutex, MutexGuard};

uniffi::setup_scaffolding!();

const PATTERN: &str = "Noise_XX_25519_ChaChaPoly_BLAKE2s";
/// Maximum plaintext bytes per Noise transport message.
const CHUNK: usize = 65_000;
const TAG: usize = 16;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum LinkError {
    #[error("handshake error: {msg}")]
    Handshake { msg: String },
    #[error("crypto error: {msg}")]
    Crypto { msg: String },
    #[error("format error: {msg}")]
    Format { msg: String },
}

fn hs_err(e: impl std::fmt::Display) -> LinkError {
    LinkError::Handshake { msg: e.to_string() }
}
fn crypto_err(e: impl std::fmt::Display) -> LinkError {
    LinkError::Crypto { msg: e.to_string() }
}
fn fmt_err(m: &str) -> LinkError {
    LinkError::Format { msg: m.to_string() }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|p| p.into_inner())
}

// ---------------------------------------------------------------- keys

#[derive(Debug, Clone, uniffi::Record)]
pub struct KeyPair {
    pub private_key: Vec<u8>,
    pub public_key: Vec<u8>,
}

#[uniffi::export]
pub fn generate_keypair() -> Result<KeyPair, LinkError> {
    let kp = snow::Builder::new(PATTERN.parse().map_err(hs_err)?)
        .generate_keypair()
        .map_err(hs_err)?;
    Ok(KeyPair { private_key: kp.private, public_key: kp.public })
}

#[uniffi::export]
pub fn public_key_for(private_key: Vec<u8>) -> Result<Vec<u8>, LinkError> {
    let sk: [u8; 32] = private_key
        .as_slice()
        .try_into()
        .map_err(|_| fmt_err("private key must be 32 bytes"))?;
    // X25519 base-point multiplication via snow's resolver.
    let resolver = snow::resolvers::DefaultResolver;
    use snow::resolvers::CryptoResolver;
    let mut dh = resolver
        .resolve_dh(&snow::params::DHChoice::Curve25519)
        .ok_or_else(|| crypto_err("no x25519"))?;
    dh.set(&sk);
    Ok(dh.pubkey().to_vec())
}

// ---------------------------------------------------------------- handshake

#[derive(uniffi::Object)]
pub struct Handshake {
    state: Mutex<Option<snow::HandshakeState>>,
}

impl Handshake {
    fn build(local_private_key: Vec<u8>, initiator: bool) -> Result<Self, LinkError> {
        if local_private_key.len() != 32 {
            return Err(fmt_err("private key must be 32 bytes"));
        }
        let b = snow::Builder::new(PATTERN.parse().map_err(hs_err)?).local_private_key(&local_private_key);
        let st = if initiator { b.build_initiator() } else { b.build_responder() }.map_err(hs_err)?;
        Ok(Self { state: Mutex::new(Some(st)) })
    }
}

#[uniffi::export]
impl Handshake {
    /// Phone side.
    #[uniffi::constructor]
    pub fn initiator(local_private_key: Vec<u8>) -> Result<Self, LinkError> {
        Self::build(local_private_key, true)
    }

    /// Mac side.
    #[uniffi::constructor]
    pub fn responder(local_private_key: Vec<u8>) -> Result<Self, LinkError> {
        Self::build(local_private_key, false)
    }

    /// The next handshake message to send (empty payload).
    pub fn write_message(&self) -> Result<Vec<u8>, LinkError> {
        let mut g = lock(&self.state);
        let st = g.as_mut().ok_or_else(|| hs_err("handshake already consumed"))?;
        let mut buf = vec![0u8; 1024];
        let n = st.write_message(&[], &mut buf).map_err(hs_err)?;
        buf.truncate(n);
        Ok(buf)
    }

    /// Feed a received handshake message.
    pub fn read_message(&self, message: Vec<u8>) -> Result<(), LinkError> {
        let mut g = lock(&self.state);
        let st = g.as_mut().ok_or_else(|| hs_err("handshake already consumed"))?;
        let mut buf = vec![0u8; message.len().max(1024)];
        st.read_message(&message, &mut buf).map_err(hs_err)?;
        Ok(())
    }

    pub fn is_finished(&self) -> bool {
        lock(&self.state).as_ref().map(|s| s.is_handshake_finished()).unwrap_or(false)
    }

    /// The peer's static key, once it has arrived.
    pub fn remote_public_key(&self) -> Option<Vec<u8>> {
        lock(&self.state).as_ref().and_then(|s| s.get_remote_static().map(|k| k.to_vec()))
    }

    /// Valid when finished.
    pub fn handshake_hash(&self) -> Result<Vec<u8>, LinkError> {
        let g = lock(&self.state);
        let st = g.as_ref().ok_or_else(|| hs_err("handshake already consumed"))?;
        if !st.is_handshake_finished() {
            return Err(hs_err("handshake not finished"));
        }
        Ok(st.get_handshake_hash().to_vec())
    }

    /// Consumes the handshake state; a second call errors.
    pub fn into_session(&self) -> Result<Session, LinkError> {
        let mut g = lock(&self.state);
        match g.as_ref() {
            None => return Err(hs_err("handshake already consumed")),
            Some(s) if !s.is_handshake_finished() => return Err(hs_err("handshake not finished")),
            _ => {}
        }
        let st = g.take().expect("checked above");
        let t = st.into_transport_mode().map_err(hs_err)?;
        Ok(Session { transport: Mutex::new(t) })
    }
}

// ---------------------------------------------------------------- session

#[derive(uniffi::Object)]
pub struct Session {
    transport: Mutex<snow::TransportState>,
}

#[uniffi::export]
impl Session {
    /// Split into 65,000-byte chunks, encrypt each, output `[u16 BE len][ciphertext]` per chunk.
    pub fn seal(&self, plaintext: Vec<u8>) -> Result<Vec<u8>, LinkError> {
        let mut t = lock(&self.transport);
        let mut out = Vec::with_capacity(plaintext.len() + (plaintext.len() / CHUNK + 1) * (TAG + 2));
        let mut buf = vec![0u8; CHUNK + TAG];
        let chunks: Vec<&[u8]> = if plaintext.is_empty() { vec![&[][..]] } else { plaintext.chunks(CHUNK).collect() };
        for c in chunks {
            let n = t.write_message(c, &mut buf).map_err(crypto_err)?;
            out.extend_from_slice(&(n as u16).to_be_bytes());
            out.extend_from_slice(&buf[..n]);
        }
        Ok(out)
    }

    /// Decrypt and join. Errors on any tampering or malformed framing.
    pub fn open(&self, sealed: Vec<u8>) -> Result<Vec<u8>, LinkError> {
        let mut t = lock(&self.transport);
        let mut out = Vec::with_capacity(sealed.len());
        let mut buf = vec![0u8; CHUNK + TAG];
        let mut rest = sealed.as_slice();
        if rest.is_empty() {
            return Err(fmt_err("empty sealed message"));
        }
        while !rest.is_empty() {
            if rest.len() < 2 {
                return Err(fmt_err("truncated length prefix"));
            }
            let len = u16::from_be_bytes([rest[0], rest[1]]) as usize;
            rest = &rest[2..];
            if len < TAG || len > CHUNK + TAG {
                return Err(fmt_err("bad chunk length"));
            }
            if rest.len() < len {
                return Err(fmt_err("truncated chunk"));
            }
            let n = t.read_message(&rest[..len], &mut buf).map_err(crypto_err)?;
            out.extend_from_slice(&buf[..n]);
            rest = &rest[len..];
        }
        Ok(out)
    }
}

// ---------------------------------------------------------------- pairing helpers

#[uniffi::export]
pub fn pairing_token() -> Result<Vec<u8>, LinkError> {
    let mut t = vec![0u8; 16];
    getrandom::getrandom(&mut t).map_err(crypto_err)?;
    Ok(t)
}

fn digits(domain: &[u8], data: &[u8], modulus: u32, width: usize) -> String {
    let mut h = Blake2s256::new();
    h.update(domain);
    h.update(data);
    let d = h.finalize();
    let v = u32::from_be_bytes([d[0], d[1], d[2], d[3]]) % modulus;
    format!("{:0width$}", v, width = width)
}

/// 8 decimal digits derived from the token.
#[uniffi::export]
pub fn pairing_code(token: Vec<u8>) -> String {
    digits(b"apnum-pairing-code", &token, 100_000_000, 8)
}

/// 6 decimal digits derived from the handshake hash.
#[uniffi::export]
pub fn safety_number(handshake_hash: Vec<u8>) -> String {
    digits(b"apnum-safety-number", &handshake_hash, 1_000_000, 6)
}

/// "4F2A 91C0 7B3E 55D1": first 8 bytes of BLAKE2s(public key), uppercase hex in groups of four.
#[uniffi::export]
pub fn fingerprint(public_key: Vec<u8>) -> String {
    let d = Blake2s256::digest(&public_key);
    d[..8]
        .chunks(2)
        .map(|c| format!("{:02X}{:02X}", c[0], c[1]))
        .collect::<Vec<_>>()
        .join(" ")
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PairInfo {
    pub host: String,
    pub port: u16,
    pub public_key: Vec<u8>,
    pub token: Vec<u8>,
    pub name: String,
}

#[uniffi::export]
pub fn make_pair_uri(host: String, port: u16, public_key: Vec<u8>, token: Vec<u8>, name: String) -> String {
    format!(
        "apnum://pair?v=1&host={}&port={}&pk={}&token={}&name={}",
        utf8_percent_encode(&host, NON_ALPHANUMERIC),
        port,
        URL_SAFE_NO_PAD.encode(public_key),
        URL_SAFE_NO_PAD.encode(token),
        utf8_percent_encode(&name, NON_ALPHANUMERIC),
    )
}

#[uniffi::export]
pub fn parse_pair_uri(uri: String) -> Result<PairInfo, LinkError> {
    let rest = uri.trim().strip_prefix("apnum://pair?").ok_or_else(|| fmt_err("not an apnum pairing link"))?;
    let (mut v, mut host, mut port, mut pk, mut token, mut name) = (None, None, None, None, None, None);
    for pair in rest.split('&') {
        let (k, val) = pair.split_once('=').unwrap_or((pair, ""));
        let dec = || percent_decode_str(val).decode_utf8().map(|s| s.into_owned()).map_err(|_| fmt_err("invalid encoding"));
        match k {
            "v" => v = Some(val.to_string()),
            "host" => host = Some(dec()?),
            "port" => port = Some(val.to_string()),
            "pk" => pk = Some(val.to_string()),
            "token" => token = Some(val.to_string()),
            "name" => name = Some(dec()?),
            _ => {}
        }
    }
    if v.as_deref() != Some("1") {
        return Err(fmt_err("unsupported pairing link version"));
    }
    let host = host.filter(|h| !h.is_empty()).ok_or_else(|| fmt_err("missing host"))?;
    let port: u16 = port.and_then(|p| p.parse().ok()).filter(|p| *p != 0).ok_or_else(|| fmt_err("bad port"))?;
    let public_key = URL_SAFE_NO_PAD
        .decode(pk.ok_or_else(|| fmt_err("missing pk"))?)
        .ok()
        .filter(|k| k.len() == 32)
        .ok_or_else(|| fmt_err("bad public key"))?;
    let token = URL_SAFE_NO_PAD
        .decode(token.ok_or_else(|| fmt_err("missing token"))?)
        .ok()
        .filter(|t| t.len() == 16)
        .ok_or_else(|| fmt_err("bad token"))?;
    Ok(PairInfo { host, port, public_key, token, name: name.unwrap_or_default() })
}
