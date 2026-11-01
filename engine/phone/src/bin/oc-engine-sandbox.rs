use oc_phone_engine::boundary;

use boundary::{BoundaryError, Rule};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;

fn run() -> Result<(), BoundaryError> {
    let mut args = std::env::args_os().skip(1);
    let mut rules = Vec::new();
    let mut program = None;
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--check-kernel") if rules.is_empty() && args.next().is_none() => {
                boundary::kernel_abi()?;
                return Ok(());
            }
            Some("--read-only" | "--read-write" | "--device") => {
                let path = args.next().ok_or(BoundaryError("invalid_arguments"))?;
                rules.push(Rule {
                    path: PathBuf::from(path),
                    write: arg == "--read-write",
                    device: arg == "--device",
                });
            }
            Some("--") => {
                program = args.next();
                break;
            }
            _ => return Err(BoundaryError("invalid_arguments")),
        }
    }
    let program = program.ok_or(BoundaryError("invalid_arguments"))?;
    if !PathBuf::from(&program).is_absolute() {
        return Err(BoundaryError("invalid_program"));
    }
    // No inherited directory/file handle may bypass the pathname policy.
    boundary::close_inherited_descriptors()?;
    boundary::confine(&rules)?;
    let _error = std::process::Command::new(program).args(args).exec();
    Err(BoundaryError("sandbox_exec_failed"))
}

fn main() {
    if let Err(error) = run() {
        // Stable code only, never paths, raw OS errors, argv or environment.
        eprintln!("{}", error.0);
        std::process::exit(78);
    }
}
