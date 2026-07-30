# Crucible Benchmark Integration Guide

A step-by-step guide for adding a new benchmark tool to the crucible test harness
([perftool-incubator/crucible](https://github.com/perftool-incubator/crucible)).
Derived from the bench-rant integration, capturing every mistake, correction,
undocumented behavior, and missing context encountered during the process.

This guide complements the official crucible documentation at
`docs/implementing-a-new-benchmark.md`, which covers the basics but has gaps
documented in the [retrospective](crucible-integration-retrospective.md).

## Reference Implementations

- **bench-uperf** — the canonical, mature reference (`subprojects/benchmarks/uperf/`)
- **bench-rant** — the most recent integration; demonstrates stress-ng integration patterns

When in doubt about any pattern, check how uperf does it.

---

## High-Level Workflow (24 Steps)

The complete integration process, in the order things need to happen:

1. **Study the benchmark tool** — run `--help`, capture full CLI reference,
   understand output format, identify client-server model vs client-only,
   determine how it terminates (duration flag, signal, etc.)
2. **Study crucible's framework** — read `docs/implementing-a-new-benchmark.md`,
   understand the file contract (rickshaw.json schema, workshop build stages,
   multiplex validation, post-process CDM output)
3. **Study an existing benchmark** — read bench-uperf end-to-end as the
   canonical reference: file structure, role handling, getopt patterns, service
   discovery messaging, post-process metric format
4. **Create the bench-\<name\> repository** — on GitHub under
   perftool-incubator, with LICENSE
5. **Write `rickshaw.json`** — declares all scripts, file transfers, and
   client/server structure; the manifest that tells crucible what your benchmark
   provides
6. **Write `workshop.json`** — build instructions to compile/install the tool
   and its dependencies inside the container image
7. **Write `<name>-base`** — thin shim that sources the toolbox bench-base
   library; provides `dump_runtime`, `validate_label`, `exit_error`, metrics API
8. **Write `<name>-server-start`** — parse params via getopt (silently skip
   client-only params), determine server IP from interface, publish service
   discovery message to `msgs/tx/svc`, start server in background, save PID,
   create `<name>-start.txt` timestamp; server must NOT have a duration flag
9. **Write `<name>-server-stop`** — read PID file, send SIGTERM (not SIGINT),
   wait, create `<name>-stop.txt` timestamp
10. **Write `<name>-client`** — parse params via getopt (silently skip
    server-only params), read server address from `msgs/rx/svc` for
    auto-discovery, create start timestamp, run tool in foreground with
    duration, create stop timestamp
11. **Write `<name>-get-runtime`** — extract `--duration` value from args for
    crucible's timeout calculation
12. **Write `multiplex.json`** — define all parameter defaults and validation
    rules; every default must have a validation; no empty string vals (use
    `"none"` sentinel); classify params by validation type
13. **Write `<name>-post-process`** — parse tool output, emit CDM-compliant
    metrics; use only allowed keys in names dict (`role`, `cmd`); encode metric
    variants in the type string; handle 0-sample results gracefully (exit 0);
    define `primary-metric` and `primary-period`
14. **Local validation** — `bash -n` on all scripts, `python3 -m json.tool` on
    all JSON, `chmod +x` on all scripts
15. **Create a minimal run file** — single iteration, explicit `role:client` and
    `role:server` on every param, `tags` and `tool-params` sections present,
    real endpoint host
16. **Register with crucible controller** — `crucible repo config add` with your
    repo URL; use `checkout-target` for feature branches (`primary-branch` only
    allows HEAD/main/master)
17. **Run first smoke test** — `crucible run <run-file.json>`; check stderrout
    logs for both roles; verify server started, client connected, results
    produced, post-process succeeded
18. **Debug and iterate** — fix issues found in smoke test (missing roles, wrong
    signals, missing timestamps, CDM schema violations, getopt failures from
    cross-role params)
19. **Create README and example run files** — document usage, parameters,
    standalone operation, crucible integration; include examples with CHANGEME
    placeholders; no environment-specific numbers or hostnames
20. **Create `config.sh`** (if applicable) — system configuration script for the
    test host (NIC tuning, CPU isolation, namespace setup, IRQ affinity); must
    be portable, no hardcoded values
21. **Add stress-ng integration** (if applicable) — add stress params to
    multiplex.json, add stress-ng lifecycle to client and server scripts, add
    stress-ng to workshop.json deps; use `--taskset` (never external
    `taskset -c`); use `numactl --membind` for NUMA-aware stress
22. **Full end-to-end validation** — 2-iteration A/B run file (clean baseline
    + one variable changed); verify both iterations complete, metrics are
    correct, stress-ng starts/stops properly
23. **Create PRs on bench-\<name\>** — branch protection requires PRs, no
    direct push to main
24. **Create PR on crucible** — add repo to `config/repos.json` for official
    registration

**Key ordering dependencies:** Steps 2–3 before anything else (understand the
framework first). Steps 5–7 before 8–11 (manifest and build before scripts).
Step 12 before 15 (multiplex before run files). Step 14 before 16 (validate
before registering). Steps 17–18 are always iterative. Steps 19–21 can happen
in any order after step 18 passes.

---

## Phase 1: Pre-Integration Research

Before writing any code:

### 1.1 Understand the Benchmark Tool Completely

- Run the tool's `--help` / `-h` and capture the **full** output
- Identify **every** flag and parameter — do NOT invent flags that don't exist
  (we added a nonexistent `-s` flag to rant, causing silent failures)
- Classify each flag: client-only, server-only, or both
- Identify the tool's output format (stdout, file, JSON, etc.)
- Understand the tool's lifecycle: does it run for a duration and exit?
  Does it run until signaled? Does it fork workers?

### 1.2 Determine the Benchmark Model

- **Client-only**: Tool runs, produces results, exits (e.g., fio)
- **Client-server**: Server listens, client connects, client drives the test
  (e.g., uperf, rant, iperf)
- For client-server: how does the server terminate?
  (SIGTERM, SIGINT, client-initiated, timeout)

### 1.3 Identify the Metrics

- What metrics does the tool produce? (throughput, latency, IOPS, etc.)
- Which metric is the **primary** metric for this benchmark?
- For latency benchmarks: the primary metric is typically MAX (tail latency),
  not p50 or average
- What percentiles does the tool report?
- What is the output format for parsing?

---

## Phase 2: Required Files

Every crucible benchmark needs these files in a `bench-<name>/` repository:

### 2.1 `rickshaw.json` — Integration Manifest

Declares the benchmark's scripts, file transfers, and capabilities.

```json
{
    "rickshaw-benchmark": {
        "schema": { "version": "2020.05.18" }
    },
    "benchmark": "<name>",
    "controller": {
        "post-script": "<name>-post-process"
    },
    "client": {
        "files-from-controller": ["<name>-base", "<name>-client"],
        "runtime": "<name>-get-runtime",
        "start": "<name>-client"
    },
    "server": {
        "files-from-controller": [
            "<name>-base", "<name>-server-start", "<name>-server-stop"
        ],
        "start": "<name>-server-start",
        "stop": "<name>-server-stop"
    }
}
```

Schema validated against `subprojects/core/rickshaw/schema/benchmark.json`.

### 2.2 `workshop.json` — Build Configuration

Defines how to compile/install the benchmark tool inside the container image.

```json
{
    "<name>_deps": {
        "packages": {
            "default": ["dep1", "dep2"]
        }
    },
    "<name>_install": {
        "cmds": {
            "default": [
                "git clone <repo> /opt/<name>",
                "cd /opt/<name> && make",
                "cp <name> /usr/local/bin/<name>"
            ]
        }
    }
}
```

Package names go under a `"default"` distro key. If the tool needs stress-ng for
load testing, add `"stress-ng"` to the deps packages.

### 2.3 `multiplex.json` — Parameter Defaults and Validation

#### Critical rules (undocumented, caused multiple failures):

1. **`vals` must be non-empty strings.** The multiplex JSON schema enforces
   `minLength: 1`. Using `""` as a default **will** fail schema validation with
   error `'' should be non-empty`. For optional parameters, use a sentinel value
   like `"none"` and check for it in scripts.

2. **Every param in `presets` MUST have a matching validation rule.** A param
   without a validation entry will cause silent failures or schema errors.

3. **Preset names are arbitrary** — uperf uses `"basic"`, bench-rant uses
   `"defaults"`. The run file references the preset by name.

```json
{
    "presets": {
        "defaults": [
            { "arg": "duration", "vals": ["60"] },
            { "arg": "optional-param", "vals": ["none"] }
        ]
    },
    "validations": {
        "positive_integer": {
            "description": "a whole number greater than 0",
            "args": ["duration"],
            "vals": "[1-9][0-9]*"
        },
        "string_value": {
            "description": "a non-empty string",
            "args": ["optional-param"],
            "vals": ".+"
        }
    }
}
```

### 2.4 `<name>-base` — Common Library

Thin wrapper that sources the toolbox bench-base library:

```bash
#!/bin/bash
. $TOOLBOX_HOME/bash/library/bench-base
```

This provides `dump_runtime`, `validate_label`, `validate_sw_prereqs`,
`exit_error`, and the metrics API (`log_sample`, `finish_samples`).

### 2.5 `<name>-client` — Client Execution Script

**Lifecycle:**
1. Source `<name>-base`
2. Parse ALL parameters via `getopt` (including server-only params — silently
   skip them)
3. Build the command line
4. Start any auxiliary processes (stress-ng, etc.)
5. Write `date +%s.%N > <name>-start.txt`
6. Run the benchmark (foreground, blocking)
7. Write `date +%s.%N > <name>-stop.txt`
8. Stop auxiliary processes
9. Exit with the benchmark's return code

**Must handle:**

- **Server-only params arriving via getopt.** Crucible sends ALL params to ALL
  roles. Add catch-all cases that `shift; shift` to skip them silently.
- **Stdout/stderr redirection:** `exec ><name>-client-stderrout.txt` and
  `exec 2>&1` at the top.
- **Timestamp files:** BOTH `<name>-start.txt` and `<name>-stop.txt` are
  REQUIRED for post-processing. Missing timestamps cause post-process failures.

### 2.6 `<name>-server-start` — Server Start Script

**Lifecycle:**
1. Source `<name>-base`
2. Parse params (silently skip client-only params)
3. Determine server IP from the interface (for service discovery)
4. Publish the server address via messaging:
   `echo '{"svc":{"ip":"...","ports":[...]}}' > msgs/tx/svc`
5. Write `date +%s.%N > <name>-start.txt`
6. Start the benchmark server in BACKGROUND (`&`)
7. Save PID: `echo $pid > <name>-server.pid`
8. Verify the server started (check `/proc/$pid`)
9. Exit 0

**CRITICAL: The server must NOT have a duration flag.** It runs indefinitely
until SIGTERM'd by the stop script.

### 2.7 `<name>-server-stop` — Server Stop Script

```bash
#!/bin/bash
. /usr/bin/<name>-base || exit 1

if [ -e <name>-server.pid ]; then
    pid=$(cat <name>-server.pid)
    if [ -e /proc/$pid ]; then
        kill -TERM $pid
        wait $pid 2>/dev/null
    fi
fi

date +%s.%N > <name>-stop.txt
```

**CRITICAL: Use SIGTERM, not SIGINT.** Many tools handle SIGTERM by flushing
output (histograms, stats) to stdout. SIGINT may produce incomplete output or
0 samples. The stop script must also create the `<name>-stop.txt` timestamp
file.

### 2.8 `<name>-get-runtime` — Duration Extractor

Simple script that parses the `--duration` arg and outputs the value:

```bash
#!/bin/bash
opts=$(getopt -q -o "" --longoptions "duration:" -- "$@")
eval set -- "$opts"
while true; do
    case "$1" in
        --duration) shift; echo "$1"; shift ;;
        --) shift; break ;;
        *) shift ;;
    esac
done
```

### 2.9 `<name>-post-process` — Metric Extraction

Parses benchmark output and produces CDM-compliant metrics.

#### CDM Metric Schema (undocumented — caused multiple failures)

The metric descriptor (`desc`) dict requires exactly:
- `source` — benchmark name string
- `class` — one of: `throughput`, `count` (check existing benchmarks for others)
- `type` — the metric type string (e.g., `round-trip-usec-max`, `Gbps`,
  `transactions-sec`)

The `names` dict holds disambiguation key-value pairs. **Only predefined keys
are allowed:**
- `role` — `client` or `server` (from `$RS_CS_LABEL`)
- `cmd` — command/operation type
- Other keys from the CDM schema

**DO NOT invent custom keys** like `percentile` or `stat` in the names dict.
They will be silently dropped or cause indexing failures. Instead, encode the
variant in the `type` string itself (e.g., `round-trip-usec-p50`,
`round-trip-usec-max`, `round-trip-usec-avg`).

**Output files:**
- `post-process-data.json` — metadata with `primary-period`, `primary-metric`,
  and `periods` array
- `metric-data-N.csv` — tab-separated metric samples
- `metric-data-N.json` — JSON metric descriptors

**Must handle empty/zero-sample results gracefully.** Server may produce
0 samples in some configurations. Post-process must NOT return rc=1 for this
— produce an empty metric file and exit 0.

---

## Phase 3: Run File Structure

### 3.1 Role Assignment — The #1 Source of Bugs

**Every parameter in a run file MUST have an explicit `role` field.**

```json
{ "arg": "duration", "vals": ["60"], "role": "client" }
```

- `"role": "client"` — sent only to client engine
- `"role": "server"` — sent only to server engine
- `"role": "all"` — sent to both (exists in schema but prefer explicit
  duplication for clarity)
- **No role field** — silently defaults to `"client"` (rickshaw-run.py
  line 110). **This is the #1 mistake.**

**Best practice:** Create separate global-options groups (`common-client`,
`common-server`) with explicit roles on every parameter. Duplicate shared params
(like binary path, scheduling priority) into both groups.

### 3.2 Required Run File Sections

```json
{
    "benchmarks": [
        {
            "name": "<name>",
            "ids": "1",
            "mv-params": {
                "global-options": [...],
                "sets": [...]
            }
        }
    ],
    "tags": {},
    "tool-params": [],
    "endpoints": [...]
}
```

- **`tags` is required** — even if empty. Missing `tags` causes validation
  errors.
- **`tool-params` is required** — even if empty array.

### 3.3 Endpoint Configuration

```json
{
    "type": "remotehosts",
    "settings": { "osruntime": "chroot" },
    "remotes": [
        {
            "engines": [
                { "role": "client", "ids": "1" },
                { "role": "server", "ids": "1" }
            ],
            "config": {
                "host": "testhost.example.com",
                "settings": { "cpu-partitioning": false }
            }
        }
    ]
}
```

### 3.4 Multi-Iteration A/B Testing

Use multiple `sets` in `mv-params` for comparing configurations (baseline vs
stress, different tunings, etc.). Each set becomes a separate iteration in the
crucible run:

```json
"sets": [
    {
        "include": ["common-client", "common-server"],
        "params": [
            { "arg": "interface", "vals": ["eth0"], "role": "client" }
        ]
    },
    {
        "include": ["common-client", "common-server"],
        "params": [
            { "arg": "interface", "vals": ["eth0"], "role": "client" },
            { "arg": "stress-type", "vals": ["sched"], "role": "client" },
            { "arg": "stress-cpus", "vals": ["57-63"], "role": "client" },
            { "arg": "stress-workers", "vals": ["7"], "role": "client" },
            { "arg": "stress-membind", "vals": ["7"], "role": "client" }
        ]
    }
]
```

---

## Phase 4: Stress-ng Integration (Optional)

For benchmarks that need latency-under-load testing:

### 4.1 Parameters

| Param | Default | Description |
|-------|---------|-------------|
| `stress-type` | `none` | Comma-separated: `cache,cpu,memory,io,fork,sched` |
| `stress-cpus` | `none` | CPU list for `--taskset` (e.g., `57-63`) |
| `stress-workers` | `0` | Workers per stressor type |
| `stress-membind` | `none` | NUMA node(s) for `numactl --membind` |

### 4.2 CRITICAL: Use `--taskset`, NOT external `taskset -c`

```bash
# CORRECT — pins all workers to specified CPUs
stress-ng --schedpolicy 7 --taskset 57-63 --timeout 0

# WRONG — only pins parent process, workers migrate everywhere
taskset -c 57-63 stress-ng --schedpolicy 7 --timeout 0
```

External `taskset -c` only pins the parent stress-ng process. Worker processes
inherit the affinity briefly but the kernel scheduler migrates them to other
CPUs. This causes **catastrophic latency spikes** (orders of magnitude worse)
when workers land on the benchmark's CPUs.

### 4.3 Lifecycle

- Start stress-ng **before** the benchmark, with `--timeout 0` (run
  indefinitely)
- `sleep 3` after starting to let workers stabilize
- Kill stress-ng **after** the benchmark finishes
- For server: save PIDs to a file (`stress-ng.pids`) since start/stop are
  separate scripts
- Use `numactl --membind=$node` prefix for NUMA-aware memory allocation

---

## Phase 5: Testing and Deployment

### 5.1 Local Validation

```bash
# Syntax check all scripts
bash -n <name>-client <name>-server-start <name>-server-stop \
       <name>-base <name>-get-runtime

# Validate all JSON files
python3 -m json.tool rickshaw.json
python3 -m json.tool workshop.json
python3 -m json.tool multiplex.json
python3 -m json.tool examples/*.json
```

### 5.2 Register with Crucible Controller

```bash
# Add as unofficial repo for testing
crucible repo config add \
    --repo-url https://github.com/perftool-incubator/bench-<name>.git \
    --repo-name <name> --primary-branch main --checkout-target <branch>

# If testing a feature branch, update checkout-target separately:
crucible repo config update --repo-name <name> --checkout-target <branch-name>
```

Note: `primary-branch` only allows `HEAD`, `main`, or `master`. Use
`checkout-target` for feature branches.

### 5.3 Run the Test

```bash
crucible run <run-file.json>
```

**NOT** `crucible run --from <file>` (wrong syntax). **NOT** direct invocation
of `rickshaw-run.py`.

### 5.4 Check Results

```bash
# Run directory structure
ls /var/lib/crucible/run/<name>--<timestamp>--<run-id>/

# Engine logs (available after run completes)
cat .../run/iterations/iteration-1/sample-1/client/1/<name>-client-stderrout.txt
cat .../run/iterations/iteration-1/sample-1/client/1/<name>-client-result.txt

# Post-process output
cat .../run/iterations/iteration-1/sample-1/client/1/postprocess/post-process-data.json
cat .../run/iterations/iteration-1/sample-1/client/1/postprocess/post-process-output.txt
```

### 5.5 Crucible PR for Registration

Once tested, submit a PR to `perftool-incubator/crucible` adding the repo to
`config/repos.json`:

```json
{
    "name": "<name>",
    "url": "https://github.com/perftool-incubator/bench-<name>.git",
    "primary-branch": "main",
    "checkout-target": "main"
}
```

### 5.6 Branch Protection

perftool-incubator repos have branch protection on `main`. You cannot push
directly — always create PRs.

---

## Phase 6: Pre-Flight Checklist

Before submitting for review, verify:

- [ ] All scripts pass `bash -n` syntax check
- [ ] All JSON files pass `python3 -m json.tool` validation
- [ ] Every multiplex default param has a validation rule
- [ ] No multiplex default vals are empty strings (use `"none"` sentinel)
- [ ] Every run file param has explicit `role: client` or `role: server`
- [ ] Server script does NOT use a duration flag
- [ ] Server stop script sends SIGTERM (not SIGINT)
- [ ] Both client and server create start/stop timestamp files (`date +%s.%N`)
- [ ] Client script silently skips server-only params in getopt
- [ ] Server scripts silently skip client-only params in getopt
- [ ] Post-process handles 0-sample results without error
- [ ] CDM names dict uses only allowed keys (`role`, `cmd`, etc.)
- [ ] Metric types are encoded in the `type` string, not custom names dict keys
- [ ] `workshop.json` installs the tool and all dependencies
- [ ] `msgs/tx/svc` service discovery message is published by server-start
- [ ] Client reads server address from `msgs/rx/svc` as fallback
- [ ] `tags` and `tool-params` sections exist in example run files
- [ ] All tool parameters verified against actual `--help` output
- [ ] No hostnames, IPs, passwords, or sensitive data in committed files
- [ ] Scripts are executable (`chmod +x`)
- [ ] Crucible subprojects are up to date on the controller before testing
