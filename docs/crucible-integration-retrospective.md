# Crucible Benchmark Integration Retrospective

Derived from the bench-rant integration (July 2026). Covers every error,
correction, and undocumented behavior encountered during the process of adding
a UDP latency benchmark (rant) to crucible as a client-server benchmark with
stress-ng support.

---

## Gaps in Official Documentation

The official guide (`docs/implementing-a-new-benchmark.md`) covers file
structure and basic patterns but is missing the following. These gaps caused
the majority of rework during the bench-rant integration.

### 1. Role Assignment Semantics

**Gap:** Not documented that params without `role` default to `"client"`
(rickshaw-run.py line 110).

**Impact:** Server runs with wrong defaults — wrong binary path, missing
scheduling params, missing NUMA binding. Silently produces degraded or
incorrect results.

**Fix needed:** Explicit statement that `role` defaults to `"client"` and that
every param should carry an explicit role.

### 2. Multiplex Schema Constraints

**Gap:** Not documented that `vals` arrays require `minLength: 1` on each
string element.

**Impact:** Optional params defaulting to `""` fail schema validation at
multiplex time with error `'' should be non-empty`.

**Fix needed:** Schema constraint reference for multiplex.json, including the
sentinel pattern (`"none"` instead of `""`).

### 3. CDM Metric Names Dict

**Gap:** No documentation of which keys are valid in the `names` dict of
metric descriptors.

**Impact:** Custom keys like `percentile` or `stat` are silently dropped or
cause indexing failures in OpenSearch.

**Fix needed:** Enumerate allowed keys (`role`, `cmd`, `type`, `class`, and
any others from the CDM schema). Explain that metric variants should be
encoded in the `type` string.

### 4. Server Signal Semantics

**Gap:** Not documented that SIGTERM (not SIGINT) is the expected shutdown
signal for server processes.

**Impact:** SIGINT may produce incomplete output (0 samples). Server
histogram/stats are only flushed on clean SIGTERM in many tools.

**Fix needed:** Explicit statement about server lifecycle and expected signal
handling.

### 5. Timestamp File Requirements

**Gap:** Not documented that both client and server MUST produce
`<name>-start.txt` and `<name>-stop.txt` containing epoch timestamps.

**Impact:** Post-process cannot determine measurement period boundaries, fails
with missing file errors.

### 6. Post-Process Error Handling

**Gap:** Not documented that post-process must handle 0-sample or empty results
gracefully (exit 0).

**Impact:** If server produces 0 samples (valid in some configs), post-process
returning rc=1 marks the entire iteration as failed.

### 7. Run File Required Sections

**Gap:** Not documented that `tags` and `tool-params` are required sections in
run files, even if empty.

**Impact:** Validation errors at run time.

---

## Timeline of Errors

