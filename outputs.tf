# ── Outputs ──────────────────────────────────────────────────────
output "certificate_p12" {
  description = "The PKCS#12 bundle (base64-encoded) containing cert, chain, and private key."
  value       = acme_certificate.cert.certificate_p12
  sensitive   = true
}

output "certificate_not_after" {
  description = "Certificate expiry timestamp."
  value       = acme_certificate.cert.certificate_not_after
}

output "cert_files_dir" {
  description = "Directory where the PKCS#12 bundle was written (empty when create_local_pfx is false)."
  value       = var.create_local_pfx ? var.output_dir : ""
}

# ── XC Certificate Outputs ──────────────────────────────────────────
output "xc_certificates" {
  description = "Per-certificate summary with expiry dates."
  value = {
    for k, v in var.xc_certificates : k => {
      name      = v.name
      namespace = v.namespace
      domains   = v.domains
      not_after = acme_certificate.xc_cert[k].certificate_not_after
    }
  }
}
