#!/usr/bin/env bash
# Phase 2: restart neutron-server and install a Keystone policy override through
# the keystone charm's policyd-override resource. Run after 01-renameAdminRole.sh
# has settled.
set -euo pipefail
# shellcheck disable=SC1090
. "${OPENRC:-./admin-openrc.sh}"

juju ssh neutron-api/0 "sudo systemctl restart neutron-server.service"
sleep 5
# Confirm healthy
juju ssh neutron-api/0 "sudo systemctl status neutron-server.service"
# Expected: active (running)

# Step 1: Create the overrides file.
# Scope note: cloud_admin -> admin_required makes the "admin" role a cloud-wide
# administrator regardless of domain. Fine for a single-operator cloud; review it
# before using this on a multi-domain cloud with delegated domain admins.
# create_trust lets a user create trusts for themselves (Magnum/Heat need this).
cat > keystone-overrides.yaml << 'EOF'
admin_required: "role:admin"
cloud_admin: "rule:admin_required"
admin_or_owner: "rule:admin_required or rule:owner"
identity:list_user_projects: "rule:owner or rule:admin_required"
identity:delete_trust: "rule:admin_required or user_id:%(target.trust.trustor_user_id)s"
identity:create_trust: "user_id:%(trust.trustor_user_id)s"
EOF

# Step 2: Zip it (charm requires zip format)
sudo apt install zip -y
zip keystone-policyd-override.zip keystone-overrides.yaml

# Step 3: Attach as Juju resource
juju attach-resource keystone policyd-override=keystone-policyd-override.zip

# Step 4: Enable the override
juju config keystone use-policyd-override=true

# Step 5: Verify charm applied it
#juju ssh keystone/0 "sudo ls /etc/keystone/policy.d/"
# Expected: keystone-overrides.yaml listed

#juju ssh keystone/0 "sudo cat /etc/keystone/policy.d/keystone-overrides.yaml"
# Expected: contents of your overrides file

# Wait for ALL units to reach active/idle before proceeding to Phase 3
# Do not continue until this is clean (takes a lot of time to propagate)
juju status
echo "***** Wait for ALL units to reach active/idle before running 03-setConsoleProtocol.sh *****"
echo "***** If Heat reports internal errors, see https://docs.cc.uniza.sk (heat internal error) *****"
