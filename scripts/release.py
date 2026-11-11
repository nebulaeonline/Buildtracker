"""Build/test/package six Native AOT RIDs using Pivot's existing SSH profiles.

Run: python scripts/release.py --config J:/coding/Pivot/artifacts/validation-config/RobPC.json
Optionally restrict work with --rids linux-x64 osx-arm64.
"""
import argparse
import base64
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
import zipfile

WORKER = r'''
import os, pathlib, shutil, subprocess, sys, tarfile, zipfile
rid, run, dotnet_root = sys.argv[1:]
windows = rid.startswith('win-')
root = pathlib.Path.home() / 'BuildtrackerBuilds' / run / rid
root.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(pathlib.Path.home() / ('bt-source-' + run + '.zip')) as z:
    z.extractall(root)
os.chdir(root)
env = dict(os.environ)
if rid.startswith('osx-'):
    dotnet_root = '/usr/local/share/dotnet' + ('/x64' if rid == 'osx-x64' else '')
if dotnet_root:
    env['DOTNET_ROOT'] = dotnet_root
    env['PATH'] = dotnet_root + os.pathsep + env.get('PATH', '')
if rid.startswith('osx-'):
    env['PATH'] = '/Library/Developer/CommandLineTools/usr/bin:' + env['PATH']
dotnet = str(pathlib.Path(dotnet_root) / ('dotnet.exe' if windows else 'dotnet')) if dotnet_root else 'dotnet'
def run_command(command):
    print('+ ' + ' '.join(command), flush=True)
    subprocess.run(command, env=env, check=True)
run_command([dotnet, '--info'])
publish = [dotnet, 'publish', 'bt.csproj', '-c', 'Release', '-r', rid, '-o', 'publish']
if rid.startswith('osx-'):
    publish += ['-p:CppCompilerAndLinker=/Library/Developer/CommandLineTools/usr/bin/clang']
run_command(publish)
exe = root / 'publish' / ('bt.exe' if windows else 'bt')
if windows:
    import struct
    binary = exe.read_bytes()
    pe_offset = struct.unpack_from('<I', binary, 0x3c)[0]
    machine = struct.unpack_from('<H', binary, pe_offset + 4)[0]
    assert machine == (0xaa64 if rid == 'win-arm64' else 0x8664), hex(machine)
    print('Verified PE architecture: ' + rid, flush=True)
if windows:
    run_command(['pwsh', '-NoProfile', '-File', 'tests/smoke.ps1', '-Executable', str(exe)])
else:
    run_command(['file', str(exe)])
    run_command(['sh', 'tests/smoke.sh', str(exe)])
package = root / ('bt-' + rid)
package.mkdir()
for item in (root / 'publish').iterdir():
    if item.suffix not in ('.pdb', '.dbg') and not item.name.endswith('.dSYM'):
        if item.is_dir(): shutil.copytree(item, package / item.name)
        else: shutil.copy2(item, package / item.name)
for name in ['README.md', 'LICENSE']:
    shutil.copy2(root / name, package / name)
archive = pathlib.Path.home() / ('bt-' + run + '-' + rid + ('.zip' if windows else '.tar.gz'))
if windows:
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
        for item in package.rglob('*'):
            if item.is_file(): z.write(item, str(item.relative_to(package.parent)))
else:
    with tarfile.open(archive, 'w:gz') as t: t.add(package, arcname=package.name)
print('PACKAGE=' + str(archive), flush=True)
# Verify the distributable after extraction, not just the publish directory.
unpacked = root / 'unpacked'
unpacked.mkdir()
if windows:
    with zipfile.ZipFile(archive) as z: z.extractall(unpacked)
else:
    with tarfile.open(archive) as t: t.extractall(unpacked)
exe = unpacked / package.name / ('bt.exe' if windows else 'bt')
if windows:
    run_command(['pwsh', '-NoProfile', '-File', 'tests/smoke.ps1', '-Executable', str(exe)])
else:
    run_command(['sh', 'tests/smoke.sh', str(exe)])
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--rids', nargs='+', default=['win-x64', 'win-arm64', 'linux-x64', 'linux-arm64', 'osx-x64', 'osx-arm64'])
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    profiles = json.loads(Path(args.config).read_text())['targets']
    run = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
    output = root / 'artifacts' / 'releases' / run
    output.mkdir(parents=True)
    source = output / ('bt-source-' + run + '.zip')
    with zipfile.ZipFile(source, 'w', zipfile.ZIP_DEFLATED) as z:
        for name in ['Program.cs', 'bt.csproj', 'global.json', 'README.md', 'LICENSE', 'tests/smoke.sh', 'tests/smoke.ps1']:
            z.write(root / name, name)
    encoded = base64.b64encode(WORKER.encode()).decode()

    def build(rid):
        profile = profiles[rid]
        options = profile['ssh_options'] + ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10']
        host = profile['host']
        log = output / (rid + '.log')
        print(rid + ': staging', flush=True)
        with log.open('w', encoding='utf-8') as stream:
            def execute(command):
                subprocess.run(command, check=True, stdout=stream, stderr=subprocess.STDOUT)
            execute(['scp', *options, str(source), host + ':bt-source-' + run + '.zip'])
            python = profile.get('python', ['python3'])[0]
            command = python + ' -c "import base64;exec(base64.b64decode(\'' + encoded + '\'))" ' + rid + ' ' + run + ' ' + (profile.get('dotnet_root') or "\"\"")
            execute(['ssh', *options, host, command])
        package_line = next(line for line in log.read_text(encoding='utf-8').splitlines() if line.startswith('PACKAGE='))
        remote = package_line[len('PACKAGE='):].replace('\\', '/')
        suffix = '.zip' if rid.startswith('win-') else '.tar.gz'
        archive = output / ('bt-' + rid + suffix)
        subprocess.run(['scp', *options, host + ':' + remote, str(archive)], check=True)
        print(rid + ': passed, ' + archive.name, flush=True)
        return archive

    failures = []
    archives = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        tasks = {pool.submit(build, rid): rid for rid in args.rids}
        for task in concurrent.futures.as_completed(tasks):
            try:
                archives.append(task.result())
            except Exception as error:
                failures.append(tasks[task])
                print(tasks[task] + ': FAILED (see target log)', file=sys.stderr, flush=True)
    with (output / 'SHA256SUMS').open('w', encoding='ascii', newline='\n') as checksums:
        for archive in sorted(archives):
            checksums.write(hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n')
    print('Output: ' + str(output), flush=True)
    return bool(failures)


if __name__ == '__main__':
    sys.exit(main())
