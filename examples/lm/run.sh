#!/usr/bin/env bash
# Build the Plankalkül transformer, train it on a text and let it write.
#   run.sh [STEPS] [TEMPERATURE] [OPTIMIZER: muon|adamw] [SEED]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$here/../..
steps=${1:-600}; temp=${2:-0}; opt=${3:-muon}; seed=${4:-7}
corpus="konrad zuse designed the plankalkul between nineteen fortytwo and \
nineteen fortyfive. it was the first high level programming language. "
prompt="konrad z"

[ -x "$root/bin/plankc" ] || (cd "$root" && gprbuild -q -P plankc.gpr)
exe=$(mktemp -d)/lm
"$root/bin/plankc" "$here/transformer.pk" -o "$exe"

out=$("$exe" "$("$here/text.sh" encode 256 "$corpus")" \
             "$("$here/text.sh" encode 8 "$prompt")" \
             "$seed" "$steps" "$temp" "$([ "$opt" = muon ] && echo 1 || echo 0)")
echo "optimizer: $opt, steps: $steps, temperature: $temp"
echo "loss by tenth of training: $(sed -n 1p <<<"$out")"
echo "prompt + generated text:   $prompt$("$here/text.sh" decode "$(sed -n 2p <<<"$out")")"
