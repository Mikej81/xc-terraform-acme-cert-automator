# ── Per-LB ACME Certificates ────────────────────────────────────────
resource "tls_private_key" "xc_cert" {
  for_each    = var.xc_certificates
  algorithm   = var.key_algorithm
  rsa_bits    = var.key_algorithm == "RSA" ? var.rsa_bits : null
  ecdsa_curve = var.key_algorithm == "ECDSA" ? "P256" : null
}

resource "tls_cert_request" "xc_csr" {
  for_each        = var.xc_certificates
  private_key_pem = tls_private_key.xc_cert[each.key].private_key_pem

  subject {
    common_name = each.value.domains[0]
  }

  dns_names = each.value.domains
}

resource "acme_certificate" "xc_cert" {
  for_each                = var.xc_certificates
  account_key_pem         = acme_registration.reg.account_key_pem
  certificate_request_pem = tls_cert_request.xc_csr[each.key].cert_request_pem
  min_days_remaining      = var.min_days_remaining
  cert_timeout            = var.cert_timeout
  pre_check_delay         = var.pre_check_delay
  recursive_nameservers   = length(var.recursive_nameservers) > 0 ? var.recursive_nameservers : null

  dns_challenge {
    provider = local.effective_dns_provider
    config   = local.dns_challenge_config
  }

  lifecycle {
    precondition {
      condition = var.dns_provider != "f5xc" || alltrue([
        for d in each.value.domains : anytrue([
          for z in var.xc_dns_zones : endswith(d, ".${z}") || d == z
        ])
      ])
      error_message = "Discovered LB ${each.key} has domains that do not match any zone in xc_dns_zones. Ensure all LB domains belong to a configured zone."
    }
  }
}

# ── Push Certs to F5 XC ─────────────────────────────────────────────
resource "volterra_certificate" "xc_cert" {
  for_each  = var.create_xc_certificates ? var.xc_certificates : {}
  name      = each.value.name
  namespace = each.value.namespace

  certificate_url = "string:///${base64encode(
    "${acme_certificate.xc_cert[each.key].certificate_pem}${acme_certificate.xc_cert[each.key].issuer_pem}"
  )}"

  private_key {
    clear_secret_info {
      url = "string:///${base64encode(tls_private_key.xc_cert[each.key].private_key_pem)}"
    }
  }
}
