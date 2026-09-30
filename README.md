# plankc: a Plankalkül compiler in Ada

`plankc` compiles Konrad Zuse's Plankalkül (designed 1942–45, published 1972) to native
executables. The front end is written in Ada 2022. The back end emits LLVM IR in SSA form,
and clang/LLVM optimise it and generate machine code.

Input uses the **linear notation** from the Free University of Berlin implementation
(R. Rojas et al., *Plankalkül: The First High-Level Programming Language and its
Implementation*, 2000), with the extensions listed below. Zuse's two-dimensional notation,
with its stacked V/K/S rows, is not parsed.

## Build

Requirements: GNAT (Ada 2022, tested with GCC 13), gprbuild, and clang/LLVM 15 or later
(opaque pointers; tested with 18).

```
gprbuild -P plankc.gpr          # produces bin/plankc
tests/run.sh                    # compiles and runs every test at -O0 and -O2
```

## Usage

```
bin/plankc examples/max3.pk            # builds examples/max3
examples/max3 3 200 17                 # prints 200
bin/plankc -S examples/max3.pk         # writes examples/max3.ll
```

Options: `-o FILE`, `-S`/`--emit-llvm`, `--entry NAME` (plan run by `main`, default: the
first plan), `-O0`..`-O3`, `--clang PATH`, `--keep-ll`.

The executable takes one command-line argument per parameter of the entry plan. Values are
decimal or `0x` hexadecimal. An array is given as comma-separated values of its leaf words
in row-major order. Each result is printed on its own line, arrays comma-separated. Bad
input or a runtime error prints a message to stderr and exits with status 1. A wrong
number of arguments exits with status 2.

## Language

```
P1 max3 (V0[:8.0], V1[:8.0], V2[:8.0]) → R0[:8.0]
  max(V0[:8.0], V1[:8.0]) → Z1[:8.0]
  max(Z1[:8.0], V2[:8.0]) → R0[:8.0]
END

P2 max (V0[:8.0], V1[:8.0]) → R0[:8.0]
  V0[:8.0] → Z1[:8.0]
  (Z1[:8.0] < V1[:8.0]) → V1[:8.0] → Z1[:8.0]
  Z1[:8.0] → R0[:8.0]
END
```

**Plans (Rechenpläne).** Header: `P<n> [name] (V<k>[:T], ...) → R<k>[:T], ...`. Several
results may be enclosed in parentheses. The body is terminated by `END`. A plan is called
as `name(args)` or `P<n>(args)`. Recursion is allowed.

**Variables.**

| Class | Meaning |
|---|---|
| `V<k>` | input; read-only |
| `Z<k>` | intermediate; the type is declared at first textual use as `Z<k>[:T]` and the initial value is 0 |
| `R<k>` | result; initial value 0 |
| `i`, `i<d>` | index of the innermost W1/W2 loop, or of the loop at nesting depth `d` (`i0` is the outermost); read-only |

**Types (Strukturen).**

| Notation | Meaning |
|---|---|
| `0` | one bit |
| `n.0` | word of n bits, used as an unsigned integer (n ≤ 64). A wider `n.0` is an array of n bits. |
| `m.T` | array of m components of type T, e.g. `8.16.0` (eight 16-bit words), `2.3.8.0` |

**Components.** `X[e]` selects array component `e`, or bit `e` of a word (bit 0 is the
least significant). `X[e:T]` also states the component type, which the compiler checks.
Selectors chain: `V0[i0][i1]`. Out-of-range indices are rejected at compile time when they
are literals, and trap at run time otherwise.

**Statements.**

| Form | Meaning |
|---|---|
| `e → X` | assignment. A word value is zero-extended or truncated to the target width. Arrays must have the same type. |
| `plan(args) → X, Y` | assigns the results of a plan with several results |
| `c → statement` | conditional statement; `c` must be of type `0`. Chains are allowed: `c → e → X`. |
| `[ statements ]` | block |
| `W [ ... ]` | repeat until `FIN` |
| `W (c) [ ... ]` | repeat while `c` (extension) |
| `W1(n) [ ... ]` / `W2(n) [ ... ]` | repeat n times, with `i` counting up from 0 / down to 0 |
| `FIN` | leave the innermost loop |

Statements are separated by line breaks or `;`. Comments start with `#` or `//`.

**Expressions.** Word arithmetic is unsigned and modulo 2^width. Operands of different widths
are zero-extended to the wider one. An untyped literal takes the type of the other operand
and must fit in it. Precedence, from lowest to highest:

| Level | Operators |
|---|---|
| 1 | `∨` `\|` |
| 2 | `⊕` `^` |
| 3 | `∧` `&` |
| 4 | `=` `≠` `!=` `<` `≤` `<=` `>` `≥` `>=` (not chainable; the result has type `0`) |
| 5 | `+` `-` |
| 6 | `×` `*` `/` `÷` `%` |
| 7 | unary `-`, `¬` `!` `~` |

The arrow may be written `→`, `->`, `⇒` or `=>`. Division by zero traps.

## Design

```
source ─ PK.Lexer ─ PK.Parser ─ AST ─ PK.Sema ─ PK.Codegen ─ LLVM IR ─ clang ─ executable
```

- Each plan becomes an internal LLVM function. Word parameters are passed by value, arrays
  by `noalias readonly` pointer, and results through out pointers.
- Variables are stack slots with explicit loads and stores. LLVM's mem2reg/SROA passes turn
  them into SSA registers, which is the standard front-end strategy for LLVM. In the example
  above, `max3` becomes two `llvm.umax.i8` intrinsics at `-O2`.
- Words map to LLVM's arbitrary-width integers (`i1` to `i64`), so a `5.0` word gets exact
  5-bit wrap-around semantics.
- Runtime checks (index range, division by zero, input parsing) call a cold, `noreturn`
  trap function. The error message includes the source position.

## Not implemented

- Zuse's two-dimensional notation.
- Floating-point numbers.
- Tuples and records of mixed component types.
- Signed words.
- Assertions.
- Named constants.
