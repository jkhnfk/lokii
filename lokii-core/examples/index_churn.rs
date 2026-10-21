use lokii_core::compact_index::CompactIndex;
use lokii_core::indexer::FileEntry;
use std::time::Instant;

fn entry(ordinal: usize, parent: &str) -> FileEntry {
    let name = format!("file_{ordinal:07}.rs");
    FileEntry {
        path: format!("{parent}/{name}"),
        name,
        is_dir: false,
        size: 1,
        modified: 1_700_000_000,
        created_at: 1_600_000_000,
        extension: "rs".into(),
    }
}

fn main() {
    let mut index = CompactIndex::from_entries(
        (0..1_000_000)
            .map(|ordinal| entry(ordinal, &format!("/synthetic/project_{}", ordinal / 100))),
    )
    .unwrap();
    let mut cycles = Vec::new();
    for cycle in 0..20 {
        let parent = format!("/churn/{cycle}");
        let started = Instant::now();
        index
            .apply_event_batch(
                &[],
                &[],
                &[],
                (0..10_000).map(|ordinal| entry(ordinal, &parent)).collect(),
            )
            .unwrap();
        let add_ms = started.elapsed().as_secs_f64() * 1000.0;
        let started = Instant::now();
        index
            .apply_event_batch(&[], &[], &[parent], Vec::new())
            .unwrap();
        let remove_ms = started.elapsed().as_secs_f64() * 1000.0;
        index.validate().unwrap();
        assert_eq!(index.len(), 1_000_000);
        cycles.push(
            serde_json::json!({"cycle":cycle, "add_ms":add_ms, "remove_ms":remove_ms,
            "memory":index.memory_stats(), "pools":index.pool_counts()}),
        );
    }
    println!(
        "{}",
        serde_json::json!({"entries":index.len(), "cycles":cycles})
    );
}
