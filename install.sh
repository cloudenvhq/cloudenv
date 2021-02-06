#!/bin/bash
set -u

# Check if script is run non-interactively (e.g. CI)
# If it is run non-interactively we should not prompt for passwords.
if [ "$EUID" -eq 0 ]; then
  NONINTERACTIVE=1
fi

abort() {
  printf "%s\n" "$1"
  exit 1
}

UNAME_MACHINE="$(uname -m)"
CLOUDENV_PREFIX="/usr/local"

# First check OS.
OS="$(uname)"
if [[ "$OS" == "Linux" ]]; then
  CLOUDENV_ON_LINUX=1
elif [[ "$OS" == "Darwin" ]]; then
  CLOUDENV_ON_MAC=1
elif [[ "$OS" != "Darwin" ]]; then
  abort "CloudEnv is currently only supported on macOS and Linux."
fi

# Required installation paths. To install elsewhere (which is unsupported)
# you can untar https://github.com/CloudEnv/brew/tarball/master
# anywhere you like.
if [[ -z "${CLOUDENV_ON_LINUX-}" ]]; then
  STAT="stat -f"
  CHOWN="/usr/sbin/chown"
  CHGRP="/usr/bin/chgrp"
  GROUP="admin"
  TOUCH="/usr/bin/touch"
else
  STAT="stat --printf"
  CHOWN="/bin/chown"
  CHGRP="/bin/chgrp"
  GROUP="$(id -gn)"
  TOUCH="/bin/touch"
fi

REQUIRED_BASH_VERSION=4

CLOUDENV_BIN="https://raw.githubusercontent.com/cloudenvhq/cli/master/cloudenv"

# string formatters
if [[ -t 1 ]]; then
  tty_escape() { printf "\033[%sm" "$1"; }
else
  tty_escape() { :; }
fi
tty_mkbold() { tty_escape "1;$1"; }
tty_underline="$(tty_escape "4;39")"
tty_blue="$(tty_mkbold 34)"
tty_red="$(tty_mkbold 31)"
tty_bold="$(tty_mkbold 39)"
tty_reset="$(tty_escape 0)"

have_sudo_access() {
  local -a args
  if [[ -n "${SUDO_ASKPASS-}" ]]; then
    args=("-A")
  elif [[ -n "${NONINTERACTIVE-}" ]]; then
    args=("-n")
  fi

  if [[ -z "${HAVE_SUDO_ACCESS-}" ]]; then
    if [[ -n "${args[*]-}" ]]; then
      SUDO="/usr/bin/sudo ${args[*]}"
    else
      SUDO="/usr/bin/sudo"
    fi
    if [[ -n "${NONINTERACTIVE-}" ]]; then
      ${SUDO} -l mkdir &>/dev/null
    else
      ${SUDO} -v && ${SUDO} -l mkdir &>/dev/null
    fi
    HAVE_SUDO_ACCESS="$?"
  fi

  return "$HAVE_SUDO_ACCESS"
}

shell_join() {
  local arg
  printf "%s" "$1"
  shift
  for arg in "$@"; do
    printf " "
    printf "%s" "${arg// /\ }"
  done
}

chomp() {
  printf "%s" "${1/"$'\n'"/}"
}

ohai() {
  printf "${tty_blue}==>${tty_bold} %s${tty_reset}\n" "$(shell_join "$@")"
}

warn() {
  printf "${tty_red}Warning${tty_reset}: %s\n" "$(chomp "$1")"
}

execute() {
  if ! "$@"; then
    abort "$(printf "Failed during: %s" "$(shell_join "$@")")"
  fi
}

execute_sudo() {
  local -a args=("$@")
  if have_sudo_access; then
    if [[ -n "${SUDO_ASKPASS-}" ]]; then
      args=("-A" "${args[@]}")
    fi
    ohai "/usr/bin/sudo" "${args[@]}"
    execute "/usr/bin/sudo" "${args[@]}"
  else
    ohai "${args[@]}"
    execute "${args[@]}"
  fi
}

getc() {
  local save_state
  save_state=$(/bin/stty -g)
  /bin/stty raw -echo
  IFS= read -r -n 1 -d '' "$@"
  /bin/stty "$save_state"
}

wait_for_user() {
  local c
  echo
  echo "Press RETURN to continue or any other key to abort. If you would like to do these steps yourself, just press any other key"
  getc c
  # we test for \r and \n because some stuff does \r instead
  if ! [[ "$c" == $'\r' || "$c" == $'\n' ]]; then
    exit 1
  fi
}

