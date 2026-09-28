# DNS and TLS

Read at Phase 8, after the target is deployed and reachable by IP. Do this yourself - DNS/domain access is
discovered in Phase 1 (`prerequisites.md` section 6), not asked for here.

## 1. Detect the DNS provider

```bash
. .vps-clone/env.sh && "$PY" "$S/doctor.py" --domain new.example.org
```
Resolves the zone's NS records over DNS-over-HTTPS and matches the suffix against the provider table (full
list: `providers.md`). If it does not recognize the suffix, resolve manually and match by hand - a provider
missing from the table can still be handled through its own panel/API once you know its name:
```bash
dig NS new.example.org +short   ||   nslookup -type=NS new.example.org
```

## 2. Read the zone before writing to it

Every provider below: list the existing records first, and only add or edit the ones this clone needs.
**Never delete a record you did not create.** A zone usually carries MX, TXT (SPF/DKIM/domain verification)
and other A/AAAA records unrelated to this clone; wiping them breaks mail and other services silently.

## 3. Create or update an A record, per provider

### Cloudflare
Token scope `Zone:DNS:Edit`, from `dash.cloudflare.com/profile/api-tokens`.
```bash
curl -s "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=app.new.example.org" \
  -H "Authorization: Bearer $CF_TOKEN"                                          # read first
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
  --data '{"type":"A","name":"app.new.example.org","content":"198.51.100.20","ttl":300,"proxied":false}'
```
`proxied:false` while a HTTP-01 certificate is being issued (the proxy intercepts 80/443 otherwise); switch
to `true` afterward only if the brief wants Cloudflare's proxy. MCP: `claude mcp add --transport http
cloudflare https://mcp.cloudflare.com` (official, OAuth in the browser) - same create/list/update ability as
the API, through tool calls instead of curl.

### Hostinger
OAuth MCP (preferred): `claude mcp add --transport http hostinger https://mcp.hostinger.com` (details:
`prerequisites.md` section 8). Once connected, call its DNS tools directly in-session - validate before
writing, then update with `overwrite:false` so it only touches the record you name instead of replacing the
zone:
```
DNS_validateDNSRecordsV1({"domain":"new.example.org","zone":[{"type":"A","name":"app","records":[{"content":"198.51.100.20"}],"ttl":300}]})
DNS_updateDNSRecordsV1({"domain":"new.example.org","overwrite":false,"zone":[{"type":"A","name":"app","records":[{"content":"198.51.100.20"}],"ttl":300}]})
```
No MCP registered and no `node`/`npx` to add it on the spot: fall back to the raw JSON-RPC stdio pattern in
`prerequisites.md` section 7, same tool names. Token-based CLI alternative (`hostinger` binary, API token
from hPanel -> profile -> Account Information -> API): install/subcommands in `providers.md`.

### AWS Route53
```bash
cat > /tmp/change.json <<'EOF'
{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"app.new.example.org","Type":"A","TTL":300,
  "ResourceRecords":[{"Value":"198.51.100.20"}]}}]}
EOF
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch file:///tmp/change.json
```
`UPSERT` creates or updates that one name/type pair only - it never touches any other record in the zone.

### DigitalOcean
```bash
doctl compute domain records list new.example.org                       # read first
doctl compute domain records create new.example.org --record-type A --record-name app --record-data 198.51.100.20 --record-ttl 300
```

### Hetzner DNS
Separate token from the Cloud API, generated at the DNS console (`dns.hetzner.com`).
```bash
curl -s "https://dns.hetzner.com/api/v1/records?zone_id=$ZONE_ID" -H "Auth-API-Token: $HDNS_TOKEN"
curl -s -X POST "https://dns.hetzner.com/api/v1/records" -H "Auth-API-Token: $HDNS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"zone_id":"'"$ZONE_ID"'","type":"A","name":"app","value":"198.51.100.20","ttl":300}'
```

### GoDaddy
Header is `sso-key`, not a bearer token.
```bash
curl -s -X PUT "https://api.godaddy.com/v3/domains/new.example.org/records/A/app" \
  -H "Authorization: sso-key $GODADDY_KEY:$GODADDY_SECRET" -H "Content-Type: application/json" \
  -d '[{"data":"198.51.100.20","ttl":3600}]'
```

### Namecheap
**`setHosts` replaces the entire record set of the domain in one call** - there is no per-record update.
Read every existing record first, build the full list, add or change the one you need inside it, and send
all of them together, or you silently delete MX/TXT/every other A record:
```bash
curl -s "https://api.namecheap.com/xml.response?ApiUser=$NC_USER&ApiKey=$NC_KEY&UserName=$NC_USER&Command=namecheap.domains.dns.getHosts&ClientIp=$MY_IP&SLD=example&TLD=org"
# resend getHosts's full list via setHosts, with app's A record added/changed:
curl -s "https://api.namecheap.com/xml.response?ApiUser=$NC_USER&ApiKey=$NC_KEY&UserName=$NC_USER&Command=namecheap.domains.dns.setHosts&ClientIp=$MY_IP&SLD=example&TLD=org&HostName1=app&RecordType1=A&Address1=198.51.100.20&TTL1=300&HostName2=...&..."
```

