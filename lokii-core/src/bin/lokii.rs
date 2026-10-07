//! `lokii` — command-line interface for the Lokii file index.
//!
//! This binary reuses the exact same in-memory index engine that backs the
//! macOS app: the same `AppConfig` (`~/.config/lokii/config.toml`), the same
//! persistent cache (`~/.config/lokii/index.cache`), the same parallel
//! scanner, exclusion filter and query dispatcher. It exposes them as a
//! script-friendly CLI: feed it a query, get matching paths on stdout.
//!
//! Typical usage:
//!
//! ```bash
//! lokii report                # substring / fuzzy auto-detect
//! lokii '*.rs'                # wildcard
//! lokii 'regex:^main.*\.rs$'  # regex
//! lokii -d ~/Projects -m fuzzy cfg
//! vim "$(lokii -l 1 'todo.md')"
//! lokii --rebuild             # (re)build the shared index cache
//! ```
//!
//! The index cache is shared with the GUI app, so when the app has been run
//! the CLI answers instantly without re-scanning the filesystem.

use std::io::{self, IsTerminal, Write};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use lokii_core::cache;
use lokii_core::config::{self, AppConfig};
use lokii_core::filter::CompiledFilter;
use lokii_core::indexer::IndexStore;
use lokii_core::scanner;
use lokii_core::search::{self, SearchMode};

/// Version reported by `--version`, sourced from `Cargo.toml`.
const VERSION: &str = env!("CARGO_PKG_VERSION");

const HELP: &str = "\
lokii — ultra-fast command-line file search (Lokii core engine)

USAGE:
    lokii [OPTIONS] [QUERY...]

    QUERY tokens are joined with spaces and matched against file names.
    With no flag the mode is auto-detected: plain text does substring search
    (falling back to fuzzy when nothing matches), '*' / '?' selects wildcard,
    and a 'regex:' prefix selects the regular expression engine.

OPTIONS:
    -d, --dir <PATH>       Index root to scan (repeatable). Overrides the
                           configured index_paths and answers from a fresh
                           scan instead of the shared cache.
    -l, --limit <N>        Maximum number of results. Defaults to the
                           configured max_results.
    -a, --all              Print every match (ignore the limit).
    -m, --mode <MODE>      Force a search mode: auto | substring |
                           wildcard | regex | fuzzy.
    -e, --ext <EXT>        Keep only results with this extension
                           (repeatable, leading dot optional).
    -f, --files-only       Exclude directories from the results.
    -D, --dirs-only        Keep only directories.
    -j, --json             Emit one JSON object per result (JSON Lines).
    -0, --print0           Separate results with NUL (for `xargs -0`).
    -i, --rebuild          Rebuild the shared index cache, then search.
        --no-cache         Scan fresh; do not read or write the cache.
        --no-scan          Never scan; use the cache only (error if absent).
        --include-hidden   Include hidden files/directories in the scan.
    -q, --quiet            Suppress progress and diagnostics on stderr.
        --stats            Print index/result statistics to stderr.
    -h, --help             Show this help and exit.
    -V, --version          Show version and exit.

EXIT STATUS:
    0  success (even when there are no matches)
    1  runtime error (e.g. unusable cache)
    2  usage error
";

/// Search mode override parsed from `--mode`.
fn parse_mode(raw: &str) -> Result<SearchMode, String> {
    match raw.to_ascii_lowercase().as_str() {
        "auto" | "a" => Ok(SearchMode::Auto),
        "substring" | "sub" | "s" => Ok(SearchMode::Substring),
        "wildcard" | "glob" | "w" => Ok(SearchMode::Wildcard),
        "regex" | "re" | "r" => Ok(SearchMode::Regex),
        "fuzzy" | "fz" | "f" => Ok(SearchMode::Fuzzy),
        other => Err(format!(
            "unknown mode '{other}' (expected auto/substring/wildcard/regex/fuzzy)"
        )),
    }
}

