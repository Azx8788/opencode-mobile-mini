//! Exact observed Termux L2S object shape, without trusting link target paths.
use git2::{Oid, Repository, Signature};
use oc_phone_engine::repository::RepositoryAuthority;
use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use tempfile::TempDir;

struct Fixture {
    _temp: TempDir,
    source: PathBuf,
    private: PathBuf,
    authority: RepositoryAuthority,
    main: Oid,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::var_os("OC_ENGINE_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(".qa-artifacts"));
        assert!(root.is_absolute() && !root.starts_with("/tmp"));
        fs::create_dir_all(&root).unwrap();
        let temp = tempfile::tempdir_in(root).unwrap();
        let source = temp.path().join("projects/scratch1");
        let private = temp.path().join("native-private");
        let repo = Repository::init(&source).unwrap();
        repo.set_head("refs/heads/main").unwrap();
        let main = commit(&source, "README", "seed\n");
        let authority =
            RepositoryAuthority::new(private.clone(), temp.path().join("rootfs/work")).unwrap();
        authority.import_repo("existing", &source).unwrap();
        Self {
            _temp: temp,
            source,
            private,
            authority,
            main,
        }
    }
    fn unchanged(&self) {
        assert_eq!(
            self.authority.refs("existing").unwrap()["mainCommit"],
            self.main.to_string()
        );
    }
    fn logical(&self) -> PathBuf {
        loose_path(&self.source, self.main)
    }
    fn refuse(&self, code: &str) {
        assert_eq!(
            self.authority
                .import_repo("candidate", &self.source)
                .unwrap_err()
                .code(),
            code
        );
        self.unchanged();
        assert!(!self.private.join("repos/candidate.git").exists());
    }
}

