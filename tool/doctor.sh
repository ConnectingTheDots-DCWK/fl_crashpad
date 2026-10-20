#!/usr/bin/env bash
# `mise run doctor`: this machine against what the repository says it needs,
# and the command that fixes each thing it lacks.
#
# It reads the pins rather than knowing them — mise.toml through
# tool/mise_pin.sh, and the files that keep their own — and holds a machine
# to two tiers. **Required** is what working on this repository at all needs:
# a commit runs the hooks, a push runs the suite. A miss there fails. The rest
# belongs to one group (a platform, a maintainer's task) and only warns.
#
# It probes with mise's shims first on PATH, as the secret-scan hook puts
# them, and with mise's auto-install off: a shim installs a pin it lacks the
# first time it runs, and a check should report that rather than download it.
#
# The part above "This repository" is the same in every binding; below it is
# this one's list.
set -uo pipefail
cd "$(dirname "$0")/.."

shims="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims"
[ -d "$shims" ] && PATH="$shims:$PATH"
export PATH MISE_AUTO_INSTALL=0

failed=0
fixes=()

have() { command -v "$1" > /dev/null 2>&1; }

# The first version-shaped string a command prints, or nothing.
version_of() { "$@" 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1; }

section() { printf '\n%s\n' "$1"; }

# row <ok 0|1> <required 0|1> <name> <detail> <fix>
row() {
  local mark='✓'
  if [ "$1" != 1 ]; then
    if [ "$2" = 1 ]; then mark='✗' && failed=1; else mark='!'; fi
    fixes+=("$5")
  fi
  printf '  %s %-30s %s\n' "$mark" "$3" "$4"
}

# tool <required> <name> <fix> <command> [args to print a version]
tool() {
  local required=$1 name=$2 fix=$3
  shift 3
  if have "$1"; then
    local found
    found=$(version_of "$@")
    row 1 "$required" "$name" "${found:-present}" "$fix"
  else
    row 0 "$required" "$name" missing "$fix"
  fi
}

# pin <required> <mise.toml key> <command> [version flag]
pin() {
  local required=$1 key=$2 command=$3 flag=${4:---version} wanted found
  wanted=$(bash tool/mise_pin.sh "$key")
  found=$(have "$command" && version_of "$command" "$flag")
  if [ "$found" = "$wanted" ]; then
    row 1 "$required" "$command" "$wanted" 'mise install'
  else
    row 0 "$required" "$command" "${found:-missing}, wants $wanted" 'mise install'
  fi
}

# check <required> <name> <fix> <test...>
check() {
  local required=$1 name=$2 fix=$3
  shift 3
  if "$@" > /dev/null 2>&1; then row 1 "$required" "$name" '' "$fix"; else row 0 "$required" "$name" '' "$fix"; fi
}

hooks_installed() {
  local dir
  dir=$(git rev-parse --git-path hooks) || return 1
  grep -q pre-commit "$dir/pre-commit" 2> /dev/null && grep -q pre-commit "$dir/pre-push" 2> /dev/null
}

report() {
  if [ ${#fixes[@]} -eq 0 ]; then
    printf '\nEverything this repository asks for is here.\n'
    return
  fi
  printf '\nTo fix:\n'
  printf '%s\n' "${fixes[@]}" | awk '!seen[$0]++ { print "  " $0 }'
  if [ "$failed" = 1 ]; then
    printf '\n✗ is needed to work on this repository at all; ! only by the group it is in.\n'
  fi
}

windows=0
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) windows=1 ;; esac

# --- This repository ----------------------------------------------------------

# This repository installs the commit hook only: there is no pre-push stage.
hooks_installed() {
  local dir
  dir=$(git rev-parse --git-path hooks) || return 1
  grep -q pre-commit "$dir/pre-commit" 2> /dev/null
}

flutter_pin=$(sed -n 's/.*"flutter": *"\([^"]*\)".*/\1/p' .fvmrc)
fvm_sdk="${FVM_CACHE_PATH:-$HOME/fvm}/versions/$flutter_pin"
case "$(uname -s)" in
  Linux) native_cache="$HOME/.cache/fl_crashpad" ;;
  Darwin) native_cache="$HOME/Library/Caches/fl_crashpad" ;;
  *) native_cache="${LOCALAPPDATA:-}/fl_crashpad" ;;
esac

section required
tool 1 fvm 'https://fvm.app/documentation/getting-started/installation' fvm --version
check 1 "Flutter $flutter_pin (.fvmrc)" "fvm install $flutter_pin" test -x "$fvm_sdk/bin/flutter"
tool 1 git 'your package manager: git' git --version
if [ "$windows" = 1 ]; then
  tool 1 pre-commit 'pip install pre-commit' pre-commit --version
else
  pin 1 aqua:pre-commit/pre-commit pre-commit
fi
check 1 'hooks installed' 'pre-commit install' hooks_installed

# tool/build_native.dart: Crashpad's build, which the tests need in the cache.
section 'building the native half (tool/build_native.dart)'
pin 0 python python3
if [ "$windows" = 1 ]; then
  tool 0 'MSVC (cl)' 'a Visual Studio developer prompt' cl
elif [ "$(uname -s)" = Darwin ]; then
  tool 0 Xcode 'the App Store' xcodebuild -version
else
  # mini_chromium builds with -std=c++23, which clang accepts from 17.
  clang_major=$(have clang && version_of clang --version | cut -d. -f1)
  row "$([ "${clang_major:-0}" -ge 17 ] && echo 1 || echo 0)" 0 'clang 17 or newer' "${clang_major:-missing}" \
    'apt.llvm.org: sudo bash llvm.sh 18, then put /usr/lib/llvm-18/bin on PATH'
  check 0 "libcurl's and zlib's headers" 'your package manager: libcurl4-openssl-dev zlib1g-dev' \
    pkg-config --exists libcurl zlib
fi
check 0 'the native half in the cache' 'fvm dart run tool/build_native.dart --install' \
  bash -c "[ -n \"\$(ls -A '$native_cache' 2> /dev/null)\" ]"

section android
java_pin=$(bash tool/mise_pin.sh java)
java_major=$(have javac && version_of javac -version | cut -d. -f1)
row "$([ "${java_major:-0}" = "$(echo "$java_pin" | sed 's/^temurin-//' | cut -d. -f1)" ] && echo 1 || echo 0)" 0 \
  "JDK ${java_pin#temurin-}" "${java_major:-missing}" 'mise install'
ndk_root="${ANDROID_NDK_HOME:-${ANDROID_HOME:-$HOME/Android/Sdk}/ndk}"
check 0 'an Android NDK' 'sdkmanager "ndk;<version>", or set ANDROID_NDK_HOME' test -d "$ndk_root"

report
exit "$failed"
