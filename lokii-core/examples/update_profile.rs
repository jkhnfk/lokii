use lokii_core::compact_index::CompactIndex;
use lokii_core::indexer::FileEntry;
use std::time::Instant;

fn entry(ordinal: usize) -> FileEntry {
    let name = format!("file_{ordinal:07}.rs");
    let parent = ordinal / 100;
    FileEntry {
        path: format!("/synthetic/project_{parent}/{name}"),
        name,
        is_dir: false,
        size: 1,
        modified: 1,
        created_at: 1,
        extension: "rs".into(),
    }
}

fn main() {
    let mut index = CompactIndex::from_entries((0..1_000_000).map(entry)).unwrap();
    let mut timings = Vec::new();
    for count in [1, 100, 10_000] {
        let mut samples = Vec::new();
        for _ in 0..15 {
            let creates: Vec<_> = (0..count).map(entry).collect();
            let started = Instant::now();
            index.apply_event_batch(&[], &[], &[], creates).unwrap();
            samples.push(started.elapsed().as_secs_f64() * 1000.0);
        }
        samples.sort_by(f64::total_cmp);
        timings
            .push(serde_json::json!({"count":count, "median_ms":samples[7], "p95_ms":samples[14]}));
    }

    // 目录改名是生产里最典型的批量 rename。两种情形成本差一个量级，分开量：
    // 不匹配的 rename 对每条记录只花一次比较，匹配的才走 materialize + rewrite。
    // 匹配组每次采样后原路改回，保证每轮起点一致。
    let mut rename_timings = Vec::new();
    for count in [1, 10, 100] {
        let forward: Vec<(String, String)> = (0..count)
            .map(|i| {
                (
                    format!("/synthetic/project_{i}"),
                    format!("/synthetic/moved_{i}"),
                )
            })
            .collect();
        let backward: Vec<(String, String)> = (0..count)
            .map(|i| {
                (
                    format!("/synthetic/moved_{i}"),
                    format!("/synthetic/project_{i}"),
                )
            })
            .collect();
        let mut matched = Vec::new();
        for _ in 0..15 {
            let started = Instant::now();
            index
                .apply_event_batch(&forward, &[], &[], Vec::new())
                .unwrap();
            matched.push(started.elapsed().as_secs_f64() * 1000.0);
            index
                .apply_event_batch(&backward, &[], &[], Vec::new())
                .unwrap();
        }

        let missing: Vec<(String, String)> = (0..count)
            .map(|i| {
                (
                    format!("/synthetic/absent_{i}"),
                    format!("/synthetic/nowhere_{i}"),
                )
            })
            .collect();
        let mut unmatched = Vec::new();
        for _ in 0..15 {
            let started = Instant::now();
            index
                .apply_event_batch(&missing, &[], &[], Vec::new())
                .unwrap();
            unmatched.push(started.elapsed().as_secs_f64() * 1000.0);
        }

        matched.sort_by(f64::total_cmp);
        unmatched.sort_by(f64::total_cmp);
        rename_timings.push(serde_json::json!({
            "renames": count,
            "matching_median_ms": matched[7],
            "nonmatching_median_ms": unmatched[7],
        }));
    }

    // `removes` 走同一条记录扫描。这里量不匹配的路径：它能重复采样，且把
    // 扫描本身的开销从摘记录的代价里隔离出来。
    let mut remove_timings = Vec::new();
    for count in [1, 10, 100] {
        let missing: Vec<String> = (0..count)
            .map(|i| format!("/synthetic/absent_{i}"))
            .collect();
        let mut samples = Vec::new();
        for _ in 0..15 {
            let started = Instant::now();
            index
                .apply_event_batch(&[], &[], &missing, Vec::new())
                .unwrap();
            samples.push(started.elapsed().as_secs_f64() * 1000.0);
        }
        samples.sort_by(f64::total_cmp);
        remove_timings.push(serde_json::json!({"removes": count, "median_ms": samples[7]}));
    }

    let started = Instant::now();
    index
        .rename_prefix("/synthetic/project_0", "/synthetic/renamed")
        .unwrap();
    println!(
        "{}",
        serde_json::json!({"upserts":timings, "rename_batches":rename_timings,
        "remove_batches":remove_timings, "rename_prefix_ms":started.elapsed().as_secs_f64()*1000.0})
    );
}
