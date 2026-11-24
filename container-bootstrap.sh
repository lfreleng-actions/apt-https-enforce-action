#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ] || [ -z "$1" ]; then
    echo "Usage: sh container-bootstrap.sh CA_BUNDLE [HTTP_FALLBACK [HTTP_FALLBACK_OVERRIDE]]" >&2
    exit 2
fi

exec sh "$(dirname -- "$0")/apt-https.sh" "${2-}" "${3-}" "$1"
