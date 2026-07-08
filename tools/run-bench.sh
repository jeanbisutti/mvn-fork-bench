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
pct() {  # pct <value> <base> -> "+240%" | "-12%" | "n/a"   (increase over base)
  awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0 > 0) printf "%+.0f%%", 100.0*(a-b)/b; else printf "n/a" }'
}

mult() {  # mult <value> <base> -> "2.83×" | "n/a"          (times as long as base)
  awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0 > 0) printf "%.2f×", a/b; else printf "n/a" }'
}

delta() {  # delta <value> <base> -> "+183%, 2.83×" | "n/a" (both forms; no nested parens)
  awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0 > 0) printf "%+.0f%%, %.2f×", 100.0*(a-b)/b, a/b; else printf "n/a" }'
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
    printf '%s ms ±%s%% (%s)%s' "$med" "$cv" "$(delta "$med" "$base")" "$flag"
  fi
}

# Pick the largest N that has both baseline and forked medians, for the headline.
head_n=""
for N in $NLIST; do
  if [ "${MED[$N,nofork_c2on]:-NA}" != "NA" ] && [ "${MED[$N,fork_c2on]:-NA}" != "NA" ]; then
    head_n="$N"
  fi
done

# --- chart helpers -------------------------------------------------------
# Fixed-width (15-char) config label so the Unicode bars line up.
label_of() {
  case "$1" in
    nofork_c2on)  printf 'no-fork  C2-on ' ;;
    nofork_c2off) printf 'no-fork  C2-off' ;;
    fork_c2on)    printf 'forked   C2-on ' ;;
    fork_c2off)   printf 'forked   C2-off' ;;
  esac
}

# bar_of <value> <max> -> a MAXW-wide █/░ bar scaled to <max>. Built entirely in
# awk, so there is no shell arithmetic (set -e safe) and no multibyte surprises.
MAXW=40
bar_of() {
  awk -v v="$1" -v m="$2" -v W="$MAXW" 'BEGIN{
    n = (m <= 0) ? 0 : int(v / m * W + 0.5)
    if (n < 0) n = 0; if (n > W) n = W
    s = ""; for (i = 0; i < n; i++) s = s "█"; for (i = n; i < W; i++) s = s "░"
    printf "%s", s
  }'
}

# Global max median (a comparable bar scale across every N) plus the mermaid
# fork-cost series: per-N fork-cost %, the x-axis categories, and the y-axis max.
gmax=1; mm_x=""; mm_bar=""; mm_ymax=10
for N in $NLIST; do
  for cfg in $CONFIGS; do
    m="${MED[$N,$cfg]:-NA}"
    if [ "$m" = "NA" ]; then continue; fi
    if [ "$m" -gt "$gmax" ] 2>/dev/null; then gmax="$m"; fi
  done
  fc="0"
  b="${MED[$N,fork_c2on]:-NA}"; a="${MED[$N,nofork_c2on]:-NA}"
  if [ "$a" != "NA" ] && [ "$b" != "NA" ] && [ "$a" -gt 0 ] 2>/dev/null; then
    fc="$(awk -v x="$b" -v base="$a" 'BEGIN{ r = 100.0*(x-base)/base; if (r < 0) r = 0; printf "%.0f", r }')"
  fi
  mm_x="${mm_x}${mm_x:+, }${N}"
  mm_bar="${mm_bar}${mm_bar:+, }${fc}"
  if [ "$fc" -gt "$mm_ymax" ] 2>/dev/null; then mm_ymax="$fc"; fi
done
mm_ymax="$(awk -v m="$mm_ymax" 'BEGIN{ b = 50; if (m < b) m = b; print (int((m - 1) / b) + 1) * b }')"

