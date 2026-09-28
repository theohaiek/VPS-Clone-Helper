# Provider Matrix

Read this at Phase 3 (choosing the target type) and Phase 4 (provisioning). One subsection per
provider: CLI, install, auth, where to generate a token, the literal commands to list resources and
create a server, snapshot/transfer support, the instance metadata endpoint, available MCP servers, and
rescue mode. Items not confirmed against an official source in this repo's research are marked
`[unverified]` — treat them as a starting guess, not a fact, and confirm against the provider's current
docs or `--help` before relying on them.

Server names, tokens, IDs and IPs below are placeholders (`<...>`, or `198.51.100.20`-style examples)
— never literal values from a real account.

## Hetzner Cloud

| Field | Value |
|---|---|
| CLI | `hcloud` |
| Install | Win: `winget install hetznercloud.cli` / `scoop install hcloud` · Mac/Linux: `brew install hcloud` |
| Auth | `hcloud context create <project>` (pastes the token) or env `HCLOUD_TOKEN` |
| Token URL | `console.hetzner.cloud/projects/<id>/security/tokens` |
| List | `hcloud server-type list` · `hcloud image list` · `hcloud location list` |
| Create | `hcloud server create --name <name> --type cx23 --image debian-12 --ssh-key vps-clone --location nbg1` |
| Snapshot -> new server | `hcloud server create-image --type snapshot <server>` then `hcloud server create ... --image <snapshot-id>` |
| Cross-account/region transfer | Same account, different project: yes (official FAQ). Different account: no documented mechanism `[unverified]` |
| Metadata endpoint | `http://169.254.169.254/hetzner/v1/metadata` (`[unverified]` exact path in this research) |
| MCP | community `dkruyt/mcp-hetzner` (145★) — no official server |
| Rescue mode | `hcloud server enable-rescue <server> --ssh-key vps-clone && hcloud server reset <server>` — boots a live Linux separate from the installed disk, SSH on port 22/222 |

## DigitalOcean

| Field | Value |
|---|---|
| CLI | `doctl` |
| Install | Win: `choco install doctl` / `scoop install doctl` `[unverified exact command]`, or download a release zip · Mac/Linux: `brew install doctl` |
| Auth | `doctl auth init` (pastes the token) |
| Token URL | `cloud.digitalocean.com/account/api/tokens` |
| List | `doctl compute size list` · `doctl compute image list --public` · `doctl compute region list` |
| SSH key upload | `doctl compute ssh-key import vps-clone --public-key-file .vps-clone/keys/id_ed25519.pub` |
| Create | `doctl compute droplet create <name> --region nyc3 --image debian-12-x64 --size s-1vcpu-1gb --ssh-keys <fingerprint>` |
| Snapshot -> new server | `doctl compute droplet-action snapshot <id> --snapshot-name <name>`, then create a droplet from that image id |
| Cross-account/region transfer | Official — transfer by email or to a team via the API (`recipient_email` / `recipient_uuid`). Cross-region: `[unverified]`, snapshots are region-scoped |
| Metadata endpoint | `http://169.254.169.254/metadata/v1/` (e.g. `.../interfaces/public/0/ipv4/address`) — confirmed |
| MCP | official, remote: `digitalocean-labs/mcp-digitalocean` (139★) at `mcp.digitalocean.com`; the older `digitalocean/digitalocean-mcp` (80★) is archived |
| Rescue mode | Panel -> Droplet -> "Recovery" tab, boot with a recovery ISO / web console mount — no dedicated `doctl` subcommand confirmed |

## Vultr

| Field | Value |
|---|---|
| CLI | `vultr-cli` |
| Install | `go install github.com/vultr/vultr-cli/v3@latest`, or a release binary (Win/Mac/Linux 64-bit) · Mac: `brew install vultr/vultr-cli/vultr-cli` |
| Auth | env `VULTR_API_KEY` (no `auth init` subcommand) |
| Token URL | `my.vultr.com/settings/#settingsapi` |
| List | `vultr-cli plans list` · `vultr-cli os list` · `vultr-cli regions list` |
| SSH key upload | `vultr-cli ssh-key create --name vps-clone --key "$(cat .vps-clone/keys/id_ed25519.pub)"` `[unverified exact flag]` |
| Create | `vultr-cli instance create --region ewr --plan vc2-1c-1gb --os <os-id> --ssh-keys <key-id> --label <name>` |
| Snapshot -> new server | `vultr-cli snapshot create --instance-id <id>`, then create an instance from that snapshot id |
| Cross-account/region transfer | Not self-service — requires a support ticket asking to move the snapshot to another account, confirmed by both sides |
| Metadata endpoint | `http://169.254.169.254/v1.json` `[unverified]` |
| MCP | official `vultr/vultr-mcp` (0★, 2026, read-only by default) hosted at `vultrmcp.com`; community `rsp2k/mcp-vultr` (22★, 335+ tools) more complete |
| Rescue mode | Web console + custom ISO / recovery option — no confirmed CLI subcommand |

