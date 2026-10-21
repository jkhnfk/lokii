use crate::legacy::indexer::{score_match, IndexStore, MatchScore};

use super::{AdvancedSearchResult, SearchMode};

/// Convert MatchScore to normalized f64 per research recommendation.
fn score_to_f64(score: MatchScore) -> f64 {
    match score {
        MatchScore::Exact => 1.0,
        MatchScore::Prefix => 0.75,
        MatchScore::Substring => 0.5,
    }
}

/// Compute match positions for substring matches.
/// Returns byte ranges of each keyword match in the name.
fn find_positions(name_lower: &str, keywords: &[String]) -> Vec<(usize, usize)> {
    let mut positions = Vec::new();
    for kw in keywords {
        if let Some(start) = name_lower.find(kw.as_str()) {
            positions.push((start, start + kw.len()));
        }
    }
    positions
}

/// Substring search wrapping existing IndexStore logic.
/// Preserves v1.0 behavior: extension filter, multi-keyword AND, Exact > Prefix > Substring ranking.
pub fn search(store: &IndexStore, query: &str, max_results: usize) -> Vec<AdvancedSearchResult> {
    let query = query.trim();
    if query.is_empty() {
        return Vec::new();
    }

    // Extension filter path: query starts with '.' and contains no spaces
    if query.starts_with('.') && !query.contains(' ') {
        let ext = query[1..].to_lowercase();
        let entries = store.entries();
        let mut results: Vec<AdvancedSearchResult> = entries
            .iter()
            .filter(|e| e.extension == ext)
            .map(|e| AdvancedSearchResult {
                entry: e.clone(),
                score: 1.0,
                match_positions: vec![],
                search_mode: SearchMode::Substring,
            })
            .collect();
        results.sort_by(|a, b| a.entry.name.cmp(&b.entry.name));
        results.truncate(max_results);
        return results;
    }

    // Standard substring search
    let keywords: Vec<String> = query.split_whitespace().map(|s| s.to_lowercase()).collect();

    let entries = store.entries();
    let mut results: Vec<AdvancedSearchResult> = entries
        .iter()
        .filter_map(|e| {
            let name_lower = e.name.to_lowercase();
            score_match(&name_lower, &keywords).map(|score| {
                let positions = find_positions(&name_lower, &keywords);
                AdvancedSearchResult {
                    entry: e.clone(),
                    score: score_to_f64(score),
                    match_positions: positions,
                    search_mode: SearchMode::Substring,
                }
            })
        })
        .collect();

    results.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.entry.name.cmp(&b.entry.name))
    });
    results.truncate(max_results);
    results
}
