# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

function uri(value,    path) {
    if (mode == "mirrors" && value ~ /^mirror(\+|:)/) {
        if (kind == "mirror" || value !~ /^mirror\+file:(\/\/)?\/[^\/]/) {
            print "Unsupported APT mirror list in " FILENAME > "/dev/stderr"
            exit 1
        }
        path = value
        sub(/^mirror\+file:(\/\/)?/, "", path)
        if (path ~ /[%?#]/) {
            print "Unsupported APT mirror path in " FILENAME > "/dev/stderr"
            exit 1
        }
        print path
    }
    if (value ~ /^http:\/\//) {
        if (mode == "check") {
            print "HTTP APT source remains in " FILENAME > "/dev/stderr"
            exit 1
        }
        if (mode == "rewrite") {
            sub(/^http:/, "https:", value)
            changed = 1
        }
    }
    return value
}

# Keep whitespace and comments intact, changing only URI tokens.
function uris(text, multiple,    result, token) {
    while (match(text, /[^[:space:]]+/)) {
        token = substr(text, RSTART, RLENGTH)
        if (token ~ /^#/)
            break
        result = result substr(text, 1, RSTART - 1) uri(token)
        text = substr(text, RSTART + RLENGTH)
        if (!multiple)
            break
    }
    return result text
}

kind == "deb822" {
    if (tolower($0) ~ /^uris:/) {
        in_uris = 1
        $0 = substr($0, 1, 5) uris(substr($0, 6), 1)
    } else if ($0 !~ /^#/ && $0 !~ /^[[:space:]]*$/) {
        if (in_uris && $0 ~ /^[[:blank:]]/)
            $0 = uris($0, 1)
        else
            in_uris = 0
    } else if ($0 ~ /^[[:space:]]*$/) {
        in_uris = 0
    }
}

kind == "list" && match($0, /^[[:blank:]]*deb(-src)?[[:blank:]]+/) {
    prefix = substr($0, 1, RLENGTH)
    rest = substr($0, RLENGTH + 1)
    if (match(rest, /^\[[^]]*\][[:blank:]]*/)) {
        prefix = prefix substr(rest, 1, RLENGTH)
        rest = substr(rest, RLENGTH + 1)
    }
    $0 = prefix uris(rest, 0)
}

kind == "mirror" { $0 = uris($0, 0) }
mode == "rewrite" { print }
END { if (mode == "rewrite" && !changed) exit 3 }