## Linode / Akamai

| Field | Value |
|---|---|
| CLI | `linode-cli` |
| Install | `pip3 install linode-cli --upgrade` (needs Python3+pip) · Mac: `brew install linode-cli` |
| Auth | `linode-cli configure` (prompts for the token on first run) |
| Token URL | `cloud.linode.com` -> profile -> "API Tokens" -> Create a Personal Access Token |
| List | `linode-cli linodes types` · `linode-cli images list` · `linode-cli regions list` |
| SSH key | passed inline at create time, no separate upload subcommand needed |
| Create | `linode-cli linodes create --type g6-nanode-1 --region us-east --image linode/debian12 --authorized_keys "$(cat .vps-clone/keys/id_ed25519.pub)" --label <name> --root_pass <password>` |
| Snapshot -> new server | Via a custom image (`linode-cli images create`), not a classic "snapshot" — automated backups are a separate, paid feature |
| Cross-account/region transfer | `[unverified]` — images are private to the account |
| Metadata endpoint | `http://169.254.169.254/v1/instance` — needs a token first: `PUT http://169.254.169.254/v1/token` with header `Metadata-Token-Expiry-Seconds` — confirmed |
| MCP | official `akamai-developers/akamai-cloud-mcp` (0★, recently launched) — token can be scoped read-only |
| Rescue mode | `linode-cli linodes rescue <id> --devices...` — boots the Finnix rescue OS |

## AWS (EC2)

| Field | Value |
|---|---|
| CLI | `aws` |
| Install | Official MSI (Win) / pkg (Mac) / package (Linux) from AWS docs |
| Auth | `aws configure` (access key + secret) or `aws sso login` |
| Token/key URL | IAM Console -> Security credentials -> Create access key (`console.aws.amazon.com/iam/home#/security_credentials`) |
| List | `aws ec2 describe-instance-types` · `aws ec2 describe-images --owners amazon --filters "Name=name,Values=debian-12-*"` · `aws ec2 describe-regions` |
| SSH key upload | `aws ec2 import-key-pair --key-name vps-clone --public-key-material fileb://.vps-clone/keys/id_ed25519.pub` |
| Create | `aws ec2 run-instances --image-id <ami> --instance-type t3.micro --key-name vps-clone --security-group-ids <sg> --subnet-id <subnet>` |
| Snapshot -> new server | `aws ec2 create-image --instance-id <id> --name <ami-name>`, then `run-instances` from that AMI |
| Cross-account/region transfer | Both supported and official — share the AMI (`ModifyImageAttribute`, add the target account id) then `aws ec2 copy-image` in the target account/region |
| Metadata endpoint | `http://169.254.169.254/latest/meta-data/` — IMDSv2 requires a token first: `PUT http://169.254.169.254/latest/api/token` |
| MCP | official `awslabs/mcp` (9,736★, monorepo) — the generic "AWS API MCP Server" inside it covers EC2/Lightsail/Route53; some servers are hosted remotely by AWS |
| Rescue mode | No classic rescue mode — use the **EC2 Serial Console**, or detach the root volume and mount it on a helper instance |

## Google Cloud (Compute Engine)

| Field | Value |
|---|---|
| CLI | `gcloud` |
| Install | Official installer, all OSes, at `cloud.google.com/sdk/docs/install` |
| Auth | `gcloud init` / `gcloud auth login`; service account: `gcloud auth activate-service-account --key-file=key.json` |
| Token/key URL | `console.cloud.google.com` -> IAM & Admin -> Service Accounts -> Keys -> Add Key (JSON) |
| List | `gcloud compute machine-types list` · `gcloud compute images list --project debian-cloud --filter="family:debian-12"` · `gcloud compute regions list` |
| SSH key | passed inline at create time (`--metadata-from-file ssh-keys=...`), or project-wide via OS Login |
| Create | `gcloud compute instances create <name> --zone=us-central1-a --machine-type=e2-small --image-family=debian-12 --image-project=debian-cloud --metadata-from-file ssh-keys=<(echo "root:$(cat .vps-clone/keys/id_ed25519.pub)")` |
| Snapshot -> new server | `gcloud compute disks snapshot ...` then `gcloud compute images create --source-snapshot ...`, then create the instance from that image |
| Cross-account/region transfer | Official — share the image between projects via IAM (`gcloud compute images add-iam-policy-binding ... --member=... --role=roles/compute.imageUser`); images are global, so cross-region works the same way |
| Metadata endpoint | `http://metadata.google.internal/computeMetadata/v1/` (header `Metadata-Flavor: Google`) — confirmed |
| MCP | no official server dedicated to Compute Engine; `googleapis/mcp-toolbox` (16,501★) is for **databases**, not VMs; community `LokiMCPUniverse/gcp-mcp-server` (3★) covers Compute Engine among other services |
| Rescue mode | No classic rescue mode — use the **Serial Console**, or attach the boot disk to a rescue VM |

