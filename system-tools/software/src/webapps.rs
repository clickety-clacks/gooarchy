use crate::commands::{Runner, args, output_text};
use crate::ui;
use common::Failure;
use std::env;
use std::ffi::OsString;
use std::fs;
use std::io::{BufRead, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const MARKER: &str = "X-Gooarchy-WebApp=true";

#[derive(Debug, Clone)]
struct AppEntry {
    path: PathBuf,
    id: String,
    name: String,
}

pub fn dispatch(
    args: &[String],
    runner: &Runner,
    input: &mut impl BufRead,
    output: &mut impl Write,
) -> Result<ExitCode, Failure> {
    match args {
        [command, rest @ ..] if command == "install" => {
            let (name, url) = match rest {
                [] => (
                    ui::prompt(input, output, "Web app name: ")?,
                    ui::prompt(input, output, "Web app URL: ")?,
                ),
                [name, url] => (name.clone(), url.clone()),
                _ => {
                    return Err(ui::usage(
                        "usage: gooarchy software webapp install [NAME URL]",
                    ));
                }
            };
            install(&applications_dir()?, &name, &url, output)?;
            Ok(ExitCode::SUCCESS)
        }
        [command, rest @ ..] if command == "launch" => {
            let (focus_id, url) = match rest {
                [url] => (None, url.as_str()),
                [flag, id, url] if flag == "--focus" => (Some(id.as_str()), url.as_str()),
                _ => {
                    return Err(ui::usage(
                        "usage: gooarchy software webapp launch [--focus ID] URL",
                    ));
                }
            };
            launch(runner, focus_id, url)?;
            Ok(ExitCode::SUCCESS)
        }
        [command] if command == "remove" => {
            remove(&applications_dir()?, None, input, output)?;
            Ok(ExitCode::SUCCESS)
        }
        [command, name] if command == "remove" => {
            remove(&applications_dir()?, Some(name), input, output)?;
            Ok(ExitCode::SUCCESS)
        }
        [command] if command == "remove-all" => {
            remove_all(&applications_dir()?, output)?;
            Ok(ExitCode::SUCCESS)
        }
        [] => Err(ui::usage("expected install, launch, remove, or remove-all")),
        [command, ..] => Err(ui::usage(format!("unknown web-app command: {command}"))),
    }
}

fn applications_dir() -> Result<PathBuf, Failure> {
    if let Some(data_home) = env::var_os("XDG_DATA_HOME") {
        let data_home = PathBuf::from(data_home);
        if data_home.is_absolute() {
            return Ok(data_home.join("applications"));
        }
    }
    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| Failure::new("HOME must be set to install a web-app launcher"))?;
    Ok(home.join(".local/share/applications"))
}