{
  echo "# mvn-fork-bench — results"
  echo
  echo "Wall-clock cost of forking one JVM per test class versus running the same"
  echo "tests in-process, and what disabling the C2 JIT does to each. Every cell is"
  echo "the **median** of the measured runs; \`±CV%\` is the coefficient of variation"
  echo "(a noise gauge — cells above ${NOISY_CV}% are flagged ⚠ and should be re-run)."
  echo
  echo "- Timed goal: \`surefire:test\` only, offline (\`-o\`), against pre-compiled classes."
  echo "- Baseline (100%): **no-fork, C2-on**. Other cells show their **delta % and multiplier (×)** vs that baseline (see \"How the numbers are computed\")."
  echo "- Repeats: ${REPEATS} per cell (adaptively trimmed for large N)."
  echo

  echo "## Key findings"
  echo
  if [ -n "$head_n" ]; then
    fc_pct="$(pct "${MED[$head_n,fork_c2on]}" "${MED[$head_n,nofork_c2on]}")"
    fc_mult="$(mult "${MED[$head_n,fork_c2on]}" "${MED[$head_n,nofork_c2on]}")"
    echo "At **N=${head_n}** (${REPS[$head_n,fork_c2on]:-?} measured runs):"
    echo
    echo "- **Fork cost:** forking ${head_n} cold JVMs takes **${fc_mult}** as long as in-process — **${fc_pct}** (both C2-on)."
    if [ "${MED[$head_n,fork_c2off]:-NA}" != "NA" ]; then
      c2f_pct="$(pct "${MED[$head_n,fork_c2off]}" "${MED[$head_n,fork_c2on]}")"
      c2f_mult="$(mult "${MED[$head_n,fork_c2off]}" "${MED[$head_n,fork_c2on]}")"
      echo "- **C2 in the forks:** turning C2 off makes the forked column **${c2f_mult}** (**${c2f_pct}**)."
    fi
    if [ "${MED[$head_n,nofork_c2off]:-NA}" != "NA" ]; then
      c2n_pct="$(pct "${MED[$head_n,nofork_c2off]}" "${MED[$head_n,nofork_c2on]}")"
      c2n_mult="$(mult "${MED[$head_n,nofork_c2off]}" "${MED[$head_n,nofork_c2on]}")"
      echo "- **C2 in-process:** turning C2 off makes the no-fork column **${c2n_mult}** (**${c2n_pct}**)."
    fi
  else
    echo "_No cell produced a median — check $LOG and results/wall.tsv._"
  fi
  echo

  echo "## Median wall time by N"
  echo
  echo "_Bars scaled to the global maximum (${gmax} ms): longer = slower, and the"
  echo "forked rows visibly stretch as N grows._"
  echo
  echo '```text'
  for N in $NLIST; do
    echo "N=${N}"
    for cfg in $CONFIGS; do
      m="${MED[$N,$cfg]:-NA}"
      if [ "$m" = "NA" ]; then
        printf '  %s  %s     —\n'   "$(label_of "$cfg")" "$(bar_of 0 "$gmax")"
      else
        printf '  %s  %s  %6s ms\n' "$(label_of "$cfg")" "$(bar_of "$m" "$gmax")" "$m"
      fi
    done
    echo
  done
  echo '```'
  echo

  echo "## Fork cost by N"
  echo
  echo '```mermaid'
  echo 'xychart-beta'
  echo '    title "Fork cost: forked C2-on vs in-process baseline (% over baseline)"'
  echo "    x-axis [${mm_x}]"
  echo "    y-axis \"Fork cost (%)\" 0 --> ${mm_ymax}"
  echo "    bar [${mm_bar}]"
  echo '```'
  echo "_Each bar = median forked (C2-on) wall time as a percentage above the"
  echo "no-fork/C2-on baseline for that N; values below 0 (within noise) clamped to 0._"
  echo

  echo "## Wall time by N (median ± CV, then delta % and × vs baseline)"
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
  echo "| N | fork cost — forked C2-on vs baseline | C2 in forks — C2-off vs C2-on |"
  echo "|---|---|---|"
  for N in $NLIST; do
    fc="—"; cf="—"
    if [ "${MED[$N,fork_c2on]:-NA}" != "NA" ] && [ "${MED[$N,nofork_c2on]:-NA}" != "NA" ]; then
      fc="$(delta "${MED[$N,fork_c2on]}" "${MED[$N,nofork_c2on]}")"
    fi
    if [ "${MED[$N,fork_c2off]:-NA}" != "NA" ] && [ "${MED[$N,fork_c2on]:-NA}" != "NA" ]; then
      cf="$(delta "${MED[$N,fork_c2off]}" "${MED[$N,fork_c2on]}")"
    fi
    printf '| %s | %s | %s |\n' "$N" "$fc" "$cf"
  done
  echo
  echo "## How the numbers are computed"
  echo
  echo "\`median\` = middle of the measured runs (mean of the two middle values when the"
  echo "count is even). Everything else is relative to **B = that N's no-fork C2-on"
  echo "median** (the baseline). For any config with median \`m\`:"
  echo
  echo '```text'
  echo 'multiplier  =  m / B                 how many times as long as baseline'
  echo 'delta %     =  100 × (m - B) / B     =  (multiplier - 1) × 100'
  echo '```'
  if [ -n "$head_n" ]; then
    _B="${MED[$head_n,nofork_c2on]}"; _F="${MED[$head_n,fork_c2on]}"
    _diff=$(( _F - _B ))
    _pct="$(pct "$_F" "$_B")"
    _mnum="$(awk -v b="$_B" -v f="$_F" 'BEGIN{ printf "%.2f", f/b }')"
    echo
    echo "Worked example — **N=${head_n}, forked C2-on** (medians from this run):"
    echo
    echo '```text'
    echo "B (no-fork C2-on) = ${_B} ms        forked C2-on (m) = ${_F} ms"
    echo "multiplier = ${_F} / ${_B}              = ${_mnum}×"
    echo "delta %    = 100 × (${_F} - ${_B}) / ${_B}  = ${_pct}"
    echo "cross-check: (${_mnum} - 1) × 100        = ${_pct}     (extra time ${_F} - ${_B} = ${_diff} ms)"
    echo '```'
    echo
    echo "\`${_mnum}×\` and \`${_pct}\` are the same jump two ways: \`×\` counts the whole run,"
    echo "\`+%\` counts only the added time, so they differ by exactly one baseline (100%)."
  fi
  echo
  echo "_Raw per-run timings: \`results/wall.tsv\`. Per-cell stats: \`results/stats.tsv\`._"
} > "$SUMMARY"

echo
echo "== done =="
echo "wrote $SUMMARY"
echo
cat "$SUMMARY"
