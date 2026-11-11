"""Verify the default lock timeout and --nolockout against an actual held lock.

Usage: python tests/lock-wait.py <published-bt-executable>
Requires only Python's standard library. Each scenario holds a lock for 6 seconds.
"""
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time


def check_lock_wait(executable, selection, operation, expected):
    with tempfile.TemporaryDirectory(prefix='bt-lock-test-') as directory:
        command = [executable, '--root', directory] + selection
        subprocess.run(command + ['--init'], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        processes = []
        connection = sqlite3.connect(str(Path(directory) / '.buildtracker' / 'builds.db'))
        try:
            connection.execute('BEGIN EXCLUSIVE')
            started = time.monotonic()
            default = subprocess.Popen(command + operation, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            processes.append(default)
            unlimited = subprocess.Popen(command + operation + ['--nolockout'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            processes.append(unlimited)
            output, error = default.communicate(timeout=12)
            elapsed = time.monotonic() - started
            assert default.returncode == 1 and output == b'' and b'locked' in error, (output, error)
            assert 4 <= elapsed < 12, elapsed
            time.sleep(max(0, 6 - elapsed))
            assert unlimited.poll() is None, '--nolockout stopped while the lock was held'
            connection.rollback()
            output, error = unlimited.communicate(timeout=10)
            assert unlimited.returncode == 0 and output.strip() == expected and not error, (output, error)
            current = subprocess.run(command + ['--noinc'], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            assert current.stdout.strip() == expected, current.stdout
        finally:
            connection.close()
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.communicate()


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('Usage: python tests/lock-wait.py <published-bt-executable>')
    executable = str(Path(sys.argv[1]).resolve())
    check_lock_wait(executable, [], [], b'1')
    check_lock_wait(executable, ['--tag', 'api'], [], b'1')
    check_lock_wait(executable, [], ['--noinc'], b'0')
    print('Default 5-second timeout and --nolockout passed for main/tagged increments and reads.')
