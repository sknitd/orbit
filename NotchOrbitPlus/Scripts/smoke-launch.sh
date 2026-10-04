#!/bin/bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'A macOS session is required for the NotchOrbitPlus launch smoke check.' >&2; exit 1; }
app_path="${1:?Pass the path to NotchOrbitPlus.app}"
executable="$app_path/Contents/MacOS/NotchOrbitPlus"
[[ -x "$executable" ]] || { echo 'The NotchOrbitPlus executable is missing.' >&2; exit 1; }
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
log_path="$task_root/build/launch-smoke.log"
performance_path="$task_root/build/idle-performance.json"
app_pid=''
cleanup() {
  if [[ -n "$app_pid" ]]; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
"$executable" >"$log_path" 2>&1 &
app_pid=$!
python3 - "$app_pid" "$performance_path" <<'PY' | tee -a "$log_path"
import datetime, json, math, os, pathlib, subprocess, sys, time

pid = int(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
warmup_seconds, intervals, interval_seconds = 8, 10, 1
cpu_limit_percent, rss_limit_mb = 3.0, 250.0
started = time.monotonic()
samples = []
report = {
    'schema_version': 1, 'product': 'NotchOrbitPlus', 'pid': pid,
    'measured_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'source_commit': os.environ.get('GITHUB_SHA'),
    'configuration': 'Release launch with default local setup; harness enables no tool, account, permission, playback, or network action.',
    'scope': 'Owned application process only. RSS excludes WindowServer, GPU allocations and other processes. This is runner idle-launch evidence, not physical Finder/notch performance.',
    'startup_check_seconds': 3, 'warmup_seconds': warmup_seconds,
    'sample_interval_seconds': interval_seconds, 'measurement_intervals': intervals,
    'budgets': {'mean_cpu_percent': cpu_limit_percent, 'sampled_peak_rss_mb': rss_limit_mb},
    'cpu_method': 'Delta of ps cumulative application CPU time divided by measured monotonic wall time; 100% means one fully occupied CPU core.',
    'memory_method': 'ps resident set in KiB, converted to decimal MB (1 MB = 1,000,000 bytes).',
    'samples': samples
}

def cpu_seconds(value):
    days = 0
    if '-' in value:
        day, value = value.split('-', 1)
        days = int(day)
    fields = value.split(':')
    if len(fields) == 2:
        hours, minutes, seconds = 0, int(fields[0]), float(fields[1])
    elif len(fields) == 3:
        hours, minutes, seconds = int(fields[0]), int(fields[1]), float(fields[2])
    else:
        raise ValueError('Unrecognized cumulative CPU time from ps')
    total = days * 86400 + hours * 3600 + minutes * 60 + seconds
    if not math.isfinite(total) or total < 0:
        raise ValueError('Invalid cumulative CPU time from ps')
    return total

def sample():
    result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'time=', '-o', 'rss='],
                            capture_output=True, text=True, check=False, timeout=5)
    fields = result.stdout.split()
    if result.returncode != 0 or len(fields) != 2:
        raise RuntimeError('The owned application exited or ps could not read its CPU time and resident memory')
    rss_kib = int(fields[1])
    if rss_kib <= 0:
        raise ValueError('ps returned a nonpositive resident-memory measurement')
    return {'elapsed_seconds': time.monotonic() - started,
            'cumulative_cpu_seconds': cpu_seconds(fields[0]), 'rss_kib': rss_kib,
            'rss_mb': rss_kib * 1024 / 1_000_000}

try:
    for second in range(1, warmup_seconds + 1):
        time.sleep(1)
        os.kill(pid, 0)
        # A terminated child may remain a zombie until the parent reaps it.
        state = subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'stat='], text=True).strip()
        if not state or 'Z' in state:
            raise RuntimeError('The owned application exited during startup/warmup')
        if second == 3:
            report['startup_passed'] = True
            print('NotchOrbitPlus stayed running for the 3-second startup smoke check.', flush=True)
    first = sample()
    first['interval_cpu_percent'] = None
    samples.append(first)
    for _ in range(intervals):
        time.sleep(interval_seconds)
        current = sample()
        previous = samples[-1]
        delta_cpu = current['cumulative_cpu_seconds'] - previous['cumulative_cpu_seconds']
        delta_wall = current['elapsed_seconds'] - previous['elapsed_seconds']
        if delta_cpu < 0 or delta_wall <= 0:
            raise ValueError('CPU or elapsed-time counters did not advance monotonically')
        current['interval_cpu_percent'] = 100 * delta_cpu / delta_wall
        samples.append(current)
    elapsed = samples[-1]['elapsed_seconds'] - first['elapsed_seconds']
    mean_cpu = 100 * (samples[-1]['cumulative_cpu_seconds'] - first['cumulative_cpu_seconds']) / elapsed
    peak_rss = max(value['rss_mb'] for value in samples)
    report.update({'measurement_seconds': elapsed, 'mean_cpu_percent': mean_cpu,
                   'sampled_peak_rss_mb': peak_rss,
                   'cpu_budget_passed': mean_cpu <= cpu_limit_percent,
                   'rss_budget_passed': peak_rss <= rss_limit_mb})
    passed = report['cpu_budget_passed'] and report['rss_budget_passed']
    report['outcome'] = 'passed' if passed else 'budget_failed'
    print(f'Idle launch: CPU {mean_cpu:.3f}% (limit {cpu_limit_percent:.1f}%), '
          f'sampled peak RSS {peak_rss:.3f} MB (limit {rss_limit_mb:.1f} MB), '
          f'{len(samples)} actual samples after {warmup_seconds}s warmup: {report["outcome"]}.', flush=True)
except Exception as error:
    report['outcome'] = 'measurement_failed'
    report['error'] = str(error)
    print(f'Idle-launch measurement failed: {error}', file=sys.stderr, flush=True)
    passed = False
finally:
    temporary = destination.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(report, indent=2) + '\n')
    temporary.replace(destination)

raise SystemExit(0 if passed else 1)
PY
