use std::collections::HashSet;
use std::sync::Arc;

use bitcode::{Decode, Encode};
use parking_lot::RwLock;
use serde::Serialize;

/// A single file or directory entry in the index.
///
/// All fields use bitcode-compatible types:
/// - `path` is `String` (not `PathBuf`) for bitcode native Encode/Decode
/// - `modified` is `u64` unix timestamp (not `SystemTime`) for bitcode compatibility
#[derive(Debug, Clone, PartialEq, Encode, Decode, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified: u64,
    /// File creation time as Unix timestamp (seconds). 0 if unavailable.
    pub created_at: u64,
    /// File extension, lowercased (e.g., "rs", "pdf"). Empty for directories and extensionless files.
    pub extension: String,
}

/// Match quality tier for search result ranking.
///
/// Higher value = better match. Used to sort results so that
/// exact name matches appear before prefix matches, which appear
/// before substring matches.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum MatchScore {
    Substring = 0,
    Prefix = 1,
    Exact = 2,
}

/// A search result pairing a file entry with its match score.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchResult {
    pub entry: FileEntry,
    pub score: MatchScore,
}

/// Score a filename against a set of keywords using AND logic.
///
/// All keywords must be present in `name_lower` (case-insensitive matching
/// is the caller's responsibility -- `name_lower` should already be lowercased).
/// The score is determined by the first keyword's match quality:
/// - Exact: the entire name equals the first keyword
/// - Prefix: the name starts with the first keyword
/// - Substring: the name contains the first keyword elsewhere
///
/// Returns `None` if any keyword is not found in the name.
pub fn score_match(name_lower: &str, keywords: &[String]) -> Option<MatchScore> {
    for kw in keywords {
        if !name_lower.contains(kw.as_str()) {
            return None;
        }
    }

    let first = &keywords[0];
    let score = if name_lower == first.as_str() {
        MatchScore::Exact
    } else if name_lower.starts_with(first.as_str()) {
        MatchScore::Prefix
    } else {
        MatchScore::Substring
    };

    Some(score)
}

/// Thread-safe in-memory index store.
///
/// Wraps `Vec<FileEntry>` behind `Arc<parking_lot::RwLock>` for concurrent
/// read-heavy access (many searches, rare writes).
#[derive(Clone)]
pub struct IndexStore {
    entries: Arc<RwLock<Vec<FileEntry>>>,
}

impl IndexStore {
    /// Create a new empty index store.
    pub fn new() -> Self {
        Self {
            entries: Arc::new(RwLock::new(Vec::new())),
        }
    }

    /// Replace the entire index with new entries.
    ///
    /// Takes a write lock and swaps the Vec. Build the new Vec outside
    /// the lock to minimize write lock duration.
    pub fn replace(&self, entries: Vec<FileEntry>) {
        let mut lock = self.entries.write();
        *lock = entries;
    }

    /// Return the number of entries in the index.
    pub fn len(&self) -> usize {
        self.entries.read().len()
    }

    /// Return whether the index is empty.
    pub fn is_empty(&self) -> bool {
        self.entries.read().is_empty()
    }

    /// Return a read guard to the entries for search operations.
    pub fn entries(&self) -> parking_lot::RwLockReadGuard<'_, Vec<FileEntry>> {
        self.entries.read()
    }

    /// Add new entries to the index (per D-06).
    pub fn add_entries(&self, new_entries: Vec<FileEntry>) {
        if new_entries.is_empty() {
            return;
        }
        let mut lock = self.entries.write();
        lock.extend(new_entries);
    }

    /// Remove entries whose path is in the given set (per D-06).
    pub fn remove_paths(&self, paths: &HashSet<String>) {
        if paths.is_empty() {
            return;
        }
        let mut lock = self.entries.write();
        lock.retain(|e| !paths.contains(&e.path));
    }

    /// Get a mutable write guard for complex batch operations (per D-07).
    pub fn entries_mut(&self) -> parking_lot::RwLockWriteGuard<'_, Vec<FileEntry>> {
        self.entries.write()
    }

    /// Search the index for entries matching the query.
    ///
    /// Query behavior:
    /// - Empty/whitespace-only query returns empty results
    /// - Query starting with '.' (no spaces) triggers extension-only filter
    /// - Otherwise: split by whitespace into keywords, ALL must match (AND logic)
    ///
    /// Results are ranked: Exact > Prefix > Substring. Within each tier,
    /// results are sorted alphabetically by name. Results are truncated
    /// to `max_results`.
    pub fn search(&self, query: &str, max_results: usize) -> Vec<SearchResult> {
        let query = query.trim();
        if query.is_empty() {
            return Vec::new();
        }

        // Extension filter path: query starts with '.' and contains no spaces
        if query.starts_with('.') && !query.contains(' ') {
            let ext = query[1..].to_lowercase();
            let entries = self.entries.read();
            let mut results: Vec<SearchResult> = entries
                .iter()
                .filter(|e| {
                    e.name
                        .rsplit('.')
                        .next()
                        .map(|e_ext| e_ext.to_lowercase() == ext)
                        .unwrap_or(false)
                })
                .map(|e| SearchResult {
                    entry: e.clone(),
                    score: MatchScore::Exact,
                })
                .collect();
            results.sort_by(|a, b| a.entry.name.cmp(&b.entry.name));
            results.truncate(max_results);
            return results;
        }

        // Standard search path
        let keywords: Vec<String> = query
            .split_whitespace()
            .map(|s| s.to_lowercase())
            .collect();

        let entries = self.entries.read();
        let mut results: Vec<SearchResult> = entries
            .iter()
            .filter_map(|e| {
                let name_lower = e.name.to_lowercase();
                score_match(&name_lower, &keywords).map(|score| SearchResult {
                    entry: e.clone(),
                    score,
                })
            })
            .collect();

        // Sort: score descending, then name ascending
        results.sort_by(|a, b| {
            b.score
                .cmp(&a.score)
                .then_with(|| a.entry.name.cmp(&b.entry.name))
        });
        results.truncate(max_results);
        results
    }
}

impl Default for IndexStore {
    fn default() -> Self {
        Self::new()
    }
}