fn install(
    applications: &Path,
    name: &str,
    raw_url: &str,
    output: &mut impl Write,
) -> Result<(), Failure> {
    let name = name.trim();
    if name.is_empty() || name.contains(['\n', '\r']) {
        return Err(ui::usage("web-app name must be a single nonempty line"));
    }
    let id = app_id(name)?;
    let url = normalize_url(raw_url)?;
    fs::create_dir_all(applications)?;
    let path = applications.join(format!("{id}.desktop"));
    match fs::symlink_metadata(&path) {
        Ok(metadata) => {
            let is_gooarchy_launcher = metadata.file_type().is_file()
                && fs::read_to_string(&path)
                    .is_ok_and(|contents| contents.lines().any(|line| line == MARKER));
            if !is_gooarchy_launcher {
                return Err(Failure::new(format!(
                    "refusing to replace an existing launcher without the Gooarchy marker: {}",
                    path.display()
                )));
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    let desktop = desktop_entry(name, &id, &url);
    fs::write(&path, desktop)?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755))?;
    writeln!(output, "Installed web app {name} at {}", path.display())?;
    Ok(())
}

fn app_id(name: &str) -> Result<String, Failure> {
    let mut slug = String::new();
    let mut separator = false;
    for byte in name.bytes() {
        if byte.is_ascii_alphanumeric() {
            if separator && !slug.is_empty() {
                slug.push('-');
            }
            slug.push((byte as char).to_ascii_lowercase());
            separator = false;
        } else {
            separator = true;
        }
    }
    if slug.is_empty() {
        return Err(ui::usage("web-app name must contain a letter or number"));
    }
    Ok(format!("gooarchy-webapp-{slug}"))
}

fn normalize_url(raw_url: &str) -> Result<String, Failure> {
    let url = raw_url.trim();
    if url.is_empty() || url.chars().any(char::is_whitespace) {
        return Err(ui::usage(
            "web-app URL must not be empty or contain whitespace",
        ));
    }
    if !url.contains("://") {
        if let Some((prefix, _)) = url.split_once(':') {
            let looks_like_host_port =
                prefix.contains('.') || prefix == "localhost" || prefix == "127.0.0.1";
            if !looks_like_host_port {
                return Err(ui::usage("web-app URL must use http or https"));
            }
        }
    }
    let normalized = if url.contains("://") {
        url.to_owned()
    } else {
        format!("https://{url}")
    };
    let lower = normalized.to_ascii_lowercase();
    let authority = if lower.starts_with("https://") {
        &normalized[8..]
    } else if lower.starts_with("http://") {
        &normalized[7..]
    } else {
        return Err(ui::usage("web-app URL must use http or https"));
    };
    if authority.is_empty() || authority.starts_with('/') {
        return Err(ui::usage("web-app URL must include a host"));
    }
    Ok(normalized)
}

fn desktop_entry(name: &str, id: &str, url: &str) -> String {
    format!(
        "[Desktop Entry]\n\
Type=Application\n\
Version=1.0\n\
Name={}\n\
Comment=Open {} as a web app\n\
Exec=gooarchy software webapp launch --focus {id} {}\n\
Terminal=false\n\
Icon=web-browser\n\
StartupNotify=true\n\
StartupWMClass={id}\n\
{MARKER}\n\
X-Gooarchy-WebApp-Id={id}\n\
X-Gooarchy-WebApp-URL={}\n",
        desktop_string_escape(name),
        desktop_string_escape(name),
        desktop_exec_arg(url),
        desktop_string_escape(url)
    )
}

fn desktop_string_escape(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('\t', "\\t")
        .replace('\r', "\\r")
        .replace('\n', "\\n")
}

fn desktop_exec_arg(value: &str) -> String {
    let mut escaped = String::from("\"");
    for character in value.chars() {
        match character {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            '`' => escaped.push_str("\\`"),
            '$' => escaped.push_str("\\$"),
            '%' => escaped.push_str("%%"),
            other => escaped.push(other),
        }
    }
    escaped.push('"');
    escaped
}

fn launch(runner: &Runner, focus_id: Option<&str>, raw_url: &str) -> Result<(), Failure> {
    let url = normalize_url(raw_url)?;
    if let Some(id) = focus_id {
        if !id.starts_with("gooarchy-webapp-")
            || !id
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        {
            return Err(ui::usage("web-app focus ID is invalid"));
        }
        let windows = runner.output("scottland-ctl", &args(&["windows"]))?;
        if !windows.status.success() {
            return Err(crate::commands::command_error("scottland-ctl", &windows));
        }
        if let Some(window_id) = window_for_app(&output_text(&windows), id) {
            runner.status("scottland-ctl", &args(&["present", &window_id]))?;
            return Ok(());
        }
    }

    let mut browser_args = vec![OsString::from(format!("--app={url}"))];
    if let Some(id) = focus_id {
        browser_args.push(OsString::from(format!("--class={id}")));
    }
    runner.spawn("chromium", &browser_args)
}

fn window_for_app(windows: &str, app_id: &str) -> Option<String> {
    windows.lines().find_map(|line| {
        let mut fields = line.split_whitespace();
        let id = fields.next()?;
        let window_app_id = fields.next()?;
        (window_app_id == app_id && id.bytes().all(|byte| byte.is_ascii_digit()))
            .then(|| id.to_owned())
    })
}

fn entries(applications: &Path) -> Result<Vec<AppEntry>, Failure> {
    let mut found = Vec::new();
    let directory = match fs::read_dir(applications) {
        Ok(directory) => directory,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(found),
        Err(error) => return Err(error.into()),
    };
    for entry in directory {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|extension| extension.to_str()) != Some("desktop") {
            continue;
        }
        let contents = fs::read_to_string(&path)?;
        if !contents.lines().any(|line| line == MARKER) {
            continue;
        }
        let id = contents
            .lines()
            .find_map(|line| line.strip_prefix("X-Gooarchy-WebApp-Id="))
            .map(str::to_owned)
            .or_else(|| path.file_stem()?.to_str().map(str::to_owned));
        let Some(id) = id else { continue };
        let name = contents
            .lines()
            .find_map(|line| line.strip_prefix("Name="))
            .map(desktop_string_unescape)
            .unwrap_or_else(|| id.clone());
        found.push(AppEntry { path, id, name });
    }
    found.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(found)
}

fn desktop_string_unescape(value: &str) -> String {
    let mut result = String::new();
    let mut escaped = false;
    for character in value.chars() {
        if escaped {
            result.push(match character {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                other => other,
            });
            escaped = false;
        } else if character == '\\' {
            escaped = true;
        } else {
            result.push(character);
        }
    }
    if escaped {
        result.push('\\');
    }
    result
}

