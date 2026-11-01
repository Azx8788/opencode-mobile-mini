//! Android system parents are searchable but not readable by the app UID.
//! These controls require non-root credentials so DAC cannot be bypassed.
use git2::{Repository, Signature};
use oc_phone_engine::repository::RepositoryAuthority;
use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::PathBuf;

struct SearchOnly(PathBuf);
impl Drop for SearchOnly {
    fn drop(&mut self) {
        // Restore permission before TempDir's own recursive cleanup runs.
        fs::set_permissions(&self.0, fs::Permissions::from_mode(0o700)).unwrap();
    }
}

fn scratch() -> tempfile::TempDir {
    assert_ne!(
        unsafe { libc::geteuid() },
        0,
        "this DAC proof must run as non-root"
    );
    let root = std::env::var_os("OC_ENGINE_TEST_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(".qa-artifacts"));
    assert!(root.is_absolute() && !root.starts_with("/tmp"));
    fs::create_dir_all(&root).unwrap();
    tempfile::tempdir_in(root).unwrap()
}

#[test]
fn execute_only_ancestor_supports_create_import_worker_and_readable_leaf_operations() {
    let temp = scratch();
    let parent = temp.path().join("search-only");
    let app = parent.join("user/app/files");
    fs::create_dir_all(&app).unwrap();
    let source = app.join("source");
    let repo = Repository::init(&source).unwrap();
    repo.set_head("refs/heads/main").unwrap();
    let tree_id = repo.index().unwrap().write_tree().unwrap();
    let tree = repo.find_tree(tree_id).unwrap();
    let signature = Signature::now("Fixture", "fixture@invalid.example").unwrap();
    let initial = repo
        .commit(Some("HEAD"), &signature, &signature, "seed", &tree, &[])
        .unwrap();
    drop(tree);
    drop(repo);
    let _restore = SearchOnly(parent.clone());
    fs::set_permissions(&parent, fs::Permissions::from_mode(0o111)).unwrap();
    assert_eq!(
        fs::read_dir(&parent).unwrap_err().kind(),
        std::io::ErrorKind::PermissionDenied
    );

    // Several managed ancestors are absent: creation must preserve usable,
    // readable leaf descriptors and directory durability beneath app storage.
    let private = app.join("native-private");
    let workers = app.join("linux/ubuntu/root/aiteam/work/profile");
    let authority = RepositoryAuthority::new(private.clone(), workers.clone()).unwrap();
    authority.import_repo("repo", &source).unwrap();
    assert_eq!(
        authority.refs("repo").unwrap()["mainCommit"],
        initial.to_string()
    );
    let worker = authority.prepare_worker("repo", "task").unwrap();
    assert!(PathBuf::from(worker["workerPath"].as_str().unwrap()).is_dir());
    assert!(fs::read_dir(private.join("repos"))
        .unwrap()
        .next()
        .is_some());
    // Reopening existing roots must work without trying to modify /data-like
    // ancestors or demanding read permission on them.
    RepositoryAuthority::new(private, workers).unwrap();
}

#[test]
fn execute_only_ancestor_does_not_make_descendant_symlinks_trusted() {
    let temp = scratch();
    let parent = temp.path().join("search-only");
    let app = parent.join("user/app/files");
    let external = temp.path().join("external");
    fs::create_dir_all(&app).unwrap();
    fs::create_dir_all(&external).unwrap();
    symlink(&external, app.join("linked")).unwrap();
    let _restore = SearchOnly(parent.clone());
    fs::set_permissions(&parent, fs::Permissions::from_mode(0o111)).unwrap();
    assert_eq!(
        fs::read_dir(&parent).unwrap_err().kind(),
        std::io::ErrorKind::PermissionDenied
    );
    let failure = RepositoryAuthority::new(app.join("linked/private"), app.join("worker"))
        .err()
        .expect("descendant link must be rejected");
    assert_eq!(failure.code(), "symlink_refused");
    assert!(!external.join("private").exists());
    assert!(!app.join("worker").exists());
}
