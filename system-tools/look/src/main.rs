//! Gooarchy's look tool. Theme and wallpaper resolution/application stay in flavorings helpers;
//! this command owns user interaction and delegates each operation to its existing owner.

use common::Failure;
use std::collections::BTreeSet;
use std::env;
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

const THEME_DIRS: &str = "/usr/share/gooarchy-flavorings/themes";
const LOOKUP: &str = "/usr/lib/gooarchy-flavorings/gooarchy-theme-lookup";
const REFRESH: &str = "/usr/lib/gooarchy-flavorings/gooarchy-theme-refresh";
const WALLPAPER: &str = "/usr/lib/gooarchy-flavorings/gooarchy-wallpaper";
const INTEGRATIONS: &str = "/usr/lib/gooarchy-flavorings/gooarchy-theme-integrations";
const HELP: &str = "Usage: gooarchy look <current|list|set THEME|pick|wallpaper ...|font ...>\n\n\
current  Show the effective selected theme and mode\n\
list     List installed catalogue themes\n\
set      Select an installed theme and refresh the desktop\n\
pick     Choose an installed theme from a numbered terminal list\n\
wallpaper current|list|set NAME|next|pick\n\
         Show, choose, advance, or pick this variant's wallpaper\n\
font current|list|set FAMILY|pick\n\
         Show or choose an installed compatible monospace family\n";

#[derive(Clone, Debug)]
struct Paths {
    themes: PathBuf,
    selection: PathBuf,
    lookup: PathBuf,
    refresh: PathBuf,
    wallpaper: PathBuf,
    integrations: PathBuf,
}

impl Paths {
    fn installed() -> Result<Self, Failure> {
        let config_home = match env::var_os("XDG_CONFIG_HOME") {
            Some(value) if !value.is_empty() => PathBuf::from(value),
            _ => PathBuf::from(env::var_os("HOME").ok_or_else(|| {
                Failure::new("HOME is not set and XDG_CONFIG_HOME is empty")
            })?)
            .join(".config"),
        };
        Ok(Self {
            themes: PathBuf::from(THEME_DIRS),
            selection: config_home.join("gooarchy/theme"),
            lookup: PathBuf::from(LOOKUP),
            refresh: PathBuf::from(REFRESH),
            wallpaper: PathBuf::from(WALLPAPER),
            integrations: PathBuf::from(INTEGRATIONS),
        })
    }
}

fn main() -> std::process::ExitCode {
    common::run("gooarchy-look", || {
        let paths = Paths::installed()?;
        dispatch(
            env::args_os().skip(1).collect(),
            &paths,
            &mut io::stdin().lock(),
            &mut io::stdout().lock(),
            &mut io::stderr().lock(),
        )
    })
}