fn remove(
    applications: &Path,
    name: Option<&str>,
    input: &mut impl BufRead,
    output: &mut impl Write,
) -> Result<(), Failure> {
    let found = entries(applications)?;
    if found.is_empty() {
        writeln!(output, "No web apps to remove.")?;
        return Ok(());
    }
    let selected = if let Some(name) = name {
        let wanted_id = app_id(name).ok();
        found
            .into_iter()
            .find(|entry| entry.name == name || wanted_id.as_deref() == Some(&entry.id))
            .ok_or_else(|| Failure::new(format!("Gooarchy web app not found: {name}")))?
    } else {
        let choices: Vec<_> = found
            .iter()
            .map(|entry| (entry.id.clone(), entry.name.clone()))
            .collect();
        let selected = ui::pick(
            input,
            output,
            &choices,
            false,
            "Select a web app to remove: ",
        )?;
        if selected.is_empty() {
            return Ok(());
        }
        let id = &selected[0];
        found
            .into_iter()
            .find(|entry| &entry.id == id)
            .ok_or_else(|| Failure::new("selected web app is no longer available"))?
    };
    fs::remove_file(&selected.path)?;
    writeln!(output, "Removed web app {}", selected.name)?;
    Ok(())
}

fn remove_all(applications: &Path, output: &mut impl Write) -> Result<(), Failure> {
    let found = entries(applications)?;
    for entry in &found {
        fs::remove_file(&entry.path)?;
    }
    if found.is_empty() {
        writeln!(output, "No Gooarchy web apps found.")?;
    } else {
        writeln!(output, "Removed {} Gooarchy web app(s).", found.len())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Fixture {
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = env::temp_dir().join(format!(
                "gooarchy-webapp-test-{}-{nonce}",
                std::process::id()
            ));
            fs::create_dir_all(&path).unwrap();
            Fixture(path)
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn web_app_install_creates_a_marked_launcher_with_a_quoted_http_url() {
        let fixture = Fixture::new();
        let mut output = Vec::new();
        install(
            &fixture.0,
            "My Favorite App",
            "example.com/path?a=1&b=two%20words",
            &mut output,
        )
        .unwrap();
        let file =
            fs::read_to_string(fixture.0.join("gooarchy-webapp-my-favorite-app.desktop")).unwrap();
        assert!(file.contains("X-Gooarchy-WebApp=true"));
        assert!(file.contains(
            "Exec=gooarchy software webapp launch --focus gooarchy-webapp-my-favorite-app"
        ));
        assert!(file.contains("\"https://example.com/path?a=1&b=two%%20words\""));
        assert_ne!(
            fs::metadata(fixture.0.join("gooarchy-webapp-my-favorite-app.desktop"))
                .unwrap()
                .permissions()
                .mode()
                & 0o111,
            0
        );
        assert_eq!(entries(&fixture.0).unwrap().len(), 1);
    }

    #[test]
    fn web_app_install_refuses_to_replace_an_unmanaged_launcher() {
        let fixture = Fixture::new();
        let path = fixture.0.join("gooarchy-webapp-example.desktop");
        fs::write(&path, "user launcher\n").unwrap();
        let mut output = Vec::new();
        assert!(install(&fixture.0, "Example", "example.com", &mut output).is_err());
        assert_eq!(fs::read_to_string(path).unwrap(), "user launcher\n");
    }

    #[test]
    fn launcher_values_reject_non_http_schemes_and_escape_desktop_strings() {
        assert!(normalize_url("javascript:alert(1)").is_err());
        assert!(normalize_url("https:///missing-host").is_err());
        assert_eq!(
            normalize_url("HTTP://example.com").unwrap(),
            "HTTP://example.com"
        );
        let original = "App \\\nName";
        assert_eq!(
            desktop_string_unescape(&desktop_string_escape(original)),
            original
        );
    }

    #[test]
    fn launch_focus_uses_the_scottland_window_id_for_the_matching_app_id() {
        let windows = "   42  gooarchy-webapp-calendar          main       1.00  Calendar\n   99  other-app                        main       1.00  Other\n";
        assert_eq!(
            window_for_app(windows, "gooarchy-webapp-calendar"),
            Some("42".to_owned())
        );
        assert_eq!(window_for_app(windows, "missing"), None);
    }

    #[test]
    fn remove_all_only_removes_entries_created_by_gooarchy() {
        let fixture = Fixture::new();
        install(&fixture.0, "One", "one.example", &mut Vec::new()).unwrap();
        fs::write(
            fixture.0.join("other.desktop"),
            "[Desktop Entry]\nType=Application\nName=Other\nExec=other\n",
        )
        .unwrap();
        remove_all(&fixture.0, &mut Vec::new()).unwrap();
        assert!(!fixture.0.join("gooarchy-webapp-one.desktop").exists());
        assert!(fixture.0.join("other.desktop").exists());
    }
}
