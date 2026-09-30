#!/usr/bin/env bash
# Train the recurrent-depth model (recurrent.pk) through a curriculum; each
# stage starts from the checkpoint of the previous one.
#
#   1 tinystories    simple English                              12000 steps, lr 0.01
#   2 reasoning      reasoning-gym problems + Open-Platypus      12000 steps, lr 0.005
#   3 gsm8k          all GSM8K training problems, written out    16000 steps, lr 0.005
#   4 coconut1       first reasoning line as 1 continuous thought  2000 steps, lr 0.003
#   5 coconut2       first 2 lines as 2 continuous thoughts        2000 steps, lr 0.003
#   6 coconut3       first 3 lines as 3 continuous thoughts        2000 steps, lr 0.003
#   7 humanevalplus  HumanEval+ prompts + solutions               1500 steps, lr 0.003
#
# Stages 1-3 and 7 match curriculum.sh for comparison with the dense model.
# After stage 7 the model has seen HumanEval+ and must not be evaluated on it.
#
#   curriculum-recurrent.sh [FIRST_STAGE] [LAST_STAGE] [SCALE] [RUN]
# Checkpoints and logs go to data/RUN (default data/curriculum-recurrent).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
first=${1:-1}; last=${2:-7}; scale=${3:-1}; run=${4:-curriculum-recurrent}
stages=(- tinystories reasoning gsm8k coconut1 coconut2 coconut3 humanevalplus)
steps=(- 12000 12000 16000 2000 2000 2000 1500)
lrs=(- 0.01 0.005 0.005 0.003 0.003 0.003 0.003)
thoughts=(- 0 0 0 1 2 3 0)
prompts=(- "Once upon a time" "Question: What i" "Question: A shop" \
         $'e left?\nAnswer: ' $'e left?\nAnswer: ' $'e left?\nAnswer: ' $'def area(w, h):\n')
ulimit -s unlimited 2>/dev/null || ulimit -s 262144

out=$root/data/$run
mkdir -p "$out"
py=python3; [ -x "$root/data/venv/bin/python" ] && py=$root/data/venv/bin/python
[ -x "$root/bin/plankc" ] || (cd "$root" && gprbuild -q -P plankc.gpr)
"$root/bin/plankc" -O3 "$here/recurrent.pk" -o "$out/stage"
"$root/bin/plankc" -O3 --entry cocostage "$here/recurrent.pk" -o "$out/cocostage"
"$root/bin/plankc" -O3 --entry initparams "$here/recurrent.pk" -o "$out/init"
[ -f "$out/stage0.params" ] || "$out/init" 1 > "$out/stage0.params"

for k in $(seq "$first" "$last"); do
  name=${stages[$k]}; data=$root/data/$name
  n=$(awk -v s="${steps[$k]}" -v f="$scale" 'BEGIN { printf "%d", s * f }')
  prompt=$("$here/text.py" encode 16 "${prompts[$k]}")
  start=$(date +%s)
  if [ "${thoughts[$k]}" -gt 0 ]; then
    [ -f "$data/train.records" ] || "$py" "$here/data.py" "$name" "$data"
    res=$("$out/cocostage" "@$data/train.records" "$(cat "$data/train.count")" "@$data/val.codes" \
            "@$out/stage$((k - 1)).params" "$k" "$n" "${lrs[$k]}" 1 "$prompt" 0.8 3 "${thoughts[$k]}")
  else
    [ -f "$data/train.codes" ] || "$py" "$here/data.py" "$name" "$data"
    res=$("$out/stage" "@$data/train.codes" "$(cat "$data/train.len")" "@$data/val.codes" \
            "@$out/stage$((k - 1)).params" "$k" "$n" "${lrs[$k]}" 1 "$prompt" 0.8 3)
  fi
  sed -n 3p <<<"$res" > "$out/stage$k.params"
  {
    echo "stage $k: $name, $n steps, peak lr ${lrs[$k]}, Muon, thoughts ${thoughts[$k]}, $(( $(date +%s) - start )) s"
    echo "training loss per tenth:   $(sed -n 1p <<<"$res")"
    echo "validation loss per tenth: $(sed -n 2p <<<"$res")"
    echo "--- sample (temperature 0.8, r = 3) ---"
    printf '%s' "${prompts[$k]}"
    "$here/text.py" decode "$(sed -n 4p <<<"$res")"
  } | tee "$out/stage$k.log"
done
