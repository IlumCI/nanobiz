#!/usr/bin/env python3
"""Prepare the training stages of examples/lm/curriculum.sh.

    data.py STAGE DIR

writes DIR/train.codes (the training text as blank-separated character codes,
padded with newlines to 2^23 = 8388608 characters), DIR/train.len (its real
length), DIR/val.codes (65536 validation characters) and readable copies
DIR/train.txt and DIR/val.txt. Downloads are cached in DIR/../raw.

Stages
  tinystories  TinyStories (Eldan & Li 2023, arXiv:2305.07759): the first 8.5 MB
               of the training file; validation from the validation file.
  reasoning    basic natural-language reasoning: problems from 20 reasoning-gym
               generators (open-thought/reasoning-gym) mixed with Open-Platypus
               (Lee et al. 2023, arXiv:2308.07317), 3:1 by characters. Validation:
               reasoning-gym problems from a different seed and Open-Platypus
               pages that are not used for training.
  gsm8k        GSM8K (Cobbe et al. 2021, arXiv:2110.14168), all 7473 training
               problems with their worked solutions. Validation loss is measured
               on the start of the test split (loss only; nothing is scored).
  humanevalplus  HumanEval+ (Liu et al. 2023, arXiv:2305.01210): each prompt
               followed by its canonical solution. HumanEval+ has no training
               split: after this stage the model has seen the benchmark and can
               not be evaluated on HumanEval or HumanEval+. Validation uses the
               GSM8K text, to measure forgetting.

reasoning-gym is needed only for the reasoning stage (pip install reasoning-gym).
"""
import json
import os
import random
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import text  # noqa: E402

N_MAX, N_VAL = 1 << 23, 65536
HF = "https://huggingface.co/datasets/"
ROWS = "https://datasets-server.huggingface.co/rows?dataset={}&config={}&split={}&offset={}&length=100"
RG_TASKS = ["basic_arithmetic", "chain_sum", "simple_equations", "leg_counting",
            "family_relationships", "syllogism", "aiw", "letter_counting", "number_sorting",
            "word_sorting", "spell_backward", "calendar_arithmetic", "time_intervals", "gcd",
            "lcm", "fraction_simplification", "prime_factorization", "gsm_symbolic",
            "coin_flip", "count_primes"]


def fetch(url, cache, byte_range=None):
    for attempt in range(8):
        if os.path.exists(cache):
            break
        req = urllib.request.Request(url, headers={"User-Agent": "plankc-demo"})
        if byte_range:
            req.add_header("Range", "bytes=%d-%d" % byte_range)
        try:
            with urllib.request.urlopen(req, timeout=120) as r, open(cache + ".part", "wb") as f:
                f.write(r.read())
            os.replace(cache + ".part", cache)
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == 7:
                raise
            time.sleep(2 ** attempt)                   # rate limited: back off
    with open(cache, "rb") as f:
        return f.read().decode("utf-8", errors="replace")


def rows(raw, dataset, config, split, pages=None):
    """All rows of a split, or the rows of the given 100-row pages."""
    tag = dataset.replace("/", "_") + "_" + config + "_" + split
    first = json.loads(fetch(ROWS.format(dataset, config, split, 0),
                             os.path.join(raw, tag + "_0.json")))
    n_pages = (first["num_rows_total"] + 99) // 100
    for page in (range(n_pages) if pages is None else pages(n_pages)):
        data = json.loads(fetch(ROWS.format(dataset, config, split, page * 100),
                                os.path.join(raw, "%s_%d.json" % (tag, page))))
        for r in data["rows"]:
            yield r["row"]


def qa(question, answer):
    return text.normalize("Question: %s\nAnswer: %s\n\n" % (question.strip(), answer.strip()))


