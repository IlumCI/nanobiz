#!/usr/bin/env bash
# Build the Plankalkül transformer, train it on two sentences about Konrad
# Zuse (repeated to 2^20 characters) and let it continue a prompt.
#   run.sh [STEPS] [TEMPERATURE] [OPTIMIZER: muon|adamw] [SEED]
# For natural-language datasets see train.sh.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
steps=${1:-300}; temp=${2:-0}; opt=${3:-muon}; seed=${4:-7}
corpus="konrad zuse designed the plankalkul between 1942 and 1945. it was the \
first high-level programming language. "
prompt="konrad zuse desi"
ulimit -s unlimited 2>/dev/null || ulimit -s 65536 2>/dev/null || true

[ -x "$root/bin/plankc" ] || (cd "$root" && gprbuild -q -P plankc.gpr)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$root/bin/plankc" "$here/transformer.pk" -o "$work/lm"
"$here/text.py" encode 1048576 "$corpus" > "$work/train"
"$here/text.py" encode 65536 "$corpus" > "$work/val"

out=$("$work/lm" "@$work/train" "@$work/val" "$("$here/text.py" encode 16 "$prompt")" \
             "$seed" "$steps" "$temp" "$([ "$opt" = muon ] && echo 1 || echo 0)")
echo "optimizer: $opt, steps: $steps, temperature: $temp"
echo "training loss per tenth: $(sed -n 1p <<<"$out")"
echo "prompt + generated text: $prompt$("$here/text.py" decode "$(sed -n 3p <<<"$out")" | head -c 120)"
