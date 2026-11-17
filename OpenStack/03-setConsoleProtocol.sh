#!/usr/bin/env bash
# Phase 3: switch the instance console to noVNC (Skyline does not support SPICE).
set -euo pipefail
# shellcheck disable=SC1090
. "${OPENRC:-./admin-openrc.sh}"

juju config nova-cloud-controller console-access-protocol="novnc"

juju status
echo "***** Wait for ALL units to reach active/idle and you're done. *****"
echo "***** If Heat reports internal errors, see https://docs.cc.uniza.sk (heat internal error) *****"
