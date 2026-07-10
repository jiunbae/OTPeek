//! `otpeek` — CLI for the OTPeek vault.
//! See docs/ARCHITECTURE.md §8 (frozen contract).
//!
//! Depends only on otpeek-core / otpeek-vault / otpeek-sync (never otpeek-ffi).

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, bail, Context, Result};
use clap::{Args, Parser, Subcommand};
use otpeek_core::{HashAlgorithm, OtpAccount, OtpFolder, OtpType};
use otpeek_vault::{Vault, VaultPayload};
use serde::{Deserialize, Serialize};

const KEYRING_SERVICE: &str = "otpeek";
const KEYRING_WEBDAV: &str = "otpeek-webdav";

// ---------------------------------------------------------------------------
// CLI definition
// ---------------------------------------------------------------------------

#[derive(Parser)]
#[command(name = "otpeek", version, about = "OTPeek CLI")]
struct Cli {
    /// Path to the vault file (overrides $OTPEEK_VAULT and the saved selection).
    #[arg(long, global = true)]
    vault: Option<String>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Create a new vault (prompts for a master password twice).
    Init,
    /// Add an account from an otpauth:// URI or from explicit flags.
    Add(AddArgs),
    /// List accounts.
    List(ListArgs),
    /// Print (or copy/watch) the current code for an account.
    Code(CodeArgs),
    /// Print the otpauth:// URI for an account.
    Uri { query: String },
    /// Render the account's otpauth:// URI as a QR code in the terminal.
    Qr { query: String },
    /// Delete (tombstone) an account.
    Rm {
        query: String,
        #[arg(long)]
        yes: bool,
    },
    /// Edit account metadata.
    Edit(EditArgs),
    /// Manage folders.
    Folder {
        #[command(subcommand)]
        action: FolderCmd,
    },
    /// Export a v2 encrypted backup container.
    Export {
        file: String,
        #[arg(long = "password-stdin")]
        password_stdin: bool,
    },
    /// Import a backup (v2 by default, or legacy v1 with --legacy).
    Import {
        file: String,
        #[arg(long)]
        merge: bool,
        #[arg(long)]
        legacy: bool,
    },
    /// Configure and run sync.
    Sync {
        #[command(subcommand)]
        action: SyncCmd,
    },
    /// Bootstrap this device from a backup file or WebDAV URL.
    Restore { target: String },
    /// Change the master password.
    Passwd,
    /// Select and inspect the active vault.
    Vault {
        #[command(subcommand)]
        action: VaultCmd,
    },
    /// Unlock the active vault and cache its key in the OS keyring.
    Unlock,
    /// Remove the active vault's cached key from the OS keyring.
    Lock,
}

#[derive(Args)]
struct AddArgs {
    /// otpauth:// or otpauth-migration:// URI.
    uri: Option<String>,
    #[arg(long)]
    issuer: Option<String>,
    #[arg(long)]
    account: Option<String>,
    /// Base32 secret, or `-` to read from stdin.
    #[arg(long)]
    secret: Option<String>,
    #[arg(long)]
    hotp: bool,
    #[arg(long)]
    digits: Option<u32>,
    #[arg(long)]
    period: Option<u32>,
    #[arg(long)]
    algorithm: Option<String>,
}

#[derive(Args)]
struct ListArgs {
    #[arg(long)]
    folder: Option<String>,
    #[arg(long)]
    json: bool,
}

#[derive(Args)]
struct CodeArgs {
    query: String,
    #[arg(long)]
    copy: bool,
    #[arg(long)]
    watch: bool,
    #[arg(long)]
    json: bool,
}

#[derive(Args)]
struct EditArgs {
    query: String,
    #[arg(long)]
    issuer: Option<String>,
    #[arg(long)]
    account: Option<String>,
    #[arg(long)]
    folder: Option<String>,
    #[arg(long = "no-folder")]
    no_folder: bool,
    #[arg(long)]
    favorite: bool,
    #[arg(long = "no-favorite")]
    no_favorite: bool,
}

#[derive(Subcommand)]
enum FolderCmd {
    List,
    Add { name: String },
    Rm { name: String },
}

#[derive(Subcommand)]
enum SyncCmd {
    Setup {
        #[command(subcommand)]
        backend: SyncBackendCmd,
    },
    Now,
    Status,
}

#[derive(Subcommand)]
enum SyncBackendCmd {
    Webdav {
        url: String,
        #[arg(long)]
        user: String,
    },
}

#[derive(Subcommand)]
enum VaultCmd {
    /// List built-in and configured vault locations.
    List,
    /// Show the effective vault and how it was selected.
    Current,
    /// Persist a vault selection (`cli`, `macos`, or a file path).
    Use { vault: String },
}

// ---------------------------------------------------------------------------
// Config (vault selection + sync settings — never secrets)
// ---------------------------------------------------------------------------