| # | Error | Root Cause | Time to Fix | Category |
|---|-------|-----------|-------------|----------|
| 1 | Invented nonexistent tool flag | Did not verify against `--help` | 30 min | Tool knowledge |
| 2 | Missing role on params | Undocumented default behavior | 2 hours | Framework gap |
| 3 | Empty string multiplex defaults | Undocumented schema constraint | 1 hour | Framework gap |
| 4 | Missing validation rules | No checklist | 30 min | Process gap |
| 5 | Server using SIGINT instead of SIGTERM | Undocumented signal semantics | 1 hour | Framework gap |
| 6 | Missing timestamp files | Undocumented requirement | 30 min | Framework gap |
| 7 | Custom CDM names dict keys | Undocumented schema | 1 hour | Framework gap |
| 8 | Server 0 samples crashing post-process | No error handling guidance | 30 min | Framework gap |
| 9 | Wrong primary metric (p50 vs MAX) | Domain knowledge assumption | 10 min | User correction |
| 10 | Wrong `crucible run` syntax | CLI confusion | 10 min | Docs gap |
| 11 | Empty string defaults (repeat of #3) | Same mistake, different params | 30 min | Process gap |
| 12 | Stale crucible subprojects | Environment setup | 20 min | Pre-flight gap |
| 13 | Branch protection blocking push | Org policy not known | 10 min | Workflow |
| 14 | Missing tags in run file | Undocumented requirement | 10 min | Framework gap |
| 15 | `primary-branch` validation on repo registration | Only HEAD/main/master allowed | 15 min | Docs gap |
| 16 | External `taskset -c` for stress-ng | Worker migration not obvious | Caught early | Domain knowledge |

**Total estimated rework: ~8-9 hours** across the integration, primarily
caused by undocumented framework behaviors (items 2, 3, 5, 6, 7, 8).

---

## Common Failure Modes (Ranked by Frequency)

1. **Missing role on params** — server gets wrong defaults, silent
   misconfiguration
2. **Empty string in multiplex vals** — schema validation rejects with
   `should be non-empty`
3. **Server using SIGINT instead of SIGTERM** — 0 samples, no histogram output
4. **Missing timestamp files** — post-process cannot determine measurement
   period
5. **Invented tool flags** — silent getopt failures, params ignored
6. **Custom CDM names dict keys** — metrics silently dropped or indexing fails
7. **Server with duration flag** — server exits before client finishes, no data
8. **Stale crucible subprojects** — import errors, missing library functions
9. **Not skipping cross-role params in getopt** — getopt parse errors break
   the script
10. **Post-process failing on empty results** — iteration marked as failed,
    run aborted

---

## Lessons Learned

### 1. Verify every tool flag against `--help`

Do not assume a flag exists based on documentation, general knowledge, or
analogy with other tools. Run the tool's help output and cross-reference every
parameter you plan to expose in `multiplex.json`.

### 2. The #1 mistake is missing `role` on params

Crucible's default-to-client behavior is unintuitive for shared params. The
server silently runs with script defaults instead of the values you configured.
Always use explicit `"role": "client"` or `"role": "server"` on every parameter
in run files.

**Best practice:** Create separate global-options groups (`common-client`,
`common-server`) with explicit roles. Duplicate shared params into both groups.

### 3. Sentinel values, not empty strings

The multiplex schema rejects empty strings (`minLength: 1`). Use `"none"` as
the default for optional string parameters and check `!= "none"` in scripts.
This mistake was made twice during the integration — once for base params and
again for stress params.

### 4. Encode metric variants in the type string

The CDM names dict has a fixed schema. Do not add custom keys.

```
CORRECT: type = "round-trip-usec-p50",  names = {"role": "client"}
WRONG:   type = "round-trip-usec",      names = {"role": "client", "percentile": "p50"}
```

### 5. SIGTERM for server shutdown

Many tools flush their output buffers (histograms, statistics, final summaries)
only on SIGTERM. SIGINT may produce 0 samples or incomplete output. Always use
`kill -TERM` in the server-stop script.

### 6. Both roles need timestamp files

Post-process expects `<name>-start.txt` and `<name>-stop.txt` from both client
and server. The server-start script creates the start timestamp; the server-stop
script creates the stop timestamp.

### 7. Scripts must silently skip cross-role params

Crucible sends ALL params to ALL roles via the getopt command line. Client
scripts must have catch-all `shift; shift` cases for server-only params (like
`--no-tx-ts`, `--fast-path`, `--threaded`), and server scripts must skip
client-only params (like `--duration`, `--server-address`). Failing to do this
causes getopt parse errors that silently break parameter processing.

### 8. stress-ng `--taskset` is mandatory

External `taskset -c` only pins the parent stress-ng process. Worker child
processes inherit the affinity momentarily but the kernel scheduler migrates
them to other CPUs, including the benchmark's isolated CPUs. This causes
catastrophic latency spikes (orders of magnitude worse). Always use stress-ng's
built-in `--taskset` flag.

### 9. Test with a controlled A/B run file

A 2-iteration run file (clean baseline + one variable changed) is the minimum
viable test for validating integration correctness. This catches:
- Parameter passing to both roles
- Stress-ng lifecycle (start, run, cleanup)
- Post-processing for both iterations
- Metric indexing and result comparison

### 10. Update crucible subprojects before testing

Stale toolbox/rickshaw versions cause import errors and missing library
functions. Run `crucible repo info` to check for outdated subprojects before
starting a test run.

### 11. Don't include environment-specific numbers in docs

Test results from a specific host (latency values, throughput numbers) should
not appear in README files as "typical results". They are environment-dependent
and will mislead users with different hardware.

### 12. `crucible run <file>`, not `crucible run --from <file>`

The correct invocation is `crucible run <run-file.json>`. The `--from` flag
does not exist. Do not attempt to invoke `rickshaw-run.py` directly either.

---

## Integration Checklist Summary

The [integration guide](crucible-benchmark-integration-guide.md) contains a
complete pre-flight checklist in Phase 6. The most critical items:

1. Every run file param has explicit `role`
2. No empty strings in multiplex defaults
3. Server uses SIGTERM, not SIGINT
4. Both roles produce timestamp files
5. Post-process handles 0-sample results
6. CDM names dict uses only allowed keys
7. All tool flags verified against `--help`
8. Scripts skip cross-role params silently
