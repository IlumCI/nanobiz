#!/usr/bin/env bash
# Train the Plankalkül transformer through a curriculum of stages, each
# starting from the checkpoint the previous stage wrote:
#
#   1 tinystories     simple English                       12000 steps, peak lr 0.01
#   2 reasoning       reasoning-gym problems + Open-Platypus 12000 steps, peak lr 0.005
#   3 gsm8k           all GSM8K training problems (~1 epoch) 16000 steps, peak lr 0.005
#   4 humanevalplus   HumanEval+ prompts + solutions (~4 epochs) 1500 steps, peak lr 0.003
#
# After stage 4 the model has seen HumanEval+ and must not be evaluated on it.
#
#   curriculum.sh [FIRST_STAGE] [LAST_STAGE] [SCALE] [RUN]
# SCALE multiplies every stage's step count (default 1). Checkpoints and logs
# go to data/RUN (default data/curriculum); stage k continues from
# data/RUN/stage$((k-1)).params (stage 0 = initialisation).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
first=${1:-1}; last=${2:-4}; scale=${3:-1}; run=${4:-curriculum}
stages=(- tinystories reasoning gsm8k humanevalplus)
steps=(- 12000 12000 16000 1500)
lrs=(- 0.01 0.005 0.005 0.003)
prompts=(- "Once upon a time" "Question: What i" "Question: A shop" $'def area(w, h):\n')
ulimit -s unlimited 2>/dev/null || ulimit -s 262144

out=$root/data/$run
mkdir -p "$out"
py=python3; [ -x "$root/data/venv/bin/python" ] && py=$root/data/venv/bin/python
[ -x "$root/bin/plankc" ] || (cd "$root" && gprbuild -q -P plankc.gpr)
"$root/bin/plankc" -O3 "$here/transformer.pk" -o "$out/stage"
"$root/bin/plankc" -O3 --entry initparams "$here/transformer.pk" -o "$out/init"
[ -f "$out/stage0.params" ] || "$out/init" 1 > "$out/stage0.params"

for k in $(seq "$first" "$last"); do
  name=${stages[$k]}; data=$root/data/$name
  [ -f "$data/train.codes" ] || "$py" "$here/data.py" "$name" "$data"
  n=$(awk -v s="${steps[$k]}" -v f="$scale" 'BEGIN { printf "%d", s * f }')
  start=$(date +%s)
  res=$("$out/stage" "@$data/train.codes" "$(cat "$data/train.len")" "@$data/val.codes" \
          "@$out/stage$((k - 1)).params" "$k" "$n" "${lrs[$k]}" 1 \
          "$("$here/text.py" encode 16 "${prompts[$k]}")" 0.8)
  sed -n 3p <<<"$res" > "$out/stage$k.params"
  {
    echo "stage $k: $name, $n steps, peak lr ${lrs[$k]}, Muon, $(( $(date +%s) - start )) s"
    echo "training loss per tenth:   $(sed -n 1p <<<"$res")"
    echo "validation loss per tenth: $(sed -n 2p <<<"$res")"
    echo "--- sample (temperature 0.8) ---"
    printf '%s' "${prompts[$k]}"
    "$here/text.py" decode "$(sed -n 4p <<<"$res")"
  } | tee "$out/stage$k.log"
done
