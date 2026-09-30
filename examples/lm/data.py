#!/usr/bin/env python3
"""Download a dataset, normalise it to the 64-symbol vocabulary of text.py,
and write 2^20 training and 65536 validation characters as code files that
the Plankalkül program reads with @FILE arguments.

    data.py tinystories DIR
    data.py platypus DIR

TinyStories (Eldan & Li 2023, arXiv:2305.07759): the first 3 MB of the
training file and the first 512 KB of the validation file, stories
separated by blank lines.

Open-Platypus (Lee et al. 2023, arXiv:2308.07317): rows formatted as
"question: ...\\nanswer: ...\\n\\n". Pages of 100 rows are assigned to the
validation and then the training split in a fixed pseudo-random order, so
both splits come from the same mixture of sources and do not overlap.

Output: DIR/train.txt, DIR/val.txt (normalised text), DIR/train.codes,
DIR/val.codes (blank-separated codes). Downloads are cached in DIR/raw.
"""
import json
import os
import random
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import text  # noqa: E402

N_TRAIN, N_VAL = 1 << 20, 65536
TS = "https://huggingface.co/datasets/roneneldan/TinyStories/resolve/main/"
PLATYPUS = ("https://datasets-server.huggingface.co/rows?dataset=garage-bAInd/"
            "Open-Platypus&config=default&split=train&offset={}&length=100")


def fetch(url, cache, byte_range=None):
    if not os.path.exists(cache):
        req = urllib.request.Request(url, headers={"User-Agent": "plankc-demo"})
        if byte_range:
            req.add_header("Range", "bytes=%d-%d" % byte_range)
        with urllib.request.urlopen(req, timeout=120) as r, open(cache + ".part", "wb") as f:
            f.write(r.read())
        os.replace(cache + ".part", cache)
    with open(cache, "rb") as f:
        return f.read().decode("utf-8", errors="replace")


def tinystories(raw):
    def load(name, size):
        t = fetch(TS + name, os.path.join(raw, name), (0, size - 1))
        t = t[:t.rfind("<|endoftext|>")]          # drop the cut-off last story
        return text.normalize(t.replace("<|endoftext|>", "\n\n"))
    return load("TinyStories-train.txt", 3 << 20), load("TinyStories-valid.txt", 512 << 10)


def platypus(raw):
    first = json.loads(fetch(PLATYPUS.format(0), os.path.join(raw, "page0.json")))
    pages = list(range((first["num_rows_total"] + 99) // 100))
    random.Random(1945).shuffle(pages)
    splits, current = ["", ""], 0                  # validation first, then training
    for page in pages:
        rows = json.loads(fetch(PLATYPUS.format(page * 100),
                                os.path.join(raw, "page%d.json" % page)))["rows"]
        for r in rows:
            r = r["row"]
            q = r["instruction"] + ("\n" + r["input"] if r["input"].strip() else "")
            splits[current] += text.normalize("question: %s\nanswer: %s\n\n" % (q, r["output"]))
        if current == 0 and len(splits[0]) >= N_VAL:
            current = 1
        elif current == 1 and len(splits[1]) >= N_TRAIN:
            break
    return splits[1], splits[0]


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("tinystories", "platypus"):
        sys.exit(__doc__)
    out = sys.argv[2]
    raw = os.path.join(out, "raw")
    os.makedirs(raw, exist_ok=True)
    train, val = (tinystories if sys.argv[1] == "tinystories" else platypus)(raw)
    if len(train) < N_TRAIN or len(val) < N_VAL:
        sys.exit("data.py: not enough text (%d, %d)" % (len(train), len(val)))
    for name, t, n in (("train", train, N_TRAIN), ("val", val, N_VAL)):
        with open(os.path.join(out, name + ".txt"), "w") as f:
            f.write(t[:n])
        with open(os.path.join(out, name + ".codes"), "w") as f:
            f.write(" ".join(str(text.CODE[c]) for c in t[:n]) + "\n")
    print("%s: %d training and %d validation characters in %s"
          % (sys.argv[1], N_TRAIN, N_VAL, out))


if __name__ == "__main__":
    main()
