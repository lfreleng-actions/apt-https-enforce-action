<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Enforce HTTPS for APT

Run this action before installing packages on a Debian or Ubuntu runner.
It switches APT sources to HTTPS and refreshes the package indexes with
`apt-get update --error-on=any`. Package signatures do not prevent an
on-path attacker from replaying a stale, signed index over HTTP. HTTPS
also protects the package requests from observation in transit.

## Runner usage

Replace `<commit-sha>` with the commit of the action you want to use.

```yaml
steps:
  - name: Enforce HTTPS for APT
    id: apt
    uses: lfreleng-actions/apt-https-enforce-action@<commit-sha>
    with:
      http_fallback_override: ${{ vars.APT_HTTP_FALLBACK }}
```

The action requires `sudo` and the runner's CA trust store. It checks
`/etc/apt/sources.list`, `.list` and deb822 `.sources` fragments under
`/etc/apt/sources.list.d`, and any local `mirror+file:` lists they name.
It rejects remote mirror lists because it cannot verify their entries.
Comments, signing options and non-HTTP URIs stay intact.

On GitHub's Ubuntu runners, an APT source can point to
`mirror+file:/etc/apt/apt-mirrors.txt` rather than to an HTTP endpoint.
The mirror list can include `azure.archive.ubuntu.com` and the Canonical
archive on amd64. The Ubuntu arm64 image uses `ports.ubuntu.com` and
ships `/etc/apt/apt-mirrors.txt` with `http://` entries, but no APT source
names that file, so the action leaves it untouched. The
**Record the hosted image's APT sources** CI step logs the image version
and actual source files on each architecture before the action changes them.

### Emergency fallback

| Input                    | Default | Enables fallback when set to `true` by |
| ------------------------ | ------- | -------------------------------------- |
| `http_fallback`          | `false` | The workflow author                    |
| `http_fallback_override` | empty   | The operator via `APT_HTTP_FALLBACK`   |

Set `APT_HTTP_FALLBACK` to `true` as a repository or organisation Actions
variable to enable fallback on the next run. Unset it when HTTPS works
again. The caller passes the variable in as shown above; the action
does not look it up. Valid values are `true`, `false`, and empty.

The action tries HTTPS first, regardless of either switch. If the
HTTPS update fails, it restores the original sources. A retry requires
both a source that originally used HTTP and permission to fall back.
The retry writes a warning annotation and job summary with
the enabling switch and the HTTP hosts that APT reports reaching. An
on-path attacker can provoke this downgrade by blocking HTTPS. Under
`harden-runner` with `egress-policy: block`, the retry needs the HTTP
host and port (default `:80`) in the allow-list.

### Outputs

| Name                  | Value                                           |
| --------------------- | ----------------------------------------------- |
| `transport`           | `https`, or `http` if the action fell back      |
| `fallback_enabled`    | `true` or `false`                               |
| `fallback_source`     | `input`, `override` (wins ties), or `none`      |
| `container_bootstrap` | Absolute path to the container bootstrap script |

## Container usage

Minimal Ubuntu and Debian images may not ship a CA bundle. Mount the
host bundle at a separate path so installing `ca-certificates` can write
the container's own trust store. The bootstrap uses the scripts in the
action directory, so mount that directory and the bundle with `readonly`.

```yaml
- name: Bootstrap container APT
  shell: bash
  env:
    BOOTSTRAP: ${{ steps.apt.outputs.container_bootstrap }}
  run: |
    action_dir=$(dirname "$BOOTSTRAP")
    host_ca=/etc/ssl/certs/ca-certificates.crt
    docker run --rm \
      --mount "type=bind,src=$action_dir,dst=/action,readonly" \
      --mount "type=bind,src=$host_ca,dst=/run/host-ca.pem,readonly" \
      ubuntu:24.04 sh "/action/$(basename "$BOOTSTRAP")" /run/host-ca.pem
```

The bootstrap runs as root in the container. It uses the mounted bundle
for the first update and the `ca-certificates` installation, then runs
another update using the container's own trust store. Pass the fallback
input and override values as optional second and third script arguments
to enable the same HTTPS-first fallback inside the container. Successful
use prints `APT transport: https` or `APT transport: http`. Run later
package commands in the same container; the example removes it at exit.
To copy fallback warnings to the job summary, mount the step's
`GITHUB_STEP_SUMMARY` file and pass its container path in that environment
variable.

## Development

Run `sh tests/apt-https.sh` for fixture tests without `sudo` or Docker.
The testing workflow covers Ubuntu 24.04 hosted runners and the pinned
Ubuntu 24.04 and Debian trixie-slim images on amd64 and arm64.
