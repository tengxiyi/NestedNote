//! 迁移护栏（铁律 Q2 / Q10）。
//!
//! ## 为什么需要这个测试
//!
//! 已发布的迁移文件一旦被修改，会造成**新装用户与老用户的 schema 悄悄分叉**：
//! 老用户的库是按旧文件迁移过的，永远不会重新执行；新用户的库按新文件创建。
//! 两者表面版本号相同，实际结构不同 —— 这类问题只在生产环境爆雷。
//!
//! 因此这里做两件事：
//! 1. **哈希清单**：每个已发布迁移文件的 SHA-256 必须与下表一致。任何修改都会失败。
//! 2. **清单一致性**：磁盘上的文件与代码内嵌的 `MIGRATIONS` 必须一一对应。
//!
//! ## 如果确实需要修改一条迁移
//!
//! **不要**改历史文件（除非该迁移从未发布给任何用户，且经过负责人批准）。
//! 正确做法是新增 `000N_xxx.sql` 并在 [`nested_db::migrations::MIGRATIONS`] 中追加。
//!
//! ## 如果本测试因"仅仅是换行符变了"而失败
//!
//! 运行 `pwsh scripts/normalize-line-endings.ps1`（`.gitattributes` 已规定迁移为 LF）。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use nested_db::migrations::MIGRATIONS;

/// 已发布迁移的哈希清单：`文件名 -> 小写十六进制 SHA-256`。
///
/// 新增迁移时**追加**一行；修改既有行等于承认"改动了已发布迁移"，需走 ADR。
const MIGRATION_HASHES: &[(&str, &str)] = &[(
    "0001_init.sql",
    "4566e916ca98e4d437020b13a79999abaf6fa7639a09146f57b8159125d93341",
)];

/// 定位迁移目录：`client/migrations`。
fn migrations_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../migrations")
}

/// 极简 SHA-256 实现，避免为一个测试引入额外依赖（铁律 A8：依赖必须值得）。
///
/// 仅用于**完整性护栏**，安全性不依赖它（这不是密码学用途）。
fn sha256_hex(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a_2f98,
        0x7137_4491,
        0xb5c0_fbcf,
        0xe9b5_dba5,
        0x3956_c25b,
        0x59f1_11f1,
        0x923f_82a4,
        0xab1c_5ed5,
        0xd807_aa98,
        0x1283_5b01,
        0x2431_85be,
        0x550c_7dc3,
        0x72be_5d74,
        0x80de_b1fe,
        0x9bdc_06a7,
        0xc19b_f174,
        0xe49b_69c1,
        0xefbe_4786,
        0x0fc1_9dc6,
        0x240c_a1cc,
        0x2de9_2c6f,
        0x4a74_84aa,
        0x5cb0_a9dc,
        0x76f9_88da,
        0x983e_5152,
        0xa831_c66d,
        0xb003_27c8,
        0xbf59_7fc7,
        0xc6e0_0bf3,
        0xd5a7_9147,
        0x06ca_6351,
        0x1429_2967,
        0x27b7_0a85,
        0x2e1b_2138,
        0x4d2c_6dfc,
        0x5338_0d13,
        0x650a_7354,
        0x766a_0abb,
        0x81c2_c92e,
        0x9272_2c85,
        0xa2bf_e8a1,
        0xa81a_664b,
        0xc24b_8b70,
        0xc76c_51a3,
        0xd192_e819,
        0xd699_0624,
        0xf40e_3585,
        0x106a_a070,
        0x19a4_c116,
        0x1e37_6c08,
        0x2748_774c,
        0x34b0_bcb5,
        0x391c_0cb3,
        0x4ed8_aa4a,
        0x5b9c_ca4f,
        0x682e_6ff3,
        0x748f_82ee,
        0x78a5_636f,
        0x84c8_7814,
        0x8cc7_0208,
        0x90be_fffa,
        0xa450_6ceb,
        0xbef9_a3f7,
        0xc671_78f2,
    ];
    const H0: [u32; 8] = [
        0x6a09_e667,
        0xbb67_ae85,
        0x3c6e_f372,
        0xa54f_f53a,
        0x510e_527f,
        0x9b05_688c,
        0x1f83_d9ab,
        0x5be0_cd19,
    ];

    let mut message = data.to_vec();
    let bit_len = (data.len() as u64).wrapping_mul(8);
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&bit_len.to_be_bytes());

    let mut hash = H0;
    for chunk in message.chunks_exact(64) {
        let mut w = [0u32; 64];
        for (index, word) in w.iter_mut().take(16).enumerate() {
            let base = index * 4;
            *word = u32::from_be_bytes([
                chunk[base],
                chunk[base + 1],
                chunk[base + 2],
                chunk[base + 3],
            ]);
        }
        for index in 16..64 {
            let s0 = w[index - 15].rotate_right(7)
                ^ w[index - 15].rotate_right(18)
                ^ (w[index - 15] >> 3);
            let s1 = w[index - 2].rotate_right(17)
                ^ w[index - 2].rotate_right(19)
                ^ (w[index - 2] >> 10);
            w[index] = w[index - 16]
                .wrapping_add(s0)
                .wrapping_add(w[index - 7])
                .wrapping_add(s1);
        }

        let mut a = hash[0];
        let mut b = hash[1];
        let mut c = hash[2];
        let mut d = hash[3];
        let mut e = hash[4];
        let mut f = hash[5];
        let mut g = hash[6];
        let mut h = hash[7];

        for index in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let temp1 = h
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[index])
                .wrapping_add(w[index]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);

            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }

        hash[0] = hash[0].wrapping_add(a);
        hash[1] = hash[1].wrapping_add(b);
        hash[2] = hash[2].wrapping_add(c);
        hash[3] = hash[3].wrapping_add(d);
        hash[4] = hash[4].wrapping_add(e);
        hash[5] = hash[5].wrapping_add(f);
        hash[6] = hash[6].wrapping_add(g);
        hash[7] = hash[7].wrapping_add(h);
    }

    hash.iter().map(|word| format!("{word:08x}")).collect()
}

