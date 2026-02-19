# ── Request the certificate (DNS-01) ─────────────────────────────
# Uses lego under the hood. The selected dns_provider creates a
# _acme-challenge.<domain> TXT record, waits for the CA to verify
# it, then cleans up the record.
#
# No inbound port 80 required — works from anywhere that can reach
# the DNS provider's API.
#
# Direct mode (no external CSR) so the provider manages the private
# key internally and can produce a password-protected PKCS#12 bundle.
resource "acme_certificate" "cert" {
  account_key_pem           = acme_registration.reg.account_key_pem
  common_name               = var.domains[0]
  subject_alternative_names = length(var.domains) > 1 ? slice(var.domains, 1, length(var.domains)) : []
  key_type                  = var.key_algorithm == "RSA" ? tostring(var.rsa_bits) : "P256"
  min_days_remaining        = var.min_days_remaining
  cert_timeout              = var.cert_timeout
  pre_check_delay           = var.pre_check_delay
  recursive_nameservers     = length(var.recursive_nameservers) > 0 ? var.recursive_nameservers : null
  certificate_p12_password  = var.p12_password

  dns_challenge {
    provider = local.effective_dns_provider
    config   = local.dns_challenge_config
  }

  lifecycle {
    precondition {
      condition = var.dns_provider != "f5xc" || alltrue([
        for d in var.domains : anytrue([
          for z in var.xc_dns_zones : endswith(d, ".${z}") || d == z
        ])
      ])
      error_message = "When dns_provider is f5xc, all domains must belong to a zone listed in xc_dns_zones. Check that each domain in var.domains ends with one of the configured zones."
    }
  }
}

# ── Write PKCS#12 bundle to disk ─────────────────────────────────
# Contains the leaf cert, issuer chain, and private key in a single
# password-protected PFX file. No plaintext key is written to disk.
resource "local_sensitive_file" "certificate_p12" {
  count           = var.create_local_pfx ? 1 : 0
  content_base64  = acme_certificate.cert.certificate_p12
  filename        = "${var.output_dir}/certificate.pfx"
  file_permission = "0600"
}
