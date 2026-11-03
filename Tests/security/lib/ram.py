#!/usr/bin/python3 -I
# ram.py [--limit-mb 6000] [--timeout 60] -- COMMAND…: runs COMMAND, samples its memory every 50 ms, kills it over the
# limit or the timeout. One line: «PEAK_MB SECONDS RC STATE LAST_OUTPUT_LINE»; STATE is ok, oltre-ram or oltre-tempo.
import ctypes, signal, subprocess, sys, tempfile, time

libproc = ctypes.CDLL('/usr/lib/libproc.dylib')

def memory_mb(pid):
    info = (ctypes.c_uint8 * 256)()
    if libproc.proc_pid_rusage(pid, 0, info) != 0:   # RUSAGE_INFO_V0
        return 0
    data = bytes(info)
    resident = int.from_bytes(data[64:72], 'little')
    footprint = int.from_bytes(data[72:80], 'little')
    return max(resident, footprint) / 1e6   # the footprint counts compressed memory too, the resident size doesn't

args = sys.argv[1:]
limit, timeout = 6000.0, 60.0
while args[0] != '--':
    if args[0] == '--limit-mb': limit = float(args[1])
    elif args[0] == '--timeout': timeout = float(args[1])
    else: sys.exit('opzione sconosciuta')
    args = args[2:]
args = args[1:]

with tempfile.TemporaryFile() as log:
    start = time.time()
    p = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT)
    peak, state = 0.0, 'ok'
    while p.poll() is None:
        peak = max(peak, memory_mb(p.pid))
        if peak > limit: state = 'oltre-ram'
        elif time.time() - start > timeout: state = 'oltre-tempo'
        if state != 'ok':
            p.send_signal(signal.SIGKILL)
            break
        time.sleep(0.05)
    p.wait()
    seconds = time.time() - start
    log.seek(0)
    lines = log.read().decode('utf-8', 'replace').strip().splitlines()
print(f'{peak:.0f} {seconds:.1f} {p.returncode} {state} {(lines[-1] if lines else "")[:150]}')
