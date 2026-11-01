//! Fail-closed Linux/Android tool launcher. PRoot is path emulation, not authority.
//!
//! This policy requires Landlock ABI 6 (including scoped signals and abstract
//! sockets). A seccomp filter additionally closes unmediated metadata and
//! pathname-UNIX-socket operations. It intentionally makes no compatibility or
//! proof claim: the Android/proot harness is a separate prerequisite.
use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

const CREATE_RULESET: libc::c_long = 444;
const ADD_RULE: libc::c_long = 445;
const RESTRICT_SELF: libc::c_long = 446;
const FS_ALL: u64 = (1 << 16) - 1; // Through IOCTL_DEV, available in ABI 5.
const FS_READ: u64 = (1 << 0) | (1 << 2) | (1 << 3);
const FS_FILE: u64 = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 14) | (1 << 15);
const SCOPE_SIGNAL_AND_ABSTRACT_SOCKET: u64 = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BoundaryError(pub &'static str);

#[derive(Debug, Clone)]
pub struct Rule {
    pub path: PathBuf,
    pub write: bool,
    pub device: bool,
}

#[repr(C)]
struct Ruleset {
    handled_access_fs: u64,
    handled_access_net: u64,
    scoped: u64,
}

#[repr(C, packed)]
struct PathBeneath {
    allowed_access: u64,
    parent_fd: i32,
}

pub fn kernel_abi() -> Result<i32, BoundaryError> {
    if !cfg!(any(target_arch = "aarch64", target_arch = "x86_64")) {
        return Err(BoundaryError("boundary_unsupported"));
    }
    // Android's inherited seccomp policy may kill the process instead of
    // returning ENOSYS/EPERM. Query AND exercise all three Landlock syscalls in
    // a disposable child before attempting any of them in the launcher. The
    // child uses only async-signal-safe libc calls: this also works when the
    // caller has other Rust/runtime threads holding allocator locks.
    let mut pipe = [-1; 2];
    if unsafe { libc::pipe2(pipe.as_mut_ptr(), libc::O_CLOEXEC | libc::O_NONBLOCK) } != 0 {
        return Err(BoundaryError("boundary_unsupported"));
    }
    let pid = unsafe { libc::fork() };
    if pid == 0 {
        unsafe {
            libc::close(pipe[0]);
            // A deliberately disposable unsupported-kernel probe must not
            // generate a core dump containing inherited app/engine memory.
            let limit = libc::rlimit {
                rlim_cur: 0,
                rlim_max: 0,
            };
            if libc::setrlimit(libc::RLIMIT_CORE, &limit) != 0 {
                libc::_exit(1);
            }
            let abi = probe_landlock_child();
            let bytes = abi.to_ne_bytes();
            let written = libc::write(pipe[1], bytes.as_ptr().cast(), bytes.len());
            libc::_exit(if written == bytes.len() as isize {
                0
            } else {
                1
            });
        }
    }
    unsafe { libc::close(pipe[1]) };
    if pid < 0 {
        unsafe { libc::close(pipe[0]) };
        return Err(BoundaryError("boundary_unsupported"));
    }
    let completed = wait_probe(pid, std::time::Duration::from_secs(2));
    let mut bytes = [0_u8; 4];
    let count = unsafe { libc::read(pipe[0], bytes.as_mut_ptr().cast(), bytes.len()) };
    unsafe { libc::close(pipe[0]) };
    if !completed || count != bytes.len() as isize {
        return Err(BoundaryError("boundary_unsupported"));
    }
    let abi = i32::from_ne_bytes(bytes);
    if abi < 6 {
        return Err(BoundaryError("boundary_unsupported"));
    }
    Ok(abi)
}

// No allocation, locks, filesystem helpers or Rust destructors after fork.
unsafe fn probe_landlock_child() -> i32 {
    let abi = libc::syscall(CREATE_RULESET, std::ptr::null::<u8>(), 0, 1);
    if abi < 6 {
        return 0;
    }
    let attr = Ruleset {
        handled_access_fs: FS_ALL,
        handled_access_net: 0,
        scoped: SCOPE_SIGNAL_AND_ABSTRACT_SOCKET,
    };
    let ruleset = libc::syscall(CREATE_RULESET, &attr, std::mem::size_of::<Ruleset>(), 0) as i32;
    if ruleset < 0 {
        return 0;
    }
    let root = libc::open(c"/".as_ptr(), libc::O_PATH | libc::O_CLOEXEC);
    if root < 0 {
        libc::close(ruleset);
        return 0;
    }
    // This temporary child grants itself read-only access to /, then exits;
    // none of its policy state can grant authority to the launcher.
    let beneath = PathBeneath {
        allowed_access: FS_READ,
        parent_fd: root,
    };
    let added = libc::syscall(ADD_RULE, ruleset, 1, &beneath, 0);
    libc::close(root);
    let restricted = added == 0
        && libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == 0
        && libc::syscall(RESTRICT_SELF, ruleset, 0) == 0;
    libc::close(ruleset);
    if restricted {
        abi as i32
    } else {
        0
    }
}

fn wait_probe(pid: libc::pid_t, timeout: std::time::Duration) -> bool {
    let deadline = std::time::Instant::now() + timeout;
    loop {
        let mut status = 0;
        let waited = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
        if waited == pid {
            return libc::WIFEXITED(status) && libc::WEXITSTATUS(status) == 0;
        }
        if waited < 0 && std::io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
            return false;
        }
        if std::time::Instant::now() >= deadline {
            // Exact owned child only. Always reap it; a stopped or hung probe
            // must neither block startup indefinitely nor leave a zombie.
            unsafe { libc::kill(pid, libc::SIGKILL) };
            loop {
                let waited = unsafe { libc::waitpid(pid, &mut status, 0) };
                if waited >= 0
                    || std::io::Error::last_os_error().raw_os_error() != Some(libc::EINTR)
                {
                    break;
                }
            }
            return false;
        }
        std::thread::sleep(std::time::Duration::from_millis(2));
    }
}

