# Performance benchmark — Section 10 speed targets

_Generated: 2026-07-05T20:11:40.400450+00:00_

> *** REAL MEASUREMENTS — every latency is measured against a live Anki Collection running the real Rust core. Nothing here is synthetic. ***

**Deck:** 50000 cards, 1000 graded · **Platform:** macOS-15.6.1-arm64-arm-64bit-Mach-O (py 3.13.13) · **seed:** 20260705

**Overall: ✅ ALL TARGETS MET**

| Metric | p50 (ms) | p95 (ms) | max (ms) | Target | Verdict |
| --- | ---: | ---: | ---: | --- | :---: |
| Grade card (button ack) | 0.19 | 0.24 | 75.80 | p95 < 50 ms | PASS |
| Next card (fetch queued) | 0.06 | 0.06 | 33.86 | p95 < 100 ms | PASS |
| Dashboard cold (`tag_mastery`) | – | 226.27 | – | < 1000 ms | PASS |
| Dashboard refresh (`tag_mastery`) | 175.45 | 187.17 | 188.31 | p95 < 500 ms | PASS |

| Other | Value | Limit / note |
| --- | ---: | --- |
| Cold-start (open collection) | 2.9 ms | reported |
| Build time (bulk add) | 10.2 s | reported |
| Peak RSS | 136.0 MiB | limit 1024 MiB → PASS |

Latencies are `time.perf_counter` deltas around individual real operations (no averaging tricks); percentiles are nearest-rank. `grade_card` = `sched.answerCard`, `next_card` = `sched.get_queued_cards`, dashboard = `col._backend.tag_mastery`.

> *** REAL MEASUREMENTS — every latency is measured against a live Anki Collection running the real Rust core. Nothing here is synthetic. ***
