//! Authentication over the child's private launch pipe, before TCP is trusted.
use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::io::{Read, Write};

/// Metadata read by the nondumpable child itself, authenticated over its private
/// launch pipe. Native may use it only while the exact launching Process lives.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct ProcessIdentity {
    pid: i32,
    start_ticks: i64,
    parent: i32,
    group: i32,
    session: i32,
}

impl ProcessIdentity {
    fn validate(&self) -> Result<(), &'static str> {
        if self.pid <= 1
            || self.start_ticks <= 0
            || self.parent < 0
            || self.group <= 0
            || self.session < 0
        {
            return Err("startupInvalid");
        }
        Ok(())
    }

    fn from_stat(stat: &str) -> Result<Self, &'static str> {
        if stat.len() > 4096 {
            return Err("startupInvalid");
        }
        // comm can contain spaces and parentheses. Its final ')' is the only
        // reliable boundary before the fixed-position numeric stat fields.
        let (pid, _) = stat.split_once(" (").ok_or("startupInvalid")?;
        let close = stat.rfind(')').ok_or("startupInvalid")?;
        if close < pid.len() + 2 {
            return Err("startupInvalid");
        }
        let fields: Vec<&str> = stat[close + 1..].split_ascii_whitespace().collect();
        if fields.len() < 20 {
            return Err("startupInvalid");
        }
        let number = |value: &str| -> Result<i64, &'static str> {
            if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
                return Err("startupInvalid");
            }
            value.parse::<i64>().map_err(|_| "startupInvalid")
        };
        let int = |value: &str| -> Result<i32, &'static str> {
            i32::try_from(number(value)?).map_err(|_| "startupInvalid")
        };
        let identity = Self {
            pid: int(pid)?,
            start_ticks: number(fields[19])?,
            parent: int(fields[1])?,
            group: int(fields[2])?,
            session: int(fields[3])?,
        };
        identity.validate()?;
        Ok(identity)
    }

    fn current() -> Result<Self, &'static str> {
        // /proc/self remains available after PR_SET_DUMPABLE=0 even when
        // Android hidepid prevents the parent reading /proc/<child>/stat.
        let mut stat = String::new();
        std::fs::File::open("/proc/self/stat")
            .map_err(|_| "startupInvalid")?
            .take(4097)
            .read_to_string(&mut stat)
            .map_err(|_| "startupInvalid")?;
        let identity = Self::from_stat(&stat)?;
        if identity.pid as u32 != std::process::id() {
            return Err("startupInvalid");
        }
        Ok(identity)
    }
}

fn ready_line(
    port: u16,
    profile: &str,
    token: &str,
    nonce: &str,
    identity: ProcessIdentity,
) -> Result<String, &'static str> {
    identity.validate()?;
    if port == 0
        || !crate::config::valid_id(profile)
        || token.len() != 64
        || !token
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        || uuid::Uuid::parse_str(nonce).is_err()
    {
        return Err("startupInvalid");
    }
    let ProcessIdentity {
        pid,
        start_ticks,
        parent,
        group,
        session,
    } = identity;
    let message = format!("oc-phone-engine-ready-v2\n{profile}\n{port}\n{nonce}\n{pid}\n{start_ticks}\n{parent}\n{group}\n{session}");
    let mut mac = Hmac::<Sha256>::new_from_slice(token.as_bytes()).map_err(|_| "startupInvalid")?;
    mac.update(message.as_bytes());
    let signature: String = mac
        .finalize()
        .into_bytes()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    let line = serde_json::json!({"schemaVersion":2,"profileId":profile,"port":port,"nonce":nonce,"mac":signature,"identity":identity}).to_string();
    if line.len() > 1024 {
        return Err("startupInvalid");
    }
    Ok(line)
}

/// Call exactly once after binding port 0 and after startup hygiene, before HTTP.
pub fn publish_ready(port: u16, profile: &str, token: &str) -> Result<(), &'static str> {
    let identity = ProcessIdentity::current()?;
    let line = ready_line(
        port,
        profile,
        token,
        &uuid::Uuid::new_v4().to_string(),
        identity,
    )?;
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    writeln!(out, "{line}")
        .and_then(|_| out.flush())
        .map_err(|_| "startupPipeUnavailable")
}

