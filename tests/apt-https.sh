#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

set -eu

root=$(cd "${0%/*}/.." && pwd)
fixture=$(mktemp -d)
export PATH="$fixture/bin:$PATH"
export APT_TEST_DIR="$fixture/apt"
export GITHUB_OUTPUT="$fixture/outputs"
export GITHUB_STEP_SUMMARY="$fixture/summary"
mkdir -p "$fixture/bin" "$APT_TEST_DIR/sources.list.d"

cat > "$fixture/bin/apt-get" <<'STUB'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$APT_TEST_DIR/calls"
if grep -q '^deb \[arch=amd64\] http://' "$APT_TEST_DIR/sources.list"; then
    printf 'Hit:1 http://example.test stable InRelease\n'
    exit 0
fi
case "${APT_TEST_FAILURE:-}" in
    https) exit 1 ;;
    added-source)
        printf 'deb http://unexpected.test stable main\n' \
            > "$APT_TEST_DIR/sources.list.d/added.list"
        ;;
esac
STUB
chmod +x "$fixture/bin/apt-get"

cat > "$fixture/list" <<EOF
# deb http://comment.test stable main
deb [arch=amd64] http://example.test stable main
deb mirror+file://$fixture/mirrors stable main
EOF
cat > "$fixture/deb822" <<'EOF'
Types: deb
Uris: https://secure.test http://one.test
 http://two.test
Suites: stable
Components: main
Signed-By: /usr/share/keyrings/test.gpg
EOF
cat > "$fixture/mirror-original" <<'EOF'
# http://comment.test
http://mirror.test/stable	priority:1
EOF
printf 'fixture CA bundle\n' > "$fixture/ca.pem"

reset_sources() {
    cp "$fixture/list" "$APT_TEST_DIR/sources.list"
    cp "$fixture/deb822" "$APT_TEST_DIR/sources.list.d/test.sources"
    cp "$fixture/mirror-original" "$fixture/mirrors"
    : > "$APT_TEST_DIR/calls"
    : > "$GITHUB_OUTPUT"
    : > "$GITHUB_STEP_SUMMARY"
}

run() { sh "$root/apt-https.sh" "$1" "$2" "${3-}" "$APT_TEST_DIR"; }

reset_sources
run '' '' "$fixture/ca.pem"
grep -Fx 'transport=https' "$GITHUB_OUTPUT"
grep -Fx 'fallback_enabled=false' "$GITHUB_OUTPUT"
grep -Fx 'fallback_source=none' "$GITHUB_OUTPUT"
grep -Fx '# deb http://comment.test stable main' "$APT_TEST_DIR/sources.list"
grep -Fx 'deb [arch=amd64] https://example.test stable main' "$APT_TEST_DIR/sources.list"
grep -Fx 'Uris: https://secure.test https://one.test' "$APT_TEST_DIR/sources.list.d/test.sources"
grep -Fx ' https://two.test' "$APT_TEST_DIR/sources.list.d/test.sources"
grep -F 'https://mirror.test/stable' "$fixture/mirrors"
sed -n '1p' "$APT_TEST_DIR/calls" | grep -F "CaInfo=$fixture/ca.pem update --error-on=any"
sed -n '2p' "$APT_TEST_DIR/calls" | grep -F 'install -y --no-install-recommends ca-certificates'
sed -n '3p' "$APT_TEST_DIR/calls" | grep -Fx -- \
    "-o Dir::Etc::sourcelist=$APT_TEST_DIR/sources.list -o Dir::Etc::sourceparts=$APT_TEST_DIR/sources.list.d update --error-on=any"

reset_sources
run true false
grep -Fx 'transport=https' "$GITHUB_OUTPUT"
grep -Fx 'fallback_enabled=true' "$GITHUB_OUTPUT"
test ! -s "$GITHUB_STEP_SUMMARY"

assert_restored() {
    cmp "$fixture/list" "$APT_TEST_DIR/sources.list"
    cmp "$fixture/deb822" "$APT_TEST_DIR/sources.list.d/test.sources"
    cmp "$fixture/mirror-original" "$fixture/mirrors"
}

export APT_TEST_FAILURE=https
reset_sources
if run false ''; then
    echo "Fallback off: expected the HTTPS failure to fail the action" >&2
    exit 1
fi
test "$(wc -l < "$APT_TEST_DIR/calls")" -eq 1
assert_restored

for source in input override both; do
    reset_sources
    case "$source" in
        input) input=true override=false expected=input switch=http_fallback ;;
        override) input=false override=true expected=override switch=http_fallback_override ;;
        both) input=true override=true expected=override switch=http_fallback_override ;;
    esac
    run "$input" "$override" > "$fixture/log"
    test "$(wc -l < "$APT_TEST_DIR/calls")" -eq 2
    grep -Fx 'transport=http' "$GITHUB_OUTPUT"
    grep -Fx 'fallback_enabled=true' "$GITHUB_OUTPUT"
    grep -Fx "fallback_source=$expected" "$GITHUB_OUTPUT"
    warning="HTTPS APT update failed; $switch enabled HTTP fallback. HTTP hosts reached: example.test."
    grep -Fx "::warning::$warning" "$fixture/log"
    grep -Fx "$warning" "$GITHUB_STEP_SUMMARY"
    assert_restored
done

reset_sources
if run '' True || run invalid ''; then
    echo "Expected invalid fallback switches to fail" >&2
    exit 1
fi
test ! -s "$APT_TEST_DIR/calls"
assert_restored

export APT_TEST_FAILURE=added-source
if run true ''; then
    echo "Expected the final check to reject the newly added HTTP source" >&2
    exit 1
fi
test ! -s "$GITHUB_OUTPUT"
test ! -s "$GITHUB_STEP_SUMMARY"
