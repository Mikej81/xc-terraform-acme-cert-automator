# ── DNS challenge configuration ──────────────────────────────────
# When dns_provider_config is provided, use it directly.
# When empty and dns_provider is "infoblox", fall back to the
# dedicated infoblox_* variables for backward compatibility.
# When dns_provider is "f5xc", use lego's exec provider with a
# custom script that calls the XC DNS API using P12 auth.
locals {
  infoblox_legacy_config = {
    INFOBLOX_HOST         = var.infoblox_host
    INFOBLOX_USERNAME     = var.infoblox_username
    INFOBLOX_PASSWORD     = var.infoblox_password
    INFOBLOX_WAPI_VERSION = var.infoblox_wapi_version
    INFOBLOX_PORT         = var.infoblox_port
    INFOBLOX_SSL_VERIFY   = var.infoblox_ssl_verify
    INFOBLOX_DNS_VIEW     = var.infoblox_dns_view
  }

  f5xc_dns_config = {
    EXEC_PATH     = "${path.module}/scripts/xc_dns_challenge.sh"
    XC_TENANT_URL = var.xc_tenant_url
    XC_API_TOKEN  = var.xc_api_token
    XC_DNS_ZONES  = join(",", var.xc_dns_zones)
    XC_GROUP_NAME = var.xc_dns_group_name
  }

  effective_dns_provider = var.dns_provider == "f5xc" ? "exec" : var.dns_provider

  dns_challenge_config = (
    length(var.dns_provider_config) > 0
    ? var.dns_provider_config
    : (
      var.dns_provider == "f5xc"
      ? local.f5xc_dns_config
      : (var.dns_provider == "infoblox" ? local.infoblox_legacy_config : {})
    )
  )
}
