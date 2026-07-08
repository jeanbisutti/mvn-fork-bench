#!/usr/bin/env bash
#
# run-bench.sh — sweep the 2x2 (fork axis x C2 axis) across a list of N, timing
# only the `surefire:test` goal (wall-clock ms), then write results/summary.md.
#
#   Fork axis : forkCount=0 (in-process)  vs  forkCount=1,reuseForks=false (N forks)
#   C2 axis   : default (C2 on)           vs  -XX:TieredStopAtLevel=1 (C2 off)
#
# The no-fork arm disables C2 on the Maven JVM via MAVEN_OPTS (tests run there);
# the forked arm disables C2 on the forks via Surefire's argLine.
#
# Inputs (env):
#   BENCH_CLASSES  comma-separated N list   (default 0,1,10,50,100,200)
#   BENCH_REPEATS  measured runs per cell   (default 5; trimmed for large N)
#
# Network: one ONLINE prime populates ~/.m2; every TIMED run is `-o` (offline),
# so dependency/plugin resolution is never inside a measurement.
set -euo pipefail

# Run from the repo root regardless of caller CWD.
cd "$(cd "$(dirname "$0")/.." && pwd)"

CLASSES="${BENCH_CLASSES:-0,1,10,50,100,200}"
REPEATS="${BENCH_REPEATS:-5}"
NOISY_CV=15          # flag a cell whose CV% exceeds this as noisy

RESULTS="results"
WALL="$RESULTS/wall.tsv"
STATS="$RESULTS/stats.tsv"
SUMMARY="$RESULTS/summary.md"
LOG="$RESULTS/mvn-last.log"
mkdir -p "$RESULTS"
printf 'N\tconfig\trep\tms\n' > "$WALL"
printf 'N\tconfig\tmedian_ms\tmin_ms\tmax_ms\tcv_pct\treps\n' > "$STATS"

NLIST="${CLASSES//,/ }"

now_ms() { date +%s%3N; }

# ---------------------------------------------------------------------------
# Online prime: resolve compiler + JUnit + the Surefire JUnit-Platform provider
# so the offline timed runs never touch the network. Self-heal the committed
# fixed tiers if a bare checkout is missing them (no-op when they're present).
# ---------------------------------------------------------------------------
[ -d src/test/java/bench/fixed/n1 ]  || bash tools/gen-tests.sh --fixed 1
[ -d src/test/java/bench/fixed/n10 ] || bash tools/gen-tests.sh --fixed 10

echo "== prime (online): resolve deps + Surefire provider =="
mvn -B -q clean test-compile
mvn -B -q surefire:test \
    -Dbench.forkCount=1 -Dbench.reuseForks=false \
    -Dbench.includes='bench/fixed/n1/*Test.java'

# ---------------------------------------------------------------------------
# Class-set selection for a given N. Sets INCLUDES; generates gen/ when needed.
#   N=0            -> empty n0 pattern (matches nothing: the calibration floor)
#   committed tier -> src/test/java/bench/fixed/n<N>/ if it exists
#   otherwise      -> generate exactly N classes into gen/
# ---------------------------------------------------------------------------
INCLUDES=""
set_class_set() {
  local N="$1"
  if [ "$N" = "0" ]; then
    INCLUDES='bench/fixed/n0/*Test.java'
  elif [ -d "src/test/java/bench/fixed/n$N" ]; then
    INCLUDES="bench/fixed/n$N/*Test.java"
  else
    bash tools/gen-tests.sh --gen "$N" >&2
    INCLUDES='bench/gen/*Test.java'
  fi
}

# Adaptive repeats: keep total CI time bounded as N (and per-run cost) grows.
# N=200 is the heaviest tier, so it takes the trim.
repeats_for() {
  local N="$1" r="$REPEATS"
  if [ "$N" -ge 200 ]; then
    if [ "$r" -gt 4 ]; then r=4; fi
  fi
  printf '%s' "$r"
}