major_minor() {
  echo "${1%%.*}.$(x="${1#*.}"; echo "${x%%.*}")"
}

version_gt() {
  [[ "${1%.*}" -gt "${2%.*}" ]] || [[ "${1%.*}" -eq "${2%.*}" && "${1#*.}" -gt "${2#*.}" ]]
}
version_ge() {
  [[ "${1%.*}" -gt "${2%.*}" ]] || [[ "${1%.*}" -eq "${2%.*}" && "${1#*.}" -ge "${2#*.}" ]]
}
version_lt() {
  [[ "${1%.*}" -lt "${2%.*}" ]] || [[ "${1%.*}" -eq "${2%.*}" && "${1#*.}" -lt "${2#*.}" ]]
}

get_permission() {
  $STAT "%A" "$1"
}

user_only_chmod() {
  [[ -d "$1" ]] && [[ "$(get_permission "$1")" != "755" ]]
}

exists_but_not_writable() {
  [[ -e "$1" ]] && ! [[ -r "$1" && -w "$1" && -x "$1" ]]
}

get_owner() {
  $STAT "%u" "$1"
}

file_not_owned() {
  [[ "$(get_owner "$1")" != "$(id -u)" ]]
}

get_group() {
  $STAT "%g" "$1"
}

file_not_grpowned() {
  [[ " $(id -G "$USER") " != *" $(get_group "$1") "*  ]]
}

outdated_bash() {
  local bash_version
  bash_version=$(bash --version | head -n1 | sed 's/^[^0-9]*//;s/[^0-9].*$//')
  version_lt "$bash_version" "$REQUIRED_BASH_VERSION"
}

if outdated_bash
then
  if command -v zsh >/dev/null
  then
    REPLACE_BASH_WITH_ZSH=1
  else
    abort "$(cat <<-EOFABORT
    CloudEnv requires bash $REQUIRED_BASH_VERSION (or higher) which was not found on your system.
    Install bash $REQUIRED_BASH_VERSION (or higher) and add its location to your PATH.
    On Mac OS X, try running: brew install bash
EOFABORT
      )"
  fi
fi

# USER isn't always set so provide a fall back for the installer and subprocesses.
if [[ -z "${USER-}" ]]; then
  USER="$(chomp "$(id -un)")"
  export USER
fi

# Invalidate sudo timestamp before exiting (if it wasn't active before).
if ! /usr/bin/sudo -n -v 2>/dev/null; then
  trap '/usr/bin/sudo -k' EXIT
fi

# Things can fail later if `pwd` doesn't exist.
# Also sudo prints a warning message for no good reason
cd "/usr" || exit 1

####################################################################### script

if ! command -v curl >/dev/null; then
    abort "$(cat <<EOABORT
You must install cURL before installing CloudEnv.
EOABORT
)"
fi

echo
ohai "This script downloads the CloudEnv CLI:"
echo " curl ${tty_underline}https://raw.githubusercontent.com/cloudenvhq/cli/master/cloudenv${tty_reset} -o ${CLOUDENV_PREFIX}/bin/cloudenv"
echo
ohai "and then runs this command to make it executable:"
echo " chmod +x ${CLOUDENV_PREFIX}/bin/cloudenv"
echo

if [[ -z "${NONINTERACTIVE-}" ]]; then
  wait_for_user
fi

if [ ! -w "${CLOUDENV_PREFIX}/bin/cloudenv" ]; then
  if [[ -z "${CLOUDENV_ON_LINUX-}" ]]; then
    have_sudo_access
  else
    if [[ -n "${NONINTERACTIVE-}" ]] ||
       [[ -w "${CLOUDENV_PREFIX_DEFAULT}" ]] ||
       [[ -w "/home" ]]; then
      CLOUDENV_PREFIX="$CLOUDENV_PREFIX_DEFAULT"
    else
      trap exit SIGINT
      if ! /usr/bin/sudo -n -v &>/dev/null; then
        ohai "Select the CloudEnv installation directory"
        echo "- ${tty_bold}Enter your password${tty_reset} to install to ${tty_underline}${CLOUDENV_PREFIX_DEFAULT}${tty_reset} (${tty_bold}recommended${tty_reset})"
        echo "- ${tty_bold}Press Control-C${tty_reset} to cancel installation"
      fi
      if have_sudo_access; then
        CLOUDENV_PREFIX="$CLOUDENV_PREFIX_DEFAULT"
      fi
      trap - SIGINT
    fi
  fi

  if [[ -d "${CLOUDENV_PREFIX}" && ! -x "${CLOUDENV_PREFIX}" ]]; then
    abort "$(cat <<EOABORT
  The CloudEnv prefix, ${CLOUDENV_PREFIX}, exists but is not searchable.
  If this is not intentional, please restore the default permissions and
  try running the installer again:
      sudo chmod 775 ${CLOUDENV_PREFIX}
