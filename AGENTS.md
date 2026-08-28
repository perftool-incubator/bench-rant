# Bench-rant

## Purpose
Crucible benchmark integration for rant (Round-trip And Network Timing), a UDP latency microbenchmark designed for sub-10 microsecond round-trip measurement on Linux real-time systems using hardware timestamps (`SO_TIMESTAMPING`).

## Language
- Bash for client/server execution scripts
- Python for post-processing (`rant-post-process`)

## Key Files
| File | Purpose |
|------|---------|
| `rickshaw.json` | Rickshaw integration: client/server scripts, parameter transformations |
| `multiplex.json` | Parameter validation rules, unit conversions, and presets for multiplex |
| `benchmark-metadata.json` | Machine-readable description and CDM-indexed source/type list (consumed by `crucible benchmarks list`) |
| `rant-base` | Base setup shared by other scripts |
| `rant-client` | Client-side benchmark execution (emit) |
| `rant-server-start` / `rant-server-stop` | Server lifecycle management (reflect) |
| `rant-get-runtime` | Extracts runtime from command-line options |
| `rant-post-process` | Parses rant output into crucible metrics |
| `workshop.json` | Engine image build requirements |

## Conventions
- Primary branch is `main`
- Standard Bash modelines and 4-space indentation
- Python code follows 4-space indentation with standard modelines
