#!/usr/bin/env bash
# Train the Plankalkül transformer on a natural-language dataset.
#   train.sh DATASET [STEPS] [OPTIMIZER] [SEED] [TEMPERATURE] [PROMPT]
# DATASET: tinystories | platypus. OPTIMIZER: muon | adamw.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
dataset=${1:?usage: train.sh tinystories|platypus [STEPS] [OPTIMIZER] [SEED] [TEMPERATURE] [PROMPT]}
steps=${2:-2000}; opt=${3:-muon}; seed=${4:-1}; temp=${5:-0.8}
case $dataset in
  tinystories) prompt=${6:-"once upon a time"} ;;
  platypus)    prompt=${6:-"question: what is"} ;;
  *) echo "train.sh: unknown dataset $dataset" >&2; exit 2 ;;
esac
ulimit -s unlimited 2>/dev/null || ulimit -s 65536 2>/dev/null || true

data=$root/data/$dataset
[ -f "$data/train.codes" ] || python3 "$here/data.py" "$dataset" "$data"
[ -x "$root/bin/plankc" ] || (cd "$root" && gprbuild -q -P plankc.gpr)
exe=$(mktemp -d)/lm
"$root/bin/plankc" -O3 "$here/transformer.pk" -o "$exe"

out=$("$exe" "@$data/train.codes" "@$data/val.codes" \
             "$("$here/text.py" encode 16 "$prompt")" "$seed" "$steps" "$temp" \
             "$([ "$opt" = muon ] && echo 1 || echo 0)")
echo "dataset: $dataset, optimizer: $opt, steps: $steps, seed: $seed, temperature: $temp"
echo "training loss per tenth:   $(sed -n 1p <<<"$out")"
echo "validation loss per tenth: $(sed -n 2p <<<"$out")"
echo "--- sample ---"
printf '%s' "$("$here/text.py" encode 16 "$prompt" | "$here/text.py" decode)" | tr -d '\n'
"$here/text.py" decode "$(sed -n 3p <<<"$out")"
