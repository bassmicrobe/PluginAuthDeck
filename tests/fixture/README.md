# Synthetic activation-detection fixture

This deliberately synthetic VST3 exposes one non-editable JUCE label:
`Plugin Auth Desk Fixture is not activated on this machine`.
It does not read licenses, open audio or MIDI devices, or make network calls.
It is never copied into a user or system plug-in directory.

From the repository root, build the public app and the arm64 fixture with CMake
3.22 or newer on `PATH`, then run the test on an Apple Silicon Mac:

```sh
python3 build.py
cmake -S tests/fixture -B tests/fixture/build -DCMAKE_BUILD_TYPE=Release
cmake --build tests/fixture/build --target AuthDetectionFixture_VST3 --config Release -j 4
python3 tests/fixture/verify_installed_host.py
python3 tests/fixture/verify_installed_host.py --variant delayed
python3 tests/fixture/verify_installed_host.py --variant transient
```

The default host is the executable inside
`dist/Plugin Auth Desk.app/Contents/Helpers/AuthPluginHost.app`.
Use `--host /path/to/AuthPluginHost` to test a different built helper, and
`--output /path/to/report.json` to choose a report destination. The runner only
loads the fixture built in this checkout; there is no arbitrary plug-in option.

The delayed variant passes `PAD_FIXTURE_DELAY_MS=2200` only to its retained test
child. The non-editable label appears after that delay. A pass requires a
`licenseCandidate` containing only the fixed rule and first timestamp, followed
by two-observation evidence more than four seconds after `ready`; the original
timestamp must survive and the candidate must be removed on confirmation.

The transient variant first waits for that candidate, then writes a clear
request in its temporary directory. The fixture removes its label; a pass
requires the host to remove the candidate without producing license evidence.
It does not send UI clicks or write any production status.

The runner copies only the generated fixture into a temporary directory under
`results/fixture-staging`, removes attributes from that copy, signs it after
module metadata generation, and verifies the signature. It launches the chosen
AuthPluginHost with a temporary `--request`, its own Python parent PID, and scan
mode. Only that retained child is stopped: `quit.request`, then bounded
termination fallbacks. The observation window is 30 seconds; cleanup waits total
at most 8 seconds. The temporary request and staged plug-in are removed afterward.
No production Sessions, inventory, or license-state file is used.

Reports default to ignored `results/host-fixture[-variant]-verification.json`.
Set `FIXTURE_SAMPLE=1` to capture a one-second sample of the retained test child
if it has not succeeded after five seconds. That diagnostic is written beside
its report as `*.sample.txt`. Reports and diagnostics contain local paths and
process metadata and must not be committed or uploaded as public examples.
