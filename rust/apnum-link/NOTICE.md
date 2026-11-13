# Third-party licences (rust/apnum-link)

apnum-link is MIT licensed. Its dependencies (checked with `cargo tree -f '{p}|{l}'`) are all permissive or file-level copyleft, compatible with MIT distribution:

| Crate | Licence |
|---|---|
| snow (Noise protocol) and its crypto backends: chacha20poly1305, curve25519-dalek, aes-gcm, sha2, blake2, rand_core, subtle | Apache-2.0 / MIT; curve25519-dalek and subtle are BSD-3-Clause |
| base64, getrandom, percent-encoding, thiserror, and the other transitive crates | MIT OR Apache-2.0 (a few MIT only; memchr is Unlicense OR MIT; unicode-ident adds Unicode-3.0) |
| uniffi, uniffi_core, uniffi_macros, uniffi_meta, uniffi_bindgen, uniffi_udl and related | MPL-2.0 (Mozilla). File-level copyleft: we use them unmodified, so the MPL only requires that their source stays available under the MPL. The generated Swift and Kotlin bindings are ours. |

The BSD-3-Clause notices (curve25519-dalek, subtle) must be retained in binary distributions: copyright Isis Agora Lovecruft, Henry de Valence (curve25519-dalek) and Isis Lovecruft, Henry de Valence (subtle).

The Kotlin bindings need JNA (Apache-2.0 or LGPL-2.1, used under Apache-2.0) at runtime on Android.