#[test]
fn sha256_implementation_is_correct() {
    // 已知向量：空串与 "abc"
    assert_eq!(
        sha256_hex(b""),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );
    assert_eq!(
        sha256_hex(b"abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
}

#[test]
fn published_migrations_are_unchanged() {
    let dir = migrations_dir();
    let mut actual: BTreeMap<String, String> = BTreeMap::new();

    for entry in std::fs::read_dir(&dir)
        .unwrap_or_else(|error| panic!("无法读取迁移目录 {}：{error}", dir.display()))
        .flatten()
    {
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("sql") {
            continue;
        }
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or_default()
            .to_owned();
        let bytes = std::fs::read(&path)
            .unwrap_or_else(|error| panic!("无法读取 {}：{error}", path.display()));
        actual.insert(name, sha256_hex(&bytes));
    }

    for (name, expected) in MIGRATION_HASHES {
        let found = actual.get(*name).unwrap_or_else(|| {
            panic!("迁移文件 {name} 不存在：它已被重命名或删除，这会破坏老用户升级路径")
        });
        assert_eq!(
            found, expected,
            "迁移文件 {name} 内容已改变！\n\
             已发布的迁移不可修改（铁律 Q2）。请新增一条迁移，而不是改这一条。\n\
             若只是换行符漂移，运行 pwsh scripts/normalize-line-endings.ps1"
        );
    }

    assert_eq!(
        actual.len(),
        MIGRATION_HASHES.len(),
        "磁盘上的迁移文件与哈希清单数量不一致：新增迁移时必须同时登记哈希。\n\
         磁盘：{actual:#?}"
    );
}

#[test]
fn embedded_migrations_match_files_on_disk() {
    for migration in MIGRATIONS {
        let file_name = format!("{}.sql", migration.name);
        let path = migrations_dir().join(&file_name);
        let bytes = std::fs::read(&path)
            .unwrap_or_else(|error| panic!("{} 无法读取：{error}", path.display()));
        let on_disk = String::from_utf8(bytes).expect("迁移文件必须是 UTF-8");
        assert_eq!(
            on_disk, migration.sql,
            "{file_name} 与代码内嵌的 SQL 不一致：迁移清单与文件已漂移"
        );
    }
}

#[test]
fn migration_names_match_version_numbers() {
    for migration in MIGRATIONS {
        let expected_prefix = format!("{:04}_", migration.version);
        assert!(
            migration.name.starts_with(&expected_prefix),
            "迁移名称 {} 应以 {} 开头（名称必须与版本号对应）",
            migration.name,
            expected_prefix.trim_end_matches('_')
        );
    }
}

#[test]
fn migrations_are_lf_terminated() {
    let dir = migrations_dir();
    for entry in std::fs::read_dir(&dir).expect("读取迁移目录").flatten() {
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("sql") {
            continue;
        }
        let bytes = std::fs::read(&path).expect("读取文件");
        assert!(
            !bytes.contains(&b'\r'),
            "{} 含 CR 字符（必须为 LF 行尾，否则哈希会随平台漂移）",
            path.display()
        );
    }
}
