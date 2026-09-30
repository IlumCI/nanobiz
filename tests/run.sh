#!/usr/bin/env bash
# Test driver for plankc.
#   tests/pass/*.pk  lines "# run: ARGS => EXPECTED" (output lines joined by " / ";
#                    "!N" expects exit status N)
#   tests/fail/*.pk  one line "# error: TEXT"; compilation must fail with TEXT
#   examples/*.pk    same "# run:" convention as tests/pass
set -u
cd "$(dirname "$0")/.."
PLANKC=${PLANKC:-bin/plankc}
OUT=tests/out
mkdir -p "$OUT"
pass=0; fail=0

report() { if [ "$1" = ok ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi; }

run_file() {
  local f=$1 exe="$OUT/$(basename "${f%.pk}")"
  for opt in -O0 -O2; do
    if ! "$PLANKC" "$opt" "$f" -o "$exe" 2>"$OUT/err"; then
      report fail "$f ($opt): compile error: $(cat "$OUT/err")"; continue
    fi
    while IFS= read -r line; do
      local spec=${line#\# run: } status got
      local args=${spec%% => *} want=${spec#* => }
      # shellcheck disable=SC2086
      "$exe" $args >"$OUT/stdout" 2>/dev/null; status=$?
      got=$(awk 'NR>1{printf " / "}{printf "%s",$0}' "$OUT/stdout")
      if [[ $want == !* ]]; then
        [ "$status" = "${want#!}" ] && report ok || report fail "$f ($opt) [$args]: want exit ${want#!}, got $status"
      elif [ "$status" = 0 ] && [ "$got" = "$want" ]; then report ok
      else report fail "$f ($opt) [$args]: want '$want', got '$got' (exit $status)"; fi
    done < <(grep '^# run: ' "$f")
  done
}

for f in tests/pass/*.pk examples/*.pk; do run_file "$f"; done

# Transformer demo (examples/lm): analytic vs numerical gradient, forward
# pass vs an independent numpy implementation, and a short training run.
lm=examples/lm/transformer.pk
if "$PLANKC" --entry gradcheck "$lm" -o "$OUT/gc" 2>"$OUT/err"; then
  for seed in 42 5; do
    res=$("$OUT/gc" "$seed" 37); err=$(sed -n 1p <<<"$res"); loss=$(sed -n 2p <<<"$res")
    if awk -v e="$err" 'BEGIN { exit !(e < 1e-4) }'; then report ok
    else report fail "lm gradcheck seed $seed: max relative error $err"; fi
    if python3 -c 'import numpy' 2>/dev/null; then
      ref=$(python3 examples/lm/reference.py "$seed")
      if awk -v a="$loss" -v b="$ref" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d < 1e-12) }'
      then report ok; else report fail "lm forward seed $seed: plankalkul $loss, numpy $ref"; fi
    else
      echo "note: numpy not installed, skipping the lm reference comparison"
    fi
  done
else
  report fail "$lm: compile error: $(cat "$OUT/err")"
fi
lmout=$(examples/lm/run.sh 150 0 muon 7 2>&1)
last=$(sed -n 's/^training loss per tenth: //p' <<<"$lmout" | awk -F, '{ print $NF }')
if awk -v l="$last" 'BEGIN { exit !(l != "" && l < 0.8) }'; then report ok
else report fail "lm training: final loss '$last'"; fi
if grep -q 'konrad zuse designed the plankalkul' <<<"$lmout"; then report ok
else report fail "lm generation: $(tail -1 <<<"$lmout")"; fi

for f in tests/fail/*.pk; do
  want=$(sed -n 's/^# error: //p' "$f")
  if "$PLANKC" -S "$f" -o "$OUT/x.ll" 2>"$OUT/err"; then
    report fail "$f: compiled, expected error '$want'"
  elif grep -qF -- "$want" "$OUT/err"; then report ok
  else report fail "$f: want error '$want', got '$(cat "$OUT/err")'"; fi
done

echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
