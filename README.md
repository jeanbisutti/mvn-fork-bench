# mvn-fork-bench

A standalone Maven benchmark that measures, in **wall-clock seconds only**, the
cost of the way Surefire runs tests by default: **forking a fresh JVM per test
class**. It compares that against running the *same* tests **in-process**, and
checks whether having the **C2 JIT compiler** enabled changes the picture. It
also times a **bare JVM start** (an empty `main`, no user code) so the per-fork
cost can be split into "pure JVM startup" versus "everything Surefire adds".

No profiling, no JIT statistics, no JFR, no hyperfine — just `date`, `mvn`, and
`awk`.

## The question

When Surefire forks a JVM per test class, a large suite pays for *hundreds* of
cold JVM starts. Each fresh fork also re-warms the C2 compiler from cold, while a
single long-lived JVM warms it once. So:

1. **How much does forking many test JVMs cost** versus one in-process JVM?
2. **Does C2 make that worse?** Turning C2 off should *hurt* the in-process case
   (one JVM that would have amortised the warm-up) but may *help* many
   short-lived forks (which never run long enough to cash in on C2).

## The experiment — a 2×2, wall-clock only

The same **N** test classes in every cell; only two knobs move.

|                                   | **no fork** (in-process) | **many forks** (one JVM per class) |
|-----------------------------------|--------------------------|------------------------------------|
| **C2 on** (JVM default)           | wall time                | wall time                          |
| **C2 off** (`-XX:TieredStopAtLevel=1`) | wall time           | wall time                          |

- **Fork axis** — `forkCount=0` (tests run in the Maven JVM, no fork) vs
  `forkCount=1, reuseForks=false` (a fresh JVM per class → **N forks**).
- **C2 axis** — default tiered compilation up to C2 vs `-XX:TieredStopAtLevel=1`
  (C1 only, C2 disabled). We stop at C1 rather than `-Xint` to isolate *just* the
  C2 tier.
  - The **no-fork** arm disables C2 on the Maven JVM itself, via `MAVEN_OPTS`,
    because the tests run there.
  - The **forked** arm disables C2 only in the forks, via Surefire's `argLine`.

Both knobs are POM properties read by the Surefire config:

```xml
<forkCount>${bench.forkCount}</forkCount>
<reuseForks>${bench.reuseForks}</reuseForks>
<argLine>${bench.argLine}</argLine>
<includes><include>${bench.includes}</include></includes>
```

### The bare-JVM baseline (outside the matrix)

Alongside the 2×2, `run-bench.sh` times **one cold `java` start executing no
user code**: an empty `main`, compiled once (untimed) into
`target/jvm-baseline/`, then started and exited repeatedly with the same `java`
binary the forks use (`JAVA_HOME` when set). It is measured on both C2 rows for
symmetry — nothing runs long enough to JIT, so the two should agree within
noise. Because it is N-independent it is recorded under the pseudo-N `-` in
`wall.tsv`/`stats.tsv`, with at least 10 repeats (starts are cheap; the extra
repeats buy precision).

This is the number that turns "forking is X× slower" into a mechanism: the
summary divides the marginal per-fork overhead, `(forked − no-fork) / N`, into
the slice that is **pure JVM startup** and the remainder (Surefire fork
scaffolding, test-class loading, per-class JIT re-warm).

## Class-set tiers

`N` is literally the number of test classes — and, in the forked column, the
number of forked JVMs (`reuseForks=false` ⇒ one fork per class).

- **Committed tiers — N ∈ {0, 1, 10}.** Small, stable, reviewable, checked into
  git under `src/test/java/bench/fixed/`:
  - **N=0** is the empty set — nothing on disk; its include pattern
    (`bench/fixed/n0/*Test.java`) matches no class. This is the **calibration
    floor**: no test runs, so no fork happens even in the forked column, isolating
    the fixed `surefire:test` goal + classpath-scan overhead every other cell also
    pays.
  - **N=1**, **N=10** live in `bench/fixed/n1/` and `bench/fixed/n10/`.
- **Generated tiers — N ∈ {50, 100, 200}** (the CI default). Emitted at bench
  time into `src/test/java/bench/gen/` (gitignored) and regenerated for each N.

Every class under `src/test/java` always compiles, but a single timed run
activates exactly **one** set via `bench.includes`, so committed and generated
classes never mix in a measurement.

## Running it locally

Requires JDK 17+ and Maven. The scripts are bash (Linux / macOS / Git Bash / WSL).

### Full sweep

```bash
# defaults: BENCH_CLASSES="0,1,10,50,100,200", BENCH_REPEATS="5"
bash tools/run-bench.sh

# a quick subset:
BENCH_CLASSES="0,1,10" BENCH_REPEATS="3" bash tools/run-bench.sh
```

`run-bench.sh` primes `~/.m2` **online once**, then times every `surefire:test`
run **offline** (`-o`) so no download ever lands inside a measurement. It writes
`results/wall.tsv` (raw), `results/stats.tsv` (per-cell median/CV), and
`results/summary.md` (findings + tables), and prints the summary at the end.

