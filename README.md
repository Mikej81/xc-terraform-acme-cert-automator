# ACME Certificate Automation with F5 XC Load Balancer Discovery

## Proof of Concept

Customers want automated certificate lifecycle management, but migrating HTTPS Custom Cert load balancers to AutoCert isn't supported today. This project works around that - it uses ACMEv2 with DNS-01 challenges to issue new certs that you can swap into your existing LB configs without changing the load balancer type, and it handles renewals automatically.

---

## Table of Contents

- [Architecture](#architecture)
- [Migration and Renewal](#migration-and-renewal)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [ACME Certificate Authority Selection](#acme-certificate-authority-selection)
- [DNS Challenge Providers](#dns-challenge-providers)
- [F5 XC Load Balancer Discovery](#f5-xc-load-balancer-discovery)
- [Certificate Lifecycle and Automated Renewal](#certificate-lifecycle-and-automated-renewal)
- [Let's Encrypt Certificate Lifetime Changes (2025-2028)](#lets-encrypt-certificate-lifetime-changes-2025-2028)
- [Variables Reference](#variables-reference)
- [Outputs Reference](#outputs-reference)
- [File Structure](#file-structure)
- [Troubleshooting](#troubleshooting)
- [Security Considerations](#security-considerations)

---

## Architecture

Under the hood, this uses the [vancluever/acme](https://registry.terraform.io/providers/vancluever/acme/latest) Terraform provider, which wraps [lego](https://go-acme.github.io/lego/). It talks to any ACME CA (Let's Encrypt, ZeroSSL, Google Trust Services, etc.) and proves domain ownership via DNS-01 challenges - meaning lego creates `_acme-challenge` TXT records through your DNS provider's API.

The DNS provider is pluggable. Out of the box you can use InfoBlox, Cloudflare, Route 53, Azure DNS, Google Cloud DNS, F5 XC DNS, or any of the [90+ providers lego supports](https://go-acme.github.io/lego/dns/). Switching providers is just changing one variable.

Once a cert is issued, it gets bundled into a password-protected PKCS#12 (.pfx) file in `./certs/`. No plaintext private key ever touches disk. The PFX works with Envoy, IIS, or anything else that speaks PKCS#12.

The primary use case is **XC certificate migration**: a one-time script queries the F5 XC API to find internet-facing HTTPS (manual certificate) load balancers that need ACME-based certificates and generates a `certificates.auto.tfvars.json` file. Terraform picks that up, issues a cert for each LB, and optionally creates a `volterra_certificate` object in the same namespace. After that first run, you just schedule `terraform apply` and it handles renewals on its own.

**What gets renewed and when:**

- The **standalone PFX** renews on schedule whenever `create_local_pfx` is true
- **Every cert** in `xc_certificates` renews on schedule regardless of other settings
- When `create_xc_certificates = true` (the default), renewed certs get pushed to XC automatically - the `volterra_certificate` object updates in place. If the LB is already using that cert object, you're done. If not, you'll need to point the LB at it once (manually or via Terraform). This could be automated in the future.
- When `create_xc_certificates = false`, certs still renew in Terraform state, but nothing gets pushed to XC

**Design decisions worth knowing about:**

- **DNS-01 only** - no inbound port 80 needed, works from behind firewalls
- **Pluggable everything** - swap DNS providers or CAs with a variable change, no code edits
- **Discovery runs once** - the script writes `certificates.auto.tfvars.json` and that's it. No XC API calls during renewal.
- **XC push is optional** - set `create_xc_certificates = false` if you want to handle the import yourself
- **Local PFX is optional** - set `create_local_pfx = false` to skip writing to disk
- **The Volterra provider is needy** - it validates its config at plan time, so you always need `xc_api_p12_file`, `xc_api_p12_password`, and the `VES_P12_PASSWORD` env var set, even if you're not using any XC features
- **One ACME account** - shared across standalone and XC certs

---

## Migration and Renewal

### Step 1: Migration (run once)

Before Terraform can issue certificates, it needs to know which load balancers need them. The discovery script talks to the XC API, finds the HTTPS LBs in the namespaces you care about, grabs their domain lists, and writes everything to `certificates.auto.tfvars.json` - a standard Terraform variable file that gets picked up automatically.

**1a. Run the discovery script:**

```bash
bash scripts/discover_xc_lbs.sh \
  --p12-file /path/to/api-credential.p12 \
  --p12-pass yourpassword \
  --tenant-url https://tenant.console.ves.volterra.io/api \
  --namespaces production,staging \
  --domain-filter example.com
```

Here's what each flag does:

- `--p12-file` / `--p12-pass` - your XC API P12 credential and its password. Same P12 you use for the Volterra provider. You can generate one in the XC console under Administration > Credentials.
- `--tenant-url` - your XC tenant API URL. Make sure to include the `/api` suffix (e.g. `https://tenant.console.ves.volterra.io/api`).
- `--namespaces` - comma-separated list of XC namespaces to scan. The script looks at every HTTP load balancer in each namespace and picks out the ones that are both HTTPS-enabled and internet-facing.
- `--domain-filter` (optional) - comma-separated domain suffixes. When set, the script only includes LBs whose domains all match at least one of these suffixes. This is useful when you don't want to accidentally issue certs for LBs in DNS zones you don't control. Leave it off to include everything.

Once it finishes, check what it found:

```bash
cat certificates.auto.tfvars.json | jq .
```

See [F5 XC Load Balancer Discovery](#f5-xc-load-balancer-discovery) for the full details on filtering logic and what qualifies as "internet-facing HTTPS."

**1b. Issue certificates and push to XC:**

```bash
export VES_P12_PASSWORD="your-p12-password"
terraform init
terraform plan -var-file=your.tfvars    # review what will be created
terraform apply -var-file=your.tfvars   # issue certs and push to XC
```

Terraform picks up `certificates.auto.tfvars.json` automatically (that's how `*.auto.tfvars.json` files work), runs a DNS-01 challenge for each cert, and creates `volterra_certificate` objects in XC if `create_xc_certificates` is true.

### Step 2: Renewal (run on a schedule)

Just run `terraform apply` again. Terraform checks every cert's expiry date in state - both the standalone cert and every entry in `xc_certificates`. If anything is within `min_days_remaining` days of expiring, it re-issues via ACME, updates the PFX, and pushes to XC. If everything's still valid, you get "No changes."

```bash
# Cron - runs daily, only actually renews when something's close to expiring
30 2 * * * root cd /opt/acme-automation && VES_P12_PASSWORD="..." terraform apply -auto-approve -input=false
```

### CI/CD example (GitLab CI)

```yaml
stages:
  - migrate
  - renew

# Step 1: Run once to discover LBs and issue certs
acme-migrate:
  stage: migrate
  rules:
    - if: $CI_PIPELINE_SOURCE == "web"  # manual trigger only
  script:
    - bash scripts/discover_xc_lbs.sh
        --p12-file "$XC_P12_FILE"
        --p12-pass "$XC_P12_PASSWORD"
        --tenant-url "$XC_TENANT_URL"
        --namespaces "$XC_NAMESPACES"
        --domain-filter "$XC_DOMAIN_FILTER"
    - terraform init -input=false
    - terraform apply -auto-approve -input=false
  variables:
    VES_P12_PASSWORD: $VES_P12_PASSWORD_CI

# Step 2: Scheduled renewal - runs daily
acme-renew:
  stage: renew
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
  script:
    - terraform init -input=false
    - terraform apply -auto-approve -input=false
  variables:
    VES_P12_PASSWORD: $VES_P12_PASSWORD_CI
```

---

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| Terraform | >= 1.3 | Uses HCL features from 1.3+ |
| DNS provider API access | - | Credentials for whatever DNS provider you're using |
| `bash`, `curl`, `jq`, `openssl` | - | Only needed for the migration discovery script |
| F5 XC API P12 credential | - | The Volterra provider needs this even if you're not doing XC stuff |
| F5 XC API token | - | Only if you're using F5 XC as your DNS provider |

### Provider versions

| Provider | Source | Version |
|----------|--------|---------|
| acme | `vancluever/acme` | `~> 2.0` |
| tls | `hashicorp/tls` | `~> 4.0` |
| local | `hashicorp/local` | `~> 2.0` |
| volterra | `volterraedge/volterra` | `~> 0.11` |

---

## Quick Start

### 1. Clone and configure

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
```

### 2. Initialize and apply

```bash
terraform init
terraform plan     # review what will be created
terraform apply    # issue the certificate
```

### 3. Find your certificate

```bash
ls -la ./certs/
# certificate.pfx - PKCS#12 bundle (cert + chain + private key, password-protected)
```

### Minimal tfvars (Let's Encrypt + InfoBlox)

```hcl
email   = "team@example.com"
domains = ["app.example.com", "www.app.example.com"]

acme_server_url = "https://acme-staging-v02.api.letsencrypt.org/directory"
p12_password    = "00000000"

infoblox_host     = "gridmaster.internal.example.com"
infoblox_username = "acme-svc"
infoblox_password = "secret"
```

### Minimal tfvars (Let's Encrypt + Cloudflare)

```hcl
email   = "team@example.com"
domains = ["app.example.com"]

acme_server_url = "https://acme-staging-v02.api.letsencrypt.org/directory"
p12_password    = "00000000"

dns_provider = "cloudflare"
dns_provider_config = {
  CF_DNS_API_TOKEN = "your-cloudflare-api-token"
}
```

---

## ACME Certificate Authority Selection

The `acme_server_url` variable picks which CA issues your certs. Any ACME-compliant CA works.

### Available CAs

| CA | Directory URL | EAB Required | Cert Lifetime | Notes |
|----|--------------|:---:|---|---|
| **Let's Encrypt (staging)** | `https://acme-staging-v02.api.letsencrypt.org/directory` | No | 90 days | Fake certs, no rate limits. **Start here.** |
| **Let's Encrypt (production)** | `https://acme-v02.api.letsencrypt.org/directory` | No | 90 days* | [Rate limits](https://letsencrypt.org/docs/rate-limits/) apply |
| **ZeroSSL** | `https://acme.zerossl.com/v2/DV90` | Yes | 90 days | Free, needs EAB from [ZeroSSL dashboard](https://app.zerossl.com/developer) |
| **Google Trust Services** | `https://dv.acme-v02.api.pki.goog/directory` | Yes | 90 days | Free, EAB from [Google Cloud console](https://cloud.google.com/certificate-manager/docs/public-ca-tutorial) |
| **BuyPass** | `https://api.buypass.com/acme/directory` | Yes | 180 days | Free tier discontinued Oct 2025 |

*\* Let's Encrypt lifetime is changing - see [Certificate Lifetime Changes](#lets-encrypt-certificate-lifetime-changes-2025-2028).*

### External Account Binding (EAB)

CAs other than Let's Encrypt usually require EAB to link your ACME account to their platform:

```hcl
acme_server_url = "https://acme.zerossl.com/v2/DV90"
eab_key_id      = "aAbBcCdDeEfF..."
eab_hmac_key    = "base64-encoded-hmac-key..."
```

Leave `eab_key_id` empty (the default) for Let's Encrypt - it doesn't need EAB.

### Switching from staging to production

1. Test the full flow with staging first - the certs are fake but the process is identical
2. Change `acme_server_url` to the production URL
3. Run `terraform apply` - it'll re-register and re-issue
4. **Important:** destroy or taint state first if switching CAs, since the ACME account key is tied to a specific CA

---

## DNS Challenge Providers

DNS-01 challenges prove you own a domain by creating a `_acme-challenge.<domain>` TXT record via your DNS provider's API. This works with [any provider lego supports](https://go-acme.github.io/lego/dns/) (90+).

### How provider switching works

Two variables control everything:

| Variable | What it does |
|----------|---------|
| `dns_provider` | The provider name (`"infoblox"`, `"cloudflare"`, `"route53"`, `"f5xc"`, etc.) |
| `dns_provider_config` | Map of provider-specific env vars that get passed to lego |

When `dns_provider_config` is empty and `dns_provider` is `"infoblox"`, the dedicated `infoblox_*` variables kick in for backward compatibility. When `dns_provider` is `"f5xc"`, the `xc_*` variables are used and lego's exec provider runs a custom script.

### Provider Configuration Examples

#### InfoBlox (default)

Using the dedicated `infoblox_*` variables:

```hcl
dns_provider = "infoblox"  # default, can be omitted

infoblox_host         = "gridmaster.example.com"
infoblox_username     = "acme-svc"
infoblox_password     = "secret"
infoblox_wapi_version = "2.11"
infoblox_port         = "443"
infoblox_ssl_verify   = "false"   # self-signed grid cert
infoblox_dns_view     = "External"
```

Or via the generic `dns_provider_config`:

```hcl
dns_provider = "infoblox"
dns_provider_config = {
  INFOBLOX_HOST         = "gridmaster.example.com"
  INFOBLOX_USERNAME     = "acme-svc"
  INFOBLOX_PASSWORD     = "secret"
  INFOBLOX_SSL_VERIFY   = "false"
}
```

The WAPI user needs permission to create and delete TXT records in the target zone.

| Variable | Lego Env Var | Required | Default |
|----------|-------------|:---:|---------|
| `infoblox_host` | `INFOBLOX_HOST` | Yes | - |
| `infoblox_username` | `INFOBLOX_USERNAME` | Yes | - |
| `infoblox_password` | `INFOBLOX_PASSWORD` | Yes | - |
| `infoblox_wapi_version` | `INFOBLOX_WAPI_VERSION` | No | `2.11` |
| `infoblox_port` | `INFOBLOX_PORT` | No | `443` |
| `infoblox_ssl_verify` | `INFOBLOX_SSL_VERIFY` | No | `true` |
| `infoblox_dns_view` | `INFOBLOX_DNS_VIEW` | No | `default` |

#### Cloudflare

```hcl
dns_provider = "cloudflare"
dns_provider_config = {
  CF_DNS_API_TOKEN = "your-api-token-with-dns-edit"
}
```

Use a scoped API token (recommended) with **Zone:DNS:Edit** permission, or a global API key:

```hcl
dns_provider_config = {
  CF_API_EMAIL = "you@example.com"
  CF_API_KEY   = "your-global-api-key"
}
```

| Env Var | Required | Description |
|---------|:---:|-------------|
| `CF_DNS_API_TOKEN` | Yes* | API token with DNS:Edit permission |
| `CF_API_EMAIL` | Alt | Account email (with `CF_API_KEY`) |
| `CF_API_KEY` | Alt | Global API key (with `CF_API_EMAIL`) |
| `CLOUDFLARE_PROPAGATION_TIMEOUT` | No | Max wait for DNS (default: `120`s) |
| `CLOUDFLARE_TTL` | No | TXT record TTL (default: `120`s) |

#### AWS Route 53

```hcl
dns_provider = "route53"
dns_provider_config = {
  AWS_ACCESS_KEY_ID     = "AKIA..."
  AWS_SECRET_ACCESS_KEY = "..."
  AWS_REGION            = "us-east-1"
  AWS_HOSTED_ZONE_ID    = "Z1234..."  # optional, speeds up lookup
}
```

The IAM user/role needs `route53:GetChange`, `route53:ChangeResourceRecordSets`, and `route53:ListHostedZonesByName`.

**Heads up about subdelegated zones:** If your domains live in a subdelegated zone (e.g. `sub.example.com` is its own hosted zone, delegated from `example.com`), you **must** set `AWS_HOSTED_ZONE_ID`. Lego walks up the domain hierarchy to find the zone and will happily match the parent zone instead, creating challenge records in the wrong place.

| Env Var | Required | Description |
|---------|:---:|-------------|
| `AWS_ACCESS_KEY_ID` | Yes* | AWS access key |
| `AWS_SECRET_ACCESS_KEY` | Yes* | AWS secret key |
| `AWS_REGION` | Yes | AWS region |
| `AWS_HOSTED_ZONE_ID` | No* | Explicit zone ID - **required for subdelegated zones** |
| `AWS_PROFILE` | Alt | Use named profile instead of keys |
| `AWS_ASSUME_ROLE_ARN` | No | ARN to assume for cross-account |
| `AWS_PROPAGATION_TIMEOUT` | No | Max wait for DNS (default: `120`s) |

#### Azure DNS

```hcl
dns_provider = "azuredns"
dns_provider_config = {
  AZURE_CLIENT_ID       = "..."
  AZURE_CLIENT_SECRET   = "..."
  AZURE_TENANT_ID       = "..."
  AZURE_SUBSCRIPTION_ID = "..."
  AZURE_RESOURCE_GROUP  = "dns-rg"
}
```

| Env Var | Required | Description |
|---------|:---:|-------------|
| `AZURE_CLIENT_ID` | Yes | Service principal client ID |
| `AZURE_CLIENT_SECRET` | Yes | Service principal secret |
| `AZURE_TENANT_ID` | Yes | Azure AD tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Yes | Subscription containing the DNS zone |
| `AZURE_RESOURCE_GROUP` | Yes | Resource group containing the DNS zone |
| `AZURE_ZONE_NAME` | No | Explicit zone name |
| `AZURE_PROPAGATION_TIMEOUT` | No | Max wait for DNS (default: `120`s) |

#### Google Cloud DNS

```hcl
dns_provider = "gcloud"
dns_provider_config = {
  GCE_PROJECT              = "my-gcp-project"
  GCE_SERVICE_ACCOUNT_FILE = "/path/to/service-account.json"
}
```

| Env Var | Required | Description |
|---------|:---:|-------------|
| `GCE_PROJECT` | Yes | GCP project ID |
| `GCE_SERVICE_ACCOUNT_FILE` | Yes* | Path to service account JSON |
| `GCE_SERVICE_ACCOUNT` | Alt | Service account email (with ADC) |
| `GCE_ZONE_ID` | No | Explicit zone ID (skips auto-detection) |
| `GCE_PROPAGATION_TIMEOUT` | No | Max wait for DNS (default: `180`s) |

#### F5 XC DNS

If your domains are hosted on F5 Distributed Cloud DNS, you can use XC itself as the DNS challenge provider.

**Why this needs a script:** The Volterra Terraform provider has [`dns_zone`](https://registry.terraform.io/providers/volterraedge/volterra/latest/docs/resources/volterra_dns_zone) and [`dns_zone_record`](https://registry.terraform.io/providers/volterraedge/volterra/latest/docs/resources/volterra_dns_zone_record) resources for creating and managing DNS records, but DNS-01 challenges need ephemeral TXT records that get created, verified, and deleted all within a single `terraform apply` - you can't model that as a declarative resource. So `scripts/xc_dns_challenge.sh` calls the XC DNS API directly to handle challenge records. If lego gets a native f5xc provider, this script goes away.

Terraform still handles everything else: account registration, cert issuance, renewal, PKCS#12 bundling, and the XC certificate push. The script only runs during the brief challenge window.

**Authentication:** The script uses an XC API token, which is separate from the P12 credential. Create one in the XC console under Administration > Credentials.

**Domain validation:** At plan time, Terraform checks that every cert domain belongs to one of the zones in `xc_dns_zones`. If something doesn't match, the plan fails with a clear error. If your domains span multiple zones, just list them all - the script routes each challenge to the right zone.

```hcl
dns_provider = "f5xc"

xc_tenant_url     = "https://tenant.console.ves.volterra.io/api"
xc_api_token      = "your-xc-api-token"
xc_dns_zones      = ["example.com", "other.com"]
xc_dns_group_name = "default"
```

| Variable | Required | Default | Description |
|----------|:---:|---------|-------------|
| `xc_api_token` | Yes | `""` | XC API token with DNS zone record permissions |
| `xc_dns_zones` | Yes | `[]` | DNS zone names in XC that your domains belong to |
| `xc_dns_group_name` | No | `"default"` | DNS record group name within each zone |

The `xc_tenant_url` variable is shared with the Volterra provider. The API token needs permission to create and delete TXT records in the specified zones.

**Dependencies:** `bash`, `curl`, `jq`

#### Other Providers

Any of the [90+ lego DNS providers](https://go-acme.github.io/lego/dns/) work. Set `dns_provider` to the lego provider name and pass the required env vars through `dns_provider_config`. Check the [lego docs](https://go-acme.github.io/lego/dns/) for what each provider needs.

---

## F5 XC Load Balancer Discovery

Discovery is a **one-time migration step**. You run the script, it finds your HTTPS load balancers, and it writes `certificates.auto.tfvars.json` - a Terraform variable file that populates `xc_certificates`. After that, Terraform manages the certificate objects on its own. It never calls the XC API again.

### Running the discovery script

```bash
bash scripts/discover_xc_lbs.sh \
  --p12-file /path/to/api-credential.p12 \
  --p12-pass yourpassword \
  --tenant-url https://tenant.console.ves.volterra.io/api \
  --namespaces production,staging \
  --domain-filter example.com
```

The script writes `certificates.auto.tfvars.json` in the current directory:

```json
{
  "xc_certificates": {
    "production/my-app": {
      "namespace": "production",
      "name": "my-app",
      "domains": ["app.example.com", "www.example.com"]
    }
  }
}
```

Terraform picks up `*.auto.tfvars.json` files automatically - no `-var-file` flag needed.

| Flag | Required | Description |
|------|:---:|-------------|
| `--p12-file` | Yes | Path to the XC API P12 credential |
| `--p12-pass` | Yes | P12 file password |
| `--tenant-url` | Yes | XC tenant API URL (include `/api` suffix) |
| `--namespaces` | Yes | Comma-separated namespace(s) to scan |
| `--domain-filter` | No | Comma-separated domain suffixes. Only LBs whose domains all match a suffix get included. |

### What the script looks for

The script hits `GET <tenant_url>/api/config/namespaces/<ns>/http_loadbalancers?report_fields` for each namespace and keeps LBs that match **both**:

- **HTTPS with manual cert:** has `get_spec.https` (skips `https_auto_cert` LBs - those already have ACME certs managed by XC)
- **Internet-facing:** has `get_spec.advertise_on_public` or `get_spec.advertise_on_public_default_vip`

If every namespace fails (bad creds, network issues), the script errors out instead of silently writing an empty file.

**Dependencies:** `bash`, `openssl`, `curl`, `jq`

### What Terraform does with xc_certificates

For each entry in the `xc_certificates` variable, Terraform:

1. Creates a TLS private key
2. Builds a CSR with the entry's domains
3. Issues an ACME cert via DNS-01 challenge
4. Creates a `volterra_certificate` object in the entry's namespace (when `create_xc_certificates` is true)

When `xc_certificates` is empty (the default), none of this happens - you just get the standalone cert.

### Skipping the XC certificate push

Set `create_xc_certificates = false` to issue certs without creating `volterra_certificate` objects in XC. The ACME certs still get issued and renewed on schedule in Terraform state - only the push to XC is skipped. Useful if you want to review certs before importing, or if you manage the LB-to-cert binding outside of Terraform.

### XC credentials

The Volterra provider reads the P12 password from the `VES_P12_PASSWORD` env var:

```bash
export VES_P12_PASSWORD="your-p12-password"
terraform apply
```

```hcl
xc_tenant_url       = "https://tenant.console.ves.volterra.io/api"
xc_api_p12_file     = "/path/to/api-credential.p12"
xc_api_p12_password = "p12-password"
```

### Certificate naming on XC

Each `volterra_certificate` gets created with:

- **name** = the load balancer's name (e.g. `my-app-lb`)
- **namespace** = the LB's namespace
- **certificate_url** = full chain (cert + issuer) as base64 `string:///` format
- **private_key** = cert private key as base64 `string:///` format via `clear_secret_info`

---

## Certificate Lifecycle and Automated Renewal

### How renewal works

The `acme_certificate` resource tracks expiry in Terraform state. Every time you run `terraform apply`:

1. Terraform checks the `certificate_not_after` timestamp
2. If fewer than `min_days_remaining` days are left (default: 30), it triggers a renewal
3. DNS-01 challenge runs again, new cert gets issued, state updates
4. Downstream resources (`local_sensitive_file`, `volterra_certificate`) update automatically

No manual work needed - just run `terraform apply` on a schedule.

### Automated scheduling

#### Option A: Cron

```bash
# /etc/cron.d/acme-renewal
# Runs daily at 2:30 AM - Terraform only renews if needed
30 2 * * * root cd /opt/acme-automation && terraform apply -auto-approve -input=false >> /var/log/acme-renewal.log 2>&1
```

#### Option B: Systemd timer

```ini
# /etc/systemd/system/acme-renewal.service
[Unit]
Description=ACME certificate renewal via Terraform

[Service]
Type=oneshot
WorkingDirectory=/opt/acme-automation
ExecStart=/usr/bin/terraform apply -auto-approve -input=false
Environment=VES_P12_PASSWORD=your-p12-password

# /etc/systemd/system/acme-renewal.timer
[Unit]
Description=Run ACME renewal daily

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true
RandomizedDelaySec=1800

[Install]
WantedBy=timers.target
```

```bash
systemctl enable --now acme-renewal.timer
```

#### Option C: CI/CD pipeline (GitLab CI)

```yaml
acme-renew:
  stage: deploy
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"  # daily schedule
  script:
    - terraform init -input=false
    - terraform apply -auto-approve -input=false
  variables:
    VES_P12_PASSWORD: $VES_P12_PASSWORD_CI
```

### Recommended renewal schedules

| Cert Lifetime | `min_days_remaining` | Cron Frequency | Notes |
|---------------|---------------------|----------------|-------|
| 90 days (current LE default) | `30` | Daily | Renews at ~60 days |
| 45 days (LE `tlsserver` profile, May 2026+) | `15` | Daily | Renews at ~30 days |
| 6 days (LE `shortlived` profile) | `2` | Every 6 hours | Renews at ~4 days |

### The `min_days_remaining` variable

This controls when Terraform decides a cert needs renewal:

```hcl
min_days_remaining = 30   # default - renew when < 30 days remain
```

If the cert has more than 30 days left, Terraform says "no changes." Once it crosses the threshold, renewal kicks in.

### State management

- Certificate state (including private keys) lives in `terraform.tfstate`
- **Don't commit state files** - use a remote backend (S3, GCS, Terraform Cloud) for anything real
- The ACME account key persists across renewals - you don't re-register each time
- If you lose state, Terraform creates a new account and issues fresh certs. Not the end of the world, but try to avoid it.

---

## Let's Encrypt Certificate Lifetime Changes (2025-2028)

Let's Encrypt is gradually shortening certificate lifetimes. Here's the timeline and what it means for this automation.

### Timeline

| Date | Change | Impact |
|------|--------|--------|
| **Now** | 90-day certs (default `classic` profile) | Current behavior |
| **Feb 2025** | 6-day certs available (`shortlived` profile, opt-in) | For high-security use cases |
| **May 13, 2026** | `tlsserver` profile -> 45-day certs | Opt-in for early adopters |
| **Feb 10, 2027** | `classic` profile -> 64-day certs, 10-day auth reuse | Affects everyone not on another profile |
| **Feb 16, 2028** | `classic` profile -> 45-day certs, 7-hour auth reuse | Full DNS challenge on every renewal |

### Certificate profiles

Let's Encrypt will offer three ACME profiles:

| Profile | Cert Lifetime | Auth Reuse Window | How to Select |
|---------|--------------|-------------------|---------------|
| `classic` | 90d -> 64d -> 45d | 30d -> 10d -> 7h | Default (no action needed) |
| `tlsserver` | 45 days | Shorter | Opt-in via ACME profile negotiation |
| `shortlived` | 6 days | - | Opt-in via ACME profile negotiation |

**Note:** ACME profile selection isn't supported in the `vancluever/acme` provider or lego yet. When it is, it'll probably be a new attribute on `acme_certificate`. For now you get whatever the default profile gives you.

### Authorization reuse

"Authorization reuse" means the CA remembers your domain validation for a window and skips the challenge on subsequent requests:

- **Now:** 30-day window - you can renew without a new DNS challenge within 30 days
- **Feb 2027:** 10-day window
- **Feb 2028:** 7-hour window - basically a full DNS challenge every time

This doesn't affect us since we run the DNS challenge on every `terraform apply` anyway. It matters more for tools that cache authorizations.

### ACME Renewal Information (ARI) - RFC 9773

[ARI](https://datatracker.ietf.org/doc/rfc9773/) lets the CA tell your client the best time to renew, based on cert lifetime, revocation status, and CA operational needs (like mass re-issuance after a key compromise).

- Published as RFC 9773 (September 2025)
- Supported in certbot 4.1+
- **Not yet supported** in the `vancluever/acme` provider or lego
- When it lands, it would likely replace or work alongside `min_days_remaining`

### DNS-PERSIST-01 (expected 2026)

A new challenge type being standardized that eliminates dynamic DNS changes on renewal:

1. You create a TXT record **once** with a static token
2. On renewal, the CA checks the same record - no DNS API calls needed
3. The record only changes if your account key changes

This would be a big deal - no more DNS provider credentials on the renewal host, no more API calls to InfoBlox/Cloudflare/Route53 after initial setup.

- Under active development at IETF
- Expected in Let's Encrypt during 2026
- Not in lego or any Terraform provider yet
- When available, it'd be a new `dns_challenge { provider = "..." }` option

### What to do now

1. **Set up automated renewal** (cron/systemd/CI) - this is the important thing regardless of lifetime changes
2. **Use `min_days_remaining = 30`** for 90-day certs (the default)
3. **When 45-day certs arrive** (May 2026 opt-in, Feb 2028 default): lower to `15`
4. **When ARI support lands:** switch to ARI-based renewal for optimal timing
5. **When DNS-PERSIST-01 is available:** evaluate switching to simplify DNS credentials

---

## Variables Reference

### Core Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `email` | `string` | - (required) | Email for ACME account registration |
| `domains` | `list(string)` | - (required) | Domain names for the standalone cert. First entry is the CN. |
| `acme_server_url` | `string` | `https://acme-staging-v02.api.letsencrypt.org/directory` | ACME CA directory URL |
| `output_dir` | `string` | `./certs` | Directory for the PKCS#12 bundle |
| `p12_password` | `string` (sensitive) | - (required) | Password for the output PKCS#12 (.pfx) file |
| `key_algorithm` | `string` | `RSA` | `RSA` or `ECDSA` |
| `rsa_bits` | `number` | `4096` | RSA key size (ignored for ECDSA) |
| `create_local_pfx` | `bool` | `true` | Write PKCS#12 bundle to disk. Set `false` if you only need XC-pushed certs. |
| `create_xc_certificates` | `bool` | `true` | Create `volterra_certificate` objects in XC. Set `false` to issue certs without pushing to XC. |

### Certificate Lifecycle Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `min_days_remaining` | `number` | `30` | Renew when fewer than N days until expiry |
| `cert_timeout` | `number` | `300` | Timeout in seconds for ACME operations |
| `pre_check_delay` | `number` | `0` | Seconds to wait before DNS propagation check |
| `recursive_nameservers` | `list(string)` | `[]` | Override nameservers for challenge verification |

### ACME CA Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `eab_key_id` | `string` | `""` | EAB Key ID (ZeroSSL, Google, etc.) |
| `eab_hmac_key` | `string` (sensitive) | `""` | EAB HMAC key in base64 |

### DNS Provider Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `dns_provider` | `string` | `"infoblox"` | DNS provider name (`infoblox`, `cloudflare`, `route53`, `f5xc`, etc.) |
| `dns_provider_config` | `map(string)` (sensitive) | `{}` | Provider-specific env var config |

### InfoBlox Variables (legacy)

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `infoblox_host` | `string` | `""` | Grid Manager hostname/IP |
| `infoblox_username` | `string` | `""` | WAPI username |
| `infoblox_password` | `string` (sensitive) | `""` | WAPI password |
| `infoblox_wapi_version` | `string` | `"2.11"` | WAPI version |
| `infoblox_port` | `string` | `"443"` | WAPI port |
| `infoblox_ssl_verify` | `string` | `"true"` | Verify TLS to InfoBlox |
| `infoblox_dns_view` | `string` | `"default"` | DNS view for TXT records |

### F5 XC Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `xc_certificates` | `map(object)` | `{}` | Certificates to manage. Populated by `scripts/discover_xc_lbs.sh`. |
| `xc_tenant_url` | `string` | `""` | XC tenant API URL |
| `xc_api_p12_file` | `string` | `""` | Path to P12 cert for XC API auth |
| `xc_api_p12_password` | `string` (sensitive) | `""` | P12 file password |
| `xc_api_token` | `string` (sensitive) | `""` | XC API token for DNS record management (only for f5xc DNS provider) |
| `xc_dns_zones` | `list(string)` | `[]` | XC DNS zone names (only for f5xc DNS provider) |
| `xc_dns_group_name` | `string` | `"default"` | XC DNS record group name (only for f5xc DNS provider) |

---

## Outputs Reference

### Standalone Certificate Outputs

| Output | Sensitive | Description |
|--------|:---------:|-------------|
| `certificate_p12` | Yes | PKCS#12 bundle (base64-encoded) with cert, chain, and private key |
| `certificate_not_after` | No | Certificate expiry timestamp |
| `cert_files_dir` | No | Directory where the PKCS#12 bundle was written |

### XC Certificate Outputs

| Output | Sensitive | Description |
|--------|:---------:|-------------|
| `xc_certificates` | No | Per-cert summary: `{ "ns/name" => { name, namespace, domains, not_after } }` |

---

## File Structure

| File | What's in it |
|------|----------|
| `versions.tf` | `terraform {}` block with `required_providers` |
| `providers.tf` | `provider "acme"` and `provider "volterra"` |
| `variables.tf` | All variable declarations |
| `locals.tf` | DNS challenge config locals |
| `acme_account.tf` | ACME account key + registration |
| `cert_standalone.tf` | Standalone ACME cert + PFX file |
| `certificates.auto.tfvars.json` | Generated by discovery script, populates `xc_certificates` (not in repo) |
| `xc_certificates.tf` | Per-cert resources: private key, CSR, ACME cert, volterra_certificate |
| `outputs.tf` | All outputs |
| `terraform.tfvars.example` | Template - copy to `terraform.tfvars` |
| `terraform.tfvars` | Your config (gitignored) |
| `terraform.tfstate` | State file (gitignored, use a remote backend) |
| `scripts/discover_xc_lbs.sh` | One-time migration script, writes `certificates.auto.tfvars.json` |
| `scripts/xc_dns_challenge.sh` | DNS challenge script for f5xc DNS provider |
| `certs/` | Output directory (gitignored), has `certificate.pfx` |

### Resource dependency chain

There are two parallel branches sharing one ACME account:

`tls_private_key.acme_account` -> `acme_registration.reg` (shared root)

**Standalone branch:** `acme_registration.reg` -> `acme_certificate.cert` (manages its own key internally) -> `local_sensitive_file.certificate_p12`

**XC branch** (one per entry in `xc_certificates`): `acme_registration.reg` -> `tls_private_key.xc_cert[k]` -> `tls_cert_request.xc_csr[k]` -> `acme_certificate.xc_cert[k]` -> `volterra_certificate.xc_cert[k]`

---

## Troubleshooting

### DNS propagation timeout

```
Error: acme: error presenting token: infoblox: timeout waiting for DNS propagation
```

- Bump `pre_check_delay` (e.g. `30`) to give DNS time to propagate
- Set `recursive_nameservers = ["8.8.8.8:53"]` to avoid stale local DNS caches
- Make sure the DNS provider API user can create TXT records

### Subdelegated zone propagation failure (Route 53)

```
authoritative nameservers: NS parent-ns.example.com returned NXDOMAIN for _acme-challenge.app.sub.example.com
```

Lego's propagation check is querying the parent zone's nameservers instead of following the NS delegation to Route 53. The parent NS doesn't know about the subdelegated zone, so it returns NXDOMAIN even though the TXT record exists.

**Fix:** Set `recursive_nameservers = ["8.8.8.8:53", "1.1.1.1:53"]` so lego uses public resolvers that follow the full delegation chain. Also set `AWS_HOSTED_ZONE_ID` to make sure records go in the right zone.

### InfoBlox TLS errors

```
Error: x509: certificate signed by unknown authority
```

Set `infoblox_ssl_verify = "false"` if the grid uses self-signed certs.

### Rate limiting (Let's Encrypt production)

```
Error: acme: error: 429 :: POST :: too many requests
```

- Use staging for testing: `acme_server_url = "https://acme-staging-v02.api.letsencrypt.org/directory"`
- Production limits: 50 certs per registered domain per week, 5 duplicate certs per week
- See [Let's Encrypt Rate Limits](https://letsencrypt.org/docs/rate-limits/)

### XC discovery returns empty

- Check the P12 file: `openssl pkcs12 -in cred.p12 -info -nokeys -passin pass:yourpass`
- Test the API manually: `curl --cert cert.pem --key key.pem https://tenant.console.ves.volterra.io/api/config/namespaces/your-ns/http_loadbalancers`
- Make sure LBs match: they need `https` (not `https_auto_cert`) AND `advertise_on_public` or `advertise_on_public_default_vip`
- Make sure `jq` is installed

### State lock issues

```
Error: Error locking state
```

Another `terraform apply` is probably running. Wait for it, or force-unlock:

```bash
terraform force-unlock LOCK_ID
```

### EAB errors with ZeroSSL/Google

```
Error: acme: error registering account: urn:ietf:params:acme:error:externalAccountRequired
```

The CA needs EAB credentials. Set `eab_key_id` and `eab_hmac_key` in your tfvars.

---

## Security Considerations

### Don't commit these files

| File | Why |
|------|----------|
| `terraform.tfvars` | Has DNS passwords, P12 passwords, API tokens, EAB keys |
| `terraform.tfstate` | Has private keys, cert material, ACME account key |
| `certs/certificate.pfx` | Has the cert, chain, and private key |
| XC P12 file | API authentication credential |

Your `.gitignore` should have:

```
terraform.tfvars
*.tfstate
*.tfstate.backup
.terraform/
certs/
*.p12
*.pfx
```

### Sensitive variables

- All password/key variables are marked `sensitive = true` so Terraform redacts them from output
- `dns_provider_config` is sensitive since it carries provider credentials
- Use env vars or a secrets manager for CI/CD
- Consider Terraform Cloud/Enterprise for encrypted state storage

### Least privilege

- **InfoBlox:** dedicated WAPI user with TXT create/delete only in the challenge zone
- **Cloudflare:** scoped API token with Zone:DNS:Edit on the target zone only
- **Route 53:** IAM policy limited to `route53:ChangeResourceRecordSets` on the specific hosted zone
- **Azure:** service principal with DNS Zone Contributor on the specific zone
- **Google Cloud:** service account with `dns.changes.create` and `dns.resourceRecordSets.*` on the specific zone
- **F5 XC (P12):** write access for certificate objects (read-only LB access only needed for the one-time migration script)
- **F5 XC (API token):** TXT record create/delete on the DNS zone, only needed for f5xc DNS provider
