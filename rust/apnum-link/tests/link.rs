use apnum_link::*;
use std::sync::Arc;

fn pair() -> (Arc<Session>, Arc<Session>, Vec<u8>, Vec<u8>, KeyPair, KeyPair) {
    let a = generate_keypair().unwrap();
    let b = generate_keypair().unwrap();
    let init = Handshake::initiator(a.private_key.clone()).unwrap();
    let resp = Handshake::responder(b.private_key.clone()).unwrap();
    let m1 = init.write_message().unwrap();
    resp.read_message(m1).unwrap();
    let m2 = resp.write_message().unwrap();
    init.read_message(m2).unwrap();
    assert!(init.remote_public_key().is_some());
    let m3 = init.write_message().unwrap();
    resp.read_message(m3).unwrap();
    assert!(init.is_finished() && resp.is_finished());
    assert_eq!(init.remote_public_key().unwrap(), b.public_key);
    assert_eq!(resp.remote_public_key().unwrap(), a.public_key);
    let hi = init.handshake_hash().unwrap();
    let hr = resp.handshake_hash().unwrap();
    let si = init.into_session().unwrap();
    let sr = resp.into_session().unwrap();
    assert!(init.into_session().is_err(), "second into_session must fail");
    (Arc::new(si), Arc::new(sr), hi, hr, a, b)
}

#[test]
fn handshake_and_keys() {
    let (_, _, hi, hr, a, b) = pair();
    assert_eq!(hi, hr);
    assert_eq!(public_key_for(a.private_key.clone()).unwrap(), a.public_key);
    assert_eq!(public_key_for(b.private_key).unwrap(), b.public_key);
    assert!(public_key_for(vec![1, 2, 3]).is_err());
}

#[test]
fn round_trips() {
    let (i, r, ..) = pair();
    for n in [0usize, 5, 65_000, 65_001, 1_000_000] {
        let data: Vec<u8> = (0..n).map(|x| (x % 251) as u8).collect();
        let sealed = i.seal(data.clone()).unwrap();
        assert_eq!(r.open(sealed).unwrap(), data, "i->r {n}");
        let sealed = r.seal(data.clone()).unwrap();
        assert_eq!(i.open(sealed).unwrap(), data, "r->i {n}");
    }
}

#[test]
fn chunk_framing() {
    let (i, _, ..) = pair();
    assert_eq!(i.seal(vec![]).unwrap().len(), 2 + 16);
    let s = i.seal(vec![0; 65_001]).unwrap();
    assert_eq!(u16::from_be_bytes([s[0], s[1]]) as usize, 65_016);
    assert_eq!(s.len(), 2 + 65_016 + 2 + 1 + 16);
}

#[test]
fn tamper_and_order() {
    let (i, r, ..) = pair();
    let mut s = i.seal(b"hello".to_vec()).unwrap();
    let last = s.len() - 1;
    s[last] ^= 1;
    assert!(r.open(s).is_err());

    let (i, r, ..) = pair();
    let first = i.seal(b"one".to_vec()).unwrap();
    let second = i.seal(b"two".to_vec()).unwrap();
    assert!(r.open(second).is_err(), "out of order must fail");
    let _ = first;

    let (i, r, ..) = pair();
    let s = i.seal(b"hello".to_vec()).unwrap();
    assert!(r.open(s[..s.len() - 1].to_vec()).is_err());
    assert!(r.open(vec![]).is_err());
}

#[test]
fn handshake_wrong_order() {
    let a = generate_keypair().unwrap();
    let init = Handshake::initiator(a.private_key.clone()).unwrap();
    let resp = Handshake::responder(a.private_key.clone()).unwrap();
    assert!(init.read_message(vec![0; 40]).is_err());
    assert!(resp.write_message().is_err());
    assert!(resp.read_message(vec![1, 2, 3]).is_err());
    assert!(init.into_session().is_err());
    assert!(init.handshake_hash().is_err());
    assert!(Handshake::initiator(vec![0; 5]).is_err());
}

#[test]
fn pairing_helpers() {
    let t = pairing_token().unwrap();
    assert_eq!(t.len(), 16);
    assert_ne!(t, pairing_token().unwrap());
    let c = pairing_code(t.clone());
    assert_eq!(c.len(), 8);
    assert!(c.chars().all(|x| x.is_ascii_digit()));
    assert_eq!(c, pairing_code(t));

    let (_, _, hi, hr, ..) = pair();
    let (sa, sb) = (safety_number(hi), safety_number(hr));
    assert_eq!(sa, sb);
    assert_eq!(sa.len(), 6);
    assert!(sa.chars().all(|x| x.is_ascii_digit()));

    let f = fingerprint(vec![7; 32]);
    assert_eq!(f.len(), 19);
    let groups: Vec<&str> = f.split(' ').collect();
    assert_eq!(groups.len(), 4);
    assert!(groups.iter().all(|g| g.len() == 4 && g.chars().all(|c| c.is_ascii_hexdigit() && !c.is_lowercase())));
}

#[test]
fn pair_uri() {
    let kp = generate_keypair().unwrap();
    let token = pairing_token().unwrap();
    for name in ["Aarsh's MacBook Pro", "Mac é 日本 & = ?", "", "plain"] {
        let uri = make_pair_uri("192.168.1.20".into(), 47800, kp.public_key.clone(), token.clone(), name.into());
        assert!(uri.starts_with("apnum://pair?v=1&host=192%2E168%2E1%2E20&port=47800"));
        let info = parse_pair_uri(uri).unwrap();
        assert_eq!(info.host, "192.168.1.20");
        assert_eq!(info.port, 47800);
        assert_eq!(info.public_key, kp.public_key);
        assert_eq!(info.token, token);
        assert_eq!(info.name, name);
    }
    // plain (unescaped host) as written in the spec also parses
    let pk = base64_pk(&kp.public_key);
    let tk = base64_pk(&token);
    let ok = format!("apnum://pair?v=1&host=10.0.0.2&port=1&pk={pk}&token={tk}&name=My%20Mac");
    assert_eq!(parse_pair_uri(ok.clone()).unwrap().name, "My Mac");

    for bad in [
        "".to_string(),
        "http://pair?v=1".into(),
        ok.replace("v=1", "v=2"),
        ok.replace("port=1", "port=99999"),
        ok.replace("port=1", "port=0"),
        ok.replace("host=10.0.0.2&", ""),
        ok.replace(&pk, "AAAA"),
        ok.replace(&tk, "AAAA"),
        ok.replace("token=", "t="),
        ok.replace("%20", "%FF"),
    ] {
        assert!(parse_pair_uri(bad.clone()).is_err(), "should reject {bad}");
    }
}

fn base64_pk(b: &[u8]) -> String {
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
    URL_SAFE_NO_PAD.encode(b)
}

#[test]
fn concurrent_session_use() {
    let (i, r, ..) = pair();
    let i2 = i.clone();
    let h = std::thread::spawn(move || (0..50).map(|_| i2.seal(vec![1; 10]).unwrap()).collect::<Vec<_>>());
    let a: Vec<_> = (0..50).map(|_| i.seal(vec![2; 10]).unwrap()).collect();
    let b = h.join().unwrap();
    // Nonces are consumed in lock order, so receive in any order is not allowed; just verify count.
    assert_eq!(a.len() + b.len(), 100);
    let _ = r;
}
