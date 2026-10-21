use regex::RegexBuilder;

use crate::legacy::indexer::IndexStore;
use super::{AdvancedSearchResult, SearchMode};

/// Regex search using the `regex` crate.
///
/// Queries are expected to start with "regex:" prefix (stripped before compilation).
/// Case-insensitive matching per R1.3. Invalid regex returns an error string
/// instead of panicking (per D-07). A size_limit caps pathological patterns.
pub fn search(
    store: &IndexStore,
    query: &str,
    max_results: usize,
) -> (Vec<AdvancedSearchResult>, Option<String>) {
    let pattern = query
        .trim()
        .strip_prefix("regex:")
        .unwrap_or(query.trim());

    if pattern.is_empty() {
        return (Vec::new(), None);
    }

    let re = match RegexBuilder::new(pattern)
        .case_insensitive(true)
        .size_limit(10_000_000)
        .build()
    {
        Ok(re) => re,
        Err(err) => {
            return (Vec::new(), Some(format!("Invalid regex: {}", err)));
        }
    };

    let entries = store.entries();
    let mut results: Vec<AdvancedSearchResult> = entries
        .iter()
        .filter_map(|entry| {
            re.find(&entry.name).map(|m| AdvancedSearchResult {
                entry: entry.clone(),
                score: 1.0,
                match_positions: vec![(m.start(), m.end())],
                search_mode: SearchMode::Regex,
            })
        })
        .collect();

    results.sort_by(|a, b| a.entry.name.cmp(&b.entry.name));
    results.truncate(max_results);
    (results, None)
}