/// Parsed command-line options.
struct Options {
    query: String,
    dirs: Vec<String>,
    limit: Option<usize>,
    all: bool,
    mode: SearchMode,
    ext: Vec<String>,
    files_only: bool,
    dirs_only: bool,
    json: bool,
    print0: bool,
    rebuild: bool,
    no_cache: bool,
    no_scan: bool,
    include_hidden: bool,
    quiet: bool,
    stats: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            query: String::new(),
            dirs: Vec::new(),
            limit: None,
            all: false,
            mode: SearchMode::Auto,
            ext: Vec::new(),
            files_only: false,
            dirs_only: false,
            json: false,
            print0: false,
            rebuild: false,
            no_cache: false,
            no_scan: false,
            include_hidden: false,
            quiet: false,
            stats: false,
        }
    }
}

/// Top-level action resolved from the command line.
enum Action {
    Help,
    Version,
    Run(Options),
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    match parse_args(&argv) {
        Ok(Action::Help) => {
            print!("{HELP}");
            ExitCode::SUCCESS
        }
        Ok(Action::Version) => {
            println!("lokii {VERSION}");
            ExitCode::SUCCESS
        }
        Ok(Action::Run(opts)) => run(opts),
        Err(msg) => {
            eprintln!("lokii: {msg}");
            eprintln!("Try 'lokii --help' for usage.");
            ExitCode::from(2)
        }
    }
}

/// Consume the value for an option, either from an inline `--opt=value`
/// or from the following argument. Advances `i` past a consumed argument.
fn next_value(
    argv: &[String],
    i: &mut usize,
    inline: &Option<String>,
    name: &str,
) -> Result<String, String> {
    if let Some(v) = inline {
        return Ok(v.clone());
    }
    *i += 1;
    argv.get(*i)
        .cloned()
        .ok_or_else(|| format!("option '{name}' requires a value"))
}

fn parse_args(argv: &[String]) -> Result<Action, String> {
    let mut opts = Options::default();
    let mut query_parts: Vec<String> = Vec::new();
    let mut no_more_opts = false;

    let mut i = 0;
    while i < argv.len() {
        let arg = argv[i].clone();

        // Once `--` is seen, or for non-flag tokens, everything is query text.
        if no_more_opts || !arg.starts_with('-') || arg == "-" {
            query_parts.push(arg);
            i += 1;
            continue;
        }
        if arg == "--" {
            no_more_opts = true;
            i += 1;
            continue;
        }

        // Split `--opt=value` into name + inline value.
        let (name, inline) = match arg.split_once('=') {
            Some((n, v)) => (n.to_string(), Some(v.to_string())),
            None => (arg.clone(), None),
        };

        match name.as_str() {
            "-h" | "--help" => return Ok(Action::Help),
            "-V" | "--version" => return Ok(Action::Version),
            "-d" | "--dir" => opts.dirs.push(next_value(argv, &mut i, &inline, &name)?),
            "-l" | "--limit" => {
                let v = next_value(argv, &mut i, &inline, &name)?;
                let n: usize = v.parse().map_err(|_| {
                    format!("invalid --limit value '{v}' (expected a positive integer)")
                })?;
                if n == 0 {
                    return Err("--limit must be greater than 0".to_string());
                }
                opts.limit = Some(n);
            }
            "-a" | "--all" => opts.all = true,
            "-m" | "--mode" => {
                let v = next_value(argv, &mut i, &inline, &name)?;
                opts.mode = parse_mode(&v)?;
            }
            "-e" | "--ext" => opts.ext.push(next_value(argv, &mut i, &inline, &name)?),
            "-f" | "--files-only" => opts.files_only = true,
            "-D" | "--dirs-only" => opts.dirs_only = true,
            "-j" | "--json" => opts.json = true,
            "-0" | "--print0" => opts.print0 = true,
            "-i" | "--rebuild" | "--index" => opts.rebuild = true,
            "--no-cache" => opts.no_cache = true,
            "--no-scan" => opts.no_scan = true,
            "--include-hidden" => opts.include_hidden = true,
            "-q" | "--quiet" => opts.quiet = true,
            "--stats" => opts.stats = true,
            other => return Err(format!("unknown option '{other}'")),
        }
        i += 1;
    }

    // ── Validation ──────────────────────────────────────────────────────
    if opts.no_cache && opts.no_scan {
        return Err("--no-cache and --no-scan are mutually exclusive".to_string());
    }
    if opts.files_only && opts.dirs_only {
        return Err("--files-only and --dirs-only are mutually exclusive".to_string());
    }

    opts.query = query_parts.join(" ");
    if opts.query.is_empty() && !opts.rebuild {
        return Err("missing search query (see 'lokii --help')".to_string());
    }

    Ok(Action::Run(opts))
}

