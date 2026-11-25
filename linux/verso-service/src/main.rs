//! `verso-service`: Verso's service (Verso Drive, the top bar icon and the account, for its window) and its command
//! line.
//!
//! A thin layer. Every command resolves its inputs, calls one function, and renders the typed result: for people on
//! stdout, or as one JSON document with `--json`. Progress and errors go to stderr. `--llm` and `--man` are answered
//! before argument parsing, from the leading arguments only, so they never steal a subcommand's own arguments.

mod app;
mod commands;
mod completions;
mod online;
mod ui;
mod updates;

use clap::{CommandFactory, FromArgMatches, Parser, Subcommand};
use verso_linux::daemon::StopReason;
use verso_linux::doctor::Status;
use verso_linux::paths::Paths;
use serde::Serialize;
use std::path::PathBuf;
use std::process::ExitCode;

/// The daemon's exit status after an upgrade (EX_TEMPFAIL), on which its user service starts the new version.
const UPGRADED_EXIT_STATUS: u8 = 75;

#[derive(Parser)]
#[command(
    name = "verso-service",
    version = verso_core::product::VERSION,
    about = "Verso's service: Verso Drive, the top bar icon and the account, for its window",
    after_help = "Docs: https://github.com/jakobhviid/verso\nThe full guide, for people and LLMs: verso-service --llm"
)]
pub(crate) struct Cli {
    /// Print the command reference and all of the project's docs, for an LLM or a curious human
    #[arg(long)]
    llm: bool,

    /// Write one JSON document to stdout instead of human output
    #[arg(long, global = true)]
    json: bool,

    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Open Verso's window. Running `verso-service` with no command does the same where there is a display
    App {
        /// Handed to the app, such as the sign-in redirect the browser returns
        #[arg(trailing_var_arg = true, allow_hyphen_values = true, hide = true)]
        arguments: Vec<String>,
    },
    /// Sign in to an Immich server and remember it. Without a flag, sign in through the server's OIDC provider in
    /// your browser: it prints an address to open, then reads the address the browser ends on
    Login {
        /// Sign in with email and password (prompted on a terminal, else read from stdin, one per line)
        #[arg(long, conflicts_with = "api_key")]
        password: bool,
        /// Sign in with an API key (prompted on a terminal, else read from stdin)
        #[arg(long)]
        api_key: bool,
        /// The server's address, such as https://photos.example.org (default: the configured one)
        #[arg(long, value_name = "URL")]
        server: Option<String>,
        /// Trust the server's own certificate, which this computer does not trust, by its SHA-256 fingerprint (as
        /// `openssl x509 -noout -fingerprint -sha256` prints it); refused unless it is the one the server presents.
        /// Without it, a terminal asks
        #[arg(long, value_name = "SHA256")]
        trust_certificate: Option<immich_api::CertificatePin>,
    },
    /// Show the connection, the server, the mount and the cache
    Status,
    /// Run the daemon in the foreground (what the user service starts)
    Daemon,
    /// Read and change settings
    Configure {
        #[command(subcommand)]
        action: ConfigureAction,
    },
    /// Check that everything the mount needs is in place (changes nothing)
    Doctor,
    /// Mount the drive: starts the user service and waits for the mount
    Mount,
    /// Unmount the drive (a dead mount is detached)
    Unmount,
    /// Remove the credential and every cache (settings are kept)
    Logout,
    /// Open the item at a path in the mount in Immich's web app, in the default browser. With --json, print its web
    /// address and open nothing
    Web {
        /// Put the address on the clipboard instead of opening it
        #[arg(long)]
        copy: bool,
        /// A photo, video or folder in the mount
        path: PathBuf,
    },
    /// Show in the file manager, selected, what an immich-crosslink link or an Immich web address on the signed-in
    /// server names. With --json, print where it is and select nothing
    Show {
        /// An immich-crosslink: link, or the address of a page in Immich's web app
        link: String,
    },
    /// Print shell completions
    Completions {
        /// The shell to generate completions for
        shell: clap_complete::Shell,
    },
}