## Oracle Cloud (OCI)

| Field | Value |
|---|---|
| CLI | `oci` |
| Install | Linux/Mac: `bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"` · Windows: equivalent PowerShell installer, exact command `[unverified]` |
| Auth | `oci setup config` (interactive: tenancy OCID, user OCID, region, generates or reuses an API key) |
| Token/key URL | Console -> Profile icon -> User settings -> Tokens and keys -> API keys -> Add API key |
| List | `oci compute shape list --compartment-id <id>` · `oci compute image list --compartment-id <id> --operating-system "Canonical Ubuntu"` · `oci iam region list` |
| SSH key | passed inline at launch time |
| Create | `oci compute instance launch --compartment-id <id> --availability-domain <ad> --shape VM.Standard.E4.Flex --image-id <img-ocid> --subnet-id <subnet-id> --ssh-authorized-keys-file .vps-clone/keys/id_ed25519.pub` |
| Snapshot -> new server | Boot volume backup: `oci bv boot-volume-backup create --boot-volume-id <id>`; restoring creates a new boot volume, then launch an instance from it |
| Cross-account/region transfer | Sharing a boot volume backup between tenancies: `[unverified]` |
| Metadata endpoint | `http://169.254.169.254/opc/v2/instance/` (header `Authorization: Bearer Oracle`); v1 (`/opc/v1/`) is deprecated — confirmed |
| MCP | official `oracle/mcp` (447★, a suite of Oracle servers); OCI-compute-specific: `mdacolo/oci-mcp-server` or `sarthak-pansare/oci-mcp-server` (0★, community) |
| Rescue mode | No classic rescue mode — troubleshoot via the **serial console** |

## OVHcloud

| Field | Value |
|---|---|
| CLI | `ovhcloud` (Public Cloud instances are OpenStack-based) |
| Install | Binary from `github.com/ovh/ovhcloud-cli` releases; exact Windows install command `[unverified]` |
| Auth | `ovhcloud login` (interactive, generates AK/AS/CK) |
| Token URL | `api.ovh.com/createToken/?GET=/me` (or the regional endpoint: `eu.api.ovh.com`, `ca.api.ovh.com`, `api.us.ovhcloud.com`) — generates AK+AS+CK together |
| List | `ovhcloud cloud flavor list --service-id <id>` · `ovhcloud cloud image list --service-id <id>` — exact flags `[unverified]`, this CLI is recent; the mature fallback is calling the REST API directly with `python-ovh` |
| SSH key upload | Upload via the panel or `POST /me/sshKey`; exact `ovhcloud` CLI subcommand `[unverified]` |
| Create | `ovhcloud cloud instance create --service-id <id> --name <name> --flavor <flavor-id> --image <image-id> --ssh-key <keyname>` — flags `[unverified]` |
| Snapshot -> new server | Public Cloud instance snapshot supported via API/CLI; exact syntax `[unverified]` |
| Cross-account/region transfer | `[unverified]` |
| Metadata endpoint | Likely `http://169.254.169.254/openstack/latest/meta_data.json` (standard OpenStack path) `[unverified]` |
| MCP | none found, official or popular |
| Rescue mode | Panel has network-boot "Rescue mode"; exact CLI command `[unverified]` |

## Hostinger VPS

| Field | Value |
|---|---|
| CLI | `hostinger` (from `hostinger/api-cli`) |
| Install | Binary or npm; exact install command `[unverified]` |
| Auth | env `HOSTINGER_API_TOKEN`, or `~/.hostinger.yaml` |
| Token URL | hPanel -> profile icon -> Account Information -> API tab -> Generate token |
| List | `hostinger vps virtual-machines list` — subcommands for templates/regions and instance creation: `[unverified exact names]` |
| Other command | `hostinger vps vm start <vm_id>` |
| Snapshot -> new server | Snapshots exist in the panel/API; exact CLI flow `[unverified]` |
| Cross-account/region transfer | `[unverified]` |
| Metadata endpoint | `[unverified — likely no standard cloud-init metadata service]` |
| MCP | official `hostinger/api-mcp-server` (155★) — `npm install -g @hostinger/mcp` (package `hostinger-api-mcp`, needs Node >=24), 401 tools, covers both VPS and DNS |
| Rescue mode | hPanel has a recovery/reinstall option; CLI command `[unverified]` |

