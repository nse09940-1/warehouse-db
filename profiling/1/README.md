# Profiling run 1

Expected files after the load test:

- `k6_summary.json` from `k6 run --summary-export profiling/1/k6_summary.json load/k6_script.js`
- `pg_stat_statements.csv` exported after the run
- `explain/*.txt` with `EXPLAIN (ANALYZE, BUFFERS)` output for the workload SQL queries

Use `scripts/collect-profiling.sh` from inside the compose environment or adapt its SQL commands for a host `psql` session.