#[derive(Subcommand)]
enum ConfigureAction {
    /// Every setting with its effective value
    List,
    /// The names of all settings
    Keys,
    /// One setting's value
    Get { key: String },
    /// Change a setting
    Set { key: String, value: String },
    /// Return a setting to its default
    Unset { key: String },
}

/// The command line, as clap reads it and the completions and manual page describe it.
pub(crate) fn cli_command() -> clap::Command {
    Cli::command()
}

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().collect();
    // The Flatpak's build (`--features flatpak`), the AppImage's (`--features appimage`) and the packages' (`--features
    // package`), as the window's.
    verso_core::product::set(verso_core::product::built_for(cfg!(feature = "flatpak"), cfg!(feature = "appimage"), cfg!(feature = "package")));
    if is_leading_flag(&arguments, "--man") {
        return finish(completions::print_man());
    }
    if is_leading_flag(&arguments, "--llm") {
        print!("{}", llm_guide());
        return ExitCode::SUCCESS;
    }

    let cli = Cli::from_arg_matches(&cli_command().get_matches()).unwrap_or_else(|error| error.exit());
    let paths = Paths::from_environment();
    let json = cli.json;
    match cli.command {
        Some(Command::Login { password, api_key, server, trust_certificate }) => finish(run_login(&paths, password, api_key, server, trust_certificate, json)),
        Some(Command::Status) => finish(online::status(&paths).map(|report| {
            if json {
                print_json(&report);
            } else {
                let server = match &report.server {
                    Some(server) => format!("{}{}", server.url, server.version.as_deref().map(|version| format!(" (Immich {version})")).unwrap_or_default()),
                    None => "(none)".to_string(),
                };
                println!("state:      {}", report.state);
                if let Some(detail) = &report.detail {
                    println!("            {detail}");
                }
                println!("server:     {server}");
                if let Some(email) = &report.account.email {
                    println!("account:    {email}");
                }
                println!("credential: {}", report.account.credential.unwrap_or("(none)"));
                let mounted = if report.mount.mounted { "mounted" } else if report.mount.stale { "stale; run verso-service unmount" } else { "not mounted" };
                println!("mount:      {} ({mounted})", report.mount.path.display());
                let mebibytes = |bytes: u64| bytes as f64 / (1024.0 * 1024.0);
                println!("cache:      {:.1} MiB of {:.0} MiB", mebibytes(report.cache.used_bytes), mebibytes(report.cache.limit_bytes));
                if let Some(fetched) = &report.fetched {
                    println!("fetched:    {:.1} MiB of originals in {} requests since it mounted", mebibytes(fetched.bytes), fetched.requests);
                }
            }
        })),
        Some(Command::Daemon) => {
            ui::init_log();
            match online::daemon(&paths) {
                // The user service starts the new version on this status (`RestartForceExitStatus=75`).
                Ok(Some(StopReason::Upgraded)) => ExitCode::from(UPGRADED_EXIT_STATUS),
                outcome => finish(outcome.map(|_| ())),
            }
        }
        Some(Command::Configure { action }) => finish(run_configure(&paths, action, json)),
        Some(Command::Doctor) => finish(commands::doctor(&paths).map(|report| {
            if json {
                print_json(&report);
            } else {
                for check in &report.checks {
                    let glyph = match check.status {
                        Status::Ok => "✓",
                        Status::Warning => "⚠",
                        Status::Problem => "✗",
                        Status::Skipped => "·",
                    };
                    println!("{glyph} {}: {}", check.name, check.detail);
                    if let Some(fix) = &check.fix {
                        println!("    {fix}");
                    }
                }
                println!("{}", headline(report.problems, report.warnings));
            }
        })),
        Some(Command::Mount) => finish(commands::mount(&paths).map(|report| {
            if json {
                print_json(&report);
            } else if report.was_mounted {
                println!("{} was already mounted", report.mount_point.display());
            } else {
                println!("mounted at {}", report.mount_point.display());
            }
        })),
        Some(Command::Unmount) => finish(commands::unmount(&paths).map(|report| {
            if json {
                print_json(&report);
            } else {
                match report.was {
                    verso_linux::mounts::MountState::Mounted => println!("unmounted {}", report.mount_point.display()),
                    verso_linux::mounts::MountState::Stale => println!("detached a dead mount at {}", report.mount_point.display()),
                    verso_linux::mounts::MountState::NotMounted => println!("{} was not mounted", report.mount_point.display()),
                }
            }
        })),
        Some(Command::Logout) => finish(commands::logout(&paths, online::revoke_session(&paths)).map(|report| {
            if json {
                print_json(&report);
            } else if report.removed.is_empty() && report.seeded_thumbnails_removed == 0 && !report.unmounted && !report.session_ended {
                println!("Nothing to remove");
            } else {
                if report.session_ended {
                    println!("ended the session on the server");
                }
                if report.unmounted {
                    println!("unmounted");
                }
                if report.seeded_thumbnails_removed > 0 {
                    println!("removed {} seeded thumbnail(s)", report.seeded_thumbnails_removed);
                }
                for path in &report.removed {
                    println!("removed {}", path.display());
                }
            }
        })),
        Some(Command::Web { copy, path }) => finish(commands::web(&paths, &path).and_then(|report| {
            if json {
                print_json(&report);
            } else if copy {
                verso_linux::clipboard::copy(&report.url).map_err(anyhow::Error::msg)?;
                println!("copied {}", report.url);
            } else {
                commands::open_in_browser(&report.url)?;
                println!("opened {}", report.url);
            }
            Ok(())
        })),
        Some(Command::Completions { shell }) => {
            completions::print_completions(shell);
            ExitCode::SUCCESS
        }
        // A crosslink comes from the launcher's scheme handler: it is shown, or a notification says why not, and the
        // app does not open.
        Some(Command::App { arguments }) if commands::is_crosslink(&arguments) => finish(commands::receive_link(&arguments[0])),
        Some(Command::App { arguments }) => finish(Err(app::open(&arguments))),
        Some(Command::Show { link }) => finish(commands::show(&link, !json, false).and_then(|report| {
            if json {
                print_json(&report);
            } else if let Some(path) = &report.path {
                println!("{path}");
            }
            match report.result.as_str() {
                "show" => Ok(()),
                _ => anyhow::bail!("{}", report.message.as_deref().unwrap_or(&report.result)),
            }
        })),
        // The app first; the command line where there is no display to show it on.
        None if app::has_display() => finish(Err(app::open(&[]))),
        None => finish(cli_command().print_help().map_err(anyhow::Error::from)),
    }
}

