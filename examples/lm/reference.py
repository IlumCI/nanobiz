#!/usr/bin/env python3
"""Independent numpy implementation of examples/lm/transformer.pk.

Reproduces the random parameters and sequence of the Plankalkül entry plan
`gradcheck` for a given seed and prints the loss, which must agree with R1
of `gradcheck` to rounding error. It checks the forward pass (embedding,
RMSNorm, rotary embedding, causal attention, SwiGLU, tied output layer,
cross-entropy) and the random number generator against numpy's own
exp/log/sqrt/sin/cos.

usage: reference.py SEED
"""
import sys
import numpy as np

M64 = (1 << 64) - 1
V, T, D, H, DH, F = 28, 16, 16, 2, 8, 32
OFF = dict(E=0, g1=448, Wq=464, Wk=720, Wv=976, Wo=1232, g2=1488,
           W1=1504, W3=2016, W2=2528, gf=3040)


def rng(x):
    x ^= x >> 12
    x ^= (x << 25) & M64
    x ^= x >> 27
    return x, (((x * 2685821657736338717) & M64) >> 11) * 2.0 ** -53


def init(seed):
    s = seed ^ 0x9E3779B97F4A7C15 or 1
    p = np.empty(3056)
    for i in range(3056):
        s, u = rng(s)
        std = 0.1767766952966369 if 2528 <= i < 3040 else 0.25
        p[i] = (u * 2 - 1) * 1.7320508075688772 * std
        if 448 <= i < 464 or 1488 <= i < 1504 or i >= 3040:
            p[i] = 1.0
    return p, s


def mat(p, name, r, c):
    return p[OFF[name]:OFF[name] + r * c].reshape(r, c)


def rmsnorm(x, g):
    return x / np.sqrt((x * x).mean(axis=1, keepdims=True) + 1e-5) * g


def rope(x):
    t = np.arange(T)[:, None]
    theta = 10000.0 ** (-np.arange(4) / 4)
    ang = t * theta                                    # T × 4
    c, s = np.cos(ang), np.sin(ang)
    y = x.copy()
    for h in range(H):
        e = h * DH + 2 * np.arange(4)
        y[:, e] = x[:, e] * c - x[:, e + 1] * s
        y[:, e + 1] = x[:, e] * s + x[:, e + 1] * c
    return y


def loss(p, seq):
    E = mat(p, "E", V, D)
    x = E[seq[:T]]
    n1 = rmsnorm(x, p[448:464])
    q = rope(n1 @ mat(p, "Wq", D, D))
    k = rope(n1 @ mat(p, "Wk", D, D))
    v = n1 @ mat(p, "Wv", D, D)
    o = np.zeros((T, D))
    mask = np.tril(np.ones((T, T), dtype=bool))
    for h in range(H):
        sl = slice(h * DH, (h + 1) * DH)
        s = q[:, sl] @ k[:, sl].T / np.sqrt(DH)
        s = np.where(mask, s, -np.inf)
        a = np.exp(s - s.max(axis=1, keepdims=True))
        a /= a.sum(axis=1, keepdims=True)
        o[:, sl] = a @ v[:, sl]
    h1 = x + o @ mat(p, "Wo", D, D)
    n2 = rmsnorm(h1, p[1488:1504])
    a1, a3 = n2 @ mat(p, "W1", D, F), n2 @ mat(p, "W3", D, F)
    y = h1 + (a1 / (1 + np.exp(-a1)) * a3) @ mat(p, "W2", F, D)
    lg = rmsnorm(y, p[3040:3056]) @ E.T
    m = lg.max(axis=1, keepdims=True)
    lse = (m + np.log(np.exp(lg - m).sum(axis=1, keepdims=True)))[:, 0]
    return float(np.mean(lse - lg[np.arange(T), seq[1:]]))


def main():
    p, s = init(int(sys.argv[1]))
    for i in range(3056):                              # as in plan gradcheck
        s, u = rng(s)
        p[i] += 0.2 * (u - 0.5)
    seq = []
    for _ in range(17):
        s, u = rng(s)
        seq.append(int(u * 28.0))
    print(repr(loss(p, np.array(seq))))


if __name__ == "__main__":
    main()
