# External provider guest baseline

The machine-readable contract is
[`profiles/external-cloud-v1.schema.json`](../profiles/external-cloud-v1.schema.json).
Environment profiles and automation public keys contain operational metadata;
derive them from the schema and keep their exact values in the private
infrastructure/Drive source of truth, not in this public repository.

This repo owns the guest baseline only. Cross-provider architecture and the
network/provider rollout live in the canonical Drive documents:

- [`Drive/docs/design/2026-08-17-external-cloud-provider-standard.md`](../../docs/design/2026-08-17-external-cloud-provider-standard.md)
- [`Drive/docs/runbooks/external-cloud-provider-connectivity.md`](../../docs/runbooks/external-cloud-provider-connectivity.md)

## Required sequence

1. Create an Ubuntu VM with a name matching the profile.
2. Attach the exact private network before bootstrap and select an unused IP
   only after checking the provider's live inventory/VPC.
3. Attach a firewall that denies public SSH and permits private TCP/22 only
   from the declared management source. Workload ports are a separate review.
4. Run `bootstrap-vm.sh` in CLI mode with the final hostname. Keep SSH CA and
   PKI CA enabled; the resulting administrator is `sysadmin`.
5. From this checked-out repository, run
   `configure-external-provider-access.sh` with the profile's approved public
   key and fingerprint. It appends the automation key, validates sudo/sshd,
   and preserves all provider recovery keys.
6. Require `/etc/bootstrap-done`, private-path TCP/22, a successful ZnVault-CA
   login, and a completed Archon SSH health check.
7. Let the provider sync create the Archon machine. The provider's defaults
   attach identity and connectivity; never hard-code Archon database IDs into
   a guest image or provisioning tool.

Example after the VM has its final network configuration:

```bash
sudo ./bootstrap-vm.sh \
  --hostname <approved-name> \
  --ssh-ca \
  --pki-ca \
  --yes

sudo ./configure-external-provider-access.sh \
  --public-key-file /path/from/private-profile/archon-automation.pub \
  --expected-fingerprint SHA256:<approved-fingerprint>
```

Add `--static-ip`, `--gateway`, and `--dns` only from the reviewed provider
plan. Do not copy the Clouding CIDR into generic bootstrap logic.

## Provisioner obligations

A future Clouding, AWS, DigitalOcean, or vSphere provisioner must consume a
versioned profile and emit a redacted plan/evidence record containing the
contract version. It must stop before guest bootstrap if the network/firewall
cannot satisfy the profile. Provider-specific metadata or instance identity
does not replace the common guest controls.

Secrets, auth keys, API tokens, private keys, and SSH certificates are runtime
inputs from ZnVault. They are never fields in the JSON profile.

## Two independent guest authentication paths

Human and break-glass administration continues to use short-lived ZnVault SSH
CA certificates. Archon automation uses a dedicated P-256 identity: its
private key exists only KMS-encrypted inside Archon, while the private
environment profile carries only the approved public key and fingerprint.

The guest must retain `AuthorizedKeysFile .ssh/authorized_keys`; a CA-only
hardening drop-in with `AuthorizedKeysFile none` prevents Archon automation.
The access configurator backs up and changes only that exact directive, checks
`sshd -t`, and reloads OpenSSH. It creates `sysadmin` when needed, ensures the
`adm`/`sudo` groups, installs `/etc/sudoers.d/90-sysadmin` as mode `0440`, and
keeps `.ssh`/`authorized_keys` at `0700`/`0600` with correct ownership.

Do not retire a provider root/recovery key until both a ZnVault-CA login and an
Archon health check have passed. The configurator deliberately never disables
root. Removing a recovery path is a separate, explicitly approved change.

## Automation identity rotation

1. Create a replacement P-256 SSH identity in Archon; keep its private key
   KMS-encrypted and export only its public key.
2. Add the new public key/fingerprint to the versioned profile and stage it on
   every guest without removing the old key.
3. Prove Archon health through the new identity on every machine.
4. Change the provider default and machine assignments to the new identity.
5. Remove the retired public key from guests, then retire the old Archon
   identity after an observation window.

Tailscale enrollment-key rotation is independent and uses the ZnVault alias
`archon/connectivity/tailscale-auth-key`; it never changes guest SSH identity.