### The four commands, by hand

After a one-time warm `mvn -q test-compile` for the current N (online), each cell
is one offline command (add `-Dbench.includes=<set>` for the N you want):

```bash
# 1. no fork, C2 on
mvn -o -q surefire:test -Dbench.forkCount=0

# 2. no fork, C2 off   (C2 off on the Maven JVM that runs the tests)
MAVEN_OPTS="-XX:TieredStopAtLevel=1" mvn -o -q surefire:test -Dbench.forkCount=0

# 3. many forks, C2 on
mvn -o -q surefire:test -Dbench.forkCount=1 -Dbench.reuseForks=false

# 4. many forks, C2 off  (C2 off on the forks via argLine)
mvn -o -q surefire:test -Dbench.forkCount=1 -Dbench.reuseForks=false \
  -Dbench.argLine=-XX:TieredStopAtLevel=1
```

And the bare-JVM baseline (no Maven involved — compile once, then time a start):

```bash
mkdir -p target/jvm-baseline
printf 'public class Empty { public static void main(String[] a) {} }' \
  > target/jvm-baseline/Empty.java
javac -d target/jvm-baseline target/jvm-baseline/Empty.java

time java -cp target/jvm-baseline Empty                            # C2 on
time java -XX:TieredStopAtLevel=1 -cp target/jvm-baseline Empty    # C2 off
```

### Regenerating the class sets

```bash
# committed tiers — one-time, then `git add` the result:
bash tools/gen-tests.sh --fixed 1
bash tools/gen-tests.sh --fixed 10

# a generated tier (wipes and refills src/test/java/bench/gen/):
bash tools/gen-tests.sh --gen 100
```

## Running it in CI

`.github/workflows/bench.yml` runs on **ubuntu-latest** only:

- **Trigger:** `workflow_dispatch` (inputs: `classes` = N-list, `repeats`) plus an
  optional nightly `schedule`.
- Caches `~/.m2/repository` via `setup-java`'s `cache: maven`.
- Runs `tools/run-bench.sh`, appends `results/summary.md` to the **job summary**
  (so findings show without a download), and uploads `results/` as an artifact.

Launch it from the repo's **Actions ▸ fork-bench ▸ Run workflow**, tuning the N
list and repeat count in the dispatch form.

## Reading `results/summary.md`

- Each cell is `median ms ±CV%`, and — for the three non-baseline cells — a delta
  vs the baseline in parentheses, e.g. `4812 ms ±2.1% (+240%)`.
- **`no-fork C2-on` is the 100% baseline.**
- A cell with **CV > 15%** is flagged **⚠** — GitHub-hosted runners are shared
  VMs and go noisy under load; re-run before trusting a flagged number.
- The **Derived** table states the two headline quantities as percentages: *fork
  cost* (forked C2-on vs baseline) and *C2's effect within the forked column*
  (C2-off vs C2-on).
- The **Bare JVM startup** section gives the cost of one cold, code-free `java`
  start on both C2 rows, then computes what share of the marginal per-fork
  overhead — `(forked − no-fork) / N` at the largest measured N — is pure JVM
  startup versus Surefire's own fork machinery.

## Interpreting the axes (and a caveat)

- **Fork cost** = forked − no-fork on the same C2 row; expected to grow with N.
- **Floor & marginal fork** — N=0 is the goal's no-test floor; `N=1 − N=0`
  approximates one cold fork; N=10 shows whether per-fork cost is linear early.
- **Bare start vs marginal fork** — a Surefire fork should always cost *more*
  than the bare-JVM start (it boots the same JVM, then loads the provider and
  the test class on top). If the reported per-fork overhead ever lands *below*
  the bare start, the cells are within noise — check the CV columns.
- **Caveat on no-fork C2-off:** `MAVEN_OPTS=-XX:TieredStopAtLevel=1` slows the
  *whole* Maven JVM (Maven's own work, not just the tests). The N=0 row captures
  part of that fixed overhead; keep it in mind when reading the no-fork C2-off
  column.

### If the C2 signal is flat

The generated tests are deliberately trivial, so the C2 on/off delta may be small.
If it is, give C2 something to compile: add a small compute loop to the `@Test`
body in `tools/gen-tests.sh` (e.g. a summation over a few million iterations) and
regenerate. Startup/fork cost still dominates, but the JIT now has real work.

## Layout

```
mvn-fork-bench/
├── pom.xml                       JUnit 5 + Surefire 3.2.5; the bench.* properties
├── src/test/java/bench/
│   ├── fixed/{n1,n10}/           committed tiers (N=0 = empty set, no dir)
│   └── gen/                      generated at bench time, N ≥ 50 (gitignored)
├── tools/
│   ├── gen-tests.sh              emit N test classes (→ fixed/ once, → gen/ per run)
│   └── run-bench.sh              sweep the 2×2 × N + bare-JVM baseline → summary.md
└── .github/workflows/bench.yml   ubuntu-latest; job summary + results artifact
```

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
