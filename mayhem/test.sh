#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

# wcc ships no test suite (src/wcc/Makefile's `test` target only libifies /bin/ls and runs
# `file`). This oracle runs the three tools built by build.sh (normal flags, mayhem/out/oracle/)
# on the fixtures build.sh compiled from mayhem/testdata/, and checks their OUTPUT with the
# system readelf: a no-op tool leaves its input unchanged / writes nothing / prints nothing, so
# every case fails. Missing binaries or fixtures are failures, never skips.
O="$SRC/mayhem/out/oracle"
F="$SRC/mayhem/out/fixtures"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wcc-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
command -v readelf >/dev/null || { echo "FATAL: readelf missing" >&2; exit 1; }

passed=0; failed=0
check() {  # check <name> <command...>: the command must succeed
  local name="$1"; shift
  if ( "$@" ) >"$WORK/$name.log" 2>&1; then
    echo "PASS $name"; passed=$((passed + 1))
  else
    echo "FAIL $name"; sed 's/^/    /' "$WORK/$name.log" | tail -20; failed=$((failed + 1))
  fi
}

# wld -l (sections mode): a PIE becomes a shared object, and DF_1_PIE is cleared.
t_wld_sections() {
  cp "$F/hello-pie" "$WORK/a"
  readelf -h "$WORK/a" | grep -q 'Type: *DYN (Position-Independent Executable file)'
  readelf -d "$WORK/a" | grep -q 'FLAGS_1) *Flags: PIE'
  "$O/wld" -l "$WORK/a"
  readelf -h "$WORK/a" | grep -q 'Type: *DYN (Shared object file)'
  readelf -d "$WORK/a" | grep -q 'FLAGS_1) *Flags: None'
}
# wld -l -S (segments mode): same result reached via PT_DYNAMIC.
t_wld_segments() {
  cp "$F/hello-pie" "$WORK/b"
  "$O/wld" -l -S "$WORK/b"
  readelf -h "$WORK/b" | grep -q 'Type: *DYN (Shared object file)'
  readelf -d "$WORK/b" | grep -q 'FLAGS_1) *Flags: None'
}
# wld -l -n (no-init): the constructor/destructor arrays are emptied (DT_INIT_ARRAY/SZ = 0).
t_wld_noinit() {
  cp "$F/hello-pie" "$WORK/c"
  readelf -d "$WORK/c" | grep -q '(INIT_ARRAYSZ) *8 (bytes)'
  "$O/wld" -l -n "$WORK/c"
  readelf -d "$WORK/c" | grep -q '(INIT_ARRAYSZ) *0 (bytes)'
  readelf -d "$WORK/c" | grep -q '(FINI_ARRAYSZ) *0 (bytes)'
  readelf -d "$WORK/c" | grep -q '(INIT_ARRAY) *0x0$'
}
# wldd: prints the DT_NEEDED libraries as linker flags.
t_wldd() {
  out="$("$O/wldd" "$F/hello-pie")"
  [ "$(echo "$out" | tr -d '[:space:]')" = "-lc" ]
}
# wcc -c: relocatable object exporting the fixture's function (text) and data symbols.
t_wcc_reloc() {
  ( cd "$WORK" && "$O/wcc" -c -o reloc.o "$F/nostdlib.so" )
  readelf -h "$WORK/reloc.o" | grep -q 'Type: *REL (Relocatable file)'
  readelf -Ws "$WORK/reloc.o" | grep -Eq 'FUNC +GLOBAL +DEFAULT +[0-9]+ mayhem_add$|NOTYPE +GLOBAL +DEFAULT +[0-9]+ mayhem_add$'
  readelf -Ws "$WORK/reloc.o" | grep -Eq ' [0-9]+ mayhem_answer$'
  # .data keeps the fixture's initial values {42, 7}
  readelf -x .data "$WORK/reloc.o" | grep -q '2a000000 00000000 07000000 00000000'
}
# wcc (shared mode) on a PIE: output is an ELF that still exports mayhem_add.
t_wcc_shared() {
  ( cd "$WORK" && "$O/wcc" -o shared.out "$F/nostdlib.so" )
  readelf -h "$WORK/shared.out" 2>/dev/null | grep -q 'Class: *ELF64'
  readelf -Ws "$WORK/shared.out" 2>/dev/null | grep -q ' mayhem_add$'
}

check wld_sections t_wld_sections
check wld_segments t_wld_segments
check wld_noinit   t_wld_noinit
check wldd_needed  t_wldd
check wcc_reloc    t_wcc_reloc
check wcc_shared   t_wcc_shared

emit_ctrf "wcc-cli-kat" "$passed" "$failed" 0