fn commit(path: &Path, name: &str, data: &str) -> Oid {
    let repo = Repository::open(path).unwrap();
    fs::write(path.join(name), data).unwrap();
    let mut index = repo.index().unwrap();
    index.add_path(Path::new(name)).unwrap();
    index.write().unwrap();
    let tree_id = index.write_tree().unwrap();
    let tree = repo.find_tree(tree_id).unwrap();
    let signature = Signature::now("Fixture", "fixture@invalid.example").unwrap();
    let parent = repo.head().ok().and_then(|r| r.peel_to_commit().ok());
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

fn loose_path(repo: &Path, oid: Oid) -> PathBuf {
    let name = oid.to_string();
    repo.join(".git/objects").join(&name[..2]).join(&name[2..])
}

fn observed_chain(logical: &Path) -> (PathBuf, PathBuf) {
    let parent = logical.parent().unwrap();
    let first = parent.join(".l2s.tmp_obj_IPMtWH0001");
    let last = parent.join(".l2s.tmp_obj_IPMtWH0001.0001");
    fs::rename(logical, &last).unwrap();
    fs::set_permissions(&last, fs::Permissions::from_mode(0o400)).unwrap();
    symlink(&last, &first).unwrap();
    symlink(&first, logical).unwrap();
    (first, last)
}

#[test]
fn exact_observed_absolute_two_hop_object_imports_as_regular_validated_object() {
    let f = Fixture::new();
    observed_chain(&f.logical());
    let refs = f.authority.import_repo("candidate", &f.source).unwrap();
    assert_eq!(refs["mainCommit"], f.main.to_string());
    let canonical = Repository::open_bare(f.private.join("repos/candidate.git")).unwrap();
    let object = canonical
        .odb()
        .unwrap()
        .read(f.main)
        .unwrap()
        .data()
        .to_vec();
    assert_eq!(
        Oid::hash_object(git2::ObjectType::Commit, &object).unwrap(),
        f.main
    );
    f.unchanged();
}

#[test]
fn worker_collection_normalizes_committed_proot_object_and_preserves_main() {
    let f = Fixture::new();
    let result = f.authority.prepare_worker("existing", "task").unwrap();
    let worker = PathBuf::from(result["workerPath"].as_str().unwrap());
    let task = commit(&worker, "worker.txt", "worker\n");
    observed_chain(&loose_path(&worker, task));
    let collected = f
        .authority
        .collect_worker("existing", "task", result["devCommit"].as_str().unwrap())
        .unwrap();
    assert_eq!(collected["taskCommit"], task.to_string());
    f.unchanged();
}

#[test]
fn foreign_private_traversing_relative_and_nested_object_targets_refuse() {
    for case in ["foreign", "private", "parent", "relative", "nested"] {
        let f = Fixture::new();
        let logical = f.logical();
        let (first, last) = observed_chain(&logical);
        fs::remove_file(&logical).unwrap();
        let target = match case {
            "foreign" => f
                .source
                .join(".git/objects/foreign/.l2s.tmp_obj_IPMtWH0001"),
            "private" => f.private.join(".l2s.tmp_obj_IPMtWH0001"),
            "parent" => logical
                .parent()
                .unwrap()
                .join("../")
                .join(last.file_name().unwrap()),
            "relative" => PathBuf::from(first.file_name().unwrap()),
            _ => logical
                .parent()
                .unwrap()
                .join("nested/.l2s.tmp_obj_IPMtWH0001"),
        };
        symlink(target, &logical).unwrap();
        f.refuse("invalid_proot_object_link");
    }
}

#[test]
fn intermediate_escape_and_cycle_refuse() {
    for cycle in [false, true] {
        let f = Fixture::new();
        let (first, _) = observed_chain(&f.logical());
        fs::remove_file(&first).unwrap();
        let target = if cycle {
            first.clone()
        } else {
            f.private.join(".l2s.tmp_obj_IPMtWH0001.0001")
        };
        symlink(target, &first).unwrap();
        f.refuse("invalid_proot_object_link");
    }
}

#[test]
fn excessive_chain_and_nonregular_or_multilink_backing_refuse() {
    for case in ["depth", "directory", "hardlink"] {
        let f = Fixture::new();
        let (first, last) = observed_chain(&f.logical());
        match case {
            "depth" => {
                fs::remove_file(&first).unwrap();
                let mut previous = first;
                for number in 2..=10 {
                    let next = last
                        .parent()
                        .unwrap()
                        .join(format!(".l2s.tmp_obj_IPMtWH0001.{number:04}"));
                    symlink(&next, previous).unwrap();
                    previous = next;
                }
                symlink(&last, previous).unwrap();
            }
            "directory" => {
                fs::remove_file(&last).unwrap();
                fs::create_dir(&last).unwrap();
            }
            _ => {
                fs::hard_link(&last, f.source.join("extra-hardlink")).unwrap();
            }
        }
        f.refuse("invalid_proot_object_link");
    }
}

#[test]
fn valid_compressed_object_under_wrong_logical_oid_refuses() {
    let f = Fixture::new();
    let repo = Repository::open(&f.source).unwrap();
    let wrong = repo
        .odb()
        .unwrap()
        .write(git2::ObjectType::Blob, b"wrong valid object")
        .unwrap();
    let (_, last) = observed_chain(&f.logical());
    fs::set_permissions(&last, fs::Permissions::from_mode(0o600)).unwrap();
    fs::copy(loose_path(&f.source, wrong), &last).unwrap();
    f.refuse("repository_object_hash_mismatch");
}

#[test]
fn config_head_and_refs_never_receive_object_link_exception() {
    for field in ["config", "HEAD", "refs/heads/main"] {
        let f = Fixture::new();
        let path = f.source.join(".git").join(field);
        let backing = path.parent().unwrap().join(".l2s.tmp_obj_IPMtWH0001");
        fs::rename(&path, &backing).unwrap();
        symlink(&backing, &path).unwrap();
        f.refuse("unsafe_repository_path");
    }
}

#[test]
fn symlink_grafted_fanout_directory_refuses() {
    let f = Fixture::new();
    let fanout = f.logical().parent().unwrap().to_path_buf();
    let other = f.source.join("relocated-fanout");
    fs::rename(&fanout, &other).unwrap();
    symlink(&other, &fanout).unwrap();
    f.refuse("unsafe_repository_path");
}

#[test]
fn linked_pack_and_index_are_flattened_and_all_object_hashes_verified() {
    let f = Fixture::new();
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(&f.source)
        .args(["repack", "-ad"])
        .output()
        .unwrap();
    assert!(output.status.success());
    let pack = f.source.join(".git/objects/pack");
    for entry in fs::read_dir(&pack).unwrap() {
        let path = entry.unwrap().path();
        if matches!(
            path.extension().and_then(|s| s.to_str()),
            Some("pack" | "idx")
        ) {
            let tag = path.extension().unwrap().to_str().unwrap();
            let backing = pack.join(format!(".l2s.tmp_pack_{tag}ABC0001"));
            fs::rename(&path, &backing).unwrap();
            symlink(&backing, &path).unwrap();
        }
    }
    let refs = f.authority.import_repo("candidate", &f.source).unwrap();
    assert_eq!(refs["mainCommit"], f.main.to_string());
    f.unchanged();
}