/// Called by the daemon before secrets or worker-controlled input is read.
pub fn protect_inspection() -> Result<(), BoundaryError> {
    if unsafe { libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0) } != 0 {
        return Err(BoundaryError("inspection_boundary_unavailable"));
    }
    Ok(())
}

/// No environment/config boolean is accepted as proof of OS confinement.
pub fn confine(rules: &[Rule]) -> Result<(), BoundaryError> {
    kernel_abi()?;
    if rules.is_empty() {
        return Err(BoundaryError("empty_policy"));
    }
    let attr = Ruleset {
        handled_access_fs: FS_ALL,
        handled_access_net: 0,
        scoped: SCOPE_SIGNAL_AND_ABSTRACT_SOCKET,
    };
    let ruleset =
        unsafe { libc::syscall(CREATE_RULESET, &attr, std::mem::size_of::<Ruleset>(), 0) } as i32;
    if ruleset < 0 {
        return Err(BoundaryError("landlock_unavailable"));
    }
    let result = (|| {
        for rule in rules {
            let path = canonical_rule(rule)?;
            let cpath = CString::new(path.as_os_str().as_bytes())
                .map_err(|_| BoundaryError("invalid_policy"))?;
            let fd = unsafe { libc::open(cpath.as_ptr(), libc::O_PATH | libc::O_CLOEXEC) };
            if fd < 0 {
                return Err(BoundaryError("policy_path_unavailable"));
            }
            let access = if rule.device {
                FS_FILE & !(1 << 0)
            } else if rule.write {
                FS_ALL
            } else if path.is_dir() {
                FS_READ
            } else {
                FS_READ & !(1 << 3)
            };
            let beneath = PathBeneath {
                allowed_access: access,
                parent_fd: fd,
            };
            let added = unsafe { libc::syscall(ADD_RULE, ruleset, 1, &beneath, 0) };
            unsafe { libc::close(fd) };
            if added != 0 {
                return Err(BoundaryError("landlock_rule_failed"));
            }
        }
        if unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) } != 0 {
            return Err(BoundaryError("no_new_privs_failed"));
        }
        if unsafe { libc::syscall(RESTRICT_SELF, ruleset, 0) } != 0 {
            return Err(BoundaryError("landlock_restrict_failed"));
        }
        deny_unmediated_syscalls()?;
        Ok(())
    })();
    unsafe { libc::close(ruleset) };
    result
}

fn canonical_rule(rule: &Rule) -> Result<PathBuf, BoundaryError> {
    if !rule.path.is_absolute() {
        return Err(BoundaryError("invalid_policy"));
    }
    let path = rule
        .path
        .canonicalize()
        .map_err(|_| BoundaryError("invalid_policy"))?;
    if [
        "/",
        "/data",
        "/data/data",
        "/data/user",
        "/data/user/0",
        "/storage",
        "/dev",
    ]
    .iter()
    .any(|forbidden| path == Path::new(forbidden))
    {
        return Err(BoundaryError("unsafe_policy"));
    }
    if rule.write
        && ["/proc", "/sys", "/system", "/apex", "/vendor"]
            .iter()
            .any(|base| path.starts_with(base))
    {
        return Err(BoundaryError("unsafe_policy"));
    }
    if rule.device
        && !["/dev/null", "/dev/zero", "/dev/random", "/dev/urandom"]
            .iter()
            .any(|allowed| path == Path::new(allowed))
    {
        return Err(BoundaryError("unsafe_device"));
    }
    Ok(path)
}

