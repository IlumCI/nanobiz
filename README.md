# plankc: a Plankalkül compiler in Ada

`plankc` compiles Konrad Zuse's Plankalkül (designed 1942–45, published 1972) to native
executables. The front end is written in Ada 2022. The back end emits LLVM IR in SSA form,
and clang/LLVM optimise it and generate machine code.

Programs can be written in Zuse's **two-dimensional notation**, with V/K/S rows under each
variable, or in the **linear notation** of the Free University of Berlin implementation
(R. Rojas et al., *Plankalkül: The First High-Level Programming Language and its
Implementation*, 2000). Both can be mixed in one file. The 2D blocks are translated into
linear notation before parsing; `plankc --linear FILE` prints that translation.

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
first plan), `-O0`..`-O3`, `--clang PATH`, `--keep-ll`, `--no-assertions`, `--linear`.

The executable takes one command-line argument per parameter of the entry plan.
- **Input values:** unsigned words are decimal or `0x` hexadecimal, signed words may start
  with `-`, and floating-point values use C `strtod` syntax.
- **Structures:** an array or record is given as the comma-separated values of its leaves
  in declaration order.
- **Output:** each result is printed on its own line, with structures comma-separated.
  Floating-point values are printed with the shortest `%g` precision that reads back to the
  same value.
- **Errors:** bad input, a runtime error or a failed assertion prints a message to stderr
  and exits with status 1. A wrong number of arguments exits with status 2.

## Language

### Two-dimensional notation

This is the layout Zuse used in 1945. A main row holds the statement. Each variable letter
has its subscripts in rows below it:

```
P1 max  | (V,   V)   ⇒ R
      V |  0    1      0
      S |  8.0  8.0    8.0

        | (Z   < V)   → V   ⇒ Z
      V |  1     1      1     1
      S |  8.0   8.0    8.0   8.0
```

| Row | Contents |
|---|---|
| main | a statement or plan header; the text before `\|` is kept as a prefix (e.g. `P1 max`) |
| `V` | variable number |
| `K` | component, possibly a dotted path such as `2.3` or `i0.i1` |
| `S` (or `A`) | structure (type) of the variable or of the selected component |

- **Which letters are variables:** every standalone `V`, `Z`, `R` or `i` in the main row.
- **Which variable a subscript belongs to:** each subscript entry (a run of non-blank
  characters) belongs to the one variable whose letter lies within the entry's columns.
  If the entry lies under no variable or under several, that is an error.
- **Columns:** they count Unicode code points; tabs advance to multiples of 8.
- **Mixing notations:** 2D blocks and linear lines can be mixed freely. Linear-notation
  variables such as `V0` in a main row are left unchanged.
- **Diagnostics:** line numbers refer to the original file. Columns inside a translated
  block refer to the translated line.

The block `| Z + V ⇒ R` with the rows `V | 0 1 0`, `K | 1` (under Z) and `S | 0 8.0 8.0`
becomes `Z0[1:0] + V1[:8.0] ⇒ R0[:8.0]`.

### Linear notation

```
P1 max3 (V0[:8.0], V1[:8.0], V2[:8.0]) → R0[:8.0]
  max(V0[:8.0], V1[:8.0]) → Z1[:8.0]
  max(Z1[:8.0], V2[:8.0]) → R0[:8.0]
END
```

**Plans (Rechenpläne).** Header: `P<n> [name] (V<k>[:T], ...) → R<k>[:T], ...`. Several
results may be enclosed in parentheses. The body is terminated by `END`. A plan is called
as `name(args)` or `P<n>(args)`. Recursion is allowed.

**Variables.**

| Class | Meaning |
|---|---|
| `V<k>` | input; read-only |
| `Z<k>` | intermediate; the type is declared at first textual use as `Z<k>[:T]` and the initial value is zero |
| `R<k>` | result; initial value zero |
| `i`, `i<d>` | index of the innermost W1/W2 loop, or of the loop at nesting depth `d` (`i0` is the outermost); read-only |

**Types (Strukturen).**