### registro.br
No public API. Manual only: log into `registro.br`, or use Claude in Chrome on an already logged-in session
(verify the account first - same rule as provider purchases, `prerequisites.md` section 5) to edit the zone
through its web panel.

Full CLI/API/auth reference for every provider above, and the ones not covered here: `providers.md`.

## 4. TTL strategy

- Lower the TTL of the record(s) about to move to **300 s**, at least one old-TTL period before the cutover,
  so caches expire quickly once you flip it.
- Keep it low through the cutover and the verification window; raise it back (1h-24h, per the brief or the
  zone's normal value) only once the target has been stable for a few hours.
- A new-domain flow does not need this - nothing is moving, the record is created once.

## 5. New-domain vs same-domain cutover

**New domain** (`old.example.com` stays on the source, `new.example.org` points at the target): no downtime
pressure. Create the records whenever the target is ready, let Let's Encrypt issue at leisure, verify, done.

**Same domain** (cutover): sequence matters.
1. Lower TTL (section 4), days ahead if possible.
2. Get the target fully deployed and passing `verify_web.sh --ip TARGET_IP host...` (section 7) while DNS
   still points at the source - the check always forces the connection at `TARGET_IP` itself regardless of
   what DNS says, so this proves the target would work before touching anything live.
3. If mode is `full+cutover`: freeze writes on the source, run the final data sync (`data.md`).
4. Flip the A/AAAA record(s) to the target IP (section 3).
5. Poll the same `verify_web.sh --ip TARGET_IP host...` command (section 7) until its `dns:` line also
   lists `TARGET_IP` and the certificate shows the target - that means real DNS resolution has caught up,
   not just the forced connection at the target IP.
6. Keep the source server running and untouched as rollback until the target has been stable - services
   healthy, correct certificate, no error spikes - for the window the brief expects (default: a few hours to
   a day). Nothing on the source was changed, so rollback is just the DNS write again.

## 6. Let's Encrypt: challenge types and rate limits

- **HTTP-01** (Traefik/Caddy default): the ACME server connects to port 80 of the domain's current DNS
  target. DNS must already point at the target before the certificate request; if it still points at the
  source, the challenge fails or Traefik falls back to serving its own self-signed default certificate.
- **TLS-ALPN-01**: same requirement, over port 443 instead of 80 - used when 80 cannot be exposed.
- **DNS-01**: required for wildcard certificates; the ACME client creates a `_acme-challenge` TXT record
  through the provider's API. Only practical with a token/API-based provider (Cloudflare, Route53,
  DigitalOcean, Hetzner DNS, Hostinger...) - not with `registro.br` or any manual-only zone.
- **Rate limits** change over time - check `letsencrypt.org/docs/rate-limits/` before a run touching many
  domains. The two most likely to bite a clone: a cap on certificates per registered domain per week, and a
  much tighter cap on repeatedly requesting the exact same set of hostnames - reissuing over and over while
  debugging a broken deploy burns this fast. Traefik/Certbot logs say so explicitly when hit; wait out the
  window rather than retrying blindly.

## 7. `verify_web.sh` before and after the switch

```
verify_web.sh --ip TARGET_IP host1 [host2 ...]
```
Per host: resolves the DNS A record and compares it to `TARGET_IP`, requests HTTPS using `--resolve
host:443:TARGET_IP` (this is what lets you test **before** DNS is switched - it forces the request at the
target directly regardless of what DNS currently says), reads the certificate issuer/expiry/SAN, and flags
`TRAEFIK DEFAULT CERT` or a self-signed cert (Let's Encrypt has not issued yet). Exit 1 if any host fails.

```bash
# run before touching DNS - proves the target itself is ready
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'bash /root/vps-clone/scripts/verify_web.sh --ip 198.51.100.20 app.new.example.org'

# run again after the DNS switch - proves the world actually sees the target
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'bash /root/vps-clone/scripts/verify_web.sh --ip 198.51.100.20 app.new.example.org'
```
Same command both times; the only difference is whether the DNS record has been flipped yet. The first run
catches a target-side problem before it is live, the second catches a DNS or propagation problem.

## 8. Rollback

- Record the exact previous value of every record you change, before changing it (the `getHosts`/`list`/
  `GET` call in each provider section above), into `.vps-clone/STATE.md`.
- Same-domain cutover: reverting is re-running the same create/update call with the old value. TTL is
  already low (section 4), so recovery is fast.
- New-domain flow: rollback is simply not promoting the new domain - nothing on the source or the old domain
  was ever touched.
- Never delete the source server or its old DNS record until the target has passed verification
  (`verification.md`) and the rollback window in section 5 has passed.
