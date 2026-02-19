# ── Account private key ───────────────────────────────────────────
resource "tls_private_key" "acme_account" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# ── ACME registration ────────────────────────────────────────────
resource "acme_registration" "reg" {
  account_key_pem = tls_private_key.acme_account.private_key_pem
  email_address   = var.email

  dynamic "external_account_binding" {
    for_each = var.eab_key_id != "" ? [1] : []
    content {
      key_id      = var.eab_key_id
      hmac_base64 = var.eab_hmac_key
    }
  }
}
