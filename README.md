# Buildtracker

`bt` is a small C# / .NET 10 Native AOT utility that stores independent build
counters in SQLite. Successful counter operations print only the number and a
newline. Errors print to stderr and exit with code 1.

## Download v1.0.0

| Platform | Architecture | Download | SHA256 |
| --- | --- | --- | --- |
| Windows | x64 | [ZIP](https://github.com/nebulaeonline/Buildtracker/releases/download/v1.0.0/bt-win-x64.zip) | `c56cb0f8e2be44f29f1bd18b841aabd7d9ec43c4df67d3c51a98a24d5528e486` |
| Windows | ARM64 | [ZIP](https://github.com/nebulaeonline/Buildtracker/releases/download/v1.0.0/bt-win-arm64.zip) | `1c3cc16697ac0daa27fd364202cd820458bc374b7b6fce1458d6f13129d04f1e` |
| Linux (glibc) | x64 | [tar.gz](https://github.com/nebulaeonline/Buildtracker/releases/download/v1.0.0/bt-linux-x64.tar.gz) | `f4dfc863dbb3d3b4abc5c22cee6a5b4d67dab84c89ca0aa52d979888af48e5c3` |
| Linux (glibc) | ARM64 | [tar.gz](https://github.com/nebulaeonline/Buildtracker/releases/download/v1.0.0/bt-linux-arm64.tar.gz) | `12fd8956ed8725678411e5a4e99597b706e81a0798db0c8a6aca5d019b4dd55c` |
| macOS | x64 | [tar.gz](https://github.com/nebulaeonline/Buildtracker/releases/download/v1.0.0/bt-osx-x64.tar.gz) | `2f757a32f8bf9a6dd92d42a3b7a6bfe6f488f81d2b987a4c2562f9d1ecff54fb` |
| macOS | ARM64 | [tar.gz](https://github.com/nebulaeonline/Buildtracker/releases/download/v1.0.0/bt-osx-arm64.tar.gz) | `7457381a3ee8b33b21a2d48fb15cf318624e5ad3dfef6d09b49f74fef0833b6f` |

Extract the archive and keep the native SQLite library beside `bt.exe` (Windows)
or `bt` (Linux/macOS). No .NET runtime installation is required.
The SHA256 values above verify the downloaded archives. See the
[release notes](https://github.com/nebulaeonline/Buildtracker/releases/tag/v1.0.0)
for details.

## Main counter walkthrough

Run these commands from your project directory. In the transcripts below, `>`
marks the command you enter; the following line is the exact output.

```text
> bt --init
0
> bt
1
> bt
2
> bt --noinc
2
> bt --init 100
100
> bt
101
> bt --reset 50
50
> bt
51
> bt --reset
0
> bt --noinc
0
```

`--init` creates or resets the counter. Each plain `bt` call increments it once.
`--noinc` reads it without changing it. `--reset` sets an existing counter to the
given number, or to zero when no number is supplied.

## Tagged counter walkthrough

Continue in the same project directory. Each tag has its own counter; operations
on one tag leave the main counter and other tags unchanged.

```text
> bt --tag api --init 100
100
> bt --tag api
101
> bt --tag api
102
> bt --tag api --noinc
102
> bt --tag web --init
0
> bt --tag web
1
> bt --noinc
0
> bt --tag api --reset 200
200
> bt --tag api
201
> bt --tag api --reset
0
> bt --tag web --noinc
1
```

## Running from a subdirectory

For a project rooted at `/work/myapp`, the database is
`/work/myapp/.buildtracker/builds.db`. From `/work/myapp/src`, use `--root ..`
to access those same counters. Continuing the examples above:

```text
> bt --root .. --tag web --noinc
1
> bt --root .. --tag web
2
> bt --root /work/myapp --tag web --noinc
2
> bt --root .. --noinc
0
```

On Windows, an absolute root can be written as `--root "C:\projects\myapp"`.
Quote paths or tags containing spaces.

## Options

| Option | Behavior |
| --- | --- |
| No operation flag | Increment the selected counter and print the new value. |
| `--init [COUNT]` | Create or reset the selected counter to COUNT (default: 0). |
| `--reset [COUNT]` | Reset an existing counter to COUNT (default: 0). |
| `--noinc` | Print the selected counter without changing it. |
| `--tag <TAG>` | Select a case-sensitive tagged counter instead of the main counter. |
| `--root <DIR>` | Use `DIR/.buildtracker`; defaults to the current directory. |
| `--help`, `-h` | Display usage, options, and examples. |

## Using the number in a build

Initialize the counter once before running your build script. Each invocation
below captures a new number for that build.

PowerShell:

```powershell
$buildNumber = bt --tag api --root C:\projects\myapp
if ($LASTEXITCODE -ne 0) { throw 'Could not allocate a build number' }
dotnet build -p:Version="1.0.$buildNumber"
```

Bash:

```bash
build_number=$(bt --tag api --root /work/myapp) || exit 1
dotnet build -p:Version="1.0.$build_number"
```

## Storage and behavior

Data lives in `<root>/.buildtracker/builds.db`. The root defaults to the current
working directory, the parent of `.buildtracker`. From a subdirectory, pass
`--root ..` or an absolute project path. Relative roots resolve against the current
working directory. No ancestor search is performed.

Initialize each counter before using it. Repeating `--init` resets only the selected
counter. Tags are case-sensitive; the untagged counter is independent of all tags.
`--reset [COUNT]` resets an existing counter to COUNT, or 0 when omitted. It
requires prior initialization. `--init`, `--reset`, and `--noinc` are mutually
exclusive. Both initialization and reset print the resulting value.
Values range from 0 to 9223372036854775807. Overflow fails without changing the
counter. SQLite performs each increment atomically, including across processes,
with a 5-second lock timeout. Avoid resetting counters while builds are running.

## Shared folders

Use `--root` to point multiple machines or checkouts at the same shared folder
and database. For example, on a Windows SMB share:

```powershell
# Initialize once; repeating --init resets this counter.
bt --root "\\server\share\myapp" --tag api --init
# Use this same shared root from each machine to allocate build numbers.
bt --root "\\server\share\myapp" --tag api
```

On Linux/macOS, pass the mounted share's directory, such as
`bt --root /mnt/projects/myapp --tag api`. All clients must access the same
`.buildtracker/builds.db` and have permission to write in its directory.

SQLite depends on the share's file locking and synchronization behavior.
Reliability varies by network filesystem implementation and configuration,
including SMB and NFS; shared-folder concurrency has not been verified by this
project. See [SQLite Over a Network: Caveats and Considerations](https://www.sqlite.org/useovernet.html)
before relying on a network share for counter allocation. Using one machine at a
time reduces contention but does not eliminate network filesystem risks.

File-sync services such as OneDrive or Dropbox maintain separate local copies;
they do not provide a single shared database for coordinating increments.

## Build

Release archives are named `bt-<RID>.zip` for Windows and `bt-<RID>.tar.gz`
for Linux/macOS. Available targets are `win-x64`, `win-arm64`, `linux-x64`,
`linux-arm64`, `osx-x64`, and `osx-arm64`. Extract the archive and keep its native
SQLite library alongside the executable. Linux packages target glibc-based
distributions, rather than Alpine/musl.

Install the .NET 10 SDK and the Native AOT compiler prerequisites for your OS.
Publish on the target OS (Native AOT does not support cross-OS compilation):

```sh
dotnet publish bt.csproj -c Release -r win-x64 -o artifacts/win-x64
dotnet publish bt.csproj -c Release -r linux-x64 -o artifacts/linux-x64
dotnet publish bt.csproj -c Release -r osx-arm64 -o artifacts/osx-arm64
```

Distribute the publish directory, including the native SQLite library alongside
`bt.exe` on Windows or `bt` on Linux/macOS. No .NET runtime installation is needed.
Microsoft.Data.Sqlite supplies the native SQLite dependency through its
[default bundle](https://learn.microsoft.com/en-us/dotnet/standard/data/sqlite/custom-versions).

Run the integration checks against a published executable on Windows:

```powershell
pwsh -File tests/smoke.ps1 -Executable ./artifacts/win-x64/bt.exe
```

On Linux or macOS, use the POSIX shell script (no PowerShell required):

```sh
sh tests/smoke.sh ./artifacts/linux-x64/bt
# Or, on an Apple Silicon Mac:
sh tests/smoke.sh ./artifacts/osx-arm64/bt
```

Both scripts cover main and tagged counters, resets, invalid arguments, help,
overflow, concurrent increments, and execution from subdirectories. They use
temporary directories and clean up their test databases on exit.

## License

Buildtracker is distributed under the [MIT License](LICENSE).
