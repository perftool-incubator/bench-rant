# bench-rant

Crucible benchmark integration for [rant](https://github.com/perftool-incubator/rant), a UDP latency microbenchmark designed for sub-10 microsecond round-trip measurement on Linux real-time systems.

## What is rant?

**rant** (Round-trip And Network Timing) measures network latency using a client-server UDP ping-pong model with nanosecond precision via NIC hardware timestamps (`SO_TIMESTAMPING`).

- **Client (emit)**: sends a 1-byte UDP packet, measures round-trip time using NIC PHC timestamps (T4\_HW - T1\_HW)
- **Server (reflect)**: receives and immediately returns the packet, measures response time (T3\_HW - T2\_HW)
- Protocol: 1-byte UDP datagram on port 12345
- Primary timestamp source: NIC PHC clock (e.g. ConnectX-7) via `SOF_TIMESTAMPING_RAW_HARDWARE`
- Fallback: RDTSC calibrated to `CLOCK_TAI`

```
 Client (emit)                              Server (reflect)
 ┌──────────┐                               ┌──────────┐
 │ sendto() │──T1_HW──── 1-byte UDP ───T2_HW──▶│ recvmsg()│
 │          │                               │          │
 │ recvmsg()│◀─T4_HW──── 1-byte UDP ───T3_HW──│ send()   │
 └──────────┘                               └──────────┘

 Round-trip = T4_HW - T1_HW          Response = T3_HW - T2_HW
```

## Key Features

### Measurement

- **Hardware timestamping** — NIC PHC clock timestamps at TX and RX via `SO_TIMESTAMPING`. Isolates wire-level latency from kernel/application overhead.
- **Software timestamps** — RDTSC instruction calibrated against `CLOCK_TAI`. Used for per-syscall breakdown and as fallback when HW timestamps are disabled (`-R`).
- **Histogram** (`-H`) — built-in histogram with configurable bucket size (`-b`, default 1us) and overflow threshold (`-o`, default 100us). Reports p50, p90, p95, p99, p99.9, p99.99 percentiles with min/max/avg.
- **Transaction log** (`-l <file>`) — per-packet log of all timestamps (T1-T4, SW and HW) for offline analysis. Client logs SEQ, T1\_SW, T1\_HW, T4\_HW, T4\_SW, RTT. Server logs SEQ, T2\_HW, T2\_SW, T3\_SW, T3\_HW, RESPONSE.

### Spike Detection

- **Threshold** (`-t <us>`) — stop (or log) when latency exceeds threshold. Prints detailed RDTSC breakdown showing time spent in each syscall and between syscalls.
- **Continue mode** (`-C`) — keep running after threshold breach instead of stopping. Use with `-t` for long-running tests that log all spikes.
- **Log threshold** (`-L <us>`) — only log packets exceeding this latency. Uses a smaller circular buffer for memory efficiency.

### Kernel Trace Integration

- **Trace marker** (`-T`) — writes events to `/sys/kernel/tracing/instances/rant/trace_marker`. Marks test start, warmup completion, and threshold breaches with sequence number, latency, and PHC timestamp. On threshold breach, stops tracing (`tracing_on=0`) to freeze the buffer.
- **Snapshot** (`-S`) — triggers ftrace snapshot on threshold breach. Captures the trace buffer at the exact moment of a spike. When combined with `-l`, switches to circular buffer mode (~500K records, ~10 seconds of context).

### Performance Instrumentation

- **PMC** (`-M`) — hardware performance counters via `rdpmc`. Tracks L1d misses, icache stalls, cycles, dTLB load/store misses. On threshold breach, prints per-syscall PMC deltas comparing the spike to the fast-path average.
- **Warmup** (`-w <packets>`) — discard initial packets before measurement begins. Allows caches, branch predictors, and busy-poll state to stabilize.

### Optimizations

- **Busy polling** (`-p <us>`, `-B <budget>`, `-P`) — `SO_BUSY_POLL` per-socket timeout, `SO_BUSY_POLL_BUDGET` NAPI poll budget, and `SO_PREFER_BUSY_POLL` to always spin rather than block on interrupts.
- **No TX timestamp** (`-N`) — server-only. Skip TX timestamp retrieval from error queue, eliminating 2 extra `local_bh_disable` calls. Uses RDTSC delta instead. Recommended for server.
- **Fast-path** (`-F`) — server-only. Tightest possible recvmsg-to-send loop: `connect()` caches peer address, `send()` instead of `sendto()`, `__builtin_prefetch` on buffer. No HW timestamps.
- **Threaded** (`-2`) — split send/receive into separate pthreads. Requires 3 CPUs via `taskset -c main,recv,send`. Uses RDTSC only.
- **Hugepages** (`-G`) — 2MB hugepage allocation for log and overflow arrays via `MAP_HUGETLB`.
- **Memory locking** — `mlockall(MCL_CURRENT | MCL_FUTURE)` prevents page faults during test.

## Command-Line Reference

| Flag | Long | Arg | Description |
|------|------|-----|-------------|
| `-i` | `--interface` | `<iface>` | Network interface (**required**) |
| `-a` | `--address` | `<ip>` | Server IP (client mode; omit for server) |
| `-d` | `--duration` | `<sec>` | Test duration in seconds (client only) |
| `-w` | `--warmup` | `<pkts>` | Warmup packets to discard |
| `-H` | `--histogram` | | Show histogram with percentiles |
| `-l` | `--log` | `<file>` | Write per-packet transaction log |
| `-t` | `--threshold` | `<us>` | Stop/log on latency exceeding threshold |
| `-C` | `--continue` | | Continue after threshold breach |
| `-L` | `--log-threshold` | `<us>` | Only log packets above this latency |
| `-T` | `--trace-marker` | | Enable kernel trace\_marker integration |
| `-S` | `--snapshot` | | Ftrace snapshot on threshold breach |
| `-M` | `--pmc` | | Enable hardware performance counters |
| `-p` | `--busy-poll-us` | `<us>` | SO\_BUSY\_POLL timeout |
| `-B` | `--budget` | `<n>` | SO\_BUSY\_POLL\_BUDGET |
| `-P` | `--prefer-busypoll` | | SO\_PREFER\_BUSY\_POLL |
| `-N` | `--no-tx-ts` | | Skip TX timestamp retrieval (server) |
| `-F` | `--fast-path` | | Server fast-path optimizations |
| `-2` | `--threaded` | | Split send/recv into threads |
| `-R` | `--no-hw-ts` | | Disable all HW timestamps (RDTSC only) |
| `-G` | `--hugepages` | | Use 2MB hugepages for buffers |
| `-v` | `--verbose` | | Verbose output |
| `-o` | `--overflow` | `<us>` | Histogram overflow threshold (default: 100) |
| `-b` | `--bucket-size` | `<us>` | Histogram bucket size (default: 1) |
| `-h` | `--help` | | Show usage |

## Standalone Usage

Build:
```bash
gcc -O2 -o rant rant.c -lm
```

Server (runs until SIGTERM):
```bash
sudo numactl --membind=6 nsenter --net=/var/run/netns/ns_ens7f1np1 \
  chrt -f 2 taskset -c 50 \
  ./rant -i ens7f1np1 -N -p 50 -B 1 -P -H -w 10000
```

Client (runs for 300 seconds):
```bash
sudo numactl --membind=6 nsenter --net=/var/run/netns/ns_ens7f0np0 \
  chrt -f 2 taskset -c 49 \
  ./rant -i ens7f0np0 -a 192.168.1.11 -d 300 -p 50 -B 1 -P -H -w 10000
```

Spike investigation with trace snapshot:
```bash
sudo ./rant -i ens7f0np0 -a 192.168.1.11 -d 600 \
  -p 50 -B 1 -P -w 10000 -H \
  -T -S -C -t 35
```
This enables trace markers (`-T`), snapshot on spike (`-S`), continues after threshold (`-C`), and triggers at 35us (`-t 35`).

PMC instrumentation (8-hour run):
```bash
sudo ./rant -i ens7f1np1 -N -p 50 -B 1 -P -H -w 10000 -d 28800 -M
```

After the client finishes, send SIGTERM to the server to get its histogram output:
```bash
kill -TERM <server_pid>
```

## System Configuration

Run `config.sh` on each host before testing. It configures network namespaces, ethtool settings, IRQ affinity, CPU isolation, and kernel parameters for minimal latency jitter.

```bash
# Server host
sudo ./config.sh ens7f1np1 \
  --ip 192.168.1.11 --remote-ip 192.168.1.10 \
  --remote-mac <client_mac> \
  --cpu 50 --irq-cpu 52

# Client host
sudo ./config.sh ens7f0np0 \
  --ip 192.168.1.10 --remote-ip 192.168.1.11 \
  --remote-mac <server_mac> \
  --cpu 49 --irq-cpu 51
```

See `config.sh --help` for all options.

### What config.sh does

1. **Network namespace** — creates `ns_<ifname>`, moves interface, assigns IP, sets up static ARP
2. **Ethtool tuning** — single queue, checksums off, coalescing disabled (rx-frames 1, rx-usecs 0), ring rx 64, flow control off, all offloads off
3. **Driver-specific** — mlx5: rx\_cqe\_moder off, rx\_striding\_rq off, tx\_port\_ts off; ice: flow-director-atr off
4. **IRQ affinity** — pins NIC data-path IRQ to irq-cpu at FIFO:50, demotes competing managed IRQs (NVMe, mpi3mr) to SCHED\_OTHER
5. **CPU isolation** — via `tuna isolate`, softirq\_inline enabled on app and IRQ CPUs
6. **Sysctl** — busy\_poll=50, busy\_read=50, gro\_normal\_batch=1, noqueue qdisc
7. **SELinux** — AVC cache threshold increased to 8192 (prevents 200-300us spikes)
8. **PCIe** — power management disabled
9. **PTP** — PHC clock sync via phc2sys (optional)
10. **Traffic reduction** — IPv6 disabled, multicast off, ARP suppressed, ICMP redirects off

### Prerequisites

- PREEMPT\_RT kernel recommended
- CPU isolation boot params: `isolcpus=managed_irq,nohz,domain,<cpus> nohz_full=<cpus> rcu_nocbs=<cpus>`
- App CPU and IRQ CPU must be different CPUs on the same NUMA node
- NIC with HW timestamping support (ConnectX-7 tested, ConnectX-6 compatible)

## Crucible Integration

### Running with crucible

```bash
crucible run --from examples/rant-loopback.json
```

### Run file structure

Run files use crucible's standard format with explicit `role:client` and `role:server` assignments on every parameter. This is required because crucible defaults roleless params to `"client"`.

```json
{
    "benchmarks": [{
        "name": "rant",
        "ids": "1",
        "mv-params": {
            "global-options": [
                {
                    "name": "common-client",
                    "params": [
                        { "arg": "duration", "vals": ["60"], "role": "client" },
                        { "arg": "busy-poll-us", "vals": ["50"], "role": "client" },
                        ...
                    ]
                },
                {
                    "name": "common-server",
                    "params": [
                        { "arg": "busy-poll-us", "vals": ["50"], "role": "server" },
                        { "arg": "no-tx-ts", "vals": ["1"], "role": "server" },
                        ...
                    ]
                }
            ],
            "sets": [{
                "include": ["common-client", "common-server"],
                "params": [
                    { "arg": "interface", "vals": ["ens7f0np0"], "role": "client" },
                    { "arg": "interface", "vals": ["ens7f1np1"], "role": "server" },
                    ...
                ]
            }]
        }
    }]
}
```

See `examples/` for complete run files.

### Parameters

All rant flags are available as crucible parameters via `multiplex.json`. Key mappings:

| Crucible param | rant flag | Default |
|----------------|-----------|---------|
| `duration` | `-d` | 60 |
| `interface` | `-i` | (required) |
| `server-address` | `-a` | (auto-discovered) |
| `busy-poll-us` | `-p` | 50 |
| `busy-poll-budget` | `-B` | 1 |
| `prefer-busy-poll` | `-P` | 1 |
| `warmup` | `-w` | 10000 |
| `histogram` | `-H` | 1 |
| `no-tx-ts` | `-N` | 1 |
| `sched-priority` | chrt -f | 2 |
| `cpu` | taskset -c | (required) |
| `namespace` | nsenter --net | (optional) |
| `numa-node` | numactl --membind | (optional) |

### Metrics

The post-processor extracts these metric types for CDM indexing:

**Client** (`round-trip-usec-*`): p50, p90, p95, p99, p99.9, p99.99, min, max, avg, packets-sec

**Server** (`response-usec-*`): p50, p90, p95, p99, p99.9, p99.99, min, max, avg, packets-sec

**Primary metric**: `round-trip-usec-max`

## Examples

| File | Description |
|------|-------------|
| `examples/rant-loopback.json` | Single-host loopback via dual-port NIC (60s, smoke test) |
| `examples/rant-2host.json` | Two-host test, client and server on separate machines (300s) |

## Building

rant is built automatically by crucible's workshop from the [rant source](https://github.com/perftool-incubator/rant):

```
gcc -O2 -o /usr/local/bin/rant rant.c -lm
```

Build dependencies: `gcc`, `jq`, `bc`, `numactl`

## Key Files

| File | Purpose |
|------|---------|
| `rickshaw.json` | Rickshaw integration: defines client/server scripts and parameter transformations |
| `multiplex.json` | Parameter validation rules, unit conversions, and presets for multiplex |
| `benchmark-metadata.json` | Machine-readable description and CDM-indexed source/type list (consumed by `crucible benchmarks list`) |
| `rant-base` | Base setup shared by other scripts |
| `rant-client` | Client-side benchmark execution (emit) |
| `rant-server-start` / `rant-server-stop` | Server lifecycle management (reflect) |
| `rant-get-runtime` | Extracts runtime from command-line options |
| `rant-post-process` | Parses rant output into crucible metrics |
| `workshop.json` | Engine image build requirements |
