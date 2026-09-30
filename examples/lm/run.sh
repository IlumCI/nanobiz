#!/usr/bin/env bash
# Build the Plankalkül transformer, train it on two sentences about Konrad
# Zuse and let it continue a prompt. For real datasets see curriculum.sh.
#   run.sh [STEPS] [TEMPERATURE] [OPTIMIZER: muon|adamw] [SEED]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
steps=${1:-300}; temp=${2:-0}; opt=${3:-muon}; seed=${4:-7}
corpus="Konrad Zuse designed the Plankalkül between 1942 and 1945. It was the \
first high-level programming language. "
prompt="Konrad Zuse desi"
ulimit -s unlimited 2>/dev/null || ulimit -s 262144

[ -x "$root/bin/plankc" ] || (cd "$root" && gprbuild -q -P plankc.gpr)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$root/bin/plankc" "$here/transformer.pk" -o "$work/stage"
"$root/bin/plankc" --entry initparams "$here/transformer.pk" -o "$work/init"
"$work/init" "$seed" > "$work/init.params"
{ "$here/text.py" encode 65536 "$corpus"; awk -v n=$(( (1 << 23) - 65536 )) 'BEGIN { for (i = 0; i < n; i++) print 0 }'; } > "$work/train"
"$here/text.py" encode 65536 "$corpus" > "$work/val"

out=$("$work/stage" "@$work/train" 65536 "@$work/val" "@$work/init.params" "$seed" "$steps" 0.01 \
        "$([ "$opt" = muon ] && echo 1 || echo 0)" "$("$here/text.py" encode 16 "$prompt")" "$temp")
echo "optimizer: $opt, steps: $steps, temperature: $temp"
echo "training loss per tenth: $(sed -n 1p <<<"$out")"
echo "prompt + generated text: $prompt$("$here/text.py" decode "$(sed -n 4p <<<"$out")" | head -c 120)"
