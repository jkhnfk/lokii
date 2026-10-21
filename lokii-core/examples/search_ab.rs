#[path = "../tests/legacy/mod.rs"]
mod legacy;

use lokii_core::indexer::{FileEntry, IndexStore};
use lokii_core::search::{dispatch, SearchMode};
use std::time::Instant;

fn records(count: usize, shape: &str) -> Vec<FileEntry> {
    (0..count)
        .map(|ordinal| {
            let name = match shape {
                "shared" => format!("file_{:03}.rs", ordinal % 100),
                "unique" => format!("file_{ordinal:07}.rs"),
                _ if ordinal % 4 == 0 => format!("中文_{:03}.txt", ordinal % 400),
                _ if ordinal % 4 == 1 => format!("file_{ordinal:07}.rs"),
                _ => format!("file_{:03}.rs", ordinal % 100),
            };
            let parent = if shape == "unique" {
                ordinal / 2
            } else {
                ordinal / 100
            };
            FileEntry {
                path: format!(
                    "/synthetic/developer/project_{parent:07}/src/long_directory_component/{name}"
                ),
                extension: if name.ends_with(".rs") {
                    "rs".into()
                } else {
                    "txt".into()
                },
                name,
                is_dir: false,
                size: ordinal as u64,
                modified: 1_700_000_000,
                created_at: 1_600_000_000,
            }
        })
        .collect()
}

fn percentile(samples: &[f64], percentile: usize) -> f64 {
    let mut sorted = samples.to_vec();
    sorted.sort_by(f64::total_cmp);
    sorted[(sorted.len() * percentile).div_ceil(100) - 1]
}

#[cfg(target_os = "macos")]
fn cpu_ms() -> f64 {
    let mut timestamp = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    assert_eq!(
        unsafe { libc::clock_gettime(libc::CLOCK_PROCESS_CPUTIME_ID, &mut timestamp) },
        0
    );
    timestamp.tv_sec as f64 * 1000.0 + timestamp.tv_nsec as f64 / 1_000_000.0
}

#[cfg(not(target_os = "macos"))]
fn cpu_ms() -> f64 {
    panic!("per-query process CPU measurement currently requires macOS")
}

fn main() {
    let args: Vec<_> = std::env::args().collect();
    let implementation = args.get(1).map(String::as_str).unwrap_or("current");
    assert!(matches!(implementation, "legacy" | "current"));
    let samples = args
        .get(2)
        .map(|value| value.parse::<usize>().unwrap())
        .unwrap_or(100);
    assert!(samples > 0);
    let shape = args.get(3).map(String::as_str).unwrap_or("mixed");
    assert!(matches!(shape, "mixed" | "shared" | "unique"));
    let count = args
        .get(4)
        .map(|value| value.parse::<usize>().unwrap())
        .unwrap_or(1_000_000);
    let source = records(count, shape);
    let mut current = None;
    let mut old = None;
    if implementation == "current" {
        let store = IndexStore::new();
        store.replace(source);
        current = Some(store);
    } else {
        let store = legacy::indexer::IndexStore::new();
        store.replace(
            source
                .into_iter()
                .map(|entry| legacy::indexer::FileEntry {
                    name: entry.name,
                    path: entry.path,
                    extension: entry.extension,
                    is_dir: entry.is_dir,
                    size: entry.size,
                    modified: entry.modified,
                    created_at: entry.created_at,
                })
                .collect(),
        );
        old = Some(store);
    }
    let mut queries = Vec::new();
    for (query, mode, old_mode) in [
        (
            "file_001",
            SearchMode::Substring,
            legacy::search::SearchMode::Substring,
        ),
        ("f001", SearchMode::Fuzzy, legacy::search::SearchMode::Fuzzy),
        (
            "missing-needle",
            SearchMode::Auto,
            legacy::search::SearchMode::Auto,
        ),
        (
            "*.rs",
            SearchMode::Wildcard,
            legacy::search::SearchMode::Wildcard,
        ),
    ] {
        let run = || {
            if let Some(store) = &current {
                let response = std::hint::black_box(dispatch(store, query, mode, 500));
                (response.0.len(), response.1)
            } else {
                let response = std::hint::black_box(legacy::search::dispatch(
                    old.as_ref().unwrap(),
                    query,
                    old_mode,
                    500,
                ));
                (response.0.len(), response.1)
            }
        };
        let expected = run();
        for _ in 0..4 {
            assert_eq!(run(), expected);
        }
        let mut timings = Vec::with_capacity(samples);
        let mut cpu_timings = Vec::with_capacity(samples);
        for _ in 0..samples {
            let cpu_started = cpu_ms();
            let started = Instant::now();
            let response = run();
            timings.push(started.elapsed().as_secs_f64() * 1000.0);
            cpu_timings.push(cpu_ms() - cpu_started);
            assert_eq!(response, expected);
        }
        queries.push(serde_json::json!({
            "query": query, "result_count": expected.0,
            "samples_ms": timings, "p50_ms": percentile(&timings, 50),
            "p95_ms": percentile(&timings, 95), "p99_ms": percentile(&timings, 99),
            "max_ms": timings.iter().copied().fold(0.0, f64::max),
            "cpu_samples_ms": cpu_timings, "cpu_p50_ms": percentile(&cpu_timings, 50),
            "cpu_p95_ms": percentile(&cpu_timings, 95),
        }));
    }
    println!(
        "{}",
        serde_json::json!({"implementation":implementation, "shape":shape, "entries":count, "samples":samples, "queries":queries})
    );
}
