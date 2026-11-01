//! Explicit undispatched-worker recovery; daemon/store guard is tested by their owner.
use git2::{Oid, Repository, Signature};
use oc_phone_engine::repository::RepositoryAuthority;
use serde_json::Value;
use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use tempfile::TempDir;

struct Fixture {
    _temporary: TempDir,
    private: PathBuf,
    workers: PathBuf,
    authority: RepositoryAuthority,
    initial: String,
}

impl Fixture {
    fn new() -> Self {
        let root = std::env::var_os("OC_ENGINE_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(".qa-artifacts"));
        assert!(root.is_absolute() && !root.starts_with("/tmp"));
        fs::create_dir_all(&root).unwrap();
        let temporary = tempfile::tempdir_in(&root).unwrap();
        let source = temporary.path().join("source");
        let private = temporary.path().join("private");
        let workers = temporary.path().join("rootfs/work");
        let repo = Repository::init(&source).unwrap();
        repo.set_head("refs/heads/main").unwrap();
        let initial = commit(&source, "README", "initial").to_string();
        drop(repo);
        let authority = RepositoryAuthority::new(private.clone(), workers.clone()).unwrap();
        authority.import_repo("repo", &source).unwrap();
        Self {
            _temporary: temporary,
            private,
            workers,
            authority,
            initial,
        }
    }

    fn prepare(&self, task: &str) -> PathBuf {
        PathBuf::from(
            self.authority.prepare_worker("repo", task).unwrap()["workerPath"]
                .as_str()
                .unwrap(),
        )
    }

    fn worker_record(&self, task: &str) -> PathBuf {
        self.private
            .join("workers")
            .join(format!("repo.{task}.json"))
    }
}

fn commit(path: &Path, file: &str, text: &str) -> Oid {
    fs::write(path.join(file), text).unwrap();
    let repo = Repository::open(path).unwrap();
    let mut index = repo.index().unwrap();
    index.add_path(Path::new(file)).unwrap();
    index.write().unwrap();
    let tree_id = index.write_tree().unwrap();
    let tree = repo.find_tree(tree_id).unwrap();
    let sig = Signature::now("Fixture", "fixture@localhost").unwrap();
    let previous = repo.head().ok().and_then(|head| head.peel_to_commit().ok());
    let parents: Vec<_> = previous.iter().collect();
    repo.commit(Some("HEAD"), &sig, &sig, "fixture", &tree, &parents)
        .unwrap()
}

#[test]
fn abandoned_clone_and_untracked_files_are_replaced_from_current_dev() {
    let f = Fixture::new();
    let abandoned = f.prepare("abandoned");
    let sibling = f.prepare("sibling");
    fs::write(
        abandoned.join("untracked-agent-file"),
        "undispatched residue",
    )
    .unwrap();
    fs::write(abandoned.join("README"), "dirty working tree").unwrap();
    fs::write(sibling.join("sibling-only"), "preserve").unwrap();
    let accepted = f.prepare("accepted");
    let current_dev = commit(&accepted, "new-dev-file", "accepted").to_string();
    f.authority
        .collect_worker("repo", "accepted", &f.initial)
        .unwrap();
    f.authority
        .merge_dev("repo", "accepted", &f.initial, &current_dev)
        .unwrap();
    let before = f.authority.refs("repo").unwrap();
    // Ordinary preparation still refuses to erase existing agent work.
    assert_eq!(
        f.authority
            .prepare_worker("repo", "abandoned")
            .unwrap_err()
            .code(),
        "worker_exists"
    );
    let fresh = f
        .authority
        .prepare_fresh_worker("repo", "abandoned")
        .unwrap();
    assert_eq!(fresh["workerPath"], abandoned.to_str().unwrap());
    assert_eq!(fresh["devCommit"], current_dev);
    assert_eq!(fresh["taskCommit"], current_dev);
    assert_eq!(fresh["before"], fresh["after"]);
    assert_eq!(f.authority.refs("repo").unwrap(), before);
    assert!(!abandoned.join("untracked-agent-file").exists());
    assert_eq!(
        fs::read_to_string(abandoned.join("README")).unwrap(),
        "initial"
    );
    assert_eq!(
        fs::read_to_string(abandoned.join("new-dev-file")).unwrap(),
        "accepted"
    );
    assert_eq!(
        fs::read_to_string(sibling.join("sibling-only")).unwrap(),
        "preserve"
    );
    let record: Value =
        serde_json::from_slice(&fs::read(f.worker_record("abandoned")).unwrap()).unwrap();
    assert_eq!(record["devCommit"], current_dev);
    let repo = Repository::open(&abandoned).unwrap();
    assert!(repo.find_reference("refs/heads/main").is_err());
    assert!(repo.find_reference("refs/heads/dev").is_err());
    assert_eq!(repo.remotes().unwrap().len(), 0);
    assert!(!repo.path().join("objects/info/alternates").exists());
    assert!(!repo.path().join("commondir").exists());
    assert!(!fs::read_to_string(repo.path().join("config"))
        .unwrap()
        .contains(f.private.to_str().unwrap()));
}

#[test]
fn clone_exported_before_seed_record_commit_can_be_recovered_after_restart() {
    let f = Fixture::new();
    let worker = f.prepare("task");
    fs::write(worker.join("orphan-file"), "after clone export").unwrap();
    fs::remove_file(f.worker_record("task")).unwrap();
    let restart = RepositoryAuthority::new(f.private.clone(), f.workers.clone()).unwrap();
    let before = restart.refs("repo").unwrap();
    restart.prepare_fresh_worker("repo", "task").unwrap();
    assert!(!worker.join("orphan-file").exists());
    assert!(f.worker_record("task").exists());
    assert_eq!(restart.refs("repo").unwrap(), before);
}

#[test]
fn leftover_seed_without_clone_is_replaced_and_fresh_tasks_are_supported() {
    let f = Fixture::new();
    let worker = f.prepare("task");
    fs::remove_dir_all(&worker).unwrap();
    let before = f.authority.refs("repo").unwrap();
    f.authority.prepare_fresh_worker("repo", "task").unwrap();
    f.authority
        .prepare_fresh_worker("repo", "new-task")
        .unwrap();
    assert!(worker.join(".git").is_dir());
    assert_eq!(f.authority.refs("repo").unwrap(), before);
}

#[test]
fn readonly_and_mode_zero_nested_directories_are_deleted_through_pinned_descriptors() {
    let f = Fixture::new();
    let worker = f.prepare("task");
    let locked = worker.join("locked");
    let nested = locked.join("nested");
    fs::create_dir_all(&nested).unwrap();
    fs::write(nested.join("readonly-file"), "residue").unwrap();
    fs::set_permissions(
        nested.join("readonly-file"),
        fs::Permissions::from_mode(0o000),
    )
    .unwrap();
    fs::set_permissions(&nested, fs::Permissions::from_mode(0o000)).unwrap();
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o500)).unwrap();
    fs::set_permissions(&worker, fs::Permissions::from_mode(0o000)).unwrap();
    let before = f.authority.refs("repo").unwrap();
    f.authority.prepare_fresh_worker("repo", "task").unwrap();
    assert!(!locked.exists());
    assert!(worker.join("README").is_file());
    assert_eq!(f.authority.refs("repo").unwrap(), before);
}

