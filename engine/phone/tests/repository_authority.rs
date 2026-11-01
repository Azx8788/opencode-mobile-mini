//! Host repository proofs. Kernel denial from inside proot belongs to the native harness.
//! All fixtures remain on Storage; these tests never use the platform /tmp directory.
use git2::{Oid, Repository, Signature};
use oc_phone_engine::repository::RepositoryAuthority;
use serde_json::{json, Value};
use std::fs;
use std::os::unix::fs::{symlink, MetadataExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use tempfile::TempDir;

struct Fixture {
    _dir: TempDir,
    private: PathBuf,
    workers: PathBuf,
    source: PathBuf,
    authority: RepositoryAuthority,
    initial: String,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::var_os("OC_ENGINE_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(".qa-artifacts"));
        assert!(root.is_absolute());
        assert!(!root.starts_with("/tmp"), "Fixtures must stay on Storage");
        fs::create_dir_all(&root).unwrap();
        let dir = tempfile::tempdir_in(root).unwrap();
        let private = dir.path().join("native-private");
        let workers = dir.path().join("rootfs/work");
        let source = dir.path().join("import");
        let repo = Repository::init(&source).unwrap();
        repo.set_head("refs/heads/main").unwrap();
        let initial = commit(&source, "README", "seed\n").to_string();
        drop(repo);
        let authority = RepositoryAuthority::new(private.clone(), workers.clone()).unwrap();
        authority.import_repo("repo", &source).unwrap();
        Self {
            _dir: dir,
            private,
            workers,
            source,
            authority,
            initial,
        }
    }
    fn worker(&self, task: &str) -> (PathBuf, Value) {
        let value = self.authority.prepare_worker("repo", task).unwrap();
        (PathBuf::from(value["workerPath"].as_str().unwrap()), value)
    }
    fn restart(&self) -> RepositoryAuthority {
        RepositoryAuthority::new(self.private.clone(), self.workers.clone()).unwrap()
    }
    fn unchanged_main(&self) {
        assert_eq!(
            self.authority.refs("repo").unwrap()["mainCommit"],
            self.initial
        );
    }
}
fn commit(path: &Path, file: &str, content: &str) -> Oid {
    let repo = Repository::open(path).unwrap();
    fs::write(path.join(file), content).unwrap();
    let mut index = repo.index().unwrap();
    index.add_path(Path::new(file)).unwrap();
    index.write().unwrap();
    let tree_id = index.write_tree().unwrap();
    let tree = repo.find_tree(tree_id).unwrap();
    let signature = Signature::now("Fixture", "fixture@localhost").unwrap();
    let parent = repo.head().ok().and_then(|h| h.peel_to_commit().ok());
    let parents: Vec<_> = parent.iter().collect();
    repo.commit(
        Some("HEAD"),
        &signature,
        &signature,
        "fixture",
        &tree,
        &parents,
    )
    .unwrap()
}
fn git(path: &Path, args: &[&str]) -> bool {
    Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .output()
        .unwrap()
        .status
        .success()
}
fn receipt(f: &Fixture, id: &str, dev: &str, state: &str) -> Value {
    json!({"schemaVersion":1,"repoId":"repo","requestId":id,"expectedDev":dev,
        "expectedMain":f.initial,"confirmed":true,"state":state,
        "before":{"devCommit":dev,"mainCommit":f.initial},
        "after":{"devCommit":dev,"mainCommit":dev}})
}
fn integrate(f: &Fixture, task: &str, file: &str, text: &str, dev: &str) -> String {
    let (worker, _) = f.worker(task);
    let sha = commit(&worker, file, text).to_string();
    let collected = f.authority.collect_worker("repo", task, dev).unwrap();
    assert_eq!(collected["taskCommit"], sha);
    f.authority.merge_dev("repo", task, dev, &sha).unwrap()["devCommit"]
        .as_str()
        .unwrap()
        .into()
}

#[test]
fn workers_are_independent_with_no_main_origin_alternates_or_private_path() {
    let f = Fixture::new();
    let (a, info) = f.worker("a");
    let (b, _) = f.worker("b");
    assert_eq!(info["branch"], "task/a");
    for worker in [&a, &b] {
        let repo = Repository::open(worker).unwrap();
        assert!(repo.find_reference("refs/heads/main").is_err());
        assert!(repo.find_reference("refs/heads/dev").is_err());
        assert_eq!(repo.remotes().unwrap().len(), 0);
        assert!(!repo.path().join("objects/info/alternates").exists());
        assert!(!repo.path().join("commondir").exists());
        assert!(!repo.path().join("FETCH_HEAD").exists());
        let config = fs::read_to_string(repo.path().join("config")).unwrap();
        assert!(!config.contains(f.private.to_str().unwrap()));
        for entry in fs::read_dir(repo.path().join("objects/pack")).unwrap() {
            assert_eq!(entry.unwrap().metadata().unwrap().nlink(), 1);
        }
    }
    let a_repo = Repository::open(&a).unwrap();
    let b_repo = Repository::open(&b).unwrap();
    assert_ne!(
        fs::metadata(a_repo.path()).unwrap().ino(),
        fs::metadata(b_repo.path()).unwrap().ino()
    );
    commit(&a, "worker-a", "independent");
    assert!(!b.join("worker-a").exists());
    f.unchanged_main();
}

#[test]
fn direct_indirect_and_tool_writes_are_hook_blocked_but_bypass_only_changes_worker() {
    let f = Fixture::new();
    let (worker, _) = f.worker("task");
    let next = commit(&worker, "change", "worker").to_string();
    assert!(!git(&worker, &["update-ref", "refs/heads/main", &next]));
    assert!(git(&worker, &["symbolic-ref", "HEAD", "refs/heads/main"]));
    assert!(!git(&worker, &["update-ref", "HEAD", &next]));
    let tool = Command::new("sh")
        .current_dir(&worker)
        .args(["-c", "git update-ref refs/heads/main \"$1\"", "tool", &next])
        .output()
        .unwrap();
    assert!(!tool.status.success());
    f.unchanged_main();
    // Hooks cannot establish ownership. The bypass is expected to succeed locally.
    assert!(git(
        &worker,
        &[
            "-c",
            "core.hooksPath=/dev/null",
            "update-ref",
            "refs/heads/main",
            &next
        ]
    ));
    f.unchanged_main();
    fs::write(
        worker.join(".git/refs/heads/main"),
        format!("{}\n", f.initial),
    )
    .unwrap();
    fs::write(
        worker.join(".git/hooks/reference-transaction"),
        "#!/bin/sh\nexit 0\n",
    )
    .unwrap();
    assert!(git(&worker, &["config", "core.hooksPath", "/dev/null"]));
    assert!(git(&worker, &["update-ref", "refs/heads/main", &next]));
    f.unchanged_main();
    let collected = f
        .authority
        .collect_worker("repo", "task", &f.initial)
        .unwrap();
    f.authority
        .merge_dev(
            "repo",
            "task",
            &f.initial,
            collected["taskCommit"].as_str().unwrap(),
        )
        .unwrap();
    f.unchanged_main();
}

#[test]
fn worker_pre_receive_rejects_main_push_without_affecting_canonical_main() {
    let f = Fixture::new();
    let (a, _) = f.worker("a");
    let (b, _) = f.worker("b");
    commit(&a, "change", "push candidate");
    assert!(!git(
        &a,
        &[
            "push",
            b.to_str().unwrap(),
            "refs/heads/task/a:refs/heads/main"
        ]
    ));
    assert!(Repository::open(&b)
        .unwrap()
        .find_reference("refs/heads/main")
        .is_err());
    f.unchanged_main();
}

#[test]
fn checked_merge_then_confirmed_promotion_is_durable_and_request_bound() {
    let f = Fixture::new();
    let next = integrate(&f, "first", "change", "one", &f.initial);
    f.unchanged_main();
    assert_eq!(
        f.authority
            .promote("repo", &next, &f.initial, false, "promote1")
            .unwrap_err()
            .code(),
        "confirmation_required"
    );
    let result = f
        .authority
        .promote("repo", &next, &f.initial, true, "promote1")
        .unwrap();
    assert_eq!(result["before"]["mainCommit"], f.initial);
    assert_eq!(result["after"]["mainCommit"], next);
    assert_eq!(result["receiptId"], "promote1");
    let restart = f.restart();
    assert_eq!(
        restart
            .promote("repo", &next, &f.initial, true, "promote1")
            .unwrap(),
        result
    );
    assert_eq!(
        restart
            .promote("repo", &next, &next, true, "promote1")
            .unwrap_err()
            .code(),
        "request_id_conflict"
    );
    let persisted: Value =
        serde_json::from_slice(&fs::read(f.private.join("receipts/promote1.json")).unwrap())
            .unwrap();
    assert_eq!(persisted["state"], "applied");
    assert_eq!(persisted["before"], result["before"]);
    assert_eq!(persisted["after"], result["after"]);
}

#[test]
fn stale_refs_and_task_commit_refuse_without_main_changes() {
    let f = Fixture::new();
    let (worker, _) = f.worker("task");
    let sha = commit(&worker, "one", "one").to_string();
    f.authority
        .collect_worker("repo", "task", &f.initial)
        .unwrap();
    assert_eq!(
        f.authority
            .merge_dev("repo", "task", &f.initial, &f.initial)
            .unwrap_err()
            .code(),
        "stale_task"
    );
    f.authority
        .merge_dev("repo", "task", &f.initial, &sha)
        .unwrap();
    assert_eq!(
        f.authority
            .merge_dev("repo", "task", &f.initial, &sha)
            .unwrap_err()
            .code(),
        "stale_dev"
    );
    assert_eq!(
        f.authority
            .collect_worker("repo", "task", &f.initial)
            .unwrap_err()
            .code(),
        "stale_dev"
    );
    assert_eq!(
        f.authority
            .promote("repo", &f.initial, &f.initial, true, "stale")
            .unwrap_err()
            .code(),
        "stale_dev"
    );
    assert_eq!(
        f.authority
            .promote("repo", &sha, &sha, true, "stale-main")
            .unwrap_err()
            .code(),
        "stale_main"
    );
    f.unchanged_main();
}

#[test]
fn parallel_workers_merge_serially_and_conflicts_refuse_without_ref_updates() {
    let f = Fixture::new();
    let (a, _) = f.worker("a");
    let (b, _) = f.worker("b");
    let (c, _) = f.worker("c");
    let a_sha = commit(&a, "README", "a\n").to_string();
    let b_sha = commit(&b, "new", "b\n").to_string();
    let c_sha = commit(&c, "README", "c\n").to_string();
    f.authority.collect_worker("repo", "a", &f.initial).unwrap();
    f.authority
        .merge_dev("repo", "a", &f.initial, &a_sha)
        .unwrap();
    let b_collected = f.authority.collect_worker("repo", "b", &a_sha).unwrap();
    assert_eq!(b_collected["baseCommit"], f.initial);
    let merged = f.authority.merge_dev("repo", "b", &a_sha, &b_sha).unwrap()["devCommit"]
        .as_str()
        .unwrap()
        .to_owned();
    let canonical = Repository::open_bare(f.private.join("repos/repo.git")).unwrap();
    assert_eq!(
        canonical
            .find_commit(Oid::from_str(&merged).unwrap())
            .unwrap()
            .parent_count(),
        2
    );
    f.authority.collect_worker("repo", "c", &merged).unwrap();
    let before = f.authority.refs("repo").unwrap();
    assert_eq!(
        f.authority
            .merge_dev("repo", "c", &merged, &c_sha)
            .unwrap_err()
            .code(),
        "merge_conflict"
    );
    assert_eq!(f.authority.refs("repo").unwrap(), before);
    f.unchanged_main();
}

#[test]
fn interrupted_promotions_reconcile_before_and_after_main_update() {
    let f = Fixture::new();
    let next = integrate(&f, "task", "change", "next", &f.initial);
    let path = f.private.join("receipts/crash-before.json");
    fs::write(
        &path,
        serde_json::to_vec(&receipt(&f, "crash-before", &next, "prepared")).unwrap(),
    )
    .unwrap();
    let result = f
        .restart()
        .promote("repo", &next, &f.initial, true, "crash-before")
        .unwrap();
    assert_eq!(result["mainCommit"], next);
    // Simulate loss of the acknowledgement after the ref became durable.
    fs::write(
        &path,
        serde_json::to_vec(&receipt(&f, "crash-before", &next, "prepared")).unwrap(),
    )
    .unwrap();
    assert_eq!(
        f.restart()
            .promote("repo", &next, &f.initial, true, "crash-before")
            .unwrap(),
        result
    );
    let persisted: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    assert_eq!(persisted["state"], "applied");
}

#[test]
fn restart_reconciliation_after_later_dev_work_preserves_original_receipt() {
    let f = Fixture::new();
    let next = integrate(&f, "task", "change", "next", &f.initial);
    f.authority
        .promote("repo", &next, &f.initial, true, "promotion")
        .unwrap();
    let path = f.private.join("receipts/promotion.json");
    fs::write(
        &path,
        serde_json::to_vec(&receipt(&f, "promotion", &next, "prepared")).unwrap(),
    )
    .unwrap();
    let later = integrate(&f, "later", "later", "later", &next);
    let result = f
        .restart()
        .promote("repo", &next, &f.initial, true, "promotion")
        .unwrap();
    assert_eq!(result["devCommit"], next);
    assert_eq!(f.authority.refs("repo").unwrap()["devCommit"], later);
}

#[test]
fn a_new_promotion_reconciles_old_applied_intent_before_main_moves_again() {
    let f = Fixture::new();
    let next = integrate(&f, "first", "first", "first", &f.initial);
    f.authority
        .promote("repo", &next, &f.initial, true, "first-promotion")
        .unwrap();
    let path = f.private.join("receipts/first-promotion.json");
    fs::write(
        &path,
        serde_json::to_vec(&receipt(&f, "first-promotion", &next, "prepared")).unwrap(),
    )
    .unwrap();
    let later = integrate(&f, "second", "second", "second", &next);
    f.restart()
        .promote("repo", &later, &next, true, "second-promotion")
        .unwrap();
    assert_eq!(
        f.restart()
            .promote("repo", &next, &f.initial, true, "first-promotion")
            .unwrap()["mainCommit"],
        next
    );
    assert_eq!(f.authority.refs("repo").unwrap()["mainCommit"], later);
}

#[test]
fn unapplied_intent_is_superseded_when_its_exact_dev_changes() {
    let f = Fixture::new();
    let next = integrate(&f, "first", "first", "first", &f.initial);
    let path = f.private.join("receipts/unapplied.json");
    fs::write(
        &path,
        serde_json::to_vec(&receipt(&f, "unapplied", &next, "prepared")).unwrap(),
    )
    .unwrap();
    let later = integrate(&f, "second", "second", "second", &next);
    f.restart()
        .promote("repo", &later, &f.initial, true, "later-promotion")
        .unwrap();
    assert_eq!(
        f.restart()
            .promote("repo", &next, &f.initial, true, "unapplied")
            .unwrap_err()
            .code(),
        "promotion_superseded"
    );
    assert_eq!(f.authority.refs("repo").unwrap()["mainCommit"], later);
}

#[test]
fn malicious_alternates_local_origins_includes_symlinks_and_hardlinks_refuse() {
    let f = Fixture::new();
    let (worker, _) = f.worker("task");
    let git = worker.join(".git");
    let alternates = git.join("objects/info/alternates");
    fs::create_dir_all(alternates.parent().unwrap()).unwrap();
    fs::write(
        &alternates,
        f.private.join("repos/repo.git/objects").to_str().unwrap(),
    )
    .unwrap();
    assert_eq!(
        f.authority
            .collect_worker("repo", "task", &f.initial)
            .unwrap_err()
            .code(),
        "unsafe_repository_metadata"
    );
    fs::remove_file(alternates).unwrap();
    let config = fs::read(git.join("config")).unwrap();
    fs::write(
        git.join("config"),
        "[core]\nbare=false\n[remote \"origin\"]\nurl=../../native-private/repos/repo.git\n",
    )
    .unwrap();
    assert_eq!(
        f.authority
            .collect_worker("repo", "task", &f.initial)
            .unwrap_err()
            .code(),
        "unsafe_repository_config"
    );
    fs::write(
        git.join("config"),
        "[include]\npath=../../native-private/credentials\n",
    )
    .unwrap();
    assert_eq!(
        f.authority
            .collect_worker("repo", "task", &f.initial)
            .unwrap_err()
            .code(),
        "unsafe_repository_config"
    );
    fs::write(git.join("config"), config).unwrap();
    symlink(
        f.private.join("repos/repo.git/objects"),
        git.join("objects/pivot"),
    )
    .unwrap();
    assert_eq!(
        f.authority
            .collect_worker("repo", "task", &f.initial)
            .unwrap_err()
            .code(),
        "unsafe_repository_path"
    );
    fs::remove_file(git.join("objects/pivot")).unwrap();
    fs::hard_link(git.join("HEAD"), git.join("shared-head")).unwrap();
    assert_eq!(
        f.authority
            .collect_worker("repo", "task", &f.initial)
            .unwrap_err()
            .code(),
        "shared_repository_objects"
    );
    f.unchanged_main();
}

#[test]
fn ids_roots_and_worker_parent_symlink_are_rejected() {
    let f = Fixture::new();
    assert_eq!(
        f.authority
            .prepare_worker("../repos", "task")
            .unwrap_err()
            .code(),
        "invalid_id"
    );
    assert_eq!(
        f.authority
            .prepare_worker("repo", "../escape")
            .unwrap_err()
            .code(),
        "invalid_id"
    );
    let overlap = RepositoryAuthority::new(f.private.clone(), f.private.join("work"));
    assert_eq!(overlap.err().unwrap().code(), "overlapping_roots");
    let link = f._dir.path().join("link");
    symlink(&f.private, &link).unwrap();
    assert_eq!(
        RepositoryAuthority::new(link.join("child"), f.workers.clone())
            .err()
            .unwrap()
            .code(),
        "symlink_refused"
    );
    symlink(f.private.join("repos"), f.workers.join("repo")).unwrap();
    assert_eq!(
        f.authority
            .prepare_worker("repo", "task")
            .unwrap_err()
            .code(),
        "unsafe_repository_path"
    );
    f.unchanged_main();
}

#[test]
fn symbolic_task_ref_and_unrelated_history_are_untrusted() {
    let f = Fixture::new();
    let (worker, _) = f.worker("task");
    let repo = Repository::open(&worker).unwrap();
    repo.reference_symbolic(
        "refs/heads/task/task",
        "refs/heads/main",
        true,
        "fixture attack",
    )
    .unwrap();
    assert_eq!(
        f.authority
            .collect_worker("repo", "task", &f.initial)
            .unwrap_err()
            .code(),
        "symbolic_ref_refused"
    );
    let tree = repo
        .find_commit(Oid::from_str(&f.initial).unwrap())
        .unwrap()
        .tree()
        .unwrap();
    let sig = Signature::now("Fixture", "fixture@localhost").unwrap();
    let unrelated = repo
        .commit(None, &sig, &sig, "unrelated", &tree, &[])
        .unwrap();
    repo.reference("refs/heads/task/task", unrelated, true, "fixture attack")
        .unwrap();
    assert_eq!(
        f.authority
            .collect_worker("repo", "task", &f.initial)
            .unwrap_err()
            .code(),
        "task_not_descendant"
    );
    f.unchanged_main();
}

#[test]
fn network_import_origin_is_removed_and_local_import_origin_refuses() {
    let f = Fixture::new();
    let source = Repository::open(&f.source).unwrap();
    source
        .remote("origin", "https://fixture.invalid/repository.git")
        .unwrap();
    f.authority
        .import_repo("network-import", &f.source)
        .unwrap();
    let canonical = Repository::open_bare(f.private.join("repos/network-import.git")).unwrap();
    assert_eq!(canonical.remotes().unwrap().len(), 0);
    source
        .remote_set_url("origin", "../../native-private/repos/repo.git")
        .unwrap();
    assert_eq!(
        f.authority
            .import_repo("unsafe-import", &f.source)
            .unwrap_err()
            .code(),
        "unsafe_repository_config"
    );
    assert!(!f.private.join("repos/unsafe-import.git").exists());
}

#[test]
fn import_replay_binds_the_authored_request_across_restart() {
    let f = Fixture::new();
    let first = f
        .authority
        .import_repo_for_request("other", &f.source, "create-request")
        .unwrap();
    let replay = f
        .restart()
        .import_repo_for_request("other", &f.source, "create-request")
        .unwrap();
    assert_eq!(first["mainCommit"], replay["mainCommit"]);
    assert_eq!(first["devCommit"], replay["devCommit"]);
    assert!(f
        .authority
        .import_repo_for_request("other", &f.source, "different-request")
        .is_err());
}

// Build objects directly: filesystem/index helpers sanitize exactly the authored
// tree metadata that this boundary must reject before private checkout.
fn authored_tree(repo: &Repository, entries: &[(&str, &[u8], Oid)]) -> Oid {
    let mut bytes = Vec::new();
    for (mode, name, oid) in entries {
        bytes.extend_from_slice(mode.as_bytes());
        bytes.push(b' ');
        bytes.extend_from_slice(name);
        bytes.push(0);
        bytes.extend_from_slice(oid.as_bytes());
    }
    repo.odb()
        .unwrap()
        .write(git2::ObjectType::Tree, &bytes)
        .unwrap()
}

fn authored_commit(repo: &Repository, tree: Oid, branch: &str) -> Oid {
    let parent = repo.head().unwrap().peel_to_commit().unwrap();
    let text = format!("tree {tree}\nparent {}\nauthor Fixture <fixture@localhost> 1 +0000\ncommitter Fixture <fixture@localhost> 1 +0000\n\nauthored fixture\n", parent.id());
    let id = repo
        .odb()
        .unwrap()
        .write(git2::ObjectType::Commit, text.as_bytes())
        .unwrap();
    repo.reference(branch, id, true, "test authored tree")
        .unwrap();
    id
}

#[test]
fn authored_unsafe_trees_never_enter_canonical_dev_or_private_checkout() {
    for attack in [
        "absolute",
        "parent",
        "nested-parent",
        "git-component",
        "duplicate",
    ] {
        let f = Fixture::new();
        let (worker, _) = f.worker("task");
        let repo = Repository::open(&worker).unwrap();
        let tree = match attack {
            "absolute" | "parent" | "nested-parent" => {
                let target: &[u8] = match attack {
                    "absolute" => b"/native-private/receipts",
                    "parent" => b"../../repos/x.git/refs/heads",
                    _ => b"directory/../file",
                };
                let blob = repo.blob(target).unwrap();
                authored_tree(&repo, &[("120000", b"link", blob)])
            }
            "git-component" => {
                let blob = repo.blob(b"payload").unwrap();
                let inner = authored_tree(&repo, &[("100644", b".GiT", blob)]);
                authored_tree(&repo, &[("40000", b"directory", inner)])
            }
            _ => {
                let blob = repo.blob(b"payload").unwrap();
                let empty = repo
                    .odb()
                    .unwrap()
                    .write(git2::ObjectType::Tree, b"")
                    .unwrap();
                authored_tree(&repo, &[("100644", b"a", blob), ("40000", b"a", empty)])
            }
        };
        authored_commit(&repo, tree, "refs/heads/task/task");
        assert_eq!(
            f.authority
                .collect_worker("repo", "task", &f.initial)
                .unwrap_err()
                .code(),
            "unsafe_task_tree",
            "{attack}"
        );
        assert_eq!(f.authority.refs("repo").unwrap()["devCommit"], f.initial);
        f.unchanged_main();
        assert_eq!(fs::read_dir(f.private.join("staging")).unwrap().count(), 0);
    }
}

#[test]
fn safe_relative_symlinks_remain_supported() {
    let f = Fixture::new();
    let (worker, _) = f.worker("task");
    let repo = Repository::open(&worker).unwrap();
    let target = repo.blob(b"README").unwrap();
    let readme = repo.blob(b"readme").unwrap();
    let tree = authored_tree(
        &repo,
        &[("100644", b"README", readme), ("120000", b"link", target)],
    );
    let id = authored_commit(&repo, tree, "refs/heads/task/task");
    f.authority
        .collect_worker("repo", "task", &f.initial)
        .unwrap();
    f.authority
        .merge_dev("repo", "task", &f.initial, &id.to_string())
        .unwrap();
    let (next, _) = f.worker("next");
    assert_eq!(
        fs::read_link(next.join("link")).unwrap(),
        Path::new("README")
    );
    f.unchanged_main();
}

#[test]
fn unsafe_imported_dev_is_refused_before_canonical_install() {
    let f = Fixture::new();
    let repo = Repository::open(&f.source).unwrap();
    let link = repo.blob(b"../../native-private").unwrap();
    let tree = authored_tree(&repo, &[("120000", b"link", link)]);
    authored_commit(&repo, tree, "refs/heads/dev");
    assert_eq!(
        f.authority
            .import_repo("unsafe", &f.source)
            .unwrap_err()
            .code(),
        "unsafe_task_tree"
    );
    assert!(!f.private.join("repos/unsafe.git").exists());
}

#[test]
fn unsafe_incoming_ref_cannot_bypass_merge_tree_validation() {
    let f = Fixture::new();
    let canonical = Repository::open_bare(f.private.join("repos/repo.git")).unwrap();
    let link = canonical.blob(b"../../receipts").unwrap();
    let tree = authored_tree(&canonical, &[("120000", b"link", link)]);
    let id = authored_commit(&canonical, tree, "refs/aiteam/collected/task");
    assert_eq!(
        f.authority
            .merge_dev("repo", "task", &f.initial, &id.to_string())
            .unwrap_err()
            .code(),
        "unsafe_task_tree"
    );
    assert_eq!(f.authority.refs("repo").unwrap()["devCommit"], f.initial);
    f.unchanged_main();
}

#[test]
fn malformed_receipt_for_another_repository_does_not_block_promotion() {
    let f = Fixture::new();
    fs::write(
        f.private.join("receipts/other.json"),
        r#"{"repoId":"unrelated","schemaVersion":"bad"}"#,
    )
    .unwrap();
    let dev = integrate(&f, "first", "change", "safe", &f.initial);
    f.authority
        .promote("repo", &dev, &f.initial, true, "good")
        .unwrap();
    assert_eq!(f.authority.refs("repo").unwrap()["mainCommit"], dev);
    assert!(f.private.join("receipts/other.json").exists());
}

#[test]
fn durable_receipt_scope_contains_complete_body_corruption_to_its_repository() {
    let f = Fixture::new();
    f.authority.import_repo("other", &f.source).unwrap();
    f.authority
        .promote("other", &f.initial, &f.initial, true, "other-receipt")
        .unwrap();
    fs::write(
        f.private.join("receipts/other-receipt.json"),
        "corrupted body",
    )
    .unwrap();
    let dev = integrate(&f, "first", "change", "safe", &f.initial);
    f.authority
        .promote("repo", &dev, &f.initial, true, "good")
        .unwrap();
    assert_eq!(
        f.authority
            .promote("other", &f.initial, &f.initial, true, "other-new")
            .unwrap_err()
            .code(),
        "invalid_receipt"
    );
    assert!(f.private.join("receipts/other-receipt.json").exists());
}

#[test]
fn legacy_receipt_with_unknown_scope_remains_fail_closed_and_preserved() {
    let f = Fixture::new();
    fs::write(
        f.private.join("receipts/unknown.json"),
        "corrupted legacy body",
    )
    .unwrap();
    assert_eq!(
        f.authority
            .promote("repo", &f.initial, &f.initial, true, "new")
            .unwrap_err()
            .code(),
        "legacy_receipt_scope_unknown"
    );
    assert_eq!(
        fs::read_to_string(f.private.join("receipts/unknown.json")).unwrap(),
        "corrupted legacy body"
    );
    f.unchanged_main();
}

#[test]
fn collection_erases_only_unreferenced_storage_and_keeps_audit_receipts() {
    use std::os::unix::fs::PermissionsExt;
    let f = Fixture::new();
    f.authority
        .import_repo_for_request("other", &f.source, "create-other")
        .unwrap();
    let exported = f.authority.prepare_worker("other", "task").unwrap();
    let worker = PathBuf::from(exported["workerPath"].as_str().unwrap());
    let kept = f.worker("retained").0;
    let sentinel = f._dir.path().join("sentinel");
    fs::create_dir(&sentinel).unwrap();
    fs::write(sentinel.join("keep"), "private data must survive").unwrap();
    symlink(&sentinel, worker.join("agent-link")).unwrap();
    fs::create_dir(worker.join("mode-zero")).unwrap();
    fs::write(worker.join("mode-zero/file"), "discard").unwrap();
    fs::set_permissions(worker.join("mode-zero"), fs::Permissions::from_mode(0)).unwrap();
    f.authority
        .promote("other", &f.initial, &f.initial, true, "audit")
        .unwrap();
    let summary = f
        .authority
        .collect_unreferenced_repositories(&["repo".into()])
        .unwrap();
    assert_eq!(summary["removedRepoIds"], json!(["other"]));
    assert!(!f.private.join("repos/other.git").exists());
    assert!(!f.private.join("imports/other.json").exists());
    assert!(!f.private.join("workers/other.task.json").exists());
    assert!(!f.workers.join("other").exists());
    assert!(kept.exists());
    assert!(f.private.join("receipts/audit.json").exists());
    assert!(f.private.join("receipt-scopes/audit.json").exists());
    assert_eq!(
        fs::read_to_string(sentinel.join("keep")).unwrap(),
        "private data must survive"
    );
    assert_eq!(
        f.authority
            .import_repo("other", &f.source)
            .unwrap_err()
            .code(),
        "repository_retired"
    );
    assert_eq!(
        f.authority
            .collect_unreferenced_repositories(&["repo".into()])
            .unwrap()["removedRepoIds"],
        json!([])
    );
    f.unchanged_main();
}

#[test]
fn collection_rejects_invalid_retained_ids_before_mutation() {
    let f = Fixture::new();
    assert_eq!(
        f.authority
            .collect_unreferenced_repositories(&["../escape".into()])
            .unwrap_err()
            .code(),
        "invalid_id"
    );
    assert!(f.private.join("repos/repo.git").exists());
    assert_eq!(fs::read_dir(f.private.join("retired")).unwrap().count(), 0);
}

#[test]
fn trusted_native_erase_handles_mode_zero_and_unlinks_symlinks_without_following() {
    use oc_phone_engine::repository::erase_tree_no_links;
    use std::os::unix::fs::PermissionsExt;
    let f = Fixture::new();
    let external = f._dir.path().join("external");
    fs::create_dir(&external).unwrap();
    fs::write(external.join("keep"), "preserve").unwrap();
    let root = f._dir.path().join("erase");
    fs::create_dir(&root).unwrap();
    fs::create_dir(root.join("zero")).unwrap();
    fs::write(root.join("zero/file"), "remove").unwrap();
    symlink(&external, root.join("link")).unwrap();
    fs::set_permissions(root.join("zero"), fs::Permissions::from_mode(0)).unwrap();
    fs::set_permissions(&root, fs::Permissions::from_mode(0o555)).unwrap();
    erase_tree_no_links(&root).unwrap();
    assert!(!root.exists());
    assert!(external.join("keep").exists());
    erase_tree_no_links(&root).unwrap();
    let alias = f._dir.path().join("alias");
    symlink(&external, &alias).unwrap();
    assert_eq!(
        erase_tree_no_links(&alias.join("keep")).unwrap_err().code(),
        "symlink_refused"
    );
    assert!(external.join("keep").exists());
}

#[test]
fn source_dev_branch_is_preserved_when_source_head_remains_main() {
    let f = Fixture::new();
    let source = Repository::open(&f.source).unwrap();
    let seed = source
        .find_commit(Oid::from_str(&f.initial).unwrap())
        .unwrap();
    source.branch("dev", &seed, false).unwrap();
    source.set_head("refs/heads/dev").unwrap();
    let dev = commit(&f.source, "dev-work", "approved development base\n");
    source.set_head("refs/heads/main").unwrap();
    let imported = f.authority.import_repo("with-dev", &f.source).unwrap();
    assert_eq!(imported["mainCommit"], f.initial);
    assert_eq!(imported["devCommit"], dev.to_string());
    let worker = f.authority.prepare_worker("with-dev", "task").unwrap();
    assert_eq!(worker["devCommit"], dev.to_string());
}

#[test]
fn failed_empty_import_can_be_corrected_and_retried_without_retiring_editor_id() {
    let f = Fixture::new();
    let empty = f._dir.path().join("empty-source");
    let repo = Repository::init(&empty).unwrap();
    repo.set_head("refs/heads/main").unwrap();
    drop(repo);
    assert!(f
        .authority
        .import_repo_for_request("editor_repo", &empty, "create-request")
        .is_err());
    f.authority
        .collect_unreferenced_repositories(&["repo".into()])
        .unwrap();
    assert!(!f.private.join("retired/editor_repo.json").exists());
    let seed = commit(&empty, "README.md", "Corrected source\n").to_string();
    let imported = f
        .authority
        .import_repo_for_request("editor_repo", &empty, "create-request")
        .unwrap();
    assert_eq!(imported["mainCommit"], seed);
    assert_eq!(imported["devCommit"], seed);
    let replay = f
        .authority
        .import_repo_for_request("editor_repo", &empty, "create-request")
        .unwrap();
    assert_eq!(replay["mainCommit"], imported["mainCommit"]);
    assert_eq!(replay["devCommit"], imported["devCommit"]);
    f.authority
        .collect_unreferenced_repositories(&["repo".into()])
        .unwrap();
    assert_eq!(
        f.authority
            .import_repo_for_request("editor_repo", &empty, "next-request")
            .unwrap_err()
            .code(),
        "repository_retired"
    );
}
