use lokii_core::{config::AppConfig, filter::CompiledFilter, scanner};
use std::sync::{atomic::AtomicUsize, Arc};
use std::time::Instant;

fn main() {
    let count = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "20000".into())
        .parse::<usize>()
        .unwrap();
    let directory = tempfile::tempdir().unwrap();
    for ordinal in 0..count {
        std::fs::write(directory.path().join(format!("file_{ordinal:07}.rs")), "").unwrap();
    }
    let mut config = AppConfig::default();
    config.index.index_paths = vec![directory.path().to_string_lossy().into_owned()];
    config.index.exclude_paths.clear();
    let filter = Arc::new(CompiledFilter::from_config(&config));
    let paths = vec![directory.path().to_owned()];
    let mut old = Vec::new();
    let mut new = Vec::new();
    for _ in 0..5 {
        let started = Instant::now();
        let entries =
            scanner::scan_directories(&paths, filter.clone(), true, Arc::new(AtomicUsize::new(0)));
        old.push(started.elapsed().as_secs_f64() * 1000.0);
        let started = Instant::now();
        let compact =
            scanner::scan_compact(&paths, filter.clone(), true, Arc::new(AtomicUsize::new(0)))
                .unwrap();
        new.push(started.elapsed().as_secs_f64() * 1000.0);
        assert_eq!(entries.len(), compact.len());
        assert_eq!(compact.len(), count + 1);
        std::hint::black_box((entries, compact));
    }
    old.sort_by(f64::total_cmp);
    new.sort_by(f64::total_cmp);
    println!(
        "{}",
        serde_json::json!({"entries":count, "legacy_ms":old, "compact_ms":new})
    );
}