fn run_login(paths: &Paths, password: bool, api_key: bool, server: Option<String>, trust_certificate: Option<immich_api::CertificatePin>, json: bool) -> anyhow::Result<()> {
    let method = match (password, api_key) {
        (true, _) => online::LoginMethod::Password,
        (_, true) => online::LoginMethod::ApiKey,
        _ => online::LoginMethod::Browser,
    };
    let report = online::login(paths, method, server, trust_certificate)?;
    // A daemon already running holds the credential it started with; it starts again with this one (`try-restart`
    // leaves a stopped service alone), unless a copy into Upload is in flight, which a restart would cut short.
    let uploading = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map(|runtime| runtime.block_on(verso_linux::dbus::uploads_in_flight()))
        .unwrap_or_default();
    if uploading.is_empty() {
        // Only an install a unit runs; a Flatpak's and an AppImage's service is started by their window.
        if verso_core::product::current().installed() {
            let _ = std::process::Command::new("systemctl")
                .args(["--user", "try-restart", &verso_linux::service::user_service()])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status();
        }
    } else if !json {
        eprintln!(
            "the mount keeps its earlier sign-in until its uploads finish; then run `{}` and `{}`",
            verso_core::product::command("unmount"),
            verso_core::product::command("mount")
        );
    }
    if json {
        print_json(&report);
    } else {
        let user = report.user.as_deref().map(|user| format!(" as {user}")).unwrap_or_default();
        println!("✓ signed in to {} (Immich {}){user} with {}, kept in {}", report.server, report.server_version, report.method, report.stored_in);
        if let Some(certificate) = &report.certificate {
            println!("  trusting its own certificate, SHA-256 {certificate}");
        }
        // A logout turns the user service off; say how to turn it on, unless it already is, and where there is a drive
        // to mount.
        let unit = verso_linux::service::user_service();
        let enabled = std::process::Command::new("systemctl")
            .args(["--user", "is-enabled", "--quiet", &unit])
            .status()
            .is_ok_and(|status| status.success());
        if !enabled && verso_core::product::current().drive {
            println!("next: `{}` mounts it now and at every login", verso_core::product::command("mount"));
        }
    }
    Ok(())
}

