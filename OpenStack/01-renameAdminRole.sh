#!/usr/bin/env bash
# Phase 1: rename the Keystone role "Admin" -> "admin" and propagate it via Juju.
# Run on the Juju client with admin credentials (set OPENRC to your openrc file).
set -euo pipefail
# shellcheck disable=SC1090
. "${OPENRC:-./admin-openrc.sh}"

# Step 1: Get the role ID
ROLE_ID=$(openstack role show Admin -f value -c id)
echo "Role ID: $ROLE_ID"
# Step 2: Remove the immutable flag (Bobcat sets this by default)
openstack role set --no-immutable "$ROLE_ID"

# Step 3: Rename the role, then make it immutable again
openstack role set --name admin "$ROLE_ID"
openstack role set --immutable "$ROLE_ID"

# Step 4: Verify
openstack role show admin
# Expected: shows role with name: admin

# Step 5: Confirm existing assignments still intact
openstack role assignment list --role admin --names | head -20 || true


# Trigger propagation
juju config keystone admin-role=admin
juju config keystone keystone-admin-role=admin

# Optional: Nudge other services to pick up the change (if they cache role info)
#TARGET_APPS="nova-cloud-controller neutron-api glance placement heat barbican designate octavia openstack-dashboard"
#for app in $TARGET_APPS; do
#    echo "--- Nudging $app ---"
#    juju config $app debug=true
#    # Give Juju a moment to trigger the hook
#    juju config $app debug=false
#done

# Wait for ALL units to reach active/idle before proceeding to Phase 2
# Do not continue until this is clean (takes a lot of time to propagate)
juju status
echo "***** Wait for ALL units to reach active/idle before running 02-overrideKeystonePolicy.sh *****"
echo "***** The neutron-server restart is MANDATORY after juju status settles (02-overrideKeystonePolicy.sh does it) *****"
echo "***** If Heat reports internal errors, see https://docs.cc.uniza.sk (heat internal error) *****"