# run_cell N config -- <full mvn command...>
# One discarded warm-up, then R timed runs -> wall.tsv. The command already
# carries every -D except includes, which we append here.
run_cell() {
  local N="$1" config="$2"; shift 2   # remaining args are the command
  local R; R="$(repeats_for "$N")"
  echo "   $config  (R=$R)"

  # warm-up (discarded); surface a broken config loudly.
  if ! "$@" -Dbench.includes="$INCLUDES" >"$LOG" 2>&1; then
    echo "   WARN: warm-up failed for $config N=$N — see $LOG" >&2
    tail -n 5 "$LOG" >&2 || true
  fi

  local rep=1 s e
  while [ "$rep" -le "$R" ]; do
    s="$(now_ms)"
    if "$@" -Dbench.includes="$INCLUDES" >"$LOG" 2>&1; then
      e="$(now_ms)"
      printf '%s\t%s\t%s\t%s\n' "$N" "$config" "$rep" "$((e - s))" >> "$WALL"
    else
      e="$(now_ms)"
      echo "   WARN: run failed for $config N=$N rep=$rep — not recorded (see $LOG)" >&2
      tail -n 5 "$LOG" >&2 || true
    fi
    rep=$((rep + 1))
  done
}

# ---------------------------------------------------------------------------
# The sweep.
# ---------------------------------------------------------------------------
for N in $NLIST; do
  echo "== N=$N =="
  set_class_set "$N"
  mvn -B -q -o clean test-compile     # offline compile of the current class set

  # 1. no fork, C2 on
  run_cell "$N" nofork_c2on \
    mvn -B -q -o surefire:test -Dbench.forkCount=0

  # 2. no fork, C2 off  (disable C2 on the Maven JVM that runs the tests)
  run_cell "$N" nofork_c2off \
    env MAVEN_OPTS=-XX:TieredStopAtLevel=1 \
    mvn -B -q -o surefire:test -Dbench.forkCount=0

  # 3. many forks, C2 on
  run_cell "$N" fork_c2on \
    mvn -B -q -o surefire:test -Dbench.forkCount=1 -Dbench.reuseForks=false

  # 4. many forks, C2 off  (disable C2 on the forks via argLine)
  run_cell "$N" fork_c2off \
    mvn -B -q -o surefire:test -Dbench.forkCount=1 -Dbench.reuseForks=false \
    -Dbench.argLine=-XX:TieredStopAtLevel=1
done

# ---------------------------------------------------------------------------
# Stats. Portable (POSIX sort + awk only; no gawk asort — ubuntu awk is mawk).
# stat_line prints: "median min max cv_pct reps" for one (N,config).
# ---------------------------------------------------------------------------
stat_line() {
  local N="$1" cfg="$2"
  awk -F'\t' -v n="$N" -v c="$cfg" '$1==n && $2==c {print $4}' "$WALL" \
    | sort -n \
    | awk '
        { v[NR] = $1; sum += $1 }
        END {
          k = NR
          if (k == 0) { print "NA NA NA NA 0"; exit }
          if (k % 2) med = v[(k + 1) / 2]
          else       med = (v[k/2] + v[k/2 + 1]) / 2.0
          mean = sum / k
          ss = 0
          for (i = 1; i <= k; i++) { d = v[i] - mean; ss += d * d }
          sd = (k > 1) ? sqrt(ss / (k - 1)) : 0
          cv = (mean > 0) ? 100.0 * sd / mean : 0
          printf "%.0f %d %d %.1f %d\n", med, v[1], v[k], cv, k
        }'
}

declare -A MED CV REPS
CONFIGS="nofork_c2on nofork_c2off fork_c2on fork_c2off"
for N in $NLIST; do
  for cfg in $CONFIGS; do
    read -r med mn mx cv reps < <(stat_line "$N" "$cfg") || true
    MED["$N,$cfg"]="$med"; CV["$N,$cfg"]="$cv"; REPS["$N,$cfg"]="$reps"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$N" "$cfg" "$med" "$mn" "$mx" "$cv" "$reps" >> "$STATS"
  done
done

# ---------------------------------------------------------------------------
# summary.md — key findings first, then the raw table + derived deltas.
# ---------------------------------------------------------------------------
pct() {  # pct <value> <base> -> "+240%" | "-12%" | "n/a"
  awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0 > 0) printf "%+.0f%%", 100.0*(a-b)/b; else printf "n/a" }'
}

cell() {  # cell <N> <cfg>  -> markdown cell (baseline shows no delta)
  local N="$1" cfg="$2" key="$1,$2"
  local med="${MED[$key]:-NA}" cv="${CV[$key]:-NA}" base="${MED[$1,nofork_c2on]:-NA}"
  if [ "$med" = "NA" ]; then printf '—'; return; fi
  local flag=""
  if awk -v c="$cv" 'BEGIN{ exit !(c+0 > '"$NOISY_CV"') }'; then flag=" ⚠"; fi
  if [ "$cfg" = "nofork_c2on" ]; then
    printf '%s ms ±%s%%%s' "$med" "$cv" "$flag"
  else
    printf '%s ms ±%s%% (%s)%s' "$med" "$cv" "$(pct "$med" "$base")" "$flag"
  fi
}

