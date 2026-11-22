# Candidate fixes from static reading of upstream `install-eSim.sh` (installers branch)

STATUS KEY: [VERIFIED] reproduced in a sandbox. [HYPOTHESIS] read from code, NOT run on 25.04.
Do not put a [HYPOTHESIS] in your report as an issue until you reproduce it in your VM log.

## C1 [VERIFIED, bash logic] installKicad(): PPA detection never works
Upstream:
    findppa=$(grep -h -r "^deb.$kicadppa" /etc/apt/sources.list* > /dev/null 2>&1 || test $? = 1)
    if [ -z "$findppa" ]; then ...add-apt-repository...
`> /dev/null` throws away grep's output, so `findppa` is always empty and the PPA is
re-added on every run. Tested with a fake sources file that DOES contain the PPA: result was "MISSING".
Note deb822 files (/etc/apt/sources.list.d/*.sources, default on 24.04+) use `URIs:`, not `deb`,
so the grep would miss them anyway.
Fix:
    if ! grep -rqE "kicad/kicad-8\.0-releases" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
        sudo add-apt-repository -y ppa:kicad/kicad-8.0-releases && sudo apt-get update
    fi
Severity: low alone, but it is the entry point to C2.

## C2 [HYPOTHESIS] KiCad 8 PPA vs 25.04 (plucky)
Check: `apt-cache policy kicad` after the PPA is added; look for "does not have a Release file"
in `apt update`. If the PPA has no plucky series, fall back to the archive package:
    if ! apt-cache policy kicad | grep -q 'Candidate: [^(]'; then <fallback>; fi
    (or install via snap if archive version is incompatible with eSim 2.5's library)
Then check copyKicadLibrary (C3) against the KiCad version actually installed.

## C3 [HYPOTHESIS] copyKicadLibrary(): hardcoded "8.0" and unguarded `ls`
    latest_version=$(ls "$kicad_config_dir" | grep ...)
Under `set -e` + ERR trap, `ls` on a nonexistent ~/.config/kicad aborts the installer (KiCad
creates that dir only after first launch). Also falls back to "8.0" even if KiCad 9 is installed.
Fix: `mkdir -p "$kicad_config_dir"` before `ls`, and derive version from `kicad-cli --version`
or `dpkg-query -W -f='${Version}' kicad`.

## C4 [HYPOTHESIS] installDependency(): `python3-distutils`
Python 3.12 removed distutils; Ubuntu 25.04 ships Python 3.13. Check:
    apt-cache policy python3-distutils
If "Unable to locate package", under `set -e` the installer dies here, before any pip step,
which makes it GUI-blocking. Fix: drop it and `pip install setuptools` inside the venv.

## C5 [HYPOTHESIS] pip sources
    pip3 install --upgrade https://github.com/hdl/pyhdlparser/tarball/master
Unpinned tarball of master, plus a duplicate `pip3 install hdlparse`. Pip runs inside the venv
(good: PEP 668 does not apply), but confirm `which pip3` resolves to the venv in the log.
Verify the URL resolves; the upstream repo name may differ in case/spelling.

## Dispatcher note
Upstream dispatcher routes 25.04 to install-eSim-scripts/install-eSim-25.04.sh. Your real work
is in that file (and in nghdl's installer), which I could not run. Audit it with:
    bash esim-diagnose.sh audit install-eSim-scripts/install-eSim-25.04.sh
