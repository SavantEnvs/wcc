#!/usr/bin/env bash
#
# mayhem/build.sh — build wcc's three ELF tools as Mayhem file-input targets, plus the oracle build.
#
# Upstream has one Makefile per tool (src/{wcc,wld,wldd}/Makefile); the top-level Makefile also
# builds wsh and its git submodules (luajit/openlibm/linenoise), which we neither need nor fetch.
# The per-tool Makefiles hard-code -O2/_FORTIFY_SOURCE/-fstack-protector (and src/wcc/Makefile
# sets CFLAGS with `:=`), so we run their exact compile/link lines here with our flags instead.
#
#   mayhem/out/wld, wcc, wldd  fuzz builds: afl-clang-fast + $SANITIZER_FLAGS + $DEBUG_FLAGS
#                              (AFL-instrumented, ASan+UBSan halting, DWARF 3) — `afl: true` targets
#   mayhem/out/oracle/*        the same tools with plain upstream-style flags, for mayhem/test.sh
#   mayhem/out/fixtures/*      mayhem/testdata/{hello,nostdlib}.c compiled (oracle inputs)
#
# All outputs live under mayhem/out/ (gitignored by mayhem/.gitignore); re-running is idempotent
# and needs no network (every dependency is an apt package baked into the image).
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${AFL_CC:=afl-clang-fast}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
OUT="$SRC/mayhem/out"
mkdir -p "$OUT/oracle" "$OUT/fixtures" "$OUT/obj"

# Upstream's defines (needed before <bfd.h>) and include path; the -Wno-* keep clang 19 from
# turning upstream's int/pointer-conversion warnings (gcc-tolerated) into hard errors.
COMMON="-I$SRC/include -DPACKAGE -DPACKAGE_VERSION -Wno-int-conversion -Wno-incompatible-pointer-types -Wno-incompatible-function-pointer-types -w"
WCC_LIBS="-l:libbfd.a -l:libsframe.a -lz -ldl -liberty -lzstd -lelf -lcapstone"
WLDD_LIBS="-lelf"

# 1) Fuzz builds (AFL-instrumented, sanitized). The input-copy wrapper is mayhem/wld_input_copy.c.
FUZZ="$SANITIZER_FLAGS $DEBUG_FLAGS -O1"
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.c" -o "$OUT/obj/lsan_off.o"
"$AFL_CC" $FUZZ $COMMON -c src/wld/wld.c -o "$OUT/obj/wld.o"
"$AFL_CC" $FUZZ $COMMON -Dmain=wld_original_main -c src/wld/main.c -o "$OUT/obj/wld_main.o"
"$AFL_CC" $FUZZ $COMMON -c "$SRC/mayhem/wld_input_copy.c" -o "$OUT/obj/wld_input_copy.o"
"$AFL_CC" $FUZZ "$OUT/obj/wld_input_copy.o" "$OUT/obj/wld_main.o" "$OUT/obj/wld.o" "$OUT/obj/lsan_off.o" \
  -o "$OUT/wld"
"$AFL_CC" $FUZZ $COMMON src/wcc/wcc.c "$OUT/obj/lsan_off.o" -o "$OUT/wcc" $WCC_LIBS
"$AFL_CC" $FUZZ $COMMON src/wldd/wldd.c "$OUT/obj/lsan_off.o" -o "$OUT/wldd" $WLDD_LIBS

# 2) Oracle build: upstream's normal flags (no sanitizers, no AFL), read by mayhem/test.sh.
ORACLE="-O2 -g $COVERAGE_FLAGS"
"$CC" $ORACLE $COMMON src/wld/wld.c src/wld/main.c -o "$OUT/oracle/wld"
"$CC" $ORACLE $COMMON src/wcc/wcc.c -o "$OUT/oracle/wcc" $WCC_LIBS
"$CC" $ORACLE $COMMON src/wldd/wldd.c -o "$OUT/oracle/wldd" $WLDD_LIBS

# 3) Oracle fixtures.
"$CC" -O0 -fPIE -pie "$SRC/mayhem/testdata/hello.c" -o "$OUT/fixtures/hello-pie"
"$CC" -O0 -fno-pie -no-pie "$SRC/mayhem/testdata/hello.c" -o "$OUT/fixtures/hello-nopie"
"$CC" -O0 -nostdlib -shared -fPIC -Wl,--version-script="$SRC/mayhem/testdata/nostdlib.map" \
  "$SRC/mayhem/testdata/nostdlib.c" -o "$OUT/fixtures/nostdlib.so"

ls -l "$OUT/wld" "$OUT/wcc" "$OUT/wldd" "$OUT/oracle/wld" "$OUT/oracle/wcc" "$OUT/oracle/wldd"
