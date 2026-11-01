//! Run on Storage with the coordinator's machine lock; host proof is not Android evidence.
use std::os::unix::fs::{symlink, PermissionsExt};
use std::process::Command;

fn fixture() -> tempfile::TempDir {
    let root = std::env::var_os("OC_PHONE_PROOF_ROOT")
        .map(std::path::PathBuf::from)
        .expect("set OC_PHONE_PROOF_ROOT to an isolated Storage artifact directory");
    assert!(root.is_absolute());
    std::fs::create_dir_all(&root).unwrap();
    tempfile::tempdir_in(root).unwrap()
}

fn git_fixture(temp: &std::path::Path) -> std::path::PathBuf {
    let generation = uuid::Uuid::new_v4().to_string();
    let parent = temp.join(format!(".phone-engine-proof-{generation}"));
    let protected = parent.join("protected");
    std::fs::create_dir_all(&protected).unwrap();
    for (file, bytes) in [
        (parent.join(".native-proof-fixture"), generation.as_bytes()),
        (
            protected.join("sentinel"),
            b"proof-only-canonical-state".as_slice(),
        ),
    ] {
        std::fs::write(&file, bytes).unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
    protected
}

fn prepare(root: &std::path::Path) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_oc-engine-boundary-probe"))
        .arg("--prepare-git-fixture")
        .arg(root)
        .output()
        .unwrap()
}

#[test]
fn preparer_seeds_real_main_and_refuses_arbitrary_paths_or_reentry() {
    let temp = fixture();
    let protected = git_fixture(temp.path());
    let result = prepare(&protected);
    assert!(result.status.success());
    let expected = String::from_utf8(result.stdout).unwrap();
    let main = expected.trim().strip_prefix("prepared-main:").unwrap();
    let repo = git2::Repository::open(&protected).unwrap();
    assert_eq!(repo.head().unwrap().name(), Some("refs/heads/main"));
    assert_eq!(repo.head().unwrap().target().unwrap().to_string(), main);
    assert_eq!(
        repo.find_commit(git2::Oid::from_str(main).unwrap())
            .unwrap()
            .parent_count(),
        0
    );
    assert!(
        !prepare(&protected).status.success(),
        "preparer must not reinitialize existing repositories"
    );
    let ordinary = temp.path().join("production");
    std::fs::create_dir(&ordinary).unwrap();
    std::fs::write(ordinary.join("sentinel"), b"proof-only-canonical-state").unwrap();
    assert!(!prepare(&ordinary).status.success());
    assert!(!ordinary.join(".git").exists());
    let invalid = git_fixture(&temp.path().join("invalid"));
    std::fs::write(
        invalid.parent().unwrap().join(".native-proof-fixture"),
        b"wrong-generation",
    )
    .unwrap();
    assert!(!prepare(&invalid).status.success());
    assert!(!invalid.join(".git").exists());
}

#[test]
fn unsupported_or_unproven_kernel_never_executes_a_tool() {
    let temp = fixture();
    let marker = temp.path().join("marker");
    // No policy is a hard refusal on every kernel, not an unsandboxed fallback.
    let result = Command::new(env!("CARGO_BIN_EXE_oc-engine-sandbox"))
        .arg("--")
        .arg("/bin/sh")
        .arg("-c")
        .arg(format!("touch {}", marker.display()))
        .status()
        .unwrap();
    assert!(!result.success());
    assert!(!marker.exists());
}

#[test]
#[ignore = "OS boundary proof requires Landlock ABI6; explicitly run on a capable kernel"]
fn raw_syscalls_proc_aliases_metadata_and_descendants_cannot_reach_private_state() {
    let temp = fixture();
    let protected = git_fixture(temp.path());
    let worker = temp.path().join("worker");
    std::fs::create_dir_all(&worker).unwrap();
    let preparation = prepare(&protected);
    assert!(preparation.status.success());
    let expected_main = std::fs::read(protected.join(".git/refs/heads/main")).unwrap();
    let expected_config = std::fs::read(protected.join(".git/config")).unwrap();
    let expected_head = std::fs::read(protected.join(".git/HEAD")).unwrap();
    symlink(&protected, worker.join("protected-alias")).unwrap();
    let probe = std::path::Path::new(env!("CARGO_BIN_EXE_oc-engine-boundary-probe"));
    // Build binaries live in a separate directory; allowing the temporary
    // fixture ancestor would defeat the protected-state test.
    assert!(!protected.starts_with(probe.parent().unwrap()));
    let result = Command::new(env!("CARGO_BIN_EXE_oc-engine-sandbox"))
        .arg("--read-only")
        .arg(probe.parent().unwrap())
        .arg("--read-only")
        .arg("/usr")
        .arg("--read-only")
        .arg("/lib")
        .arg("--read-only")
        .arg("/lib64")
        .arg("--read-only")
        .arg("/proc")
        .arg("--read-write")
        .arg(&worker)
        .arg("--")
        .arg(probe)
        .arg(&protected)
        .arg(&worker)
        .arg(std::process::id().to_string())
        .status()
        .unwrap();
    assert!(result.success(), "native attack proof did not pass");
    assert_eq!(
        std::fs::read(protected.join("sentinel")).unwrap(),
        b"proof-only-canonical-state"
    );
    assert_eq!(
        std::fs::metadata(protected.join("sentinel"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert_eq!(
        std::fs::read(protected.join(".git/refs/heads/main")).unwrap(),
        expected_main
    );
    assert_eq!(
        std::fs::read(protected.join(".git/config")).unwrap(),
        expected_config
    );
    assert_eq!(
        std::fs::read(protected.join(".git/HEAD")).unwrap(),
        expected_head
    );
    let repo = git2::Repository::open(&protected).unwrap();
    assert!(
        repo.head().unwrap().peel_to_commit().is_ok(),
        "main must still resolve to a real seed commit"
    );
    assert_eq!(
        std::fs::read(worker.join("positive-control")).unwrap(),
        b"worker"
    );
}
