#!/bin/sh
set -eu

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        printf '%s\n' "Install Node.js 18+ and unzip as an administrator, then run this script again." >&2
        exit 2
    fi
}

node_major=0
if command -v node >/dev/null 2>&1; then
    node_major=$(node -p 'Number(process.versions.node.split(".")[0])')
fi
if [ "$node_major" -ge 18 ] && command -v unzip >/dev/null 2>&1; then
    printf 'Dependencies already available: Node.js %s, unzip\n' "$(node --version)"
    exit 0
fi

if command -v apt-get >/dev/null 2>&1; then
    run_as_root apt-get update
    run_as_root apt-get install -y nodejs unzip
elif command -v dnf >/dev/null 2>&1; then
    run_as_root dnf install -y nodejs unzip
elif command -v yum >/dev/null 2>&1; then
    run_as_root yum install -y nodejs unzip
elif command -v pacman >/dev/null 2>&1; then
    run_as_root pacman -Sy --needed --noconfirm nodejs unzip
elif command -v zypper >/dev/null 2>&1; then
    run_as_root zypper --non-interactive install nodejs unzip
else
    printf '%s\n' "Unsupported package manager. Install Node.js 18+ and unzip manually." >&2
    exit 2
fi

if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'Number(process.versions.node.split(".")[0])')" -lt 18 ]; then
    printf '%s\n' "The package repository provided Node.js older than 18. Install a current Node.js LTS release and rerun." >&2
    exit 2
fi
printf 'Dependencies installed: Node.js %s, unzip\n' "$(node --version)"
