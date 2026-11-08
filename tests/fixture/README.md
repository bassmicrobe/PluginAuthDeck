# Synthetic activation-detection fixture

This deliberately synthetic VST3 exposes one non-editable JUCE label:
`Plugin Auth Desk Fixture is not activated on this machine`.
It does not read licenses, open audio or MIDI devices, or make network calls.
It is never copied into a user or system plug-in directory.

From the repository root, build the public app and the Universal fixture with CMake
3.22 or newer on `PATH`, then run the test on an Apple Silicon Mac:

```sh
python3 build.py
cmake -S tests/fixture -B tests/fixture/build -DCMAKE_BUILD_TYPE=Release
cmake --build tests/fixture/build --target AuthDetectionFixture_VST3 --config Release -j 4
python3 tests/fixture/verify_installed_host.py
python3 tests/fixture/verify_installed_host.py --variant delayed
python3 tests/fixture/verify_installed_host.py --variant transient
python3 tests/fixture/verify_installed_host.py --factory-metadata
python3 tests/fixture/verify_installed_host.py --editor-only
python3 tests/fixture/verify_installed_host.py --cancel-during-initialization
python3 tests/fixture/verify_installed_host.py --ocr-only
python3 tests/fixture/verify_installed_host.py --ocr-only --variant delayed
python3 tests/fixture/verify_installed_host.py --ocr-only --architecture x86_64
python3 tests/fixture/verify_installed_host.py --ocr-only --architecture x86_64 --variant delayed
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

Every variant verifies that exactly one processor and editor are created and
that audio processing is never called. Normal runs require processor initialization
before editor creation and resource release during teardown. `--editor-only`
exercises the explicit initialization opt-out for compatibility comparisons. The
`--cancel-during-initialization` case writes only its temporary stop request from
inside processor initialization and pumps a short native nested loop. It requires
that cancellation prevents all editor creation and ready/evidence publication,
and that the retained child exits within the stop bound. No OCR is requested.
The
`--factory-metadata` variant removes `moduleinfo.json` from the temporary staged
copy before signing. This exercises VST3 factory metadata enumeration and catches
the previous extra processor creation during JUCE's slow enumeration path.
The synthetic event file contains only fixed test event names and is removed
with its temporary directory. Reports also require ready-phase timing fields.

`--ocr-only` paints the sentence directly into the fixture editor, exposes no
AX text node, and requires the host's `ocr_matched` diagnostic alongside its
two-observation evidence. Combine it with `--variant delayed` to reveal painted
text after 2.2 seconds. This uses only the synthetic editor and stores no image
or OCR output; reports contain fixed diagnostics and evidence rule IDs.

Before any `--ocr-only` run, the runner prepares the selected, already-built
helper with `arch -arm64 ... --ocr-warmup <parentPID>`. This uses only the helper's
fixed synthetic image, requires its exact ready response and successful exit,
and loads no plug-in. The first run of a new build can take tens of seconds while
Vision prepares its model; later runs normally reuse that preparation. The helper
has a 60-second bound and the runner allows at most 75 seconds including cleanup.
A preparation failure is recorded and prevents fixture loading. Reports include
`warmup.success` and `warmup.elapsedSeconds`. The 30-second fixture observation
clock starts afterward. Ordinary AX-label fixtures do not need this preparation.

`--architecture x86_64` runs only the synthetic Universal fixture under Rosetta
on an Apple Silicon Mac. The runner verifies the requested slice in both binaries
and the architecture reported by the host. Its masked OCR image is processed by
the same Universal helper's native arm64 worker using anonymous pipes; the worker
does not load a plug-in or create a window. Rosetta must already be installed.

The runner copies only the generated fixture into a temporary directory under
`results/fixture-staging`, removes only FinderInfo and ResourceFork attributes
from that copy while preserving quarantine and other attributes, signs it after
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
