# ── Toggle between staging and production ──────────────────────────
# Staging: https://acme-staging-v02.api.letsencrypt.org/directory
# Prod:    https://acme-v02.api.letsencrypt.org/directory
provider "acme" {
  server_url = var.acme_server_url
}

provider "volterra" {
  api_p12_file = var.xc_api_p12_file
  url          = var.xc_tenant_url
}
