use glob_match::glob_match;

use crate::legacy::indexer::IndexStore;
use super::{AdvancedSearchResult, SearchMode};

/// Wildcard search using glob patterns (* and ? wildcards).
///
/// Case-insensitive matching per R1.2. Both the pattern and filenames
/// are lowercased before comparison. Matching entries get score 1.0
/// (wildcard is binary match) and match_positions covering the full name.
pub fn search(store: &IndexStore, query: &str, max_results: usize) -> Vec<AdvancedSearchResult> {
    let pattern = query.trim().to_lowercase();
    if pattern.is_empty() {
        return Vec::new();
    }

    let entries = store.entries();
    let mut results: Vec<AdvancedSearchResult> = entries
        .iter()
        .filter_map(|entry| {
            let name_lower = entry.name.to_lowercase();
            if glob_match(&pattern, &name_lower) {
                Some(AdvancedSearchResult {
                    entry: entry.clone(),
                    score: 1.0,
                    match_positions: vec![(0, entry.name.len())],
                    search_mode: SearchMode::Wildcard,
                })
            } else {
                None
            }
        })
        .collect();

    results.sort_by(|a, b| a.entry.name.cmp(&b.entry.name));
    results.truncate(max_results);
    results
}
