#!/usr/bin/env bash
# esim-diagnose.sh - evidence collector for eSim 2.5 on Ubuntu 25.04
# Modes:
#   ./esim-diagnose.sh env                    -> environment + PEP668 + python removed modules
#   ./esim-diagnose.sh audit install-eSim.sh  -> static audit: apt names, PPAs, pip calls
#   ./esim-diagnose.sh scan  run.log          -> match known error signatures with line numbers
# Output is markdown, paste it straight into the report. Nothing here modifies your system.
set -u

mode="${1:-}"; target="${2:-}"

do_env() {
  echo "## Environment"
  echo '```'
  lsb_release -ds 2>/dev/null; uname -srm
  python3 --version; gcc --version 2>/dev/null | head -1
  echo "RAM: $(free -h | awk '/Mem:/{print $2}')  Disk free: $(df -h / | awk 'NR==2{print $4}')"
  echo '```'
  echo "## PEP 668 (externally-managed-environment)"
  if ls /usr/lib/python3*/EXTERNALLY-MANAGED >/dev/null 2>&1; then
    echo "- PRESENT: system pip installs will fail without a venv or --break-system-packages"
  else
    echo "- not present"
  fi
  echo "## Python modules removed in newer versions"
  for m in imp distutils asyncore telnetlib pipes; do
    if python3 -c "import $m" 2>/dev/null; then echo "- $m: importable"
    else echo "- $m: **MISSING** on $(python3 -V)"; fi
  done
  echo "## Key package candidates in this release's archive"
  echo '```'
  for p in kicad llvm llvm-dev clang ghdl verilator ngspice libngspice0-dev python3-pyqt5 python3-pip python3-venv; do
    c=$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/{print $2}')
    printf '%-20s %s\n' "$p" "${c:-NOT FOUND}"
  done
  echo '```'
  echo "## Third-party apt sources on this machine"
  grep -rhE '^(deb|URIs:)' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | grep -i ppa || echo "- none"
}

do_audit() {
  [ -f "$target" ] || { echo "usage: $0 audit install-eSim.sh"; exit 1; }
  codename=$(lsb_release -cs 2>/dev/null)
  echo "## Static audit of $target (release: $codename)"
  echo "### PPAs / external repos"
  grep -nE 'add-apt-repository|ppa:|apt-key|sources.list' "$target" || echo "none found"
  echo "### pip usage (PEP 668 risk)"
  grep -nE 'pip3? install|python3? -m pip' "$target" || echo "none found"
  echo "### Hardcoded versions worth checking"
  grep -nE 'llvm[-_]?[0-9]+|python3\.[0-9]+|gcc-[0-9]+|ghdl.*[0-9]+\.[0-9]+|verilator.*[0-9]\.[0-9]' "$target" || echo "none found"
  echo "### apt packages the script installs -> availability on this machine"
  echo '```'
  grep -nE 'apt(-get)? +install' "$target" | sed -E 's/^([0-9]+):.*apt(-get)? +install(.*)/\1 \3/' |
  while read -r ln rest; do
    for tok in $rest; do
      case "$tok" in -*|'\'|'&&'|'||'|';'|'#'*) continue;; esac
      tok="${tok//[\"\'\\;]/}"; [ -z "$tok" ] && continue
      case "$tok" in \$*) printf 'line %-5s %-30s (variable, check manually)\n' "$ln" "$tok"; continue;; esac
      cand=$(apt-cache policy "$tok" 2>/dev/null | awk '/Candidate:/{print $2}')
      if [ -z "$cand" ] || [ "$cand" = "(none)" ]; then
        printf 'line %-5s %-30s MISSING\n' "$ln" "$tok"
      else
        printf 'line %-5s %-30s %s\n' "$ln" "$tok" "$cand"
      fi
    done
  done
  echo '```'
  echo "Only entries marked MISSING are confirmed package problems. Verify before reporting."
}