def tinystories(raw):
    def load(name, size):
        t = fetch(HF + "roneneldan/TinyStories/resolve/main/" + name, os.path.join(raw, name),
                  (0, size - 1))
        t = t[:t.rfind("<|endoftext|>")]
        return text.normalize(t.replace("<|endoftext|>", "\n\n").replace("\n\n\n", "\n\n"))
    return load("TinyStories-train.txt", 8_900_000), load("TinyStories-valid.txt", 512 << 10)


def platypus(raw, n_val, n_train):
    order = []

    def pages(n):
        order.extend(range(n))
        random.Random(1945).shuffle(order)
        return order
    splits, current = ["", ""], 0
    for r in rows(raw, "garage-bAInd/Open-Platypus", "default", "train", pages):
        q = r["instruction"] + ("\n" + r["input"] if r["input"].strip() else "")
        splits[current] += qa(q, r["output"])
        if current == 0 and len(splits[0]) >= n_val:
            current = 1
        elif current == 1 and len(splits[1]) >= n_train:
            break
    return splits[1], splits[0]


def reasoning_gym(n_chars, seed):
    import reasoning_gym
    per_task = n_chars // len(RG_TASKS)
    items = []
    for k, task in enumerate(RG_TASKS):
        size, got = 256, []
        while sum(map(len, got)) < per_task:
            ds = reasoning_gym.create_dataset(task, size=size, seed=seed * 1000 + k)
            got = [qa(x["question"], str(x["answer"])) for x in ds]
            size *= 2
        total = 0
        for g in got:
            if total >= per_task:
                break
            items.append(g)
            total += len(g)
    random.Random(seed).shuffle(items)
    return items


def mix(a, b, seed):
    items = a + b
    random.Random(seed).shuffle(items)
    return "".join(items)


def reasoning(raw):
    rg_train, rg_val = reasoning_gym(6_500_000, 1), reasoning_gym(50_000, 2)
    pl_train, pl_val = platypus(raw, 20_000, 2_200_000)
    split = lambda t: [x + "\n\n" for x in t.split("\n\n") if x.strip()]
    return mix(rg_train, split(pl_train), 1), mix(rg_val, split(pl_val), 2)


def gsm8k(raw):
    def load(split):
        return "".join(qa(r["question"], r["answer"])
                       for r in rows(raw, "openai/gsm8k", "main", split))
    return load("train"), load("test")


def humanevalplus(raw):
    train = "".join(text.normalize(r["prompt"] + r["canonical_solution"] + "\n\n")
                    for r in rows(raw, "evalplus/humanevalplus", "default", "test"))
    return train, gsm8k(raw)[1]


STAGES = {"tinystories": tinystories, "reasoning": reasoning, "gsm8k": gsm8k,
          "humanevalplus": humanevalplus}


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in STAGES:
        sys.exit(__doc__)
    out = sys.argv[2]
    raw = os.path.join(os.path.dirname(os.path.abspath(out)), "raw")
    os.makedirs(raw, exist_ok=True)
    train, val = STAGES[sys.argv[1]](raw)
    train = train[:N_MAX]
    if len(train) < 33 or len(val) < N_VAL:
        sys.exit("data.py: not enough text (%d, %d)" % (len(train), len(val)))
    val = val[:N_VAL]
    with open(os.path.join(out, "train.txt"), "w") as f:
        f.write(train)
    with open(os.path.join(out, "val.txt"), "w") as f:
        f.write(val)
    with open(os.path.join(out, "train.len"), "w") as f:
        f.write("%d\n" % len(train))
    with open(os.path.join(out, "train.codes"), "w") as f:
        f.write(" ".join(str(text.CODE[c]) for c in train))
        f.write(" 0" * (N_MAX - len(train)) + "\n")
    with open(os.path.join(out, "val.codes"), "w") as f:
        f.write(" ".join(str(text.CODE[c]) for c in val) + "\n")
    print("%s: %d training characters (padded to %d), %d validation characters, in %s"
          % (sys.argv[1], len(train), N_MAX, len(val), out))


if __name__ == "__main__":
    main()
