//! Android's app seccomp policy is inherited across exec. A denied Landlock
//! syscall must kill only the disposable probe, never the sandbox launcher.
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Command, Output};

const CREATE: u32 = 444;
const ADD: u32 = 445;
const RESTRICT: u32 = 446;
const ALLOW: u32 = 0x7fff0000;
const KILL_PROCESS: u32 = 0x80000000;
const ERRNO: u32 = 0x00050000;

fn sandbox_with_filter(syscall: u32, action: u32, args: &[&str]) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_oc-engine-sandbox"));
    command.args(args);
    unsafe {
        command.pre_exec(move || {
            // No allocation or locks in this pre-exec child.
            let mut filter = [
                libc::sock_filter {
                    code: 0x20,
                    jt: 0,
                    jf: 0,
                    k: 0,
                },
                libc::sock_filter {
                    code: 0x15,
                    jt: 0,
                    jf: 1,
                    k: syscall,
                },
                libc::sock_filter {
                    code: 0x06,
                    jt: 0,
                    jf: 0,
                    k: action,
                },
                libc::sock_filter {
                    code: 0x06,
                    jt: 0,
                    jf: 0,
                    k: ALLOW,
                },
            ];
            let program = libc::sock_fprog {
                len: filter.len() as u16,
                filter: filter.as_mut_ptr(),
            };
            let limit = libc::rlimit {
                rlim_cur: 0,
                rlim_max: 0,
            };
            libc::setrlimit(libc::RLIMIT_CORE, &limit);
            if libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0
                || libc::prctl(libc::PR_SET_SECCOMP, 2, &program, 0, 0) != 0
            {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    command.output().expect("start sandbox regression process")
}

fn assert_unsupported(output: Output) {
    assert_eq!(output.status.signal(), None, "launcher was killed");
    assert_eq!(output.status.code(), Some(78));
    assert_eq!(output.stderr, b"boundary_unsupported\n");
}

#[test]
fn seccomp_sigsys_on_query_preserves_launcher_and_reports_unsupported() {
    assert_unsupported(sandbox_with_filter(
        CREATE,
        KILL_PROCESS,
        &["--check-kernel"],
    ));
}

#[test]
fn unavailable_landlock_is_typed_unsupported() {
    assert_unsupported(sandbox_with_filter(
        CREATE,
        ERRNO | libc::ENOSYS as u32,
        &["--check-kernel"],
    ));
}

#[test]
fn query_alone_cannot_pass_when_rule_or_restriction_is_blocked() {
    // These checks work on old kernels too: ABI < 6 is itself unsupported.
    for syscall in [ADD, RESTRICT] {
        assert_unsupported(sandbox_with_filter(
            syscall,
            KILL_PROCESS,
            &["--check-kernel"],
        ));
    }
}

#[test]
fn blocked_landlock_never_executes_the_requested_program() {
    assert_unsupported(sandbox_with_filter(
        CREATE,
        KILL_PROCESS,
        &["--read-only", "/usr", "--", "/usr/bin/true"],
    ));
}