fn dispatch(
    args: Vec<OsString>,
    paths: &Paths,
    input: &mut impl BufRead,
    output: &mut impl Write,
    error: &mut impl Write,
) -> Result<(), Failure> {
    match args.as_slice() {
        [] => {
            output.write_all(HELP.as_bytes())?;
            Ok(())
        }
        [arg] if arg_text(Some(arg)).is_some_and(|arg| matches!(arg, "-h" | "--help")) => {
            output.write_all(HELP.as_bytes())?;
            Ok(())
        }
        [arg] if arg_text(Some(arg)).is_some_and(|arg| arg == "current") => {
            current(paths, output, error)
        }
        [arg] if arg_text(Some(arg)).is_some_and(|arg| arg == "list") => {
            for theme in list_themes(&paths.themes)? {
                writeln!(output, "{theme}")?;
            }
            Ok(())
        }
        [command, slug] if arg_text(Some(command)).is_some_and(|arg| arg == "set") => {
            let slug = arg_text(Some(slug)).ok_or_else(|| usage("theme names must be UTF-8"))?;
            set_theme(paths, slug, output, error)
        }
        [command] if arg_text(Some(command)).is_some_and(|arg| arg == "pick") => {
            pick(paths, input, output, error)
        }
        [category, action]
            if arg_text(Some(category)).is_some_and(|arg| arg == "wallpaper")
                && arg_text(Some(action)).is_some_and(|arg| {
                    matches!(arg, "current" | "list" | "next")
                }) =>
        {
            run_helper(&paths.wallpaper, &[action.clone()], output, error)
        }
        [category, action, name]
            if arg_text(Some(category)).is_some_and(|arg| arg == "wallpaper")
                && arg_text(Some(action)).is_some_and(|arg| arg == "set") =>
        {
            let name = arg_text(Some(name))
                .ok_or_else(|| usage("wallpaper names must be UTF-8"))?;
            run_helper(
                &paths.wallpaper,
                &[OsString::from("set"), OsString::from(name)],
                output,
                error,
            )
        }
        [category, action]
            if arg_text(Some(category)).is_some_and(|arg| arg == "font")
                && arg_text(Some(action)).is_some_and(|arg| matches!(arg, "current" | "list")) =>
        {
            run_helper(
                &paths.integrations,
                &[OsString::from("font"), action.clone()],
                output,
                error,
            )
        }
        [category, action, family]
            if arg_text(Some(category)).is_some_and(|arg| arg == "font")
                && arg_text(Some(action)).is_some_and(|arg| arg == "set") =>
        {
            let family = arg_text(Some(family))
                .ok_or_else(|| usage("font family names must be UTF-8"))?;
            run_helper(
                &paths.integrations,
                &[
                    OsString::from("font"),
                    OsString::from("set"),
                    OsString::from(family),
                ],
                output,
                error,
            )
        }
        [category, action]
            if arg_text(Some(category)).is_some_and(|arg| matches!(arg, "wallpaper" | "font"))
                && arg_text(Some(action)).is_some_and(|arg| arg == "pick") =>
        {
            if arg_text(Some(category)) == Some("wallpaper") {
                pick_helper(
                    &paths.wallpaper,
                    &[OsString::from("list")],
                    &[OsString::from("set")],
                    "Choose a wallpaper number (Enter or 0 cancels): ",
                    input,
                    output,
                    error,
                )
            } else {
                pick_helper(
                    &paths.integrations,
                    &[OsString::from("font"), OsString::from("list")],
                    &[OsString::from("font"), OsString::from("set")],
                    "Choose a font number (Enter or 0 cancels): ",
                    input,
                    output,
                    error,
                )
            }
        }
        _ => Err(usage(
            "expected a theme command, wallpaper current/list/set/next/pick, or font current/list/set/pick",
        )),
    }
}

fn run_helper(
    executable: &Path,
    args: &[OsString],
    output: &mut impl Write,
    error: &mut impl Write,
) -> Result<(), Failure> {
    let result = Command::new(executable)
        .args(args)
        .output()
        .map_err(|error| Failure::new(format!("cannot run {}: {error}", executable.display())))?;
    if !result.stdout.is_empty() {
        output.write_all(&result.stdout)?;
    }
    if !result.stderr.is_empty() {
        error.write_all(&result.stderr)?;
    }
    if !result.status.success() {
        return Err(Failure::new(format!(
            "{} failed with {}",
            executable.display(),
            exit_status(&result.status)
        )));
    }
    Ok(())
}

fn pick_helper(
    executable: &Path,
    list_args: &[OsString],
    set_prefix: &[OsString],
    prompt: &str,
    input: &mut impl BufRead,
    output: &mut impl Write,
    error: &mut impl Write,
) -> Result<(), Failure> {
    let result = Command::new(executable)
        .args(list_args)
        .output()
        .map_err(|error| Failure::new(format!("cannot run {}: {error}", executable.display())))?;
    if !result.stderr.is_empty() {
        error.write_all(&result.stderr)?;
    }
    if !result.status.success() {
        return Err(Failure::new(format!(
            "{} failed with {}",
            executable.display(),
            exit_status(&result.status)
        )));
    }
    let choices: Vec<String> = String::from_utf8_lossy(&result.stdout)
        .lines()
        .filter(|line| !line.is_empty())
        .map(str::to_owned)
        .collect();
    for (index, choice) in choices.iter().enumerate() {
        writeln!(output, "{}. {choice}", index + 1)?;
    }
    write!(output, "{prompt}")?;
    output.flush()?;
    let mut answer = String::new();
    input.read_line(&mut answer)?;
    let answer = answer.trim();
    if answer.is_empty() || answer == "0" {
        return Ok(());
    }
    let index = answer
        .parse::<usize>()
        .map_err(|_| usage("choose a listed number, or press Enter to cancel"))?;
    let choice = choices
        .get(index.checked_sub(1).ok_or_else(|| usage("choice number must be positive"))?)
        .ok_or_else(|| usage("choice number is not in the list"))?;
    let mut args = set_prefix.to_vec();
    args.push(OsString::from(choice.as_str()));
    run_helper(executable, &args, output, error)
}

