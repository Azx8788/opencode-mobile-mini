use oc_phone_engine::{config::Config, daemon};
use std::{io::Write, path::Path};

/// Only bounded static codes may cross the private launcher pipe. No raw error,
/// configuration path, credential, or environment value is ever serialized.
fn startup_failure(code: &str, status: i32) -> ! {
    let code = match code {
        "engineInspectionProtectionUnavailable"
        | "engineFdHygieneUnavailable"
        | "engineRuntimeUnavailable"
        | "nativeArgumentsInvalid"
        | "nativePinsInvalid"
        | "configUnavailable"
        | "configInvalid"
        | "symlinkRefused"
        | "boundaryInvalid"
        | "serverNotLoopback"
        | "boundaryProofRequired"
        | "credentialsUnavailable"
        | "credentialsUnsafe"
        | "credentialsInvalid"
        | "server_auth_unavailable"
        | "authUnavailable"
        | "authInvalid"
        | "serverCredentialsUnavailable"
        | "serverCredentialsInvalid"
        | "serverConfigInvalid"
        | "storeUnavailable"
        | "recoveryFailed"
        | "repositoryUnavailable"
        | "listenUnavailable"
        | "startupInvalid"
        | "startupPipeUnavailable"
        | "serverStopped"
        | "prootProofSubjectUnavailable"
        | "privateCleanupFailed" => code,
        _ => "engine_start_failed",
    };
    let frame = serde_json::json!({"schemaVersion":1,"startupError":code}).to_string();
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "{frame}").and_then(|_| stdout.flush());
    std::process::exit(status);
}

/// Run before creating Tokio threads/descriptors. ProcessBuilder already clears
/// its environment; enforce the same hygiene for every direct executable mode.
fn startup_hygiene() -> Result<(), &'static str> {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    if unsafe { libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0) } != 0 {
        return Err("engineInspectionProtectionUnavailable");
    }
    let descriptors = std::fs::read_dir("/proc/self/fd")
        .map_err(|_| "engineFdHygieneUnavailable")?
        .map(|entry| {
            entry
                .map_err(|_| "engineFdHygieneUnavailable")?
                .file_name()
                .to_string_lossy()
                .parse::<i32>()
                .map_err(|_| "engineFdHygieneUnavailable")
        })
        .collect::<Result<Vec<_>, _>>()?;
    if descriptors.len() > 4096 {
        return Err("engineFdHygieneUnavailable");
    }
    for fd in descriptors.into_iter().filter(|fd| *fd > 2) {
        if unsafe { libc::close(fd) } != 0
            && std::io::Error::last_os_error().raw_os_error() != Some(libc::EBADF)
        {
            return Err("engineFdHygieneUnavailable");
        }
    }
    for (key, _) in std::env::vars_os().collect::<Vec<_>>() {
        std::env::remove_var(key);
    }
    std::env::set_var("PATH", "/system/bin");
    Ok(())
}

/// This fixture-only subject uses the exact shipped ELF and inspection policy.
/// It receives no config, engine secret, receipt or authority and runs no turns.
fn proot_proof_subject(path: &Path) -> Result<(), &'static str> {
    use std::{
        ffi::CString,
        fs::File,
        io::Read,
        os::{fd::FromRawFd, unix::ffi::OsStrExt},
    };
    let refused = "prootProofSubjectUnavailable";
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or(refused)?;
    let uuid = name.strip_prefix(".phone-engine-view-").ok_or(refused)?;
    if !path.is_absolute()
        || uuid::Uuid::parse_str(uuid)
            .map_err(|_| refused)?
            .to_string()
            != uuid
        || std::fs::canonicalize(path).map_err(|_| refused)? != path
    {
        return Err(refused);
    }
    let raw = CString::new(path.as_os_str().as_bytes()).map_err(|_| refused)?;
    let dir_fd = unsafe {
        libc::open(
            raw.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if dir_fd < 0 {
        return Err(refused);
    }
    let dir = unsafe { File::from_raw_fd(dir_fd) };
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(dir_fd, &mut stat) } != 0
        || stat.st_mode & libc::S_IFMT != libc::S_IFDIR
        || stat.st_mode & 0o777 != 0o700
        || stat.st_uid != unsafe { libc::getuid() }
    {
        return Err(refused);
    }
    let sentinel = CString::new("sentinel").map_err(|_| refused)?;
    let fd = unsafe {
        libc::openat(
            dir_fd,
            sentinel.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
        )
    };
    if fd < 0 {
        return Err(refused);
    }
    let _sentinel = unsafe { File::from_raw_fd(fd) };
    if unsafe { libc::fstat(fd, &mut stat) } != 0
        || stat.st_mode & libc::S_IFMT != libc::S_IFREG
        || stat.st_mode & 0o777 != 0o600
        || stat.st_uid != unsafe { libc::getuid() }
        || stat.st_nlink != 1
        || !(1..=4096).contains(&stat.st_size)
    {
        return Err(refused);
    }
    // Descriptor-relative cwd avoids a replaced pathname after validation.
    if unsafe { libc::fchdir(dir_fd) } != 0 {
        return Err(refused);
    }
    drop(dir);
    let mut stdout = std::io::stdout().lock();
    writeln!(stdout, "READY_SUBJECT:{}:{fd}", unsafe { libc::getpid() })
        .and_then(|_| stdout.flush())
        .map_err(|_| refused)?;
    drop(stdout);
    let mut bytes = [0u8; 64];
    let mut stdin = std::io::stdin().lock();
    loop {
        match stdin.read(&mut bytes) {
            Ok(0) => return Ok(()),
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return Err(refused),
        }
    }
}

fn main() {
    if let Err(code) = startup_hygiene() {
        startup_failure(code, 1);
    }
    let args: Vec<String> = std::env::args().collect();
    if args.len() == 3 && args[1] == "--proot-proof-subject" {
        if let Err(code) = proot_proof_subject(Path::new(&args[2])) {
            startup_failure(code, 1);
        }
        return;
    }
    if args.len() == 3 && args[1] == "--erase-tree" {
        if oc_phone_engine::repository::erase_tree_no_links(Path::new(&args[2])).is_err() {
            startup_failure("privateCleanupFailed", 1);
        }
        return;
    }
    if !matches!(args.len(), 3 | 9) || args[1] != "--config" {
        startup_failure("nativeArgumentsInvalid", 64);
    }
    let config = Config::read(Path::new(&args[2])).unwrap_or_else(|code| startup_failure(code, 1));
    let pins = if args.len() == 9
        && args[3] == "--trusted-public-key-sha256"
        && args[5] == "--native-generation"
        && args[7] == "--policy-sha256"
    {
        Some(daemon::LaunchPins {
            trusted_public_key_sha256: args[4].clone(),
            generation: args[6].clone(),
            policy_sha256: args[8].clone(),
        })
    } else if args.len() == 3 {
        None
    } else {
        startup_failure("nativePinsInvalid", 64);
    };
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap_or_else(|_| startup_failure("engineRuntimeUnavailable", 1));
    oc_phone_engine::startup::watch_parent_pipe();
    if let Err(code) = runtime.block_on(daemon::serve(config, pins)) {
        startup_failure(code, 1);
    }
}