do_scan() {
  [ -f "$target" ] || { echo "usage: $0 scan run.log"; exit 1; }
  echo "## Log scan: $target"
  # regex | label | what to check
  sigs=(
   'externally-managed-environment :: PEP 668 blocked pip :: Use venv; update launchers to venv python'
   'Unable to locate package :: apt package not found :: apt-cache search for new name'
   'has no installation candidate :: apt package has no candidate :: Renamed/removed or virtual package'
   'does not have a Release file :: Repo/PPA lacks this Ubuntu release :: Drop PPA or use archive package'
   'NO_PUBKEY :: Missing repo signing key :: apt-key is gone; use signed-by keyring'
   'apt-key: (command )?not found :: apt-key removed :: Use /etc/apt/keyrings + signed-by'
   'ModuleNotFoundError :: Python module missing/removed :: Check imp/distutils and venv visibility'
   "No module named '(imp|distutils)' :: Removed stdlib module :: Port code or install setuptools shim"
   'error: command .gcc. failed :: C compile failed :: Read lines above the error'
   'configure: error :: configure step failed :: Read config.log'
   'make(\[[0-9]+\])?: \*\*\* :: make failed :: Read first error, not last'
   'implicit declaration :: Old C code vs strict GCC :: Try CFLAGS=-std=gnu11 / -Wno-error'
   'conflicting types :: Old C code vs strict GCC :: Same as above'
   'llvm-config :: LLVM config issue :: Match llvm-config version to installed LLVM'
   'Could not build wheels :: pip wheel build failed :: Pinned version lacks wheel for this Python'
   'No matching distribution found :: pip pin unavailable :: Relax the version pin'
   'dpkg: error :: dpkg failure :: Run dpkg --configure -a'
   'E: Unmet dependencies :: Broken deps :: apt -f install, inspect held packages'
   'Permission denied :: Permission problem :: sudo/ownership of install dir'
   'Traceback \(most recent call last\) :: Python traceback :: Capture full trace'
   'libcanberra-gtk-module :: Renamed GTK module (libcanberra) :: Check libcanberra-gtk3-module in the archive'
   'llvm-config.*(20|21)\.[0-9]|LLVM version.*(not supported|mismatch|expected) :: LLVM version check rejects newer LLVM :: Compare llvm-config --version with the hardcoded check in the NGHDL installer'
   'error: .bool. cannot be defined|error: expected identifier.*(true|false)|incompatible pointer type|too many arguments to function|-std=gnu17 :: Old C vs GCC 15 / C23 default :: Read the first compiler error; try CFLAGS=-std=gnu17 and document why'
   'fftw3\.h|readline/readline\.h|No such file or directory.*\.h :: Missing -dev header :: apt-file search <header>, add the -dev package'
   'kicadLibrary\.tar\.xz.*(No such file|Cannot open) :: KiCad library archive missing from package :: Check library/ dir in the downloaded zip'
   'DuplicateSectionError :: Config written twice (configparser) :: Installer appends [eSim] to an existing ~/.esim config'
   'PyQt6|PyQt5.*(fail|error)|qt\.qpa :: PyQt / Qt platform problem :: Check venv python version vs wheels, QT_QPA_PLATFORM'
   'Unsupported Ubuntu version :: Dispatcher has no case for this release :: Check VERSION_ID handling in Ubuntu/install-eSim.sh'
  )
  found=0
  for s in "${sigs[@]}"; do
    re="${s%% :: *}"; rest="${s#* :: }"; label="${rest%% :: *}"; hint="${rest#* :: }"
    hits=$(grep -nE "$re" "$target" | head -5)
    if [ -n "$hits" ]; then
      found=1
      echo "### $label"
      echo "Hint: $hint"
      echo '```'; echo "$hits"; echo '```'
    fi
  done
  [ $found -eq 0 ] && echo "No known signatures matched. Inspect the tail manually:" && tail -n 30 "$target"
  echo; echo "### Last 25 lines of log (where it actually stopped)"
  echo '```'; tail -n 25 "$target"; echo '```'
}

case "$mode" in
  env) do_env;; audit) do_audit;; scan) do_scan;;
  *) sed -n '2,8p' "$0"; exit 1;;
esac
