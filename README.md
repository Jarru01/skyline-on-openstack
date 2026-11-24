# Skyline Dashboard on OpenStack (MAAS + Juju)

Guides, configuration and fixes for running the OpenStack **Skyline** dashboard
(2024.2) on a Charmed OpenStack cloud (Bobcat / 2023.2) managed with **MAAS** and
**Juju**: a manual source install, the Keystone/role changes Skyline needs on a
Juju-deployed cloud, and Prometheus-fed monitoring dashboards.

> **Deploying Skyline today:** use the Juju charm in
> [Jarru01/skyline-charm](https://github.com/Jarru01/skyline-charm). The manual
> deployment guide here documents how Skyline is built and configured and served
> as the basis for that charm. The OpenStack-side fixes below (role rename, Keystone
> policy override, noVNC console) are still required with the charm.
>
> Tested on a 2-node reference cloud deployed with MAAS + Juju.

## Documents in this repository

| Document | Description |
|---|---|
| [Skyline deployment guide](Skyline/skyline-2024_2-deployment-guide.md) | Full step-by-step install of Skyline 2024.2 |
| [Skyline configuration](Skyline/skyline.yaml) | Working `skyline.yaml` reference |
| [Admin role migration guide](OpenStack/admin-role-migration-guide.md) | Renaming the Keystone `Admin` role safely |
| [Fix scripts](OpenStack/) | `01-renameAdminRole.sh` · `02-overrideKeystonePolicy.sh` · `03-setConsoleProtocol.sh` |
| [Prometheus monitoring guide](Prometheus/monitoring-prometheus.md) | Prometheus-fed dashboards for Skyline |
| [Original Keystone policy](OpenStack/policy.json.old.json) | Pre-migration `policy.json` snapshot |

## Troubleshooting

### Issue 1: Inaccessible instance console

After installing skyline dashboard the console of instances was unavailable, when trying to connect to console it threw error: Unavailable console type novnc (400). Skyline apparently doesn't support spice that was configured on the underlying openstack by default.

#### Solution: console access protocol in openstack had to be set to novnc

```
juju config nova-cloud-controller console-access-protocol="novnc"
```

### Issue 2: Login to dashboard available only for skyline service user

When attempting to log in, the dashboard shows "401 Unauthorized"; underneath, Keystone answers the `identity:list_user_projects` call with HTTP 403. The root cause is the legacy policy.json format, which does not support system_scope. Skyline sends a request with a project-scoped token, which Keystone rejects due to a domain_id mismatch.

#### Solution: Updating Access Policies

Allow any user with the admin role to list projects for any user — standard behaviour for an administrator:

```
Original: "identity:list_user_projects": "rule:owner or rule:admin_and_matching_domain_id",
New:      "identity:list_user_projects": "rule:owner or rule:admin_required",
```

Apply it through the keystone charm's policy override rather than by editing
`/etc/keystone/policy.json` (a manual edit is lost on the next charm render):
[`02-overrideKeystonePolicy.sh`](OpenStack/02-overrideKeystonePolicy.sh), explained in the
[admin role migration guide](OpenStack/admin-role-migration-guide.md) Phase 3. Then test the
login as `admin@admin_domain`.

### Issue 3: Admin dashboards are read-only

The most complex issue by far was that the admin panels in the skyline dashboards were read only and nothing was editable inside them, no option to create resources/edit them was shown in the UI.

#### What Was Tried and Didn't Work (Short Summary)

- Verified system-scoped token generation — worked correctly, token had system: all scope after granting the skyline user admin role on system:all in openstack
- Modified Keystone policy.json to allow identity:list_user_projects with system-scoped Admin role — partially helped login but not admin panel
- Set enforce_new_defaults: true in skyline.yaml — no effect
- Set enforce_new_defaults: false in skyline.yaml — no effect
- Added Admin to system_admin_roles in skyline.yaml — admin panel appeared accessible but all action buttons remained greyed out or missing
- Tried various system_scope: all configurations in skyline.yaml — no effect
- Compared Keystone policies between devstack (working) and Juju+MAAS deployment, patched multiple rules ([policy file included in files](OpenStack/policy.json.old.json)) — no effect on admin panel functionality

#### What fixed the issue

* Renaming role **A**dmin -> **a**dmin (need to set `immutable` flag of Admin role to `false` beforehand)
* Change of the keystone admin role name `juju config keystone keystone-admin-role=admin`,`juju config keystone admin-role=admin`
* Changing role name Admin -> admin in the Keystone policy (via the charm's policy override)
* Changing role name Admin -> admin in `nova.conf,neutron.conf` (should be done automatically via relation)
* Restarting neutron service `sudo systemctl restart neutron-server.service`

The full procedure is scripted in [`OpenStack/`](OpenStack/) (run `01` → `02` → `03`,
waiting for `juju status` to settle in between) and documented step by step in the
[admin role migration guide](OpenStack/admin-role-migration-guide.md).

#### Why renaming role Admin → admin Fixed Everything

##### What `system_admin_roles` in `skyline.yaml` actually does

This setting controls only one thing: whether Skyline's own frontend shows the **Administrator panel switcher** in the UI at all. It's a display gate — Skyline checks "does this user's token contain any role from this list?" and if yes, it renders the admin panel toggle. That's the full extent of its influence.

So when we had `Admin` (capital A) in `system_admin_roles`, the admin panel appeared and you could switch to it. That part worked. **But every button inside it was dead.**

##### Why the buttons were dead — the real enforcement chain

When you click anything in the Administrator panel, Skyline doesn't make the decision about whether you're allowed. It passes your token to the actual **OpenStack service APIs** — Nova, Neutron, Keystone, Cinder — and those services enforce their own policies to decide if the action is permitted.

Those service policies, both Bobcat's built-in `oslo.policy` defaults and the rules your Juju deployment inherited, are written entirely with lowercase `role:admin`. For example, in Nova:

* `"context_is_admin": "is_admin:1 or role:admin"`
* `"os_compute_api:servers:index:get_all_tenants": "rule:context_is_admin"`

`oslo.policy` role matching is **case-sensitive string comparison**. `role:admin` does not match a token carrying `role:Admin`. So every single policy check across every service evaluated to `False` for your token, regardless of what Skyline's yaml said. Skyline's `system_admin_roles` list had no bearing on this — it was never consulted by Nova, Neutron, or Keystone when they enforced their own rules.

##### Why the 400 Networking error happened after the rename

Once `admin` (lowercase) worked and the admin panel functioned, listing instances still failed because Nova internally calls Neutron to fetch port and network data for each instance. This is a **service-to-service call** — Nova authenticates to Neutron using its own service credentials from `nova.conf`.

The `[neutron]` section in `nova.conf` and neutron's `keystonemiddleware` config both still referenced the old `Admin` role name. Neutron's middleware checks that the Nova service token carries the service role and that the configured admin role matches. With the mismatch, Neutron returned `401` to Nova, and Nova translated that into the generic *"Networking client is experiencing an unauthorized exception."* response back to Skyline. Restarting `neutron-server` after fixing the role reference in both config files cleared it.

##### Why Horizon Worked With Admin (Capital A)

Horizon bypassed the role name entirely because it uses project-scoped tokens, which trigger a legacy is_admin flag that grants access before the role name is ever checked. Skyline uses system-scoped tokens by design, which never set that flag, forcing every policy check to fall through to an explicit case-sensitive role name comparison — where Admin silently failed against every rule written for admin.
