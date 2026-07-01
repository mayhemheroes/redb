#!/usr/bin/env bash
#
# mayhem/build.sh — build redb's cargo-fuzz target(s) as sanitized libFuzzer
# binaries (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), plus the
# project's own test suite (normal flags) so mayhem/test.sh only RUNS it.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo
# (pinned by the Dockerfile ENV — absolute, $HOME-independent).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry under $CARGO_HOME.
#   - The PATCH re-run resolves crates from that cache. The rlenv runtime exports
#     CARGO_NET_OFFLINE=true for the re-run so cargo won't try to refresh the
#     crates.io index over the (absent) network — so do NOT hard-code `--offline`
#     here (it would break this first, online build).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# redb's `rust-toolchain` file pins STABLE 1.89, which rustup would honour over our
# nightly default — but cargo-fuzz needs nightly (-Zsanitizer=address). Force the pinned
# nightly for this build so the -Z flags are accepted. RUSTUP_TOOLCHAIN overrides the
# repo's rust-toolchain file. The channel name comes from the Dockerfile ENV.
export RUSTUP_TOOLCHAIN="${RUST_TOOLCHAIN_CHANNEL:-nightly}"

# ── sanitizer + debug-info contract ────────────────────────────────────────────
# Rust instruments via RUSTFLAGS, not clang's $SANITIZER_FLAGS/$CFLAGS (rustc ignores
# those). We keep the $SANITIZER_FLAGS knob referenced so the fleet "turn sanitizers
# off" override (--build-arg SANITIZER_FLAGS=) is honoured: when it's emptied we drop
# -Zsanitizer=address for a natural-crash build; otherwise ASan is on (the default).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all}"
RUST_SANITIZER=""
case "$SANITIZER_FLAGS" in
  *address*|*fsanitize*) RUST_SANITIZER="-Zsanitizer=address" ;;
esac

# §6.2 item 10: fuzz binaries must carry DWARF < 4 (Mayhem's triage can't read >= 4;
# rustc's default emits DWARF-4+, and the ASan runtime archive is DWARF5). Thread
# $RUST_DEBUG_FLAGS with the cc-wrapper anchor (built in the Dockerfile) so a DWARF3
# CU lands first; the rlenv PATCH tier may prepend more debuginfo — we don't fight it.
: "${RUST_DEBUG_FLAGS:=-Cdebuginfo=2 -Zdwarf-version=3 -Clinker=/opt/mayhem-dwarf3-anchor/cc-wrapper.sh}"

export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing ${RUST_SANITIZER} -Cforce-frame-pointers ${RUST_DEBUG_FLAGS}"

# redb ships its own cargo-fuzz crate at fuzz/ — it builds on the pinned nightly, so
# we use it directly (no additive mayhem/fuzz/ crate needed).
FUZZ_DIR="fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
# common.rs is a shared module (`mod common;`), NOT a #[fuzz_target] binary — skip it.
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  name="$(basename "${f%.*}")"
  [ "$name" = common ] && continue
  FUZZ_TARGETS+=("$name")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# Use the image's DEFAULT toolchain (the Dockerfile pinned it). A `+toolchain`
# override would make rustup try to install another channel into the locked /opt/rust.
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# ── project test suite (for mayhem/test.sh) ─────────────────────────────────────
# Compile redb's own integration + unit tests with the project's NORMAL flags (clean,
# non-sanitized, no fuzzing cfg) so test.sh only RUNS them. Clear RUSTFLAGS so the test
# build isn't ASan/fuzzing-instrumented.
#
# Disambiguate the package: redb's dev-dependency pins a SECOND `redb` (redb2_6 =
# {package="redb", version="=2.6.0"}) for backwards-compat KATs, so a bare `-p redb`
# is ambiguous ("multiple redb packages"). Pin the ROOT crate by its exact version,
# read from the top-level Cargo.toml so it survives upstream version bumps.
REDB_PKG="redb@$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$SRC/Cargo.toml" | head -1)"
echo "=== cargo test --no-run ($REDB_PKG, normal flags) ==="
env -u RUSTFLAGS cargo test --no-run -p "$REDB_PKG" --lib --tests

echo "build.sh complete"
