#!/usr/bin/env bash
#
# mayhem/test.sh — RUN redb's OWN functional test suite (compiled by mayhem/build.sh
# with `cargo test --no-run`). This only RUNS the pre-built tests; it does not build.
#
# redb's tests are real behavioral assertions (round-trip reads/writes, savepoint
# restore, multimap semantics, crash-recovery invariants, backwards-compat KATs) — a
# PATCH that neuters the library to a no-op makes these assertions FAIL, so this is a
# genuine oracle, not an exit-0 check.
#
# Emits a CTRF (https://ctrf.io) summary and exits non-zero iff failed>0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"
# Pin the same toolchain build.sh used (redb's rust-toolchain file pins stable 1.89;
# match build.sh's nightly so cargo re-uses the already-compiled test artifacts).
export RUSTUP_TOOLCHAIN="${RUST_TOOLCHAIN_CHANNEL:-nightly}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# RUN the pre-built tests. env -u RUSTFLAGS mirrors the build.sh test compile so cargo
# re-uses the same (non-sanitized) artifacts instead of recompiling with fuzzing flags.
# Disambiguate the root redb crate from the pinned redb2_6 backwards-compat dep (both
# are `redb` packages) by its exact version, read from the top-level Cargo.toml.
REDB_PKG="redb@$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$SRC/Cargo.toml" | head -1)"
LOG="$(mktemp)"
env -u RUSTFLAGS cargo test -p "$REDB_PKG" --lib --tests 2>&1 | tee "$LOG"
run_rc="${PIPESTATUS[0]}"

# cargo prints one "test result: ok. N passed; M failed; K ignored; ..." line per test
# binary. Sum them across all binaries for the aggregate counts.
passed=$(grep -oE 'test result: [a-zA-Z]+\. [0-9]+ passed' "$LOG" | grep -oE '[0-9]+ passed' | awk '{s+=$1} END{print s+0}')
failed=$(grep -oE '[0-9]+ failed' "$LOG" | awk '{s+=$1} END{print s+0}')
ignored=$(grep -oE '[0-9]+ ignored' "$LOG" | awk '{s+=$1} END{print s+0}')
rm -f "$LOG"

# Guard: if cargo itself failed (compile error / runner missing) but reported no test
# result lines, surface that as a failure rather than a spurious pass.
if [ "$run_rc" -ne 0 ] && [ "$failed" -eq 0 ] && [ "$passed" -eq 0 ]; then
  failed=1
fi

emit_ctrf "cargo-test" "$passed" "$failed" "$ignored"