fn arg_text(arg: Option<&OsString>) -> Option<&str> {
    arg.and_then(|value| value.to_str())
}

fn usage(reason: &str) -> Failure {
    Failure::with_code(2, format!("{reason}\n\n{HELP}"))
}

/// Return complete `<slug>-light`/`<slug>-dark` pairs. Catalogue validity and variant choice
/// remain the flavorings lookup/install contract's responsibility.
fn list_themes(root: &Path) -> Result<Vec<String>, Failure> {
    let entries = fs::read_dir(root).map_err(|error| {
        Failure::new(format!(
            "cannot read theme catalogue {}: {error}",
            root.display()
        ))
    })?;
    let mut light = BTreeSet::new();
    let mut dark = BTreeSet::new();
    for entry in entries {
        let entry = entry.map_err(|error| {
            Failure::new(format!(
                "cannot read theme catalogue {}: {error}",
                root.display()
            ))
        })?;
        if !entry
            .file_type()
            .map_err(|error| {
                Failure::new(format!("cannot inspect theme entry: {error}"))
            })?
            .is_dir()
        {
            continue;
        }
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        if let Some(slug) = name.strip_suffix("-light").filter(|slug| valid_slug(slug)) {
            light.insert(slug.to_owned());
        } else if let Some(slug) = name.strip_suffix("-dark").filter(|slug| valid_slug(slug)) {
            dark.insert(slug.to_owned());
        }
    }
    Ok(light.intersection(&dark).cloned().collect())
}

fn valid_slug(slug: &str) -> bool {
    if slug.is_empty() || slug.starts_with('-') || slug.ends_with('-') {
        return false;
    }
    let mut previous_hyphen = false;
    for byte in slug.bytes() {
        match byte {
            b'a'..=b'z' | b'0'..=b'9' => previous_hyphen = false,
            b'-' if !previous_hyphen => previous_hyphen = true,
            _ => return false,
        }
    }
    !previous_hyphen
}

fn current(paths: &Paths, output: &mut impl Write, error: &mut impl Write) -> Result<(), Failure> {
    let result = Command::new(&paths.lookup)
        .output()
        .map_err(|error| Failure::new(format!("cannot run theme lookup: {error}")))?;
    if !result.stderr.is_empty() {
        error.write_all(&result.stderr)?;
    }
    if !result.status.success() {
        return Err(Failure::new(format!(
            "theme lookup failed with {}",
            exit_status(&result.status)
        )));
    }
    let path = String::from_utf8_lossy(&result.stdout).trim().to_owned();
    let (slug, mode) = variant_from_lookup(&path)?;
    writeln!(output, "{slug} ({mode})")?;
    Ok(())
}

fn variant_from_lookup(path: &str) -> Result<(&str, &str), Failure> {
    let path = Path::new(path);
    if !path.is_absolute() {
        return Err(Failure::new("theme lookup returned a non-absolute variant path"));
    }
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| Failure::new("theme lookup returned an invalid variant path"))?;
    for mode in ["light", "dark"] {
        if let Some(slug) = name.strip_suffix(&format!("-{mode}")) {
            if valid_slug(slug) {
                return Ok((slug, mode));
            }
        }
    }
    Err(Failure::new("theme lookup returned an unknown variant name"))
}

fn set_theme(
    paths: &Paths,
    slug: &str,
    output: &mut impl Write,
    error: &mut impl Write,
) -> Result<(), Failure> {
    if !valid_slug(slug) {
        return Err(usage("theme name must be a lowercase slug"));
    }
    if !list_themes(&paths.themes)?.iter().any(|theme| theme == slug) {
        return Err(Failure::new(format!("theme is not installed: {slug}")));
    }
    write_selection(&paths.selection, slug)?;
    let result = Command::new(&paths.refresh)
        .output()
        .map_err(|error| {
            Failure::new(format!(
                "theme {slug} was saved, but refresh could not run: {error}"
            ))
        })?;
    if !result.stdout.is_empty() {
        output.write_all(&result.stdout)?;
    }
    if !result.stderr.is_empty() {
        error.write_all(&result.stderr)?;
    }
    if !result.status.success() {
        return Err(Failure::new(format!(
            "theme {slug} was saved, but refresh failed with {}",
            exit_status(&result.status)
        )));
    }
    writeln!(output, "Selected theme: {slug}")?;
    Ok(())
}