/// Run a full scan of the configured roots, reporting progress to stderr
/// when stderr is an interactive terminal.
fn run_scan(config: &AppConfig, quiet: bool) -> Vec<lokii_core::indexer::FileEntry> {
    let progress = Arc::new(AtomicUsize::new(0));
    let filter = Arc::new(CompiledFilter::from_config(config));
    let paths = config.resolve_paths();

    let show_progress = !quiet && io::stderr().is_terminal();
    let done = Arc::new(AtomicBool::new(false));

    let handle = if show_progress {
        let p = Arc::clone(&progress);
        let d = Arc::clone(&done);
        Some(std::thread::spawn(move || {
            while !d.load(Ordering::Relaxed) {
                eprint!("\rIndexing... {} entries", p.load(Ordering::Relaxed));
                let _ = io::stderr().flush();
                std::thread::sleep(Duration::from_millis(150));
            }
        }))
    } else {
        None
    };

    let entries = scanner::scan_directories(&paths, filter, config.index.include_hidden, progress);

    done.store(true, Ordering::Relaxed);
    if let Some(h) = handle {
        let _ = h.join();
        eprintln!("\rIndexing... {} entries (done)   ", entries.len());
    }

    entries
}

/// Resolve the index store: from the shared cache when possible, otherwise
/// from a fresh scan. Honors the rebuild / no-cache / no-scan flags.
fn load_index(config: &AppConfig, opts: &Options) -> Result<(IndexStore, &'static str), String> {
    let store = IndexStore::new();
    let dirs_override = !opts.dirs.is_empty();
    let cache_file = AppConfig::config_dir().join("index.cache");

    if opts.rebuild {
        let entries = run_scan(config, opts.quiet);
        // Only persist into the shared cache when the roots are the default
        // ones — never clobber the app's cache with a partial --dir index.
        if !dirs_override {
            let _ = cache::save_cache(&entries, &cache_file);
        }
        store.replace(entries);
        return Ok((store, "scan"));
    }

    if opts.no_cache || (dirs_override && !opts.no_scan) {
        store.replace(run_scan(config, opts.quiet));
        return Ok((store, "scan"));
    }

    // Cache-first.
    match cache::load_cache(&cache_file) {
        Ok(mut entries) => {
            if dirs_override {
                let filter = CompiledFilter::from_config(config);
                entries.retain(|e| !filter.is_excluded(std::path::Path::new(&e.path)));
            }
            store.replace(entries);
            Ok((store, "cache"))
        }
        Err(e) => {
            if opts.no_scan {
                return Err(format!(
                    "no usable index cache ({e}); run 'lokii --rebuild' first or drop --no-scan"
                ));
            }
            let entries = run_scan(config, opts.quiet);
            if !dirs_override {
                let _ = cache::save_cache(&entries, &cache_file);
            }
            store.replace(entries);
            Ok((store, "scan"))
        }
    }
}