fn deny_unmediated_syscalls() -> Result<(), BoundaryError> {
    // BPF seccomp_data: nr=0, arch=4, args[0]=16, args[1]=24.
    const LOAD: u16 = 0x20;
    const EQ: u16 = 0x15;
    const RET: u16 = 0x06;
    const ALLOW: u32 = 0x7fff0000;
    const DENY: u32 = 0x00050000 | libc::EPERM as u32;
    const KILL: u32 = 0x80000000;
    #[cfg(target_arch = "aarch64")]
    const ARCH: u32 = 0xc00000b7;
    #[cfg(target_arch = "x86_64")]
    const ARCH: u32 = 0xc000003e;
    #[cfg(not(any(target_arch = "aarch64", target_arch = "x86_64")))]
    return Err(BoundaryError("unsupported_architecture"));
    #[cfg(any(target_arch = "aarch64", target_arch = "x86_64"))]
    {
        let stmt = |code, k| libc::sock_filter {
            code,
            jt: 0,
            jf: 0,
            k,
        };
        let eq = |k, jt, jf| libc::sock_filter {
            code: EQ,
            jt,
            jf,
            k,
        };
        let mut filter = vec![
            stmt(LOAD, 4),
            eq(ARCH, 1, 0),
            stmt(RET, KILL),
            stmt(LOAD, 0),
        ];
        // Prevent x32 ABI from bypassing the native syscall number filter.
        #[cfg(target_arch = "x86_64")]
        filter.extend([
            libc::sock_filter {
                code: 0x45,
                jt: 0,
                jf: 1,
                k: 0x40000000,
            },
            stmt(RET, DENY),
        ]);
        let denied = [
            libc::SYS_fchmod,
            libc::SYS_fchmodat,
            libc::SYS_fchown,
            libc::SYS_fchownat,
            libc::SYS_setxattr,
            libc::SYS_lsetxattr,
            libc::SYS_fsetxattr,
            libc::SYS_removexattr,
            libc::SYS_lremovexattr,
            libc::SYS_fremovexattr,
            libc::SYS_utimensat,
            libc::SYS_mount,
            libc::SYS_umount2,
            libc::SYS_open_by_handle_at,
            libc::SYS_name_to_handle_at,
            libc::SYS_io_uring_setup,
            libc::SYS_io_uring_enter,
            libc::SYS_io_uring_register,
            libc::SYS_bpf,
            libc::SYS_keyctl,
            libc::SYS_unshare,
            libc::SYS_setns,
            428, // open_tree: acquisition of mount handles.
            429, // move_mount
            430, // fsopen
            431, // fsconfig
            432, // fsmount
            433, // fspick
            442, // mount_setattr
            452, // fchmodat2, not present in older libc headers.
        ];
        for nr in denied {
            filter.extend([eq(nr as u32, 0, 1), stmt(RET, DENY)]);
        }
        #[cfg(target_arch = "x86_64")]
        for nr in [
            libc::SYS_chmod,
            libc::SYS_chown,
            libc::SYS_lchown,
            libc::SYS_utime,
            libc::SYS_utimes,
            libc::SYS_futimesat,
        ] {
            filter.extend([eq(nr as u32, 0, 1), stmt(RET, DENY)]);
        }
        // AF_UNIX is denied: older Landlock cannot mediate pathname sockets,
        // which otherwise let tools communicate with privileged app services.
        filter.extend([
            eq(libc::SYS_socket as u32, 0, 3),
            stmt(LOAD, 16),
            eq(libc::AF_UNIX as u32, 0, 1),
            stmt(RET, DENY),
            stmt(LOAD, 0),
        ]);
        // Inherited terminal descriptors must not inject commands into another
        // process via TIOCSTI or TIOCLINUX.
        filter.extend([
            eq(libc::SYS_ioctl as u32, 0, 5),
            stmt(LOAD, 24),
            eq(0x5412, 0, 1),
            stmt(RET, DENY),
            eq(0x541c, 0, 1),
            stmt(RET, DENY),
            stmt(RET, ALLOW),
        ]);
        let prog = libc::sock_fprog {
            len: filter.len() as u16,
            filter: filter.as_mut_ptr(),
        };
        if unsafe { libc::prctl(libc::PR_SET_SECCOMP, 2, &prog, 0, 0) } != 0 {
            return Err(BoundaryError("seccomp_failed"));
        }
        Ok(())
    }
}

/// Descriptor inheritance is not constrained by Landlock; close everything
/// except the deliberately handed-off standard input/output/error streams.
pub fn close_inherited_descriptors() -> Result<(), BoundaryError> {
    let entries = std::fs::read_dir("/proc/self/fd")
        .map_err(|_| BoundaryError("descriptor_inventory_unavailable"))?;
    let fds: Vec<i32> = entries
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| entry.file_name().to_str()?.parse::<i32>().ok())
        .filter(|fd| *fd >= 3)
        .collect();
    for fd in fds {
        unsafe { libc::close(fd) };
    }
    Ok(())
}

#[cfg(test)]
mod kernel_probe_tests {
    #[test]
    fn stopped_probe_is_killed_and_reaped_at_the_deadline() {
        let pid = unsafe { libc::fork() };
        assert!(pid >= 0);
        if pid == 0 {
            unsafe {
                // Stop forever: even a stopped child must not strand startup.
                libc::raise(libc::SIGSTOP);
                libc::_exit(1);
            }
        }
        let start = std::time::Instant::now();
        assert!(!super::wait_probe(
            pid,
            std::time::Duration::from_millis(20)
        ));
        assert!(start.elapsed() < std::time::Duration::from_secs(1));
        let mut status = 0;
        assert_eq!(
            unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) },
            -1
        );
        assert_eq!(
            std::io::Error::last_os_error().raw_os_error(),
            Some(libc::ECHILD)
        );
    }
}