fn exit_status(status: &std::process::ExitStatus) -> String {
    match status.code() {
        Some(code) => format!("exit status {code}"),
        None => "termination by signal".to_owned(),
    }
}

fn write_selection(path: &Path, slug: &str) -> Result<(), Failure> {
    let parent = path
        .parent()
        .ok_or_else(|| Failure::new("selection record has no parent directory"))?;
    fs::create_dir_all(parent)
        .map_err(|error| Failure::new(format!("cannot create selection directory: {error}")))?;
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let mut temporary = None;
    let mut file = None;
    for attempt in 0..16_u8 {
        let candidate = parent.join(format!(
            ".theme.{}.{}.{}.tmp",
            std::process::id(),
            timestamp,
            attempt
        ));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&candidate)
        {
            Ok(opened) => {
                temporary = Some(candidate);
                file = Some(opened);
                break;
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(Failure::new(format!("cannot create selection record: {error}")));
            }
        }
    }
    let temporary = temporary
        .ok_or_else(|| Failure::new("cannot reserve a temporary selection file"))?;
    let mut file = file.ok_or_else(|| Failure::new("cannot open the reserved selection file"))?;
    let write_result = file
        .write_all(format!("{slug}\n").as_bytes())
        .and_then(|()| file.sync_all());
    drop(file);
    if let Err(error) = write_result {
        let _ = fs::remove_file(&temporary);
        return Err(Failure::new(format!("cannot write selection record: {error}")));
    }
    if let Err(error) = fs::rename(&temporary, path) {
        let _ = fs::remove_file(&temporary);
        return Err(Failure::new(format!("cannot replace selection record: {error}")));
    }
    let directory = OpenOptions::new()
        .read(true)
        .open(parent)
        .and_then(|directory| directory.sync_all());
    directory.map_err(|error| Failure::new(format!("cannot sync selection directory: {error}")))
}