/// Expand `~` and turn a user-supplied `--dir` into a clean absolute path.
///
/// The scanner's include-root filter compares absolute filesystem paths with
/// the configured roots, so a relative root like `.` would never match. This
/// canonicalizes when the directory exists and otherwise falls back to a
/// lexical absolute path.
fn normalize_dir(raw: &str) -> String {
    let expanded = if raw == "~" {
        dirs::home_dir().unwrap_or_else(|| std::path::PathBuf::from("/"))
    } else if let Some(rest) = raw.strip_prefix("~/") {
        dirs::home_dir()
            .unwrap_or_else(|| std::path::PathBuf::from("/"))
            .join(rest)
    } else {
        std::path::PathBuf::from(raw)
    };

    let abs = if expanded.is_absolute() {
        expanded
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| std::path::PathBuf::from("."))
            .join(expanded)
    };

    abs.canonicalize()
        .unwrap_or(abs)
        .to_string_lossy()
        .into_owned()
}

fn run(opts: Options) -> ExitCode {
    // Effective config: start from disk, then apply CLI overrides.
    let (mut cfg, cfg_error) = config::load_or_create_config();
    if let Some(err) = &cfg_error {
        if !opts.quiet {
            eprintln!("lokii: {err}");
        }
    }
    if !opts.dirs.is_empty() {
        cfg.index.index_paths = opts.dirs.iter().map(|d| normalize_dir(d)).collect();
    }
    if opts.include_hidden {
        cfg.index.include_hidden = true;
    }

    // ── Build / load the index ──────────────────────────────────────────
    let (store, source) = match load_index(&cfg, &opts) {
        Ok(v) => v,
        Err(msg) => {
            eprintln!("lokii: {msg}");
            return ExitCode::from(1);
        }
    };

    // `--rebuild` with no query just refreshes the index and exits.
    if opts.query.is_empty() {
        if opts.stats && !opts.quiet {
            eprintln!("# index: {} entries (source: {source})", store.len());
        }
        return ExitCode::SUCCESS;
    }

    // ── Search ──────────────────────────────────────────────────────────
    // Search unbounded, then truncate, so post-filters (ext/files/dirs)
    // never starve the result set.
    let search_cap = store.len().max(1);
    let (mut results, error) = search::dispatch(&store, &opts.query, opts.mode, search_cap);
    if let Some(err) = error {
        eprintln!("lokii: {err}");
        return ExitCode::from(1);
    }

    // ── Post-filters ────────────────────────────────────────────────────
    if opts.files_only {
        results.retain(|r| !r.entry.is_dir);
    }
    if opts.dirs_only {
        results.retain(|r| r.entry.is_dir);
    }
    if !opts.ext.is_empty() {
        let wanted: std::collections::HashSet<String> = opts
            .ext
            .iter()
            .map(|e| e.trim_start_matches('.').to_ascii_lowercase())
            .collect();
        results.retain(|r| wanted.contains(&r.entry.extension));
    }

    let effective_limit = if opts.all {
        usize::MAX
    } else {
        opts.limit.unwrap_or(cfg.index.max_results)
    };
    results.truncate(effective_limit);

    if opts.stats && !opts.quiet {
        eprintln!(
            "# index: {} entries (source: {source}); results: {}",
            store.len(),
            results.len()
        );
    }

    emit(&results, &opts);
    ExitCode::SUCCESS
}

/// Write results to stdout in the requested format.
fn emit(results: &[search::AdvancedSearchResult], opts: &Options) {
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());
    let sep = if opts.print0 { b'\0' } else { b'\n' };

    for r in results {
        if opts.json {
            let obj = serde_json::json!({
                "path": r.entry.path,
                "name": r.entry.name,
                "isDir": r.entry.is_dir,
                "size": r.entry.size,
                "modified": r.entry.modified,
                "createdAt": r.entry.created_at,
                "extension": r.entry.extension,
                "score": r.score,
                "mode": serde_json::to_value(r.search_mode).unwrap_or(serde_json::Value::Null),
            });
            let _ = writeln!(out, "{obj}");
        } else {
            let _ = out.write_all(r.entry.path.as_bytes());
            let _ = out.write_all(&[sep]);
        }
    }
    let _ = out.flush();
}