EOABORT
  )"
  fi

  directories=(bin)
  mkdirs=()
  for dir in "${directories[@]}"; do
    if ! [[ -d "${CLOUDENV_PREFIX}/${dir}" ]]; then
      mkdirs+=("${CLOUDENV_PREFIX}/${dir}")
    fi
  done

  if [[ "${#mkdirs[@]}" -gt 0 ]]; then
    ohai "The following new directories will be created:"
    printf "%s\n" "${mkdirs[@]}"
  fi

  if [[ ! -d "${CLOUDENV_PREFIX}" ]]; then
    execute_sudo "/bin/mkdir" "-p" "${CLOUDENV_PREFIX}"
    if [[ -z "${CLOUDENV_ON_LINUX-}" ]]; then
      execute_sudo "$CHOWN" "root:wheel" "${CLOUDENV_PREFIX}"
    else
      execute_sudo "$CHOWN" "$USER:$GROUP" "${CLOUDENV_PREFIX}"
    fi
  fi

  if [[ "${#mkdirs[@]}" -gt 0 ]]; then
    execute_sudo "/bin/mkdir" "-p" "${mkdirs[@]}"
    execute_sudo "/bin/chmod" "g+rwx" "${mkdirs[@]}"
    execute_sudo "$CHOWN" "$USER" "${mkdirs[@]}"
    execute_sudo "$CHGRP" "$GROUP" "${mkdirs[@]}"
  fi
fi

ohai "Downloading and installing CloudEnv..."
(
  if [ -w "${CLOUDENV_PREFIX}/bin/cloudenv" ]; then
    execute "curl" "${CLOUDENV_BIN}" "-o" "${CLOUDENV_PREFIX}/bin/cloudenv"
    execute "/bin/chmod" "+x" "${CLOUDENV_PREFIX}/bin/cloudenv"
  else
    execute_sudo "curl" "${CLOUDENV_BIN}" "-o" "${CLOUDENV_PREFIX}/bin/cloudenv"
    execute_sudo "/bin/chmod" "+x" "${CLOUDENV_PREFIX}/bin/cloudenv"
    execute_sudo "$CHOWN" "$USER" "${CLOUDENV_PREFIX}/bin/cloudenv"
  fi
) || exit 1

if [[ ":${PATH}:" != *":${CLOUDENV_PREFIX}/bin:"* ]]; then
  warn "${CLOUDENV_PREFIX}/bin is not in your PATH."
fi

if [[ ! -z "${REPLACE_BASH_WITH_ZSH-}" ]]; then
  top='#!/usr/bin/env zsh'
  rest=$(awk 'NR > 1 { print }' "$CLOUDENV_PREFIX/bin/cloudenv")
  echo "$top" > "$CLOUDENV_PREFIX/bin/cloudenv"
  echo "$rest" >> "$CLOUDENV_PREFIX/bin/cloudenv"
fi

ohai "Installation successful!"
echo

# Use the shell's audible bell.
if [[ -t 1 ]]; then
  printf "\a"
fi

ohai "Next steps:"
if [[ "$UNAME_MACHINE" == "arm64" ]] || [[ -n "${CLOUDENV_ON_LINUX-}" ]]; then
  case "$SHELL" in
    */bash*)
      if [[ -r "$HOME/.bash_profile" ]]; then
        shell_profile="$HOME/.bash_profile"
      else
        shell_profile="$HOME/.profile"
      fi
      ;;
    */zsh*)
      shell_profile="$HOME/.zprofile"
      ;;
    *)
      shell_profile="$HOME/.profile"
      ;;
  esac

  cat <<EOS
EOS
fi

echo "- Run \`cloudenv login\` to get started"
echo "- Once logged in, run \`cloudenv init\` inside your app's home directory to initialize a 256-bit random cryptographic key"
echo "- Further documentation: "
echo "    ${tty_underline}https://github.com/cloudenvhq/cli${tty_reset}"
echo