## Contabo

| Field | Value |
|---|---|
| CLI | `cntb` |
| Install | Release binary, Win/Mac/Linux, from `contabo/cntb` releases; exact brew/choco packaging `[unverified]` |
| Auth | `cntb config set-credentials --oauth2-clientid=<id> --oauth2-client-secret=<secret> --oauth2-user=<user> --oauth2-password=<pass>` |
| Token/key URL | `my.contabo.com` -> API section -> Client ID/Secret; API password via the "Send Link" button (email) |
| List | `cntb get instances` · `cntb get images` — regions/datacenter and create-instance subcommands: `[unverified exact flags]` |
| SSH key upload | `cntb create secret --name vps-clone-ssh --value "$(cat .vps-clone/keys/id_ed25519.pub)" --type ssh` `[unverified exact flags]` |
| Snapshot -> new server | API supports create/list/restore of an instance snapshot |
| Cross-account/region transfer | `[unverified]` |
| Metadata endpoint | `[unverified — likely no standard cloud-init metadata service]` |
| MCP | none found, official or popular |
| Rescue mode | Panel has a "Rescue System" (ISO) accessible via VNC; API/CLI support `[unverified]` |

## DNS: create an A record

Read this at Phase 8 (DNS and TLS), after `prerequisites.md` section 6 and `doctor.py --domain
<domain>` (or the NS lookup it runs) have named the provider. Same auth token as the matching
provider row above unless noted otherwise.