| Notation | Meaning |
|---|---|
| `0` | one bit |
| `n.0`, `n x 0`, `n × 0` | unsigned word of n bits (n ≤ 64). A wider `n.0` is an array of n bits. |
| `±n.0`, `+-n.0` | signed two's-complement word of n bits |
| `A8`, `A9` | Zuse's natural / whole positive number, mapped to `64.0` |
| `A10` | Zuse's whole number (positive or negative), mapped to `±64.0` |
| `f32`, `f64` | IEEE 754 binary32 / binary64 floating point |
| `m.T`, `m x T` | array of m components of type T, e.g. `8.16.0`, `2x(f64, 0)` |
| `(T1, ..., Tk)` | record (tuple) of components of possibly different types, e.g. `(0, ±16.0, f64)` |

Zuse's A11–A13 (fractions, complex numbers) are rejected. Use `f64`, or a record such as
`(f64, f64)` for a complex number.

**Components.**
- **Selecting:** `X[e]` selects array component `e`, record component `e`, or bit `e` of a
  word (bit 0 is the least significant). `X[e:T]` also states the component's type, which
  the compiler checks.
- **Paths:** components can be chained as `V0[i0][i1]`, or written as a path, `Z1[5.3:9.0]`
  (component 3 of component 5, Rojas' notation).
- **Records:** a record component must be selected by a constant.
- **Range checks:** out-of-range indices are rejected at compile time when they are literals,
  and trap at run time otherwise.
- **Floating-point literals in selectors:** inside a component selector `X[...]`, `5.3` is a
  path, so a floating-point literal cannot appear there. In statement blocks `[ ... ]` it is
  a number.

**Statements.**

| Form | Meaning |
|---|---|
| `e → X` | assignment; numbers are converted to the target type (see Conversions). Structures must have the same type. |
| `plan(args) → X, Y` | assigns the results of a plan with several results |
| `c → statement` | conditional statement; `c` must be of type `0`. Chains are allowed: `c → e → X`. |
| `[ statements ]` | block |
| `W [ ... ]` | repeat until `FIN` |
| `W (c) [ ... ]` | repeat while `c` (extension) |
| `W1(n) [ ... ]` / `W2(n) [ ... ]` | repeat n times, with `i` counting up from 0 / down to 0; a negative signed count repeats zero times |
| `FIN` | leave the innermost loop |
| `ASSERT c` | assertion (extension): stops the program with `assertion failed: c` and the source position if `c` is 0. With `--no-assertions` it is type-checked but not executed. |

Statements are separated by line breaks or `;`. Comments start with `#` or `//`.

**Expressions.**

Arithmetic:
- **Words:** modulo 2^width (two's complement for signed words). Division truncates toward
  zero. Signed `MIN / -1` and division by zero trap.
- **Floating point:** IEEE 754. Division by zero gives ±inf or NaN. `%` is `fmod`.
- **Mixed operands:** a floating-point operand makes the operation floating point (of the
  wider format). Words of equal signedness are extended to the wider width. Mixed
  signed/unsigned words are extended to a signed word wide enough for both value ranges,
  at most 64 bits.
- **Literals:** an untyped literal takes the type of the other operand and must fit in it.
  `-5` directly before a literal is a negative literal. Floating-point literals are
  written `1.5`, `2e10` or `6.02e23`.
- **Logical operators:** they apply to words only.

Operator precedence, from lowest to highest:

| Level | Operators |
|---|---|
| 1 | `∨` `\|` |
| 2 | `⊕` `^` |
| 3 | `∧` `&` |
| 4 | `=` `≠` `!=` `<` `≤` `<=` `>` `≥` `>=` (not chainable; the result has type `0`; signed or floating-point comparison as appropriate) |
| 5 | `+` `-` |
| 6 | `×` `*` `/` `÷` `%` |
| 7 | unary `-`, `¬` `!` `~` |

The arrow may be written `→`, `->`, `⇒` or `=>`.

**Conversions** (assignment, arguments, results):

| From → to | Rule |
|---|---|
| word → word | zero- or sign-extended (by the source's signedness), or truncated |
| word → float | exact or rounded to nearest |
| float → word | truncated toward zero and saturated at the target's range; NaN becomes 0 |
| float → float | extended, or rounded to nearest |

## Demo: a transformer language model

`examples/lm/transformer.pk` (about 600 lines) is a character-level, decoder-only
transformer written entirely in Plankalkül. It trains from scratch with hand-written
backpropagation and then generates text autoregressively.

| Part | Choice |
|---|---|
| Embedding | 28-symbol vocabulary; the embedding matrix is shared with the output layer (Press & Wolf, arXiv:1608.05859) |
| Normalization | pre-norm RMSNorm (Zhang & Sennrich, arXiv:1910.07467) |
| Attention | causal self-attention, 2 heads, rotary position embeddings (Su et al., arXiv:2104.09864) |
| MLP | SwiGLU (Shazeer, arXiv:2002.05202) |
| Sizes | context 16, width 16, MLP width 32, 3056 parameters in one flat vector |
| Optimizer | AdamW (arXiv:1711.05101) for embeddings and gains; Muon for the hidden matrices (Nesterov momentum 0.95, 5 Newton–Schulz steps, update scale 0.2·√max(A,B), decoupled weight decay; Liu et al., arXiv:2502.16982) or AdamW everywhere |
| Schedule | warm-up, then cosine decay; gradient-norm clipping at 1; batches of 4 random windows |
| Arithmetic | exp, ln, √, sin/cos and the xorshift64* random generator are Plankalkül plans built from + − × ÷. The sigmoid plan is written in Zuse's 2D notation. |

```
examples/lm/run.sh 600 0 muon     # steps, temperature (0 = greedy), optimizer, [seed]
optimizer: muon, steps: 600, temperature: 0
loss by tenth of training: 2.728…,1.294…,0.659…,0.487…,0.377…,0.320…,0.281…,0.237…,0.232…,0.198…
prompt + generated text:   konrad zuse designed the plankalkul between nineteen fortytwo and ninete
```

The corpus is two sentences repeated to fill 256 characters, so the model learns to
recite them. Training for 600 steps takes about 2 s. At this size AdamW and Muon reach
similar losses: 0.20–0.23 after 600 steps over three seeds.

The demo is checked in three ways, all run by `tests/run.sh`:
- **Gradient:** the entry plan `gradcheck` compares the backpropagated gradient of every
  parameter with central differences. The largest relative error is about 1e-6, which is
  the noise level of finite differences with h = 1e-5.
- **Forward pass:** `examples/lm/reference.py`, an independent numpy implementation,
  reproduces the loss at random parameters to within 1e-12, using the same random
  generator.
- **Training:** a 300-step run must reach a final loss below 0.8 and reproduce the corpus.

## Design

```
source ─ PK.Twodim ─ PK.Lexer ─ PK.Parser ─ AST ─ PK.Sema ─ PK.Codegen ─ LLVM IR ─ clang ─ executable
```

- Each plan becomes an internal LLVM function. Word parameters are passed by value, arrays
  by `noalias readonly` pointer, and results through out pointers.
- Variables are stack slots with explicit loads and stores. LLVM's mem2reg/SROA passes turn
  them into SSA registers, which is the standard front-end strategy for LLVM. In the example
  above, `max3` becomes two `llvm.umax.i8` intrinsics at `-O2`.
- Words map to LLVM's arbitrary-width integers (`i1` to `i64`), so a `5.0` word gets exact
  5-bit wrap-around semantics. Signedness is a property of the type and selects the
  instructions used (`sdiv`/`udiv`, `slt`/`ult`, `sext`/`zext`).
- `f32` and `f64` map to `float` and `double`. Float-to-word conversions use the saturating
  `llvm.fpto[su]i.sat` intrinsics, so they never produce poison values.
- Records map to LLVM struct types. Components are addressed with constant `getelementptr`
  indices.
- Runtime checks (index range, division by zero, input parsing) call a cold, `noreturn`
  trap function. The error message includes the source position.

## Not implemented

- Zuse's A11–A13 (exact fractions, complex numbers as a primitive type).
- The Z3's 22-bit floating-point format; `f32` and `f64` are IEEE 754.
- The loop forms W0 and W3–W5, the list operators, and the predicates with quantifiers
  (∀, ∃, µ).
- Named constants.

## Sources

- R. Rojas, C. Göktekin, G. Friedland, M. Krüger, O. Langmack, D. Kuniß, *Plankalkül: The
  First High-Level Programming Language and its Implementation*, Technical Report B-3/2000,
  FU Berlin.
- B. Bruines, *Plankalkül*, bachelor's thesis, Radboud University Nijmegen, 2010: the
  V/K/S layout, dotted component paths, tuples `(σ, τ)`, and the types A8–A13.
