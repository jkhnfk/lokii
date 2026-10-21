use lokii_core::search::top_k::TopK;

#[test]
fn stable_top_k_matches_complete_order() {
    for limit in [0, 1, 2, 5, 500, usize::MAX] {
        let names = ["main", "zeta", "main", "alpha", "main"];
        let scores = [2, 3, 2, 2, 2];
        let mut top = TopK::new(limit);
        for (ordinal, name) in names.iter().enumerate() {
            top.offer(ordinal, scores[ordinal], name);
        }
        let mut expected: Vec<_> = (0..names.len()).collect();
        expected.sort_by(|left, right| {
            scores[*right]
                .cmp(&scores[*left])
                .then_with(|| names[*left].cmp(names[*right]))
                .then(left.cmp(right))
        });
        expected.truncate(limit);
        assert_eq!(
            top.finish()
                .into_iter()
                .map(|candidate| candidate.ordinal)
                .collect::<Vec<_>>(),
            expected
        );
    }
}