fn pick(
    paths: &Paths,
    input: &mut impl BufRead,
    output: &mut impl Write,
    error: &mut impl Write,
) -> Result<(), Failure> {
    let themes = list_themes(&paths.themes)?;
    for (index, theme) in themes.iter().enumerate() {
        writeln!(output, "{}. {theme}", index + 1)?;
    }
    write!(output, "Choose a theme number (Enter or 0 cancels): ")?;
    output.flush()?;
    let mut answer = String::new();
    input.read_line(&mut answer)?;
    let answer = answer.trim();
    if answer.is_empty() || answer == "0" {
        return Ok(());
    }
    let index = answer
        .parse::<usize>()
        .map_err(|_| usage("choose a listed number, or press Enter to cancel"))?;
    let slug = themes
        .get(index.checked_sub(1).ok_or_else(|| usage("theme number must be positive"))?)
        .ok_or_else(|| usage("theme number is not in the list"))?;
    set_theme(paths, slug, output, error)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT: AtomicU64 = AtomicU64::new(0);

    struct Scratch(PathBuf);

    impl Scratch {
        fn new() -> Self {
            let id = NEXT.fetch_add(1, Ordering::Relaxed);
            let root = env::temp_dir().join(format!("gooarchy-look-{}-{id}", std::process::id()));
            fs::create_dir_all(&root).unwrap();
            Self(root)
        }

        fn theme(&self, slug: &str, mode: &str) {
            fs::create_dir_all(self.0.join("themes").join(format!("{slug}-{mode}"))).unwrap();
        }

        fn executable(&self, name: &str, body: &str) -> PathBuf {
            let path = self.0.join(name);
            fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
            path
        }

        fn paths(&self) -> Paths {
            Paths {
                themes: self.0.join("themes"),
                selection: self.0.join("config/gooarchy/theme"),
                lookup: self.0.join("lookup"),
                refresh: self.0.join("refresh"),
                wallpaper: self.0.join("wallpaper"),
                integrations: self.0.join("integrations"),
            }
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn listing_returns_only_complete_slug_pairs_in_order() {
        let scratch = Scratch::new();
        scratch.theme("zeta", "light");
        scratch.theme("zeta", "dark");
        scratch.theme("alpha-2", "light");
        scratch.theme("alpha-2", "dark");
        scratch.theme("missing", "light");
        scratch.theme("Bad", "light");
        scratch.theme("Bad", "dark");
        fs::write(scratch.0.join("themes/not-a-directory-light"), "ignored").unwrap();

        let paths = scratch.paths();
        let mut input = io::Cursor::new(Vec::<u8>::new());
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        dispatch(
            vec![OsString::from("list")],
            &paths,
            &mut input,
            &mut stdout,
            &mut stderr,
        )
        .unwrap();

        assert_eq!(stdout, b"alpha-2\nzeta\n");
        assert!(stderr.is_empty());
    }

    #[test]
    fn current_displays_the_lookup_variant_and_forwards_its_warning() {
        let scratch = Scratch::new();
        let paths = scratch.paths();
        scratch.executable(
            "lookup",
            "printf '%s\\n' /usr/share/gooarchy-flavorings/themes/plain-light\nprintf 'fallback warning\\n' >&2",
        );
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        let mut input = io::Cursor::new(Vec::<u8>::new());
        dispatch(
            vec![OsString::from("current")],
            &paths,
            &mut input,
            &mut stdout,
            &mut stderr,
        )
        .unwrap();

        assert_eq!(stdout, b"plain (light)\n".to_vec());
        assert_eq!(stderr, b"fallback warning\n".to_vec());
    }

    #[test]
    fn setting_a_catalogue_theme_writes_one_slug_before_refresh() {
        let scratch = Scratch::new();
        scratch.theme("plain", "light");
        scratch.theme("plain", "dark");
        let paths = scratch.paths();
        let calls = scratch.0.join("refresh.calls");
        scratch.executable(
            "refresh",
            &format!("cat '{}' >> '{}'", paths.selection.display(), calls.display()),
        );
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        let mut input = io::Cursor::new(Vec::<u8>::new());
        dispatch(
            vec![OsString::from("set"), OsString::from("plain")],
            &paths,
            &mut input,
            &mut stdout,
            &mut stderr,
        )
        .unwrap();

        assert_eq!(fs::read(&paths.selection).unwrap(), b"plain\n".to_vec());
        assert_eq!(fs::read_to_string(calls).unwrap(), "plain\n");
        assert_eq!(stdout, b"Selected theme: plain\n".to_vec());
        assert!(stderr.is_empty());
        assert_eq!(
            fs::metadata(&paths.selection).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn unknown_or_invalid_theme_does_not_write_or_refresh() {
        let scratch = Scratch::new();
        scratch.theme("plain", "light");
        scratch.theme("plain", "dark");
        let paths = scratch.paths();
        let calls = scratch.0.join("refresh.calls");
        scratch.executable(
            "refresh",
            &format!("echo called >> '{}'", calls.display()),
        );
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();

        let mut input = io::Cursor::new(Vec::<u8>::new());
        assert!(dispatch(
            vec![OsString::from("set"), OsString::from("../plain")],
            &paths,
            &mut input,
            &mut stdout,
            &mut stderr,
        )
        .is_err());
        assert!(dispatch(
            vec![OsString::from("set"), OsString::from("missing")],
            &paths,
            &mut input,
            &mut stdout,
            &mut stderr,
        )
        .is_err());
        assert!(!paths.selection.exists());
        assert!(!calls.exists());
    }

    #[test]
    fn failed_refresh_is_reported_after_the_selection_is_saved() {
        let scratch = Scratch::new();
        scratch.theme("plain", "light");
        scratch.theme("plain", "dark");
        let paths = scratch.paths();
        scratch.executable("refresh", "echo refresh-failed >&2\nexit 1");
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();

        let failure = set_theme(&paths, "plain", &mut stdout, &mut stderr).unwrap_err();
        assert_eq!(fs::read(&paths.selection).unwrap(), b"plain\n");
        assert!(failure
            .message
            .contains("theme plain was saved, but refresh failed"));
        assert_eq!(stderr, b"refresh-failed\n".to_vec());
    }

    #[test]
    fn picker_cancellation_does_not_change_the_selection() {
        let scratch = Scratch::new();
        scratch.theme("plain", "light");
        scratch.theme("plain", "dark");
        let paths = scratch.paths();
        let mut input = io::Cursor::new(b"0\n".to_vec());
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();

        dispatch(
            vec![OsString::from("pick")],
            &paths,
            &mut input,
            &mut stdout,
            &mut stderr,
        )
        .unwrap();

        assert!(!paths.selection.exists());
        assert!(String::from_utf8(stdout).unwrap().contains("1. plain"));
    }

    #[test]
    fn picker_selects_the_numbered_theme() {
        let scratch = Scratch::new();
        scratch.theme("plain", "light");
        scratch.theme("plain", "dark");
        let paths = scratch.paths();
        let calls = scratch.0.join("refresh.calls");
        scratch.executable(
            "refresh",
            &format!("cat '{}' >> '{}'", paths.selection.display(), calls.display()),
        );
        let mut input = io::Cursor::new(b"1\n".to_vec());
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();

        dispatch(
            vec![OsString::from("pick")],
            &paths,
            &mut input,
            &mut stdout,
            &mut stderr,
        )
        .unwrap();

        assert_eq!(fs::read(&paths.selection).unwrap(), b"plain\n".to_vec());
        assert_eq!(fs::read_to_string(calls).unwrap(), "plain\n");
    }

    #[test]
    fn wallpaper_picker_lists_then_delegates_the_selected_filename() {
        let scratch = Scratch::new();
        let paths = scratch.paths();
        let calls = scratch.0.join("wallpaper.calls");
        scratch.executable(
            "wallpaper",
            &format!(
                "printf '%s\\n' \"$*\" >> '{}'\nif [ \"$1\" = list ]; then printf 'a.webp\\nb.png\\n'; fi",
                calls.display()
            ),
        );
        let mut input = io::Cursor::new(b"2\n".to_vec());
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();

        dispatch(
            vec![OsString::from("wallpaper"), OsString::from("pick")],
            &paths,
            &mut input,
            &mut stdout,
            &mut stderr,
        )
        .unwrap();

        assert_eq!(fs::read_to_string(calls).unwrap(), "list\nset b.png\n");
        assert!(String::from_utf8(stdout).unwrap().contains("2. b.png"));
        assert!(stderr.is_empty());
    }

    #[test]
    fn font_family_is_forwarded_as_one_argument_to_the_existing_integration_owner() {
        let scratch = Scratch::new();
        let paths = scratch.paths();
        let calls = scratch.0.join("font.calls");
        scratch.executable(
            "integrations",
            &format!("for arg in \"$@\"; do printf '<%s>\\n' \"$arg\" >> '{}'; done", calls.display()),
        );
        let mut input = io::Cursor::new(Vec::<u8>::new());
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();

        dispatch(
            vec![
                OsString::from("font"),
                OsString::from("set"),
                OsString::from("Fira Code"),
            ],
            &paths,
            &mut input,
            &mut stdout,
            &mut stderr,
        )
        .unwrap();

        assert_eq!(fs::read_to_string(calls).unwrap(), "<font>\n<set>\n<Fira Code>\n");
        assert!(stderr.is_empty());
    }

    #[test]
    fn wallpaper_picker_cancellation_does_not_call_set() {
        let scratch = Scratch::new();
        let paths = scratch.paths();
        let calls = scratch.0.join("wallpaper.calls");
        scratch.executable(
            "wallpaper",
            &format!(
                "printf '%s\\n' \"$*\" >> '{}'\nif [ \"$1\" = list ]; then printf 'a.webp\\n'; fi",
                calls.display()
            ),
        );
        let mut input = io::Cursor::new(b"0\n".to_vec());
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();

        dispatch(
            vec![OsString::from("wallpaper"), OsString::from("pick")],
            &paths,
            &mut input,
            &mut stdout,
            &mut stderr,
        )
        .unwrap();

        assert_eq!(fs::read_to_string(calls).unwrap(), "list\n");
    }

    #[test]
    fn font_picker_uses_the_font_list_and_set_actions() {
        let scratch = Scratch::new();
        let paths = scratch.paths();
        let calls = scratch.0.join("font.calls");
        scratch.executable(
            "integrations",
            &format!(
                "printf '%s\\n' \"$*\" >> '{}'\nif [ \"$1 $2\" = 'font list' ]; then printf 'Fira Code\\n'; fi",
                calls.display()
            ),
        );
        let mut input = io::Cursor::new(b"1\n".to_vec());
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();

        dispatch(
            vec![OsString::from("font"), OsString::from("pick")],
            &paths,
            &mut input,
            &mut stdout,
            &mut stderr,
        )
        .unwrap();

        assert_eq!(fs::read_to_string(calls).unwrap(), "font list\nfont set Fira Code\n");
        assert!(String::from_utf8(stdout).unwrap().contains("1. Fira Code"));
    }
}