| DNS provider | Auth | Command | MCP |
|---|---|---|---|
| Cloudflare | Token scoped `Zone:DNS:Edit`, from `dash.cloudflare.com/profile/api-tokens` (template "Edit zone DNS") | `curl -X POST "https://api.cloudflare.com/client/v4/zones/<zone_id>/dns_records" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data '{"type":"A","name":"sub","content":"198.51.100.20","ttl":3600,"proxied":false}'` | official, two servers: `cloudflare/mcp-server-cloudflare` (4,327★, per-product) and `cloudflare/mcp` (891★, "code mode"); remote at `mcp.cloudflare.com` |
| DigitalOcean DNS | Same token as `doctl` | `doctl compute domain records create example.org --record-type A --record-name sub --record-data 198.51.100.20` | same `digitalocean-labs/mcp-digitalocean` (139★) |
| Hetzner DNS | Separate console from Hetzner Cloud — `dns.hetzner.com`, generate a token in its settings `[unverified exact URL]` | `curl -X POST "https://dns.hetzner.com/api/v1/records" -H "Auth-API-Token: $TOKEN" -H "Content-Type: application/json" -d '{"zone_id":"<id>","type":"A","name":"sub","value":"198.51.100.20","ttl":300}'` | same `dkruyt/mcp-hetzner` (145★) covers DNS |
| Hostinger | Same token as the `hostinger` VPS CLI (hPanel API section) | same `hostinger` CLI, DNS/domains group; exact subcommand `[unverified]` | same `hostinger/api-mcp-server` (155★), covers both VPS and DNS |
| AWS Route53 | Same credentials as `aws configure` | `aws route53 change-resource-record-sets --hosted-zone-id Z1R8UBAEXAMPLE --change-batch file://change.json` (JSON body: `Action` `CREATE`/`UPSERT`, type A) | no server dedicated to Route53 in `awslabs/mcp` — use its generic "AWS API MCP Server", which covers any AWS API including Route53 |
| GoDaddy | Key from `developer.godaddy.com/keys`; header `Authorization: sso-key <key>:<secret>` (not a plain Bearer token) | `curl -X PUT "https://api.godaddy.com/v3/domains/example.org/records/A/sub" -H "Authorization: sso-key $KEY:$SECRET" -H "Content-Type: application/json" -d '[{"data":"198.51.100.20","ttl":3600}]'` | `hofmeister/godaddy-mcp` (0★) / `Harshalkatakiya/godaddy-mcp` (3★, availability check only) — none official |
| Namecheap | Enable API at `namecheap.com/myaccount/settings` (API Access tab) + a mandatory IP allowlist | `curl "https://api.namecheap.com/xml.response?ApiUser=<user>&ApiKey=<key>&UserName=<user>&Command=namecheap.domains.dns.setHosts&ClientIp=<ip>&SLD=example&TLD=org&HostName1=sub&RecordType1=A&Address1=198.51.100.20&TTL1=1800"` — `setHosts` overwrites every record on the zone: re-send the existing ones plus the new one | `johnsorrentino/mcp-namecheap` (20★) / `oso95/domain-suite-mcp` (20★, multi-provider) — none official |
| registro.br | none | no confirmed public API — panel only, manual (flag it in the doctor table and don't script around it) | none found |

## Choosing the target server type

1. **Match specs, not price**: vCPU count, RAM, disk size, architecture (x86_64 vs arm64) and CPU
   vendor (Intel/AMD/Ampere) should match the source's `inventory.sh` `HARDWARE` section. A cheaper
   type with fewer vCPUs is a scope change, not a clone — do not substitute silently.
2. **Retired types get a successor, not a downgrade** (lesson from the real clone: Hetzner retired
   CX22/CX32 in favor of CX23/CX33 with the same vCPU/RAM/disk). If the exact type name from the
   source no longer appears in `list types`/`list plans`, look for the provider's stated successor
   mapping before picking "closest by price".
3. **Same OS major version as the source.** Debian 12 stays Debian 12 even if the provider's current
   default image is Debian 13 — unless the brief explicitly asks for an OS upgrade.
4. **Region**: same region/datacenter as the source when latency to a specific peer (another node of
   the same cluster, an external DB, a CDN edge) matters; otherwise pick the region the brief's cost or
   compliance constraint points to.
5. **Cost gate**: sum the monthly price of every server type chosen, across all target nodes, and
   compare it against the cap in `BRIEF.md` *before* creating anything. Over the cap: stop and ask
   (Iron rule 6 in `SKILL.md`), do not provision partially and hope it is fine.

## SSH key creation and upload

Generate once per job, reused for every target node:

```bash
mkdir -p .vps-clone/keys
ssh-keygen -t ed25519 -N '' -C vps-clone -f .vps-clone/keys/id_ed25519
```

Upload the `.pub` file with the provider-specific command from the tables above (`ssh key upload` row,
or passed inline at `create` time where the provider has no separate upload step — Linode, GCP, OCI).

## Buying through the browser (last resort, lessons 3 and 22)

Only when section 5 of `prerequisites.md` reached this option — no token/CLI, no working MCP.

1. **Verify the account before touching the order form.** Read the account name/email shown in the
   panel (top-right menu, account settings page) and match it to the account named in `BRIEF.md`.
   Wrong account is the one mistake here with no undo once a purchase completes.
2. **Fill every field with `form_input`, never `computer` click-and-type.** Typing raw keystrokes into
   a field duplicated the first character of a pasted SSH key in the real run.
3. **Never press Enter inside a multi-value field** (an IP allow-list, a tag input). Doing so submitted
   the form early and created an unwanted firewall object in the real run. Use the field's explicit
   "Add" control, and submit only via the actual submit/confirm button.
4. **Read the order summary before confirming** — server type, region, image, monthly price — with
   `read_page`/`get_page_text`, not a screenshot alone, and check it against the plan already written
   in `STATE.md`.
5. **Record server id(s) and IP(s) in `STATE.md` immediately** after creation; the panel is the only
   source of truth until `sshx.py add` pins the host key.
6. **Anything created by mistake** (wrong region, accidental duplicate, a stray object from a premature
   Enter) — delete it yourself and log it in `STATE.md` (Iron rule 11). Do not leave cleanup for the
   human.

## Snapshot shortcut vs rebuild

A snapshot/image copy is only on the table when **both** hold:
- source and target use the **same provider**, and
- the user owns (or has write access to) **both** the source and target accounts/projects.

| Provider | Same-account path |
|---|---|
| Hetzner | Same account, different project — supported (official FAQ) |
| DigitalOcean | Snapshot transfer between accounts/teams — official API (`recipient_email`/`recipient_uuid`) |
| AWS | Share the AMI to the target account (`ModifyImageAttribute`), then `aws ec2 copy-image` there |
| GCP | Share the image via IAM (`add-iam-policy-binding ... --role=roles/compute.imageUser`), then create from it in the target project |

Even when available, **prefer rebuild + redeploy** (the default strategy in `SKILL.md` Phase 3) when:
- the brief asks for `config-only` mode — a snapshot copies data and secrets verbatim, which
  config-only explicitly excludes;
- the brief asks for hardening or new passwords — a snapshot preserves the source's exact posture
  (including any weaknesses) instead of adopting the target's.

Snapshot is the right call only for an exact, `full`-mode, same-provider copy with no posture changes
requested.
