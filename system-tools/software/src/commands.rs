use common::Failure;
use std::ffi::OsString;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Output, Stdio};

#[derive(Clone, Debug)]
pub struct Runner {
    path: Option<PathBuf>,
}

impl Runner {
    pub fn system() -> Runner {
        Runner { path: None }
    }

    #[cfg(test)]
    pub fn in_path(path: PathBuf) -> Runner {
        Runner { path: Some(path) }
    }

    fn executable(&self, program: &str) -> PathBuf {
        match &self.path {
            Some(path) => path.join(program),
            None => PathBuf::from(program),
        }
    }

    fn command(&self, program: &str) -> Command {
        let mut command = Command::new(self.executable(program));
        if let Some(path) = &self.path {
            command.env("PATH", path);
        }
        command
    }

    pub fn exists(&self, program: &str) -> bool {
        if let Some(path) = &self.path {
            return common::command::is_executable(&path.join(program));
        }
        common::command::find(program).is_some()
    }

    pub fn output(&self, program: &str, args: &[OsString]) -> Result<Output, Failure> {
        self.command(program)
            .args(args)
            .output()
            .map_err(|error| Failure::new(format!("cannot run {program}: {error}")))
    }

    pub fn output_in(
        &self,
        program: &str,
        args: &[OsString],
        directory: &Path,
    ) -> Result<Output, Failure> {
        self.command(program)
            .args(args)
            .current_dir(directory)
            .output()
            .map_err(|error| Failure::new(format!("cannot run {program}: {error}")))
    }

    pub fn output_with_input(
        &self,
        program: &str,
        args: &[OsString],
        input: &[u8],
    ) -> Result<Output, Failure> {
        let mut child = self
            .command(program)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| Failure::new(format!("cannot run {program}: {error}")))?;
        if let Some(mut stdin) = child.stdin.take() {
            stdin.write_all(input)?;
        }
        child
            .wait_with_output()
            .map_err(|error| Failure::new(format!("cannot read {program} result: {error}")))
    }

    pub fn status(&self, program: &str, args: &[OsString]) -> Result<(), Failure> {
        let status = self
            .command(program)
            .args(args)
            .status()
            .map_err(|error| Failure::new(format!("cannot run {program}: {error}")))?;
        require_success(program, status)
    }

    pub fn status_in(
        &self,
        program: &str,
        args: &[OsString],
        directory: &Path,
    ) -> Result<(), Failure> {
        let status = self
            .command(program)
            .args(args)
            .current_dir(directory)
            .status()
            .map_err(|error| Failure::new(format!("cannot run {program}: {error}")))?;
        require_success(program, status)
    }

    pub fn spawn(&self, program: &str, args: &[OsString]) -> Result<(), Failure> {
        self.command(program)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map(|_| ())
            .map_err(|error| Failure::new(format!("cannot start {program}: {error}")))
    }
}

fn require_success(program: &str, status: ExitStatus) -> Result<(), Failure> {
    if status.success() {
        Ok(())
    } else {
        Err(Failure::new(format!("{program} failed with {status}")))
    }
}

pub fn args(values: &[&str]) -> Vec<OsString> {
    values.iter().map(OsString::from).collect()
}

pub fn strings(values: &[String]) -> Vec<OsString> {
    values.iter().map(OsString::from).collect()
}

pub fn output_text(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

pub fn error_text(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).trim().to_owned()
}

pub fn command_error(program: &str, output: &Output) -> Failure {
    let detail = error_text(output);
    if detail.is_empty() {
        Failure::new(format!("{program} failed with {}", output.status))
    } else {
        Failure::new(format!("{program} failed: {detail}"))
    }
}
