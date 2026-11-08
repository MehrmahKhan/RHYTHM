#!/usr/bin/env bash
# Test runner for RHYTHM.
#
# 1. examples: every program in examples/ and tests/programs/ is run with the interpreter and also
#    compiled with rhythmc and run. The printed output, the error output, the
#    exit code and every WAV file must match between the two.
# 2. tests/errors: programs with a mistake the front end must catch. Both the
#    interpreter and the compiler must reject them with exit status 1 and the
#    message named on the first line ("// EXPECT: ..."), and the compiler must
#    not write any IR.
# 3. tests/runtime: programs that are fine to compile but fail while running
#    (division by zero, index out of range ...). The interpreter and the
#    compiled executable must both stop with exit status 1 and the same
#    message on standard error.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1
OUT="$HERE/tests/out"
rm -rf "$OUT"; mkdir -p "$OUT"

pass=0; fail=0
ok()  { echo "  ok    $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "== examples: interpreter against compiled program"
for src in examples/*.rhy tests/programs/*.rhy; do
    name="$(basename "$src" .rhy)"
    mkdir -p "$OUT/$name/interp" "$OUT/$name/comp"

    ( cd "$OUT/$name/interp" && "$HERE/bin/rhythmi" "$HERE/$src" -o out.wav > stdout.txt 2> stderr.txt ); r1=$?
    ( cd "$OUT/$name/comp" && "$HERE/rhythmc" "$HERE/$src" -o prog > build.txt 2>&1 ); rc=$?
    if [ $rc -ne 0 ]; then bad "$name (compile failed, see tests/out/$name/comp/build.txt)"; continue; fi
    ( cd "$OUT/$name/comp" && ./prog -o out.wav > stdout.txt 2> stderr.txt ); r2=$?

    if [ $r1 -ne 0 ] || [ $r2 -ne 0 ]; then bad "$name (exit codes $r1 and $r2)"; continue; fi
    if ! cmp -s "$OUT/$name/interp/stdout.txt" "$OUT/$name/comp/stdout.txt"; then
        bad "$name (printed output differs)"; continue
    fi
    if ! cmp -s "$OUT/$name/interp/stderr.txt" "$OUT/$name/comp/stderr.txt"; then
        bad "$name (error output differs)"; continue
    fi
    same=1
    for f in "$OUT/$name/interp/"*.wav; do
        [ -e "$f" ] || continue
        g="$OUT/$name/comp/$(basename "$f")"
        cmp -s "$f" "$g" || same=0
    done
    nwav=$(ls "$OUT/$name/interp/"*.wav 2>/dev/null | wc -l)
    if [ "$same" = 1 ]; then ok "$name ($nwav wav file(s), output identical)"; else bad "$name (wav files differ)"; fi
done

echo "== errors: both phases must reject the program with the right message"
for src in tests/errors/*.rhy; do
    name="$(basename "$src" .rhy)"
    want="$(head -1 "$src" | sed 's|^// EXPECT: ||')"

    ./bin/rhythmi "$src" -n > "$OUT/$name.interp.txt" 2>&1; r1=$?
    ./bin/rhythm_ir "$src" -o "$OUT/$name.ll" > "$OUT/$name.comp.txt" 2>&1; r2=$?

    if [ $r1 -ne 1 ] || [ $r2 -ne 1 ]; then bad "$name (exit codes $r1 and $r2, expected 1)"; continue; fi
    if ! grep -qF -- "$want" "$OUT/$name.interp.txt"; then bad "$name (interpreter message missing: $want)"; continue; fi
    if ! grep -qF -- "$want" "$OUT/$name.comp.txt";   then bad "$name (compiler message missing: $want)"; continue; fi
    if [ -e "$OUT/$name.ll" ]; then bad "$name (compiler wrote IR for an invalid program)"; continue; fi
    ok "$name"
done

echo "== runtime: both phases must fail the same way while running"
for src in tests/runtime/*.rhy; do
    name="$(basename "$src" .rhy)"
    want="$(head -1 "$src" | sed 's|^// EXPECT: ||')"

    ./bin/rhythmi "$src" -n > "$OUT/$name.interp.out" 2> "$OUT/$name.interp.err"; r1=$?
    if ! ./rhythmc "$src" -o "$OUT/$name.prog" > "$OUT/$name.build.txt" 2>&1; then
        bad "$name (did not compile, it should only fail at run time)"; continue
    fi
    "$OUT/$name.prog" -n > "$OUT/$name.comp.out" 2> "$OUT/$name.comp.err"; r2=$?

    if [ $r1 -ne 1 ] || [ $r2 -ne 1 ]; then bad "$name (exit codes $r1 and $r2, expected 1)"; continue; fi
    if ! grep -qF -- "$want" "$OUT/$name.interp.err"; then bad "$name (interpreter message missing: $want)"; continue; fi
    if ! cmp -s "$OUT/$name.interp.err" "$OUT/$name.comp.err"; then bad "$name (error messages differ)"; continue; fi
    if ! cmp -s "$OUT/$name.interp.out" "$OUT/$name.comp.out"; then bad "$name (printed output differs)"; continue; fi
    ok "$name"
done

echo
echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
