# ── Variables ──────────────────────────────────────────────────────
variable "acme_server_url" {
  description = "ACME directory URL. Use staging first to avoid rate limits."
  type        = string
  default     = "https://acme-staging-v02.api.letsencrypt.org/directory"
}

variable "email" {
  description = "Email for the ACME account (Let's Encrypt notifications)."
  type        = string
}

variable "domains" {
  description = "List of domain names to include in the certificate. First entry is the CN."
  type        = list(string)
}

variable "output_dir" {
  description = "Directory to write the PKCS#12 bundle into."
  type        = string
  default     = "./certs"
}

variable "p12_password" {
  description = "Password for the output PKCS#12 (.pfx) file."
  type        = string
  sensitive   = true
}

variable "key_algorithm" {
  description = "Private key algorithm: RSA or ECDSA."
  type        = string
  default     = "RSA"
  validation {
    condition     = contains(["RSA", "ECDSA"], var.key_algorithm)
    error_message = "key_algorithm must be RSA or ECDSA."
  }
}

variable "rsa_bits" {
  description = "RSA key size (only used when key_algorithm=RSA)."
  type        = number
  default     = 4096
}

variable "min_days_remaining" {
  description = "Renew certificate when fewer than this many days remain before expiry."
  type        = number
  default     = 30
}

variable "cert_timeout" {
  description = "Timeout in seconds for ACME certificate operations."
  type        = number
  default     = 300
}

variable "pre_check_delay" {
  description = "Seconds to wait before ACME checks DNS propagation."
  type        = number
  default     = 0
}

variable "recursive_nameservers" {
  description = "Explicit recursive nameservers for DNS challenge verification (e.g. [\"8.8.8.8:53\"]). Empty uses system defaults."
  type        = list(string)
  default     = []
}

# ── Output control ───────────────────────────────────────────────────
variable "create_local_pfx" {
  description = "Write the standalone PKCS#12 (.pfx) bundle to disk. Set false if you only need XC-pushed certs."
  type        = bool
  default     = true
}

variable "create_xc_certificates" {
  description = "Create and renew volterra_certificate objects in XC. When false, ACME certs are still issued and renewed but not pushed to XC."
  type        = bool
  default     = true
}

# ── ACME CA selection ────────────────────────────────────────────────
# Some CAs (ZeroSSL, Google Trust Services) require External Account
# Binding (EAB). Leave blank for Let's Encrypt.
variable "eab_key_id" {
  description = "EAB Key ID for CAs that require external account binding."
  type        = string
  default     = ""
}

variable "eab_hmac_key" {
  description = "EAB HMAC key (base64) for CAs that require external account binding."
  type        = string
  sensitive   = true
  default     = ""
}

# ── DNS challenge provider ───────────────────────────────────────────
variable "dns_provider" {
  description = "DNS provider name: infoblox, cloudflare, route53, azuredns, gcloud, f5xc, etc. When set to f5xc, uses a custom script with P12 auth via the xc_* variables."
  type        = string
  default     = "infoblox"
}

variable "dns_provider_config" {
  description = "Config map passed to the dns_challenge block. Keys are provider-specific env vars (e.g. CF_DNS_API_TOKEN for Cloudflare). When empty and dns_provider is 'infoblox', the legacy infoblox_* variables are used."
  type        = map(string)
  sensitive   = true
  default     = {}
}

# ── InfoBlox WAPI connection (legacy — used when dns_provider_config is empty) ──
variable "infoblox_host" {
  description = "InfoBlox Grid Manager hostname or IP."
  type        = string
  default     = ""
}

variable "infoblox_username" {
  description = "InfoBlox WAPI username."
  type        = string
  default     = ""
}

variable "infoblox_password" {
  description = "InfoBlox WAPI password."
  type        = string
  sensitive   = true
  default     = ""
}

variable "infoblox_wapi_version" {
  description = "InfoBlox WAPI version (e.g. 2.11)."
  type        = string
  default     = "2.11"
}

variable "infoblox_port" {
  description = "InfoBlox WAPI port."
  type        = string
  default     = "443"
}

variable "infoblox_ssl_verify" {
  description = "Verify TLS to InfoBlox. Set false if using self-signed certs on the grid."
  type        = string
  default     = "true"
}

variable "infoblox_dns_view" {
  description = "InfoBlox DNS view to create the TXT record in."
  type        = string
  default     = "default"
}

# ── F5 XC certificates ─────────────────────────────────────────────
variable "xc_certificates" {
  description = "Certificates to manage for XC load balancers. Populated once by scripts/discover_xc_lbs.sh during migration. Each key is 'namespace/name', each value has namespace, name, and domains."
  type = map(object({
    namespace = string
    name      = string
    domains   = list(string)
  }))
  default = {}
}

# ── F5 XC variables ─────────────────────────────────────────────────
variable "xc_tenant_url" {
  description = "F5 XC tenant API URL (e.g. https://tenant.console.ves.volterra.io/api)."
  type        = string
  default     = ""
}

variable "xc_api_p12_file" {
  description = "Path to P12 certificate file for F5 XC API auth."
  type        = string
  default     = ""
}

variable "xc_api_p12_password" {
  description = "Password for the P12 certificate file."
  type        = string
  sensitive   = true
  default     = ""
}

variable "xc_api_token" {
  description = "F5 XC API token for DNS record management. Required when dns_provider is f5xc. DNS-01 challenges need ephemeral TXT records created and deleted within a single apply, so the DNS challenge script calls the XC API directly using this token."
  type        = string
  sensitive   = true
  default     = ""
}

variable "xc_dns_zones" {
  description = "F5 XC DNS zone names (e.g. [\"example.com\", \"other.com\"]). Required when dns_provider is f5xc. All certificate domains must belong to one of these zones."
  type        = list(string)
  default     = []
}

variable "xc_dns_group_name" {
  description = "F5 XC DNS record group name. Required when dns_provider is f5xc."
  type        = string
  default     = "default"
}
