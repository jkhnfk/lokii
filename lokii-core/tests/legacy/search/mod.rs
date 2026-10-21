pub mod fuzzy;
pub mod substring;
pub mod wildcard;
pub mod regex_search;

use crate::legacy::indexer::{FileEntry, IndexStore};
use serde::Serialize;

/// Search mode per D-01, D-02, D-04.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum SearchMode {
    Auto,
    Substring,
    Wildcard,
    Regex,
    Fuzzy,
}

/// Result from advanced search. Per D-06.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AdvancedSearchResult {
    pub entry: FileEntry,
    pub score: f64,
    pub match_positions: Vec<(usize, usize)>,
    pub search_mode: SearchMode,
}

/// Detect search mode from query string. Per D-02.
/// - Contains `*` or `?` -> Wildcard
/// - Starts with `regex:` -> Regex
/// - Otherwise -> Auto
pub fn detect_mode(query: &str) -> SearchMode {
    let trimmed = query.trim();
    if trimmed.starts_with("regex:") {
        SearchMode::Regex
    } else if trimmed.contains('*') || trimmed.contains('?') {
        SearchMode::Wildcard
    } else {
        SearchMode::Auto
    }
}

/// Main search dispatcher. Per D-01, D-03, D-05.
///
/// If mode is Auto: run substring first; if no results, fallback to fuzzy (Plan 03 adds this).
/// If mode is explicit: run that mode only. Per D-04.
pub fn dispatch(
    store: &IndexStore,
    query: &str,
    mode: SearchMode,
    max_results: usize,
) -> (Vec<AdvancedSearchResult>, Option<String>) {
    let effective_mode = match mode {
        SearchMode::Auto => detect_mode(query),
        other => other,
    };

    // For Auto that detected as Auto (no special chars), try substring first
    let (results, error) = match effective_mode {
        SearchMode::Auto | SearchMode::Substring => {
            let results = substring::search(store, query, max_results);
            if results.is_empty() && matches!(mode, SearchMode::Auto) {
                // D-01: fallback to fuzzy when substring has no results
                // D-03: fuzzy results only appear when substring found nothing
                let fuzzy_results = fuzzy::search(store, query, max_results);
                (fuzzy_results, None)
            } else {
                (results, None)
            }
        }
        SearchMode::Wildcard => {
            let results = wildcard::search(store, query, max_results);
            (results, None)
        }
        SearchMode::Regex => {
            regex_search::search(store, query, max_results)
        }
        SearchMode::Fuzzy => {
            let results = fuzzy::search(store, query, max_results);
            (results, None)
        }
    };

    (results, error)
}