#[derive(Debug, Default, Serialize, Deserialize)]
struct Config {
    #[serde(skip_serializing_if = "Option::is_none")]
    active_vault: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    sync: Option<SyncConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SyncConfig {
    backend: String,
    url: String,
    user: String,
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

fn main() {
    let cli = Cli::parse();
    match run(cli) {
        Ok(()) => std::process::exit(0),
        Err(e) => {
            eprintln!("error: {e:#}");
            std::process::exit(1);
        }
    }
}

fn run(cli: Cli) -> Result<()> {
    let vault_flag = cli.vault.clone();
    match cli.command {
        Command::Init => cmd_init(&vault_flag),
        Command::Add(args) => cmd_add(&vault_flag, args),
        Command::List(args) => cmd_list(&vault_flag, args),
        Command::Code(args) => cmd_code(&vault_flag, args),
        Command::Uri { query } => cmd_uri(&vault_flag, &query),
        Command::Qr { query } => cmd_qr(&vault_flag, &query),
        Command::Rm { query, yes } => cmd_rm(&vault_flag, &query, yes),
        Command::Edit(args) => cmd_edit(&vault_flag, args),
        Command::Folder { action } => cmd_folder(&vault_flag, action),
        Command::Export {
            file,
            password_stdin,
        } => cmd_export(&vault_flag, &file, password_stdin),
        Command::Import {
            file,
            merge,
            legacy,
        } => cmd_import(&vault_flag, &file, merge, legacy),
        Command::Sync { action } => cmd_sync(&vault_flag, action),
        Command::Restore { target } => cmd_restore(&vault_flag, &target),
        Command::Passwd => cmd_passwd(&vault_flag),
        Command::Vault { action } => cmd_vault(&vault_flag, action),
        Command::Unlock => cmd_unlock(&vault_flag),
        Command::Lock => cmd_lock(&vault_flag),
    }
}

// ---------------------------------------------------------------------------
// Path / config helpers
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum VaultPathSource {
    Flag,
    Environment,
    Config,
    Default,
}

impl VaultPathSource {
    fn label(self) -> &'static str {
        match self {
            Self::Flag => "--vault",
            Self::Environment => "OTPEEK_VAULT",
            Self::Config => "saved selection",
            Self::Default => "CLI default",
        }
    }
}

struct ResolvedVaultPath {
    path: PathBuf,
    source: VaultPathSource,
}

fn resolve_vault(flag: &Option<String>) -> Result<ResolvedVaultPath> {
    if let Some(p) = flag.as_deref().filter(|p| !p.is_empty()) {
        return Ok(ResolvedVaultPath {
            path: expand_vault_path(p)?,
            source: VaultPathSource::Flag,
        });
    }
    if let Ok(p) = std::env::var("OTPEEK_VAULT") {
        if !p.is_empty() {
            return Ok(ResolvedVaultPath {
                path: expand_vault_path(&p)?,
                source: VaultPathSource::Environment,
            });
        }
    }
    if let Some(p) = read_config()?.active_vault {
        return Ok(ResolvedVaultPath {
            path: expand_vault_path(&p)?,
            source: VaultPathSource::Config,
        });
    }
    Ok(ResolvedVaultPath {
        path: cli_vault_path()?,
        source: VaultPathSource::Default,
    })
}

fn resolve_vault_path(flag: &Option<String>) -> Result<PathBuf> {
    Ok(resolve_vault(flag)?.path)
}

fn cli_vault_path() -> Result<PathBuf> {
    let base = dirs::data_dir().ok_or_else(|| anyhow!("cannot determine data directory"))?;
    Ok(base.join("otpeek").join("vault.otpvault"))
}

#[cfg(target_os = "macos")]
fn macos_vault_path() -> Option<PathBuf> {
    dirs::home_dir().map(|home| {
        home.join("Library")
            .join("Group Containers")
            .join("group.com.otpeek.app")
            .join("vault.otpvault")
    })
}

#[cfg(not(target_os = "macos"))]
fn macos_vault_path() -> Option<PathBuf> {
    None
}

fn expand_vault_path(raw: &str) -> Result<PathBuf> {
    let path = if raw == "~" {
        dirs::home_dir().ok_or_else(|| anyhow!("cannot determine home directory"))?
    } else if let Some(relative) = raw.strip_prefix("~/") {
        dirs::home_dir()
            .ok_or_else(|| anyhow!("cannot determine home directory"))?
            .join(relative)
    } else {
        PathBuf::from(raw)
    };

    let absolute = if path.is_absolute() {
        path
    } else {
        std::env::current_dir()
            .context("determining current directory")?
            .join(path)
    };
    Ok(absolute.canonicalize().unwrap_or(absolute))
}

fn vault_target_path(target: &str) -> Result<PathBuf> {
    match target.to_ascii_lowercase().as_str() {
        "cli" | "default" => cli_vault_path(),
        "macos" | "app" => macos_vault_path()
            .ok_or_else(|| anyhow!("the `macos` vault alias is only available on macOS")),
        _ => expand_vault_path(target),
    }
}

fn config_path() -> Result<PathBuf> {
    let base = dirs::config_dir().ok_or_else(|| anyhow!("cannot determine config directory"))?;
    Ok(base.join("otpeek").join("config.toml"))
}

fn read_config() -> Result<Config> {
    let path = config_path()?;
    if !path.exists() {
        return Ok(Config::default());
    }
    let text =
        std::fs::read_to_string(&path).with_context(|| format!("reading {}", path.display()))?;
    let cfg: Config = toml::from_str(&text).context("parsing config.toml")?;
    Ok(cfg)
}

fn write_config(cfg: &Config) -> Result<()> {
    let path = config_path()?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let text = toml::to_string_pretty(cfg).context("serializing config")?;
    std::fs::write(&path, text).with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Time / misc helpers
// ---------------------------------------------------------------------------

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn uuid_new() -> String {
    uuid::Uuid::new_v4().to_string()
}

fn env_password() -> Option<String> {
    std::env::var("OTPEEK_VAULT_PASSWORD")
        .ok()
        .filter(|s| !s.is_empty())
}

/// Password protecting a backup container. Kept separate from the vault
/// password so headless export/import works when the two differ:
/// $OTPEEK_BACKUP_PASSWORD → $OTPEEK_VAULT_PASSWORD → prompt.
fn env_backup_password() -> Option<String> {
    std::env::var("OTPEEK_BACKUP_PASSWORD")
        .ok()
        .filter(|s| !s.is_empty())
}

fn read_stdin_line() -> Result<String> {
    let mut buf = String::new();
    std::io::stdin()
        .read_to_string(&mut buf)
        .context("reading stdin")?;
    Ok(buf.trim_end_matches(['\r', '\n']).to_string())
}

fn parse_algorithm(s: Option<&str>) -> Result<HashAlgorithm> {
    match s {
        None => Ok(HashAlgorithm::Sha1),
        Some(v) => match v.to_ascii_lowercase().as_str() {
            "sha1" => Ok(HashAlgorithm::Sha1),
            "sha256" => Ok(HashAlgorithm::Sha256),
            "sha512" => Ok(HashAlgorithm::Sha512),
            other => bail!("unknown algorithm '{other}' (expected sha1|sha256|sha512)"),
        },
    }
}

// ---------------------------------------------------------------------------
// Master password acquisition
// ---------------------------------------------------------------------------

/// Password for opening an existing vault: $OTPEEK_VAULT_PASSWORD or a prompt.
fn open_password() -> Result<String> {
    if let Some(p) = env_password() {
        return Ok(p);
    }
    rpassword::prompt_password("Master password: ").context("reading password")
}

/// A brand-new master password (init): env fallback for headless use, else
/// prompt twice and confirm.
fn new_master_password() -> Result<String> {
    if let Some(p) = env_password() {
        return Ok(p);
    }
    let pw = rpassword::prompt_password("New master password: ").context("reading password")?;
    let confirm =
        rpassword::prompt_password("Confirm master password: ").context("reading password")?;
    if pw != confirm {
        bail!("passwords do not match");
    }
    Ok(pw)
}

// ---------------------------------------------------------------------------
// Keyring (VMK) — best effort; a failure just falls back to a password prompt.
// ---------------------------------------------------------------------------

fn keyring_get_vmk(path: &Path) -> Option<Vec<u8>> {
    let user = path.to_string_lossy();
    let entry = keyring::Entry::new(KEYRING_SERVICE, &user).ok()?;
    entry.get_secret().ok()
}

fn keyring_store_vmk(path: &Path, vmk: &[u8]) {
    // Skip storing in headless/CI mode (password came from the environment) so
    // integration tests never touch the real platform keystore.
    if env_password().is_some() {
        return;
    }
    let user = path.to_string_lossy();
    if let Ok(entry) = keyring::Entry::new(KEYRING_SERVICE, &user) {
        let _ = entry.set_secret(vmk);
    }
}

fn keyring_store_vmk_explicit(path: &Path, vmk: &[u8]) -> Result<()> {
    let user = path.to_string_lossy();
    let entry = keyring::Entry::new(KEYRING_SERVICE, &user).context("opening the OS keyring")?;
    entry
        .set_secret(vmk)
        .context("storing the vault key in the OS keyring")
}

fn keyring_delete_vmk(path: &Path) -> Result<bool> {
    let user = path.to_string_lossy();
    let entry = keyring::Entry::new(KEYRING_SERVICE, &user).context("opening the OS keyring")?;
    match entry.delete_credential() {
        Ok(()) => Ok(true),
        Err(keyring::Error::NoEntry) => Ok(false),
        Err(error) => Err(error).context("removing the vault key from the OS keyring"),
    }
}

fn webdav_password(url: &str) -> Result<String> {
    if let Ok(p) = std::env::var("OTP_WEBDAV_PASSWORD") {
        if !p.is_empty() {
            return Ok(p);
        }
    }
    if let Ok(entry) = keyring::Entry::new(KEYRING_WEBDAV, url) {
        if let Ok(p) = entry.get_password() {
            return Ok(p);
        }
    }
    rpassword::prompt_password("WebDAV password: ").context("reading WebDAV password")
}

// ---------------------------------------------------------------------------
// Vault session
// ---------------------------------------------------------------------------

struct Session {
    vault: Vault,
    path: PathBuf,
}

impl Session {
    fn save(&mut self) -> Result<()> {
        let bytes = self.vault.to_bytes(now_ms())?;
        otpeek_vault::write_vault_file(&self.path, &bytes)?;
        Ok(())
    }
}

fn open_session(flag: &Option<String>) -> Result<Session> {
    let path = resolve_vault_path(flag)?;
    if !path.exists() {
        let macos_hint = macos_vault_path()
            .filter(|candidate| candidate.exists() && candidate != &path)
            .map(|candidate| {
                format!(
                    "; macOS app vault found at {} (select it with `otpeek vault use macos`)",
                    candidate.display()
                )
            })
            .unwrap_or_default();
        bail!(
            "vault not found at {} (run `otpeek init`){macos_hint}",
            path.display()
        );
    }
    let data = otpeek_vault::read_vault_file(&path)?;

    // Prefer the keyring VMK (no password needed); fall back to a password.
    if let Some(vmk) = keyring_get_vmk(&path) {
        if let Ok(vault) = Vault::open_with_key(&data, &vmk) {
            return Ok(Session { vault, path });
        }
    }
    let pw = open_password()?;
    let vault = Vault::open_with_password(&data, &pw)?;
    keyring_store_vmk(&path, &vault.vmk());
    Ok(Session { vault, path })
}

// ---------------------------------------------------------------------------
// Payload query helpers
// ---------------------------------------------------------------------------

fn live_accounts_sorted(payload: &VaultPayload) -> Vec<OtpAccount> {
    let mut accounts: Vec<OtpAccount> = payload
        .accounts
        .iter()
        .filter(|a| a.deleted_at.is_none())
        .cloned()
        .collect();
    accounts.sort_by(|a, b| {
        a.sort_order.cmp(&b.sort_order).then_with(|| {
            a.issuer
                .as_deref()
                .unwrap_or("")
                .to_lowercase()
                .cmp(&b.issuer.as_deref().unwrap_or("").to_lowercase())
        })
    });
    accounts
}

fn live_folders_sorted(payload: &VaultPayload) -> Vec<OtpFolder> {
    let mut folders: Vec<OtpFolder> = payload
        .folders
        .iter()
        .filter(|f| f.deleted_at.is_none())
        .cloned()
        .collect();
    folders.sort_by(|a, b| {
        a.sort_order
            .cmp(&b.sort_order)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    folders
}

fn find_folder_id_by_name(payload: &VaultPayload, name: &str) -> Option<String> {
    payload
        .folders
        .iter()
        .find(|f| f.deleted_at.is_none() && f.name.eq_ignore_ascii_case(name))
        .map(|f| f.id.clone())
}

fn next_sort_order(items: impl Iterator<Item = i32>) -> i32 {
    items.max().map(|m| m + 1).unwrap_or(0)
}

/// Resolve a query (1-based index or fuzzy issuer/account substring) to an
/// index into `accounts`. On ambiguity, print matches and exit(2).
fn resolve_query(accounts: &[OtpAccount], query: &str) -> Result<usize> {
    if let Ok(n) = query.parse::<usize>() {
        if n >= 1 && n <= accounts.len() {
            return Ok(n - 1);
        }
    }
    let q = query.to_lowercase();
    let matches: Vec<usize> = accounts
        .iter()
        .enumerate()
        .filter(|(_, a)| {
            a.issuer
                .as_deref()
                .unwrap_or("")
                .to_lowercase()
                .contains(&q)
                || a.account_name.to_lowercase().contains(&q)
        })
        .map(|(i, _)| i)
        .collect();
    match matches.len() {
        0 => bail!("no account matches '{query}'"),
        1 => Ok(matches[0]),
        _ => {
            eprintln!("ambiguous query '{query}', {} matches:", matches.len());
            for &i in &matches {
                let a = &accounts[i];
                eprintln!(
                    "  {}  {} ({})",
                    i + 1,
                    a.issuer.as_deref().unwrap_or("-"),
                    a.account_name
                );
            }
            std::process::exit(2);
        }
    }
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

fn cmd_vault(flag: &Option<String>, action: VaultCmd) -> Result<()> {
    match action {
        VaultCmd::List => {
            let resolved = resolve_vault(flag)?;
            let configured = read_config()?.active_vault;
            let mut candidates: Vec<(String, PathBuf)> = vec![("cli".into(), cli_vault_path()?)];
            if let Some(path) = macos_vault_path() {
                candidates.push(("macos".into(), path));
            }
            if let Some(path) = configured {
                let path = expand_vault_path(&path)?;
                if !candidates.iter().any(|(_, candidate)| candidate == &path) {
                    candidates.push(("configured".into(), path));
                }
            }
            if !candidates
                .iter()
                .any(|(_, candidate)| candidate == &resolved.path)
            {
                candidates.push(("override".into(), resolved.path.clone()));
            }

            println!("Effective source: {}", resolved.source.label());
            println!("  Name        State      Path");
            for (name, path) in candidates {
                let current = if path == resolved.path { "*" } else { " " };
                let state = if path.exists() { "exists" } else { "missing" };
                println!("{current} {name:<10}  {state:<9}  {}", path.display());
            }
            Ok(())
        }
        VaultCmd::Current => {
            let resolved = resolve_vault(flag)?;
            println!("Path:   {}", resolved.path.display());
            println!("Source: {}", resolved.source.label());
            println!(
                "State:  {}",
                if resolved.path.exists() {
                    "exists"
                } else {
                    "missing"
                }
            );
            Ok(())
        }
        VaultCmd::Use { vault } => {
            let path = vault_target_path(&vault)?;
            let mut cfg = read_config()?;
            cfg.active_vault = Some(path.to_string_lossy().into_owned());
            write_config(&cfg)?;
            println!("Selected vault: {}", path.display());
            if !path.exists() {
                println!("Vault does not exist yet; run `otpeek init` to create it.");
            }
            if std::env::var("OTPEEK_VAULT").is_ok_and(|value| !value.is_empty()) {
                println!("Note: OTPEEK_VAULT currently overrides the saved selection.");
            }
            if flag.as_deref().is_some_and(|value| !value.is_empty()) {
                println!("Note: --vault overrides the saved selection for this command.");
            }
            Ok(())
        }
    }
}

fn cmd_unlock(flag: &Option<String>) -> Result<()> {
    let path = resolve_vault_path(flag)?;
    if !path.exists() {
        bail!("vault not found at {}", path.display());
    }
    let data = otpeek_vault::read_vault_file(&path)?;
    if let Some(vmk) = keyring_get_vmk(&path) {
        if Vault::open_with_key(&data, &vmk).is_ok() {
            println!("Vault is already unlocked: {}", path.display());
            return Ok(());
        }
    }

    let password = open_password()?;
    let vault = Vault::open_with_password(&data, &password)?;
    keyring_store_vmk_explicit(&path, &vault.vmk())?;
    println!("Unlocked vault: {}", path.display());
    Ok(())
}

fn cmd_lock(flag: &Option<String>) -> Result<()> {
    let path = resolve_vault_path(flag)?;
    if keyring_delete_vmk(&path)? {
        println!("Locked vault: {}", path.display());
    } else {
        println!("Vault was already locked: {}", path.display());
    }
    Ok(())
}

fn cmd_init(flag: &Option<String>) -> Result<()> {
    let path = resolve_vault_path(flag)?;
    if path.exists() {
        bail!("vault already exists at {}", path.display());
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let pw = new_master_password()?;
    let mut vault = Vault::create(&pw)?;
    let bytes = vault.to_bytes(now_ms())?;
    otpeek_vault::write_vault_file(&path, &bytes)?;
    keyring_store_vmk(&path, &vault.vmk());
    println!("Created vault at {}", path.display());
    Ok(())
}

fn cmd_add(flag: &Option<String>, args: AddArgs) -> Result<()> {
    let mut session = open_session(flag)?;
    let now = now_ms();

    if let Some(uri) = args.uri {
        let accounts = if uri.starts_with("otpauth-migration://") {
            otpeek_core::parse_migration_uri(&uri, now)?
        } else {
            vec![otpeek_core::parse_otpauth_uri(&uri, now)?]
        };
        let n = accounts.len();
        for a in accounts {
            session.vault.payload_mut().accounts.push(a);
        }
        session.save()?;
        println!("Added {n} account(s)");
        return Ok(());
    }

    let account_name = args
        .account
        .ok_or_else(|| anyhow!("--account is required (or provide an otpauth:// URI)"))?;
    let secret_raw = match args.secret.as_deref() {
        Some("-") => read_stdin_line()?,
        Some(s) => s.to_string(),
        None => bail!("--secret is required for manual add (use `-` to read from stdin)"),
    };
    let secret = otpeek_core::normalize_secret(&secret_raw)?;
    let algorithm = parse_algorithm(args.algorithm.as_deref())?;
    let sort_order = next_sort_order(
        session
            .vault
            .payload()
            .accounts
            .iter()
            .map(|a| a.sort_order),
    );

    let account = OtpAccount {
        id: uuid_new(),
        otp_type: if args.hotp {
            OtpType::Hotp
        } else {
            OtpType::Totp
        },
        secret,
        issuer: args.issuer,
        account_name,
        algorithm,
        digits: args.digits.unwrap_or(6),
        period: args.period.unwrap_or(30),
        counter: 0,
        folder_id: None,
        is_favorite: false,
        sort_order,
        icon: None,
        color: None,
        created_at: now,
        updated_at: now,
        deleted_at: None,
    };
    session.vault.payload_mut().accounts.push(account);
    session.save()?;
    println!("Added account");
    Ok(())
}

fn cmd_list(flag: &Option<String>, args: ListArgs) -> Result<()> {
    let session = open_session(flag)?;
    let payload = session.vault.payload();
    let mut accounts = live_accounts_sorted(payload);

    if let Some(folder_name) = &args.folder {
        let fid = find_folder_id_by_name(payload, folder_name)
            .ok_or_else(|| anyhow!("no folder named '{folder_name}'"))?;
        accounts.retain(|a| a.folder_id.as_deref() == Some(fid.as_str()));
    }

    if args.json {
        println!("{}", serde_json::to_string_pretty(&accounts)?);
        return Ok(());
    }

    let folder_names: std::collections::HashMap<String, String> = payload
        .folders
        .iter()
        .map(|f| (f.id.clone(), f.name.clone()))
        .collect();

    let mut table = comfy_table::Table::new();
    table.set_header(vec!["#", "Issuer", "Account", "Folder", "Fav"]);
    for (i, a) in accounts.iter().enumerate() {
        let folder = a
            .folder_id
            .as_ref()
            .and_then(|id| folder_names.get(id))
            .cloned()
            .unwrap_or_default();
        table.add_row(vec![
            (i + 1).to_string(),
            a.issuer.clone().unwrap_or_default(),
            a.account_name.clone(),
            folder,
            if a.is_favorite {
                "*".to_string()
            } else {
                String::new()
            },
        ]);
    }
    println!("{table}");
    Ok(())
}

fn cmd_code(flag: &Option<String>, args: CodeArgs) -> Result<()> {
    let session = open_session(flag)?;
    let accounts = live_accounts_sorted(session.vault.payload());
    let idx = resolve_query(&accounts, &args.query)?;
    let account = &accounts[idx];

    if args.watch {
        return watch_code(account);
    }

    let code = otpeek_core::generate_code(account, now_ms())?;
    if args.copy {
        copy_to_clipboard(&code.code)?;
    }
    if args.json {
        println!("{}", serde_json::to_string(&code)?);
    } else {
        println!("{}", code.code);
    }
    Ok(())
}

fn watch_code(account: &OtpAccount) -> Result<()> {
    let mut stdout = std::io::stdout();
    loop {
        let now = now_ms();
        let code = otpeek_core::generate_code(account, now)?;
        let remaining = ((code.valid_until - now) / 1000).max(0);
        write!(stdout, "\r{}  ({remaining:>2}s left) ", code.code)?;
        stdout.flush()?;
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
}

fn cmd_uri(flag: &Option<String>, query: &str) -> Result<()> {
    let session = open_session(flag)?;
    let accounts = live_accounts_sorted(session.vault.payload());
    let idx = resolve_query(&accounts, query)?;
    println!("{}", otpeek_core::to_otpauth_uri(&accounts[idx]));
    Ok(())
}

fn cmd_qr(flag: &Option<String>, query: &str) -> Result<()> {
    use qrcode::render::unicode;
    let session = open_session(flag)?;
    let accounts = live_accounts_sorted(session.vault.payload());
    let idx = resolve_query(&accounts, query)?;
    let uri = otpeek_core::to_otpauth_uri(&accounts[idx]);
    let code = qrcode::QrCode::new(uri.as_bytes()).context("building QR code")?;
    let rendered = code.render::<unicode::Dense1x2>().quiet_zone(true).build();
    println!("{rendered}");
    Ok(())
}

fn cmd_rm(flag: &Option<String>, query: &str, yes: bool) -> Result<()> {
    let mut session = open_session(flag)?;
    let (id, label) = {
        let accounts = live_accounts_sorted(session.vault.payload());
        let idx = resolve_query(&accounts, query)?;
        let a = &accounts[idx];
        (
            a.id.clone(),
            format!(
                "{} ({})",
                a.issuer.as_deref().unwrap_or("-"),
                a.account_name
            ),
        )
    };

    if !yes {
        print!("Delete {label}? [y/N] ");
        std::io::stdout().flush()?;
        let mut line = String::new();
        std::io::stdin().read_line(&mut line)?;
        if !matches!(line.trim().to_lowercase().as_str(), "y" | "yes") {
            println!("Aborted");
            return Ok(());
        }
    }

    let now = now_ms();
    if let Some(a) = session
        .vault
        .payload_mut()
        .accounts
        .iter_mut()
        .find(|a| a.id == id && a.deleted_at.is_none())
    {
        a.deleted_at = Some(now);
        a.updated_at = now;
    }
    session.save()?;
    println!("Deleted {label}");
    Ok(())
}

fn cmd_edit(flag: &Option<String>, args: EditArgs) -> Result<()> {
    if args.favorite && args.no_favorite {
        bail!("--favorite and --no-favorite are mutually exclusive");
    }
    if args.folder.is_some() && args.no_folder {
        bail!("--folder and --no-folder are mutually exclusive");
    }

    let mut session = open_session(flag)?;

    // Resolve the target id and the new folder id (if any) before mutating.
    let id = {
        let accounts = live_accounts_sorted(session.vault.payload());
        let idx = resolve_query(&accounts, &args.query)?;
        accounts[idx].id.clone()
    };
    let new_folder_id = match (&args.folder, args.no_folder) {
        (Some(name), _) => Some(
            find_folder_id_by_name(session.vault.payload(), name)
                .ok_or_else(|| anyhow!("no folder named '{name}'"))?,
        ),
        _ => None,
    };

    let now = now_ms();
    let account = session
        .vault
        .payload_mut()
        .accounts
        .iter_mut()
        .find(|a| a.id == id && a.deleted_at.is_none())
        .ok_or_else(|| anyhow!("account not found"))?;

    if let Some(issuer) = args.issuer {
        account.issuer = Some(issuer);
    }
    if let Some(name) = args.account {
        account.account_name = name;
    }
    if args.no_folder {
        account.folder_id = None;
    } else if let Some(fid) = new_folder_id {
        account.folder_id = Some(fid);
    }
    if args.favorite {
        account.is_favorite = true;
    }
    if args.no_favorite {
        account.is_favorite = false;
    }
    account.updated_at = now;

    session.save()?;
    println!("Updated account");
    Ok(())
}

fn cmd_folder(flag: &Option<String>, action: FolderCmd) -> Result<()> {
    match action {
        FolderCmd::List => {
            let session = open_session(flag)?;
            let folders = live_folders_sorted(session.vault.payload());
            if folders.is_empty() {
                println!("(no folders)");
            } else {
                for f in folders {
                    println!("{}", f.name);
                }
            }
            Ok(())
        }
        FolderCmd::Add { name } => {
            let mut session = open_session(flag)?;
            if find_folder_id_by_name(session.vault.payload(), &name).is_some() {
                bail!("folder '{name}' already exists");
            }
            let now = now_ms();
            let sort_order =
                next_sort_order(session.vault.payload().folders.iter().map(|f| f.sort_order));
            let folder = OtpFolder {
                id: uuid_new(),
                name: name.clone(),
                icon: None,
                color: None,
                sort_order,
                created_at: now,
                updated_at: now,
                deleted_at: None,
            };
            session.vault.payload_mut().folders.push(folder);
            session.save()?;
            println!("Added folder '{name}'");
            Ok(())
        }
        FolderCmd::Rm { name } => {
            let mut session = open_session(flag)?;
            let id = find_folder_id_by_name(session.vault.payload(), &name)
                .ok_or_else(|| anyhow!("no folder named '{name}'"))?;
            let now = now_ms();
            let payload = session.vault.payload_mut();
            if let Some(f) = payload
                .folders
                .iter_mut()
                .find(|f| f.id == id && f.deleted_at.is_none())
            {
                f.deleted_at = Some(now);
                f.updated_at = now;
            }
            for a in payload.accounts.iter_mut() {
                if a.folder_id.as_deref() == Some(id.as_str()) {
                    a.folder_id = None;
                    a.updated_at = now;
                }
            }
            session.save()?;
            println!("Removed folder '{name}'");
            Ok(())
        }
    }
}

fn cmd_export(flag: &Option<String>, file: &str, password_stdin: bool) -> Result<()> {
    let session = open_session(flag)?;
    let pw = if password_stdin {
        read_stdin_line()?
    } else if let Some(pw) = env_backup_password() {
        pw
    } else {
        let pw = rpassword::prompt_password("Backup password: ")?;
        let confirm = rpassword::prompt_password("Confirm backup password: ")?;
        if pw != confirm {
            bail!("passwords do not match");
        }
        pw
    };

    let payload = session.vault.payload().clone();
    let mut container = Vault::create(&pw)?;
    *container.payload_mut() = payload;
    let bytes = container.to_bytes(now_ms())?;
    std::fs::write(file, bytes).with_context(|| format!("writing {file}"))?;
    println!("Exported backup to {file}");
    Ok(())
}

fn cmd_import(flag: &Option<String>, file: &str, merge: bool, legacy: bool) -> Result<()> {
    let mut session = open_session(flag)?;
    let data = std::fs::read(file).with_context(|| format!("reading {file}"))?;
    let pw = match env_backup_password() {
        Some(p) => p,
        None => open_password()?,
    };

    let payload = if legacy {
        otpeek_vault::import_backup_v1(&data, &pw, now_ms())?
    } else {
        Vault::open_with_password(&data, &pw)?.payload().clone()
    };

    let count = apply_import(&mut session, payload, merge, now_ms());
    session.save()?;
    println!("Imported {count} entities");
    Ok(())
}

/// merge=false replaces the payload; merge=true adds unknown ids and
/// resurrects locally-tombstoned entities that are live in the backup
/// (updated_at is bumped so a later sync doesn't re-delete them via LWW).
fn apply_import(session: &mut Session, payload: VaultPayload, merge: bool, now_ms: i64) -> u32 {
    if !merge {
        let total = payload.accounts.len() + payload.folders.len();
        *session.vault.payload_mut() = payload;
        return total as u32;
    }
    let mut imported = 0u32;
    let local = session.vault.payload_mut();
    for f in payload.folders {
        if f.deleted_at.is_some() {
            continue;
        }
        match local.folders.iter().position(|e| e.id == f.id) {
            Some(i) => {
                if local.folders[i].deleted_at.is_some() {
                    let mut restored = f;
                    restored.updated_at = now_ms;
                    local.folders[i] = restored;
                    imported += 1;
                }
            }
            None => {
                local.folders.push(f);
                imported += 1;
            }
        }
    }
    for a in payload.accounts {
        if a.deleted_at.is_some() {
            continue;
        }
        match local.accounts.iter().position(|e| e.id == a.id) {
            Some(i) => {
                if local.accounts[i].deleted_at.is_some() {
                    let mut restored = a;
                    restored.updated_at = now_ms;
                    local.accounts[i] = restored;
                    imported += 1;
                }
            }
            None => {
                local.accounts.push(a);
                imported += 1;
            }
        }
    }
    imported
}

fn cmd_sync(flag: &Option<String>, action: SyncCmd) -> Result<()> {
    match action {
        SyncCmd::Setup { backend } => match backend {
            SyncBackendCmd::Webdav { url, user } => {
                let pw = rpassword::prompt_password("WebDAV password: ")?;
                if let Ok(entry) = keyring::Entry::new(KEYRING_WEBDAV, &url) {
                    entry
                        .set_password(&pw)
                        .context("storing WebDAV password in keyring")?;
                }
                let mut cfg = read_config()?;
                cfg.sync = Some(SyncConfig {
                    backend: "webdav".to_string(),
                    url: url.clone(),
                    user,
                });
                write_config(&cfg)?;
                println!("Configured WebDAV sync -> {url}");
                Ok(())
            }
        },
        SyncCmd::Now => {
            let cfg = read_config()?;
            let sc = cfg
                .sync
                .ok_or_else(|| anyhow!("sync not configured (run `otpeek sync setup ...`)"))?;
            let backend = build_backend(&sc)?;
            let mut session = open_session(flag)?;
            let outcome =
                otpeek_sync::SyncEngine::sync(&mut session.vault, backend.as_ref(), now_ms())?;
            session.save()?;
            println!(
                "Sync complete: pushed={} pulled={} merged_changes={}",
                outcome.pushed, outcome.pulled, outcome.merged_changes
            );
            Ok(())
        }
        SyncCmd::Status => {
            let cfg = read_config()?;
            match cfg.sync {
                Some(sc) => {
                    println!("Sync backend: {}", sc.backend);
                    println!("URL:          {}", sc.url);
                    println!("User:         {}", sc.user);
                }
                None => println!("Sync not configured"),
            }
            Ok(())
        }
    }
}

fn build_backend(sc: &SyncConfig) -> Result<Box<dyn otpeek_sync::SyncBackend>> {
    match sc.backend.as_str() {
        "webdav" => {
            let pw = webdav_password(&sc.url)?;
            Ok(Box::new(otpeek_sync::webdav::WebDavBackend::new(
                sc.url.clone(),
                sc.user.clone(),
                pw,
            )))
        }
        other => bail!("unknown sync backend '{other}'"),
    }
}

fn cmd_restore(flag: &Option<String>, target: &str) -> Result<()> {
    let path = resolve_vault_path(flag)?;

    let blob = if target.starts_with("http://") || target.starts_with("https://") {
        let cfg = read_config()?;
        let user = cfg
            .sync
            .as_ref()
            .map(|s| s.user.clone())
            .or_else(|| std::env::var("OTP_WEBDAV_USER").ok())
            .ok_or_else(|| {
                anyhow!("WebDAV user unknown; run `otpeek sync setup` or set OTP_WEBDAV_USER")
            })?;
        let pw = webdav_password(target)?;
        let backend = otpeek_sync::webdav::WebDavBackend::new(target.to_string(), user, pw);
        let remote = otpeek_sync::SyncBackend::fetch(&backend)?
            .ok_or_else(|| anyhow!("no remote vault found"))?;
        remote.data
    } else {
        std::fs::read(target).with_context(|| format!("reading {target}"))?
    };

    let pw = open_password()?;
    let mut vault = Vault::open_with_password(&blob, &pw)?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let bytes = vault.to_bytes(now_ms())?;
    otpeek_vault::write_vault_file(&path, &bytes)?;
    keyring_store_vmk(&path, &vault.vmk());
    println!("Restored vault to {}", path.display());
    Ok(())
}

fn cmd_passwd(flag: &Option<String>) -> Result<()> {
    let mut session = open_session(flag)?;
    let old = if let Some(p) = env_password() {
        p
    } else {
        rpassword::prompt_password("Current master password: ")?
    };
    let new = if let Ok(p) = std::env::var("OTPEEK_NEW_PASSWORD") {
        if p.is_empty() {
            bail!("OTPEEK_NEW_PASSWORD is empty");
        }
        p
    } else {
        let pw = rpassword::prompt_password("New master password: ")?;
        let confirm = rpassword::prompt_password("Confirm new master password: ")?;
        if pw != confirm {
            bail!("passwords do not match");
        }
        pw
    };

    session.vault.change_password(&old, &new)?;
    session.save()?;
    println!("Master password changed");
    Ok(())
}

fn copy_to_clipboard(text: &str) -> Result<()> {
    let mut clipboard = arboard::Clipboard::new().context("opening clipboard")?;
    clipboard
        .set_text(text.to_string())
        .context("writing clipboard")?;
    Ok(())
}