# Pick the largest N that has both baseline and forked medians, for the headline.
head_n=""
for N in $NLIST; do
  if [ "${MED[$N,nofork_c2on]:-NA}" != "NA" ] && [ "${MED[$N,fork_c2on]:-NA}" != "NA" ]; then
    head_n="$N"
  fi
done

{
  echo "# mvn-fork-bench — results"
  echo
  echo "Wall-clock cost of forking one JVM per test class versus running the same"
  echo "tests in-process, and what disabling the C2 JIT does to each. Every cell is"
  echo "the **median** of the measured runs; \`±CV%\` is the coefficient of variation"
  echo "(a noise gauge — cells above ${NOISY_CV}% are flagged ⚠ and should be re-run)."
  echo
  echo "- Timed goal: \`surefire:test\` only, offline (\`-o\`), against pre-compiled classes."
  echo "- Baseline (100%): **no-fork, C2-on**. Other cells show their delta vs that baseline."
  echo "- Repeats: ${REPEATS} per cell (adaptively trimmed for large N)."
  echo

  echo "## Key findings"
  echo
  if [ -n "$head_n" ]; then
    fork_cost="$(pct "${MED[$head_n,fork_c2on]}" "${MED[$head_n,nofork_c2on]}")"
    echo "At **N=${head_n}** (${REPS[$head_n,fork_c2on]:-?} measured runs):"
    echo
    echo "- **Fork cost:** forking ${head_n} cold JVMs is **${fork_cost}** vs in-process (both C2-on)."
    if [ "${MED[$head_n,fork_c2off]:-NA}" != "NA" ]; then
      c2f="$(pct "${MED[$head_n,fork_c2off]}" "${MED[$head_n,fork_c2on]}")"
      echo "- **C2 in the forks:** turning C2 off changes the forked column by **${c2f}**."
    fi
    if [ "${MED[$head_n,nofork_c2off]:-NA}" != "NA" ]; then
      c2n="$(pct "${MED[$head_n,nofork_c2off]}" "${MED[$head_n,nofork_c2on]}")"
      echo "- **C2 in-process:** turning C2 off changes the no-fork column by **${c2n}**."
    fi
  else
    echo "_No cell produced a median — check $LOG and results/wall.tsv._"
  fi
  echo

  echo "## Wall time by N (median ± CV, delta vs baseline)"
  echo
  echo "| N | no-fork C2-on (baseline) | no-fork C2-off | forked C2-on | forked C2-off |"
  echo "|---|---|---|---|---|"
  for N in $NLIST; do
    printf '| %s | %s | %s | %s | %s |\n' "$N" \
      "$(cell "$N" nofork_c2on)" "$(cell "$N" nofork_c2off)" \
      "$(cell "$N" fork_c2on)"   "$(cell "$N" fork_c2off)"
  done
  echo

  echo "## Derived"
  echo
  echo "| N | fork cost (forked C2-on vs baseline) | C2 in forks (C2-off vs C2-on) |"
  echo "|---|---|---|"
  for N in $NLIST; do
    fc="—"; cf="—"
    if [ "${MED[$N,fork_c2on]:-NA}" != "NA" ] && [ "${MED[$N,nofork_c2on]:-NA}" != "NA" ]; then
      fc="$(pct "${MED[$N,fork_c2on]}" "${MED[$N,nofork_c2on]}")"
    fi
    if [ "${MED[$N,fork_c2off]:-NA}" != "NA" ] && [ "${MED[$N,fork_c2on]:-NA}" != "NA" ]; then
      cf="$(pct "${MED[$N,fork_c2off]}" "${MED[$N,fork_c2on]}")"
    fi
    printf '| %s | %s | %s |\n' "$N" "$fc" "$cf"
  done
  echo
  echo "_Raw per-run timings: \`results/wall.tsv\`. Per-cell stats: \`results/stats.tsv\`._"
} > "$SUMMARY"

echo
echo "== done =="
echo "wrote $SUMMARY"
echo
cat "$SUMMARY"