fn wait_for_eof(mut reader: impl Read) -> std::io::Result<()> {
    let mut bytes = [0u8; 64];
    loop {
        match reader.read(&mut bytes) {
            Ok(0) => return Ok(()),
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
}

/// The native app retains the writable stdin endpoint until stop or app death.
/// Data is ignored; EOF or pipe failure sends the existing graceful SIGTERM.
pub fn watch_parent_pipe() {
    std::thread::spawn(|| {
        let _ = wait_for_eof(std::io::stdin().lock());
        unsafe {
            libc::kill(libc::getpid(), libc::SIGTERM);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture_identity() -> ProcessIdentity {
        ProcessIdentity {
            pid: 12345,
            start_ticks: 987654321,
            parent: 12000,
            group: 12000,
            session: 0,
        }
    }
    fn stat_line(pid: &str, parent: &str, group: &str, session: &str, ticks: &str) -> String {
        let mut fields = vec!["0"; 20];
        fields[0] = "S";
        fields[1] = parent;
        fields[2] = group;
        fields[3] = session;
        fields[19] = ticks;
        format!("{pid} (engine ) odd (name)) {}", fields.join(" "))
    }
    #[test]
    fn process_identity_parses_comm_and_checks_native_numeric_bounds() {
        assert_eq!(
            ProcessIdentity::from_stat(&stat_line("12345", "12000", "12000", "0", "987654321"))
                .unwrap(),
            fixture_identity()
        );
        assert!(ProcessIdentity::from_stat(&stat_line(
            "2147483647",
            "0",
            "2147483647",
            "2147483647",
            "9223372036854775807"
        ))
        .is_ok());
        for fields in [
            ["1", "0", "1", "0", "1"],
            ["2147483648", "0", "1", "0", "1"],
            ["2", "-1", "1", "0", "1"],
            ["2", "2147483648", "1", "0", "1"],
            ["2", "0", "0", "0", "1"],
            ["2", "0", "2147483648", "0", "1"],
            ["2", "0", "1", "-1", "1"],
            ["2", "0", "1", "2147483648", "1"],
            ["2", "0", "1", "0", "0"],
            ["2", "0", "1", "0", "-1"],
            ["2", "0", "1", "0", "9223372036854775808"],
            ["2", "0", "1", "0", "1.5"],
        ] {
            assert_eq!(
                ProcessIdentity::from_stat(&stat_line(
                    fields[0], fields[1], fields[2], fields[3], fields[4]
                ))
                .unwrap_err(),
                "startupInvalid"
            );
        }
        for malformed in ["", "2 engine S 1", "2 (engine) S 1", "2 engine) S 1"] {
            assert!(ProcessIdentity::from_stat(malformed).is_err());
        }
        assert!(ProcessIdentity::from_stat(&"x".repeat(4097)).is_err());
    }
    #[test]
    fn self_identity_matches_current_process() {
        let identity = ProcessIdentity::current().unwrap();
        assert_eq!(identity.pid as u32, std::process::id());
        assert_eq!(identity.parent, unsafe { libc::getppid() });
        assert_eq!(identity.group, unsafe { libc::getpgrp() });
        assert_eq!(identity.session, unsafe { libc::getsid(0) });
        assert!(identity.start_ticks > 0);
    }
    #[test]
    fn readiness_is_bounded_authenticated_and_binds_every_identity_field() {
        let token = "ab".repeat(32);
        let nonce = "57cfb6f9-6f2d-4d84-bbc4-26d23927a2c3";
        let identity = fixture_identity();
        let line = ready_line(43123, "phone", &token, nonce, identity).unwrap();
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        let mut mac = Hmac::<Sha256>::new_from_slice(token.as_bytes()).unwrap();
        mac.update(b"oc-phone-engine-ready-v2\nphone\n43123\n57cfb6f9-6f2d-4d84-bbc4-26d23927a2c3\n12345\n987654321\n12000\n12000\n0");
        let expected: String = mac
            .finalize()
            .into_bytes()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        assert_eq!(value["mac"], expected);
        assert_eq!(
            expected,
            "a821cb0022b70367032aa1ff3dff2714f9dbbfaf79fcf17b547fb9a52875552f"
        );
        assert_eq!(value["schemaVersion"], 2);
        assert_eq!(value.as_object().unwrap().len(), 6);
        assert_eq!(
            value["identity"],
            serde_json::json!({"pid":12345,"startTicks":987654321,"parent":12000,"group":12000,"session":0})
        );
        assert!(line.len() <= 1024 && !line.contains(&token));
        for changed in [
            ProcessIdentity {
                pid: 12346,
                ..identity
            },
            ProcessIdentity {
                start_ticks: 987654322,
                ..identity
            },
            ProcessIdentity {
                parent: 12001,
                ..identity
            },
            ProcessIdentity {
                group: 12001,
                ..identity
            },
            ProcessIdentity {
                session: 1,
                ..identity
            },
        ] {
            let changed: serde_json::Value =
                serde_json::from_str(&ready_line(43123, "phone", &token, nonce, changed).unwrap())
                    .unwrap();
            assert_ne!(changed["mac"], value["mac"]);
        }
        assert_ne!(
            ready_line(43124, "phone", &token, nonce, identity).unwrap(),
            line
        );
        assert_ne!(
            ready_line(43123, "other", &token, nonce, identity).unwrap(),
            line
        );
        assert!(ready_line(0, "phone", &token, nonce, identity).is_err());
        assert!(ready_line(43123, "phone", &token, "invalid", identity).is_err());
        assert!(ready_line(
            43123,
            "phone",
            &token,
            nonce,
            ProcessIdentity { pid: 1, ..identity }
        )
        .is_err());
    }
    #[test]
    fn stdin_eof_child() {
        if std::env::var_os("OC_ENGINE_STDIN_EOF_CHILD").is_some() {
            watch_parent_pipe();
            loop {
                std::thread::sleep(std::time::Duration::from_secs(1));
            }
        }
    }
    #[cfg(unix)]
    #[test]
    fn engine_process_survives_launcher_thread_and_terminates_on_actual_stdin_eof() {
        use std::os::unix::process::ExitStatusExt;
        use std::process::{Command, Stdio};
        let executable = std::env::current_exe().unwrap();
        let mut child = std::thread::spawn(move || {
            Command::new(executable)
                .args(["--exact", "startup::tests::stdin_eof_child", "--nocapture"])
                .env("OC_ENGINE_STDIN_EOF_CHILD", "1")
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap()
        })
        .join()
        .unwrap();
        std::thread::sleep(std::time::Duration::from_millis(100));
        assert!(
            child.try_wait().unwrap().is_none(),
            "launch-thread exit killed engine"
        );
        drop(child.stdin.take());
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        loop {
            if let Some(status) = child.try_wait().unwrap() {
                assert_eq!(status.signal(), Some(libc::SIGTERM));
                break;
            }
            if std::time::Instant::now() >= deadline {
                child.kill().unwrap();
                let _ = child.wait();
                panic!("engine outlived stdin EOF");
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }
    #[cfg(unix)]
    #[test]
    fn launching_thread_exit_is_not_pipe_eof_but_parent_endpoint_close_is() {
        use std::fs::File;
        use std::os::fd::FromRawFd;
        use std::sync::mpsc;
        let mut descriptors = [-1; 2];
        assert_eq!(
            unsafe { libc::pipe2(descriptors.as_mut_ptr(), libc::O_CLOEXEC) },
            0
        );
        let child = unsafe { File::from_raw_fd(descriptors[0]) };
        let parent = unsafe { File::from_raw_fd(descriptors[1]) };
        let (done_tx, done_rx) = mpsc::channel();
        // A short-lived channel thread launches the reader then exits.
        std::thread::spawn(move || {
            std::thread::spawn(move || {
                wait_for_eof(child).unwrap();
                done_tx.send(()).unwrap();
            });
        })
        .join()
        .unwrap();
        assert!(done_rx
            .recv_timeout(std::time::Duration::from_millis(100))
            .is_err());
        drop(parent);
        done_rx
            .recv_timeout(std::time::Duration::from_secs(1))
            .unwrap();
    }
}