fn run_configure(paths: &Paths, action: ConfigureAction, json: bool) -> anyhow::Result<()> {
    match action {
        ConfigureAction::List => {
            let rows = commands::configure_list(paths)?;
            if json {
                print_json(&rows);
            } else {
                for row in rows {
                    let marker = if row.is_set { "" } else { "  (default)" };
                    println!("{} = {}{marker}", row.key, if row.value.is_empty() { "(not set)" } else { &row.value });
                }
            }
        }
        ConfigureAction::Keys => {
            let keys: Vec<&str> = verso_core::settings::SETTINGS.iter().map(|setting| setting.key).collect();
            if json {
                print_json(&keys);
            } else {
                for key in keys {
                    println!("{key}");
                }
            }
        }
        ConfigureAction::Get { key } => print_row(&commands::configure_get(paths, &key)?, json),
        ConfigureAction::Set { key, value } => print_row(&commands::configure_set(paths, &key, &value)?, json),
        ConfigureAction::Unset { key } => print_row(&commands::configure_unset(paths, &key)?, json),
    }
    Ok(())
}

fn print_row(row: &commands::SettingRow, json: bool) {
    if json {
        print_json(row);
    } else {
        println!("{}", row.value);
    }
}

/// A result headline that carries failures in its text, not only in colour.
fn headline(problems: usize, warnings: usize) -> String {
    match (problems, warnings) {
        (0, 0) => "✓ all checks passed".to_string(),
        (0, warnings) => format!("⚠ {warnings} warning(s)"),
        (problems, warnings) => format!("✗ {problems} problem(s), {warnings} warning(s)"),
    }
}

fn print_json<Report: Serialize + ?Sized>(report: &Report) {
    match serde_json::to_string_pretty(report) {
        Ok(text) => println!("{text}"),
        Err(error) => ui::err(&format!("could not write JSON: {error}")),
    }
}

/// Whether `flag` appears among the leading flags, before the first subcommand or value.
fn is_leading_flag(arguments: &[String], flag: &str) -> bool {
    arguments
        .iter()
        .skip(1)
        .take_while(|argument| argument.starts_with('-'))
        .any(|argument| argument == flag)
}

fn finish(outcome: anyhow::Result<()>) -> ExitCode {
    match outcome {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            ui::err(&format!("{error:#}"));
            ExitCode::FAILURE
        }
    }
}

/// The `--llm` guide: the generated command reference, then the repository's docs, embedded at compile time so
/// they can never drift from the binary.
fn llm_guide() -> String {
    let mut guide = String::from("===== COMMAND REFERENCE =====\n\n");
    let mut root = cli_command();
    let program = root.get_name().to_owned();
    guide.push_str(&root.render_long_help().to_string());
    for subcommand in root.get_subcommands_mut().filter(|subcommand| !subcommand.is_hide_set()) {
        guide.push_str(&format!("\n\n----- {program} {} -----\n\n", subcommand.get_name()));
        guide.push_str(&subcommand.render_long_help().to_string());
    }
    let documents: &[(&str, &str)] = &[
        ("README", include_str!("../../../README.md")),
        ("WORKFLOWS", include_str!("../../../WORKFLOWS.md")),
        ("SPEC", include_str!("../../../SPEC.md")),
        ("ARCHITECTURE", include_str!("../../../ARCHITECTURE.md")),
        ("PRINCIPLES", include_str!("../../../PRINCIPLES.md")),
        ("ROADMAP", include_str!("../../../ROADMAP.md")),
    ];
    for (name, body) in documents {
        guide.push_str(&format!("\n\n===== {name} =====\n\n"));
        guide.push_str(body);
    }
    guide
}
