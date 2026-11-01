//! Native-parent pinned, fresh proof receipts. Configuration booleans confer no authority.
use p256::ecdsa::{signature::Verifier, Signature, VerifyingKey};
use p256::pkcs8::DecodePublicKey;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AttestationError(pub &'static str);

/// All pin fields originate in the trusted native parent's process handoff,
/// never in the mutable JSON config or signed payload being evaluated.
pub struct AttestationExpectation<'a> {
    pub receipt_file: &'a Path,
    pub public_key_file: &'a Path,
    pub profile_id: &'a str,
    pub generation: &'a str,
    pub trusted_public_key_sha256: &'a str,
    pub expected_parent_pid: i32,
    pub executable_path: &'a Path,
    pub expected_policy_sha256: &'a str,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum BoundaryTier {
    Landlock,
    Proot,
}
impl BoundaryTier {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Landlock => "landlock",
            Self::Proot => "proot",
        }
    }
}

#[derive(Debug)]
pub struct VerifiedBoundary {
    pub tier: BoundaryTier,
    pub generation: String,
    pub policy_sha256: String,
    pub receipt_sha256: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Receipt {
    schema_version: u32,
    #[serde(default)]
    tier: Option<BoundaryTier>,
    profile_id: String,
    parent_pid: i32,
    generation: String,
    boot_id: String,
    kernel_release: String,
    policy_sha256: String,
    engine_sha256: String,
    sandbox_sha256: String,
    probe_sha256: String,
    issued_at_elapsed_ms: u64,
    protected_launches_required: bool,
    controls: Controls,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Controls {
    native_attacks_denied: bool,
    proot_git_compatible: bool,
    fixture_unchanged: bool,
    complete: bool,
    #[serde(default)]
    canonical_paths_denied: Option<bool>,
    #[serde(default)]
    daemon_proc_denied: Option<bool>,
    #[serde(default)]
    fd_hygiene: Option<bool>,
    #[serde(default)]
    parent_inspection_denied: Option<bool>,
}

pub fn verify(expected: &AttestationExpectation<'_>) -> Result<VerifiedBoundary, AttestationError> {
    verify_impl(expected, true)
}

pub fn verify_current(
    expected: &AttestationExpectation<'_>,
    accepted: &VerifiedBoundary,
) -> Result<VerifiedBoundary, AttestationError> {
    if expected.generation != accepted.generation
        || expected.expected_policy_sha256 != accepted.policy_sha256
        || digest(&read_bounded(expected.receipt_file, 16384)?) != accepted.receipt_sha256
    {
        return Err(AttestationError("attestationChanged"));
    }
    let current = verify_impl(expected, false)?;
    if current.tier != accepted.tier {
        return Err(AttestationError("attestationChanged"));
    }
    Ok(current)
}

fn verify_impl(
    expected: &AttestationExpectation<'_>,
    fresh_start: bool,
) -> Result<VerifiedBoundary, AttestationError> {
    if !hex(expected.trusted_public_key_sha256)
        || !hex(expected.expected_policy_sha256)
        || expected.expected_parent_pid <= 1
        || uuid::Uuid::parse_str(expected.generation).is_err()
    {
        return Err(AttestationError("attestationPinInvalid"));
    }
    let key_bytes = read_bounded(expected.public_key_file, 4096)?;
    if digest(&key_bytes) != expected.trusted_public_key_sha256 {
        return Err(AttestationError("attestationKeyMismatch"));
    }
    let key = VerifyingKey::from_public_key_der(&key_bytes)
        .map_err(|_| AttestationError("attestationKeyInvalid"))?;
    let payload = read_bounded(expected.receipt_file, 16384)?;
    let signature = read_bounded(&signature_path(expected.receipt_file), 256)?;
    let signature = Signature::from_der(&signature)
        .map_err(|_| AttestationError("attestationSignatureInvalid"))?;
    key.verify(&payload, &signature)
        .map_err(|_| AttestationError("attestationSignatureInvalid"))?;
    let receipt: Receipt =
        serde_json::from_slice(&payload).map_err(|_| AttestationError("attestationMalformed"))?;
    let tier = match (receipt.schema_version, receipt.tier) {
        (1, None | Some(BoundaryTier::Landlock)) => BoundaryTier::Landlock,
        (2, Some(tier)) => tier,
        _ => return Err(AttestationError("attestationTierInvalid")),
    };
    if receipt.profile_id != expected.profile_id
        || receipt.generation != expected.generation
        || receipt.parent_pid != expected.expected_parent_pid
        || unsafe { libc::getppid() } != expected.expected_parent_pid
        || receipt.policy_sha256 != expected.expected_policy_sha256
        || !receipt.protected_launches_required
    {
        return Err(AttestationError("attestationGenerationMismatch"));
    }
    let tier_controls = match tier {
        BoundaryTier::Landlock => receipt.controls.native_attacks_denied,
        BoundaryTier::Proot => {
            receipt.controls.canonical_paths_denied == Some(true)
                && receipt.controls.daemon_proc_denied == Some(true)
                && receipt.controls.fd_hygiene == Some(true)
                && receipt.controls.parent_inspection_denied == Some(true)
        }
    };
    if !(tier_controls
        && receipt.controls.proot_git_compatible
        && receipt.controls.fixture_unchanged
        && receipt.controls.complete)
    {
        return Err(AttestationError("attestationIncomplete"));
    }
    if receipt.boot_id != boot_id()? || receipt.kernel_release != kernel_release()? {
        return Err(AttestationError("attestationBootMismatch"));
    }
    let now = elapsed_ms()?;
    if receipt.issued_at_elapsed_ms == 0
        || receipt.issued_at_elapsed_ms > now
        || (fresh_start && now - receipt.issued_at_elapsed_ms > 120_000)
    {
        return Err(AttestationError("attestationStale"));
    }
    let directory = expected
        .executable_path
        .parent()
        .ok_or(AttestationError("attestationBinaryMismatch"))?;
    if receipt.engine_sha256 != hash_file(expected.executable_path)?
        || receipt.sandbox_sha256 != hash_file(&directory.join("libaiteam_sandbox.so"))?
        || receipt.probe_sha256 != hash_file(&directory.join("libaiteam_boundary_probe.so"))?
    {
        return Err(AttestationError("attestationBinaryMismatch"));
    }
    Ok(VerifiedBoundary {
        tier,
        generation: receipt.generation,
        policy_sha256: receipt.policy_sha256,
        receipt_sha256: digest(&payload),
    })
}

pub fn signature_path(receipt: &Path) -> PathBuf {
    let mut name = receipt.as_os_str().to_os_string();
    name.push(".sig");
    PathBuf::from(name)
}

pub fn boot_id() -> Result<String, AttestationError> {
    let bytes = std::fs::read("/proc/sys/kernel/random/boot_id")
        .map_err(|_| AttestationError("attestationRuntimeUnavailable"))?;
    let id = std::str::from_utf8(&bytes)
        .map_err(|_| AttestationError("attestationRuntimeUnavailable"))?
        .trim();
    if uuid::Uuid::parse_str(id).is_err() {
        return Err(AttestationError("attestationRuntimeUnavailable"));
    }
    Ok(id.to_owned())
}

pub fn kernel_release() -> Result<String, AttestationError> {
    let mut info = std::mem::MaybeUninit::<libc::utsname>::uninit();
    if unsafe { libc::uname(info.as_mut_ptr()) } != 0 {
        return Err(AttestationError("attestationRuntimeUnavailable"));
    }
    let info = unsafe { info.assume_init() };
    unsafe { std::ffi::CStr::from_ptr(info.release.as_ptr()) }
        .to_str()
        .map(str::to_owned)
        .map_err(|_| AttestationError("attestationRuntimeUnavailable"))
}

pub fn elapsed_ms() -> Result<u64, AttestationError> {
    let mut time = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    if unsafe { libc::clock_gettime(libc::CLOCK_BOOTTIME, &mut time) } != 0 || time.tv_sec < 0 {
        return Err(AttestationError("attestationRuntimeUnavailable"));
    }
    Ok((time.tv_sec as u64).saturating_mul(1000) + time.tv_nsec as u64 / 1_000_000)
}

// The cache contains only file bytes, never accepted receipt authority. APK
// libraries are immutable in normal operation; a metadata change forces a hash.
const BINARY_HASH_CACHE_LIMIT: usize = 64;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct BinaryIdentity {
    device: u64,
    inode: u64,
    size: u64,
    modified_seconds: i64,
    modified_nanoseconds: i64,
    changed_seconds: i64,
    changed_nanoseconds: i64,
}

impl BinaryIdentity {
    fn from_file(file: &std::fs::File) -> Result<Self, AttestationError> {
        let metadata = file
            .metadata()
            .map_err(|_| AttestationError("attestationFileUnavailable"))?;
        if !metadata.is_file() {
            return Err(AttestationError("attestationFileUnavailable"));
        }
        Ok(Self {
            device: metadata.dev(),
            inode: metadata.ino(),
            size: metadata.len(),
            modified_seconds: metadata.mtime(),
            modified_nanoseconds: metadata.mtime_nsec(),
            changed_seconds: metadata.ctime(),
            changed_nanoseconds: metadata.ctime_nsec(),
        })
    }
}

#[derive(Default)]
struct BinaryHashCache {
    entries: VecDeque<(BinaryIdentity, String)>,
    #[cfg(test)]
    hash_reads: usize,
}

fn open_binary(path: &Path) -> Result<std::fs::File, AttestationError> {
    std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| AttestationError("attestationFileUnavailable"))
}

pub fn hash_file(path: &Path) -> Result<String, AttestationError> {
    static CACHE: OnceLock<Mutex<BinaryHashCache>> = OnceLock::new();
    let mut cache = CACHE
        .get_or_init(|| Mutex::new(BinaryHashCache::default()))
        .lock()
        .map_err(|_| AttestationError("attestationFileUnavailable"))?;
    hash_file_cached(path, &mut cache)
}

fn hash_file_cached(path: &Path, cache: &mut BinaryHashCache) -> Result<String, AttestationError> {
    // Opening and inspecting the actual descriptor on every check prevents a
    // removed/unreadable/symlinked path from borrowing a previously cached hash.
    let mut file = open_binary(path)?;
    let before = BinaryIdentity::from_file(&file)?;
    let cached_index = cache.entries.iter().position(|(id, _)| *id == before);
    let value = if let Some(index) = cached_index {
        cache.entries[index].1.clone()
    } else {
        #[cfg(test)]
        {
            cache.hash_reads += 1;
        }
        let mut hash = Sha256::new();
        let mut buffer = [0_u8; 65536];
        loop {
            let n = file
                .read(&mut buffer)
                .map_err(|_| AttestationError("attestationFileUnavailable"))?;
            if n == 0 {
                break;
            }
            hash.update(&buffer[..n]);
        }
        format!("{:x}", hash.finalize())
    };
    // Both a same-inode write during hashing and a path replacement invalidate
    // this check. Failed guards never insert or return a cached result.
    verify_binary_identity(&file, path, before)?;
    if let Some(index) = cached_index {
        cache.entries.remove(index);
    }
    cache.entries.push_front((before, value.clone()));
    cache.entries.truncate(BINARY_HASH_CACHE_LIMIT);
    Ok(value)
}

fn verify_binary_identity(
    file: &std::fs::File,
    path: &Path,
    before: BinaryIdentity,
) -> Result<(), AttestationError> {
    let after = BinaryIdentity::from_file(file)?;
    let current = BinaryIdentity::from_file(&open_binary(path)?)?;
    if before != after || before != current {
        return Err(AttestationError("attestationBinaryChanged"));
    }
    Ok(())
}

fn read_bounded(path: &Path, limit: usize) -> Result<Vec<u8>, AttestationError> {
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| AttestationError("attestationFileUnavailable"))?;
    if !file
        .metadata()
        .map_err(|_| AttestationError("attestationFileUnavailable"))?
        .is_file()
    {
        return Err(AttestationError("attestationFileUnavailable"));
    }
    let mut bytes = Vec::new();
    file.take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| AttestationError("attestationFileUnavailable"))?;
    if bytes.len() > limit {
        return Err(AttestationError("attestationMalformed"));
    }
    Ok(bytes)
}

fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn hex(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

#[cfg(test)]
mod cache_tests {
    use super::*;

    fn directory() -> tempfile::TempDir {
        let root = std::env::var_os("OC_PHONE_PROOF_ROOT")
            .or_else(|| std::env::var_os("CARGO_TARGET_DIR"))
            .map(PathBuf::from)
            .unwrap_or_else(|| std::env::current_dir().unwrap().join("target"))
            .join("attestation-cache-fixtures");
        std::fs::create_dir_all(&root).unwrap();
        tempfile::tempdir_in(root).unwrap()
    }

    #[test]
    fn unchanged_binary_is_read_once_and_cache_is_bounded() {
        let directory = directory();
        let binary = directory.path().join("engine.so");
        std::fs::write(&binary, b"binary").unwrap();
        let mut cache = BinaryHashCache::default();
        let first = hash_file_cached(&binary, &mut cache).unwrap();
        for _ in 0..20 {
            assert_eq!(hash_file_cached(&binary, &mut cache).unwrap(), first);
        }
        assert_eq!(
            cache.hash_reads, 1,
            "repeated checks must not re-read ELF bytes"
        );
        for index in 0..BINARY_HASH_CACHE_LIMIT + 3 {
            let path = directory.path().join(format!("binary-{index}.so"));
            std::fs::write(&path, index.to_le_bytes()).unwrap();
            hash_file_cached(&path, &mut cache).unwrap();
        }
        assert_eq!(cache.entries.len(), BINARY_HASH_CACHE_LIMIT);
        let reads = cache.hash_reads;
        assert_eq!(hash_file_cached(&binary, &mut cache).unwrap(), first);
        assert_eq!(cache.hash_reads, reads + 1, "evicted ELF must be re-hashed");
    }

    #[test]
    fn replacement_and_same_size_timestamp_restored_write_invalidate_cache() {
        let directory = directory();
        let binary = directory.path().join("engine.so");
        std::fs::write(&binary, b"binary").unwrap();
        let mut cache = BinaryHashCache::default();
        let original = hash_file_cached(&binary, &mut cache).unwrap();
        let modified = std::fs::metadata(&binary).unwrap().modified().unwrap();
        // Retaining length and mtime must not hide a same-inode write: ctime
        // cannot be restored by an ordinary unprivileged application.
        std::thread::sleep(std::time::Duration::from_millis(2));
        std::fs::write(&binary, b"edited").unwrap();
        std::fs::File::options()
            .write(true)
            .open(&binary)
            .unwrap()
            .set_times(std::fs::FileTimes::new().set_modified(modified))
            .unwrap();
        assert_ne!(hash_file_cached(&binary, &mut cache).unwrap(), original);
        assert_eq!(cache.hash_reads, 2);
        let replacement = directory.path().join("replacement.so");
        std::fs::write(&replacement, b"binary").unwrap();
        std::fs::rename(replacement, &binary).unwrap();
        assert_eq!(hash_file_cached(&binary, &mut cache).unwrap(), original);
        assert_eq!(cache.hash_reads, 3, "a different inode requires a new hash");
    }

    #[test]
    fn same_descriptor_and_current_path_guards_detect_changes_during_read() {
        let directory = directory();
        let binary = directory.path().join("engine.so");
        std::fs::write(&binary, b"binary").unwrap();
        let file = open_binary(&binary).unwrap();
        let before = BinaryIdentity::from_file(&file).unwrap();
        assert!(verify_binary_identity(&file, &binary, before).is_ok());
        std::fs::write(&binary, b"longer binary").unwrap();
        assert_eq!(
            verify_binary_identity(&file, &binary, before)
                .unwrap_err()
                .0,
            "attestationBinaryChanged"
        );
        let before_replacement = BinaryIdentity::from_file(&file).unwrap();
        let replacement = directory.path().join("replacement.so");
        std::fs::write(&replacement, b"longer binary").unwrap();
        std::fs::rename(replacement, &binary).unwrap();
        assert_eq!(
            verify_binary_identity(&file, &binary, before_replacement)
                .unwrap_err()
                .0,
            "attestationBinaryChanged"
        );
    }

    #[test]
    fn removed_symlinked_and_nonregular_paths_cannot_borrow_cached_hash() {
        let directory = directory();
        let binary = directory.path().join("engine.so");
        let target = directory.path().join("target.so");
        std::fs::write(&binary, b"binary").unwrap();
        std::fs::write(&target, b"binary").unwrap();
        let mut cache = BinaryHashCache::default();
        hash_file_cached(&binary, &mut cache).unwrap();
        std::fs::remove_file(&binary).unwrap();
        assert_eq!(
            hash_file_cached(&binary, &mut cache).unwrap_err().0,
            "attestationFileUnavailable"
        );
        std::os::unix::fs::symlink(&target, &binary).unwrap();
        assert_eq!(
            hash_file_cached(&binary, &mut cache).unwrap_err().0,
            "attestationFileUnavailable"
        );
        std::fs::remove_file(&binary).unwrap();
        std::fs::create_dir(&binary).unwrap();
        assert_eq!(
            hash_file_cached(&binary, &mut cache).unwrap_err().0,
            "attestationFileUnavailable"
        );
        assert_eq!(cache.hash_reads, 1);
    }
}
