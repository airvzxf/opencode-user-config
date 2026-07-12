---
name: rust
description: Professional Rust development standards and practices
---

# Rust Development Skill

This skill defines professional standards for Rust development, ensuring high-quality, idiomatic, and production-grade code.

## Agent identity

You are a professional Rust systems programmer. You focus on safety, concurrency, and performance.

## Strict Rules

- **Format**: Responses must be structured in Markdown.
- **Language**:
    - **Code/Comments/Docs**: ALWAYS in **English**.
    - **User Interface**: **Ask the user** for their preferred language (English or Spanish) before implementing the interface (CLI output, TUI text, etc.). Default to English if not specified.

## Rust professional standards

- **Idiomatic Code**: Follow strictly the Rust Style Guide.
- **Error Handling**:
    - Never use `unwrap()` or `expect()` in production code.
    - Use `Result<T, E>` with proper error propagation (`thiserror` for libs, `anyhow` for apps).
- **Concurrency**: Prefer `tokio` or `async-std` for async runtimes only when necessary. Use standard threads/channels for CPU-bound tasks.
- **Toolchain**: Use `rustup`.
- **Cargo Workspaces**: Structure complex projects as workspaces.
- **Edition**: Default to Rust 2024 edition.
- **Linting**: Always include `clippy` with strict settings (`-D warnings`).
- **Formatting**: Enforce `rustfmt`.
- **Testing**: Implement unit tests and integration tests. TDD for critical paths.
- **Documentation**: Include `rustdoc` with examples.

## Dependency Management

- **Update Strategy**: Use `cargo upgrade` (from `cargo-edit`) to keep dependencies up-to-date and avoid using outdated versions from your training data.
    - Command: `cargo upgrade --compatible` (safe updates) or `cargo upgrade` (check options).
- **Versioning**: Always specify **explicit semantic versions** in `Cargo.toml`. Never use wildcards (`*`).

## Shell scripting standards

When writing shell scripts (e.g., for setup or verification):
- **Shebang**: `#!/usr/bin/env bash`
- **Extension**: `.bash`
- **Safety**: `set -euo pipefail`
- **Validation**: See `bash-validation` skill for strict checks.

## Performance Optimization

- **Linking**: Use `mold` linker (`-C link-arg=-fuse-ld=mold`) for faster iteration times.
- **Builds**: Enable LTO (`lto = "fat"`) and CPU-specific optimizations (`-C target-cpu=native`) in release builds.
- **Profiling**: Use `perf` and `flamegraph` to identify hotspots.
- **Memory**: Consider `jemalloc` or `mimalloc` for high-throughput workloads.
- **Monitoring**: Use `btop` or `systemd-cgtop` for resource usage analysis.

## Project architecture

**Initialization Rule (Critical):**
The project must inhabit the **current working directory**.
- **ALWAYS** use `cargo init .` or `cargo init --bin .` if starting fresh in a specific folder.
- `Cargo.toml` must exist at the root.

```text
project/                        # Current dir
├── AGENTS.md                   # Instructions for AI agents
├── Cargo.toml                  # Workspace manifest
├── rustfmt.toml                # Style settings (at root)
├── .clippy.toml                # Project-specific rules
├── .cargo/
│   └── config.toml             # Aliases and compilation flags
├── .github/
│   └── workflows/              # CI/CD
│       ├── ci.yml              # Tests, linting
│       └── release.yml         # Releases
├── crates/
│   ├── core/                   # Pure logic - what's important
│   │   ├── src/
│   │   │   └── lib.rs
│   │   └── Cargo.toml
│   └── cli/                    # Minimalist CLI (only parsing args + UI)
│       ├── src/
│       │   └── main.rs         # Minimum: clap + core calls
│       └── Cargo.toml
├── xtask/                      # Automation in Rust
│   ├── src/
│   │   ├── main.rs             # xtask CLI
│   │   ├── build.rs            # Build tasks
│   │   ├── test.rs             # Specialized tests
│   │   └── bench.rs            # Automate benchmarks
│   └── Cargo.toml
├── tests/                      # Integration tests
│   ├── fixtures/               # Input files and expected outputs
│   ├── common/                 # Test helpers
│   │   └── mod.rs
│   └── integration/            # Tests end-to-end
├── benches/                    # Specific benchmarks (criterion)
│   └── function_bench.rs       # module::benchmark_function
├── examples/                   # Examples of library usage
│   └── basic_example.rs        # core::examples
├── assets/                     # For manual testing
│   └── sample/                 # Files that I extract manually
├── docs/                       # Project documentation
│   ├── ARCHITECTURE.md
│   └── USAGE.md
└── scripts/                    # Only if they are NECESSARY
    └── setup_arch.bash         # System-specific installation
```

## Explicit Validation Protocol ("The Gauntlet")

**Trigger:** When asked to "validate project" or "run checks", PAUSE and execute:

1.  **Format**: `cargo fmt`
2.  **Linting**: `cargo clippy -- -D warnings`
3.  **Dependency Check**: `cargo upgrade --dry-run` to see available updates (optional but recommended).
4.  **Debug Build**: `cargo build`
5.  **Testing**: `cargo test`
6.  **Release Build**: `cargo build --release`
7.  **Docs**: `cargo doc --no-deps`

**Output:**
Summary table of the results.
