#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

set -eu
export LC_ALL=C

parser=$(dirname -- "$0")/apt-sources.awk
input=${1-}
override=${2-}
ca_bundle=${3-}
apt_dir=${4:-/etc/apt}

for setting in "$input" "$override"; do
    case "$setting" in
        ''|true|false) ;;
        *) echo "APT HTTP fallback switches must be empty, true or false." >&2; exit 2 ;;
    esac
done
fallback_source=none
fallback_enabled=false
if [ "$override" = true ]; then
    fallback_source=override
elif [ "$input" = true ]; then
    fallback_source=input
fi
if [ "$fallback_source" != none ]; then
    fallback_enabled=true
fi

if [ -n "$ca_bundle" ] && [ ! -s "$ca_bundle" ]; then
    echo "The mounted CA bundle is missing or empty: $ca_bundle" >&2
    exit 2
fi

work=$(mktemp -d)
changed=0
restore_needed=false
restore_sources() {
    for backup in "$work"/backup.*; do
        [ -f "$backup" ] || continue
        original=$(cat "$work/path.${backup##*.}") || return 1
        cat "$backup" > "$original" || return 1
    done
}
finish() {
    status=$?
    if [ "$restore_needed" = true ] && ! restore_sources; then
        echo "Could not restore APT sources; backups are in $work" >&2
        exit 1
    fi
    rm -f -- "$work"/*
    rmdir -- "$work"
    exit "$status"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM

scan_source() {
    kind=$1
    file=$2
    mode=$3
    awk -v kind="$kind" -v mode="$mode" -f "$parser" "$file"
}

record_sources() {
    for file in "$apt_dir/sources.list" "$apt_dir"/sources.list.d/*.list \
        "$apt_dir"/sources.list.d/*.sources; do
        [ -f "$file" ] || continue
        # APT ignores fragment names with characters outside this set.
        case "${file##*/}" in *[!A-Za-z0-9_.-]*) continue ;; esac
        case "$file" in *.sources) kind=deb822 ;; *) kind=list ;; esac
        scan_source "$kind" "$file" mirrors >> "$work/mirrors"
        printf '%s %s\n' "$kind" "$file"
    done
}

find_sources() {
    : > "$work/mirrors"
    record_sources > "$work/sources"
    sort -u "$work/mirrors" > "$work/mirrors.sorted"
    while IFS= read -r mirror; do
        if [ ! -f "$mirror" ]; then
            echo "APT mirror list not found: $mirror" >&2
            return 1
        fi
        scan_source mirror "$mirror" mirrors
        printf 'mirror %s\n' "$mirror" >> "$work/sources"
    done < "$work/mirrors.sorted"
}

find_sources
while IFS=' ' read -r kind file; do
    status=0
    scan_source "$kind" "$file" rewrite > "$work/rewritten" || status=$?
    case "$status" in 0) ;; 3) continue ;; *) exit "$status" ;; esac
    changed=$((changed + 1))
    printf '%s\n' "$file" > "$work/path.$changed"
    cp -- "$file" "$work/original"
    mv -- "$work/original" "$work/backup.$changed"
    restore_needed=true
    cat "$work/rewritten" > "$file"
done < "$work/sources"

verify_sources() {
    find_sources
    while IFS=' ' read -r kind file; do
        scan_source "$kind" "$file" check || return 1
    done < "$work/sources"
}

apt_with_sources() {
    apt-get -o "Dir::Etc::sourcelist=$apt_dir/sources.list" \
        -o "Dir::Etc::sourceparts=$apt_dir/sources.list.d" "$@"
}

apt_with_ca() {
    if [ -n "$ca_bundle" ]; then
        apt_with_sources -o "Acquire::https::CaInfo=$ca_bundle" "$@"
    else
        apt_with_sources "$@"
    fi
}

warn_fallback() {
    # Report successful HTTP requests, without credentials or repository paths.
    hosts=$(awk '
        /^(Hit|Get):[0-9]+ http:\/\// {
            host = $2
            sub(/^http:\/\//, "", host)
            sub(/[\/?#].*$/, "", host)
            sub(/^.*@/, "", host)
            if (host ~ /^[[:alnum:].:\[\]-]+$/ && !seen[host]++)
                list = list (list == "" ? "" : ", ") host
        }
        END { print (list == "" ? "none reported" : list) }
    ' "$work/update.log")
    switch=http_fallback
    if [ "$fallback_source" = override ]; then
        switch=http_fallback_override
    fi
    warning="HTTPS APT update failed; $switch enabled HTTP fallback. HTTP hosts reached: $hosts."
    printf '::warning::%s\n' "$warning"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '%s\n' "$warning" >> "$GITHUB_STEP_SUMMARY"
    fi
}

verify_sources
transport=https
if ! apt_with_ca update --error-on=any; then
    [ "$fallback_enabled" = true ] && [ "$changed" -gt 0 ] || exit 1
    restore_sources
    restore_needed=false
    transport=http
    status=0
    apt_with_ca -o APT::Color=0 update --error-on=any > "$work/update.log" 2>&1 || status=$?
    cat "$work/update.log"
    warn_fallback
    [ "$status" -eq 0 ] || exit "$status"
fi

if [ -n "$ca_bundle" ]; then
    apt_with_ca install -y --no-install-recommends ca-certificates
    apt_with_sources update --error-on=any
fi
if [ "$transport" = https ]; then
    verify_sources
fi
restore_needed=false

printf 'APT transport: %s\n' "$transport"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'transport=%s\nfallback_enabled=%s\nfallback_source=%s\n' \
        "$transport" "$fallback_enabled" "$fallback_source" >> "$GITHUB_OUTPUT"
fi
