# hc

`hc` is a small, standard-library-only Zig wrapper that runs a command directly and reports its process lifecycle to Herdr when enabled.

## Use

```sh
hc -- <command> [args...]
hc --help
```

The `--` separator is required. `hc` passes arguments directly; it does not invoke a shell or reinterpret command text. The child's stdin, stdout, stderr, working directory, and environment are preserved. `hc` returns the child's exit status, including when it handles a forwarded signal. Signal termination returns `128 + signal` when signal numbers are available; otherwise it returns status `1`. Invalid wrapper syntax exits with status `2`.

## Herdr lifecycle

For a valid `hc -- <command> [args...]` invocation, Herdr reporting is enabled only when `HERDR_ENV=1` and `HERDR_PANE_ID`, `HERDR_BIN_PATH`, and `HERDR_SOCKET_PATH` are all nonempty. `hc` best-effort reports `working` before attempting to start the child, reports `idle` only after a started child finishes, and attempts to release the pane before exiting. Status helpers are bounded and their failures are silent.

This is process-lifecycle reporting only. A long-running agent's per-turn `idle` or `blocked` state cannot be inferred from its process lifetime. Run agents directly with their native Herdr integration for event-level status; `hc` does not install hooks or infer events. `hc` catches wrapper-directed `SIGINT`, `SIGTERM`, and `SIGHUP` on supported POSIX targets and forwards them to the child. It attempts a best-effort release after the command finishes. Other signals are not caught, so one that terminates the wrapper can bypass cleanup. `SIGKILL` cannot be caught.

Herdr documentation: [Add Herdr support](https://herdr.dev/docs/add-herdr-support/) and [Socket API](https://herdr.dev/docs/socket-api/).

## Install

Once a release has been published, install its latest build for the detected platform:

```sh
curl -fsSL https://github.com/takumi3488/hc/releases/latest/download/install.sh | sh
```

The POSIX installer uses `curl`, `tar`, and a standard SHA-256 utility. It verifies the archive against the release's `SHA256SUMS` before installing to `~/.local/bin`, without sudo or shell-profile edits. Add that directory to your `PATH` yourself if needed. Set `HC_INSTALL_DIR` to choose another directory, `HC_VERSION` to select a release tag such as `v0.1.0`, or `HC_TARGET` to select an exact published target name.

For Homebrew, tap this repository and install the formula:

```sh
brew tap takumi3488/hc https://github.com/takumi3488/hc
brew install takumi3488/hc/hc
```

The release workflow commits each release's `hc.rb` to `Formula/hc.rb` on `main`; upgrade with `brew update && brew upgrade hc`.

For manual installation, download `hc-<target>.tar.gz` and `SHA256SUMS` from the same GitHub release, verify the checksum, and extract the archive; it contains only `hc` (or `hc.exe` on Windows). Linux release targets use the ABI shown in the target name, including `musl` or `gnu` where applicable.

## Releases and target support

After the source and workflows are pushed, pushing a `v<SemVer>` tag triggers the release workflow. It attempts every Tier 1, 2, and 3 architecture/OS pattern in Zig 0.17.0's support table (76 targets, including endian variants). Archives are produced only for targets that actually compile; libc/sysroot build failures and platforms that cannot spawn processes are reported, not replaced with no-op binaries. WASI, iOS, tvOS, visionOS, and watchOS are no-spawn targets. See each release's `target-coverage.json`, per-target reports, and build logs for outcomes and reasons.

Cross-compilation and Zig tiers are not runtime guarantees. CI is configured for native checks and CLI smoke tests on Linux, macOS, and Windows; other spawn-capable targets are build-only, while no-spawn targets are reported without compilation. Release assets also include `install.sh`, `hc.rb`, and `SHA256SUMS`.

## Build and test

Use Zig **0.17.0**. The application is a single `hc.zig` file with inline tests and no `build.zig`:

```sh
zig fmt --check hc.zig
zig ast-check hc.zig
zig test hc.zig
zig build-exe hc.zig -O ReleaseSafe -femit-bin=hc
```

On Windows, name the output `hc.exe`.

See the [Zig 0.17.0 release](https://ziglang.org/download/0.17.0/) and its [Tier 1-3 support table](https://ziglang.org/download/0.17.0/release-notes.html#Support-Table).