#[test]
fn task_and_parent_symlinks_cannot_redirect_deletion_into_canonical_storage() {
    let f = Fixture::new();
    let worker = f.prepare("task");
    fs::remove_dir_all(&worker).unwrap();
    let canonical = f.private.join("repos/repo.git");
    let sentinel = canonical.join("keep-sentinel");
    fs::write(&sentinel, "canonical data").unwrap();
    let before = f.authority.refs("repo").unwrap();
    symlink(&canonical, &worker).unwrap();
    assert_eq!(
        f.authority
            .prepare_fresh_worker("repo", "task")
            .unwrap_err()
            .code(),
        "symlink_refused"
    );
    assert_eq!(fs::read_to_string(&sentinel).unwrap(), "canonical data");
    assert!(f.worker_record("task").exists());
    fs::remove_file(&worker).unwrap();
    fs::remove_dir(worker.parent().unwrap()).unwrap();
    symlink(&canonical, worker.parent().unwrap()).unwrap();
    assert_eq!(
        f.authority
            .prepare_fresh_worker("repo", "task")
            .unwrap_err()
            .code(),
        "unsafe_repository_path"
    );
    assert_eq!(fs::read_to_string(&sentinel).unwrap(), "canonical data");
    assert_eq!(f.authority.refs("repo").unwrap(), before);
}

#[test]
fn nested_symlink_is_refused_without_following_its_private_target() {
    let f = Fixture::new();
    let worker = f.prepare("task");
    let canonical = f.private.join("repos/repo.git");
    let before = f.authority.refs("repo").unwrap();
    let original_config = fs::read(canonical.join("config")).unwrap();
    symlink(&canonical, worker.join("canonical-pivot")).unwrap();
    assert_eq!(
        f.authority
            .prepare_fresh_worker("repo", "task")
            .unwrap_err()
            .code(),
        "symlink_refused"
    );
    assert_eq!(fs::read(canonical.join("config")).unwrap(), original_config);
    assert_eq!(f.authority.refs("repo").unwrap(), before);
    assert!(f.worker_record("task").exists());
    fs::remove_file(worker.join("canonical-pivot")).unwrap();
    f.authority.prepare_fresh_worker("repo", "task").unwrap();
}

#[test]
fn collected_tasks_and_mismatched_private_seed_binding_cannot_be_reset() {
    let f = Fixture::new();
    let worker = f.prepare("collected");
    fs::write(worker.join("preserve-work"), "collected evidence").unwrap();
    f.authority
        .collect_worker("repo", "collected", &f.initial)
        .unwrap();
    assert_eq!(
        f.authority
            .prepare_fresh_worker("repo", "collected")
            .unwrap_err()
            .code(),
        "worker_reset_refused"
    );
    assert!(worker.join("preserve-work").exists());
    let mismatch = f.prepare("mismatch");
    let record_path = f.worker_record("mismatch");
    let mut record: Value = serde_json::from_slice(&fs::read(&record_path).unwrap()).unwrap();
    record["taskId"] = Value::String("other-task".into());
    fs::write(record_path, serde_json::to_vec(&record).unwrap()).unwrap();
    assert_eq!(
        f.authority
            .prepare_fresh_worker("repo", "mismatch")
            .unwrap_err()
            .code(),
        "worker_binding_mismatch"
    );
    assert!(mismatch.join(".git").exists());
}
