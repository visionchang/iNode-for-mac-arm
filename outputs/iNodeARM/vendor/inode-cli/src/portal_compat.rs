//! Portal compatibility checked against Mac E0641 and Windows E0598.
//! These fixed keys and encodings are protocol obfuscation, not TLS security.
use anyhow::{Result, ensure};
use base64::Engine;
use std::io::Read;
use zeroize::Zeroizing;

pub fn password(value: &str, flag: u8) -> Result<Zeroizing<Vec<u8>>> {
    ensure!(!value.as_bytes().contains(&0), "Portal 密码不能包含空字符");
    if flag == 0 {
        return Ok(Zeroizing::new(value.as_bytes().to_vec()));
    }
    ensure!(flag == 1, "Portal 密码编码类型 {flag} 尚需适配");
    ensure!(
        value.len() <= 32,
        "该 Portal 密码编码最多支持 32 字节，请确认密码长度"
    );
    let mut out = Zeroizing::new(vec![0; 32]);
    out[..value.len()].copy_from_slice(value.as_bytes());
    // The installed E0641 utility uses 32-bit wrapping arithmetic and SAR
    // (signed right shift). E0653's 64-bit implementation produces different
    // bytes; matching its isolated routine did not establish server compatibility.
    let key = [0x35469812u32, 0x83479025, 0x23192486, 0x36615829];
    for block in out.chunks_exact_mut(8) {
        let mut a = u32::from_le_bytes(block[..4].try_into().unwrap());
        let mut b = u32::from_le_bytes(block[4..].try_into().unwrap());
        let mut sum = 0u32;
        for _ in 0..16 {
            a = a.wrapping_add(
                ((b << 4) ^ ((b as i32 >> 5) as u32))
                    .wrapping_add(sum ^ b)
                    .wrapping_add(key[(sum & 3) as usize]),
            );
            sum = sum.wrapping_add(0x9e3779b9);
            b = b.wrapping_add(
                ((a << 4) ^ ((a as i32 >> 5) as u32))
                    .wrapping_add(sum ^ a)
                    .wrapping_add(key[((sum >> 11) & 3) as usize]),
            );
        }
        block[..4].copy_from_slice(&a.to_le_bytes());
        block[4..].copy_from_slice(&b.to_le_bytes());
    }
    Ok(out)
}

fn mix(bytes: &mut [u8], key: &[u8]) {
    let n = bytes.len();
    for i in 0..n {
        bytes[i] ^= key[i % key.len()] ^ key[(n - 1 - i) % key.len()];
    }
}
fn version(seed: [u8; 4]) -> [u8; 20] {
    let mut out = [0u8; 20];
    let text = b"CH1V7.30-0653";
    out[..text.len()].copy_from_slice(text);
    let hex = seed.iter().map(|v| format!("{v:02x}")).collect::<String>();
    mix(&mut out[..16], hex.as_bytes());
    out[16..].copy_from_slice(&seed);
    mix(&mut out, b"Oly5D62FaE94W7");
    out
}

pub fn client_info(mac: Option<&[u8]>) -> Result<Vec<u8>> {
    let mut random = std::fs::File::open("/dev/urandom")?;
    let version = loop {
        let mut seed = [0; 4];
        random.read_exact(&mut seed)?;
        let v = version(seed);
        if !v.contains(&0) {
            break v;
        }
    };
    let encoded = base64::engine::general_purpose::STANDARD.encode(version);
    // Attribute 33 contains nested TLVs: 1=version, 255=MAC. A bare MAC
    // string here is not the original client's wire format.
    let mut out = vec![1, (encoded.len() + 2) as u8];
    out.extend_from_slice(encoded.as_bytes());
    if let Some(mac) = mac {
        let text = mac
            .iter()
            .map(|v| format!("{v:02x}"))
            .collect::<Vec<_>>()
            .join(":");
        out.extend_from_slice(&[255, (text.len() + 2) as u8]);
        out.extend_from_slice(text.as_bytes());
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn version_matches_original_resource_transform_and_mix() {
        // Original InitVersion retains '-' and removes the release letter E.
        // Offline original EOR_WithMix, seed 01 02 03 04, Chinese locale.
        let actual = version([1, 2, 3, 4])
            .iter()
            .map(|v| format!("{v:02x}"))
            .collect::<String>();
        assert_eq!(actual, "3e617e181d5437257c4d49622006782c4d4e2b7d");
    }
    #[test]
    fn password_matches_mac_e0641_and_windows_e0598_machine_code() {
        // Identical vectors from the installed E0641 utility's pure routine
        // and offline x86 emulation of Windows E0598 inode_utility.dll at
        // RVA 0xb3d90 (called by utl_EncryptHashKey at RVA 0xb3fc0).
        // Both decrypt roundtrips also pass. No real credentials or network.
        for (plain, expected) in [
            (
                "test&password",
                "8506da662c4c8355825db6f1d6426d8ed2b3265832d34baad2b3265832d34baa",
            ),
            (
                "local-test-password",
                "cc6050ab719ffd4a1872d43eca8b5c346b95cdb10cf998dad2b3265832d34baa",
            ),
            (
                "12345678901234567890123456789012",
                "43b2a3436170eea07ae9351552b3f1d01ce9777707cec4a6eb2646ab4c5c1ea4",
            ),
        ] {
            let actual = password(plain, 1)
                .unwrap()
                .iter()
                .map(|v| format!("{v:02x}"))
                .collect::<String>();
            assert_eq!(actual, expected);
        }
        assert!(password(&"a".repeat(33), 1).is_err());
        assert_eq!(&**password("ordinary", 0).unwrap(), b"ordinary");
    }
    #[test]
    fn client_metadata_uses_nested_fields() {
        let info = client_info(Some(&[0, 1, 2, 3, 4, 5])).unwrap();
        assert_eq!(&info[..2], &[1, 30]);
        assert_eq!(
            base64::engine::general_purpose::STANDARD
                .decode(&info[2..30])
                .unwrap()
                .len(),
            20
        );
        assert_eq!(&info[30..32], &[255, 19]);
        assert_eq!(&info[32..], b"00:01:02:03:04:05");
    }
}
