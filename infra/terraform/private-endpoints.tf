# ============================================================================
# PRIVATE NETWORKING
# ============================================================================

locals {
  private_dns_zones = {
    key_vault   = "privatelink.vaultcore.azure.net"
    app_config  = "privatelink.azconfig.io"
    acr         = "privatelink.azurecr.io"
    blob        = "privatelink.blob.core.windows.net"
    mongo       = "privatelink.mongocluster.cosmos.azure.com"
    redis       = "privatelink.redis.azure.net"
    cognitive   = "privatelink.cognitiveservices.azure.com"
    openai      = "privatelink.openai.azure.com"
    ai_services = "privatelink.services.ai.azure.com"
  }
}

resource "azurerm_virtual_network" "main" {
  count = var.enable_private_endpoints ? 1 : 0

  name                = local.resource_names.virtual_network
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = var.virtual_network_address_space
  tags                = local.tags
}

resource "azurerm_subnet" "container_apps" {
  count = var.enable_private_endpoints ? 1 : 0

  name                 = "snet-container-apps"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main[0].name
  address_prefixes     = [var.container_apps_subnet_address_prefix]

  delegation {
    name = "container-apps"
    service_delegation {
      name = "Microsoft.App/environments"
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  count = var.enable_private_endpoints ? 1 : 0

  name                              = "snet-private-endpoints"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main[0].name
  address_prefixes                  = [var.private_endpoints_subnet_address_prefix]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_private_dns_zone" "private" {
  for_each = var.enable_private_endpoints ? local.private_dns_zones : {}

  name                = each.value
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "private" {
  for_each = var.enable_private_endpoints ? local.private_dns_zones : {}

  name                  = "link-${replace(each.key, "_", "-")}"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.private[each.key].name
  virtual_network_id    = azurerm_virtual_network.main[0].id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_endpoint" "key_vault" {
  count = var.enable_private_endpoints ? 1 : 0

  name                = "pe-${azurerm_key_vault.main.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints[0].id

  private_service_connection {
    name                           = "psc-key-vault"
    private_connection_resource_id = azurerm_key_vault.main.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.private["key_vault"].id]
  }

  tags = local.tags
}

resource "azurerm_private_endpoint" "app_config" {
  count = var.enable_private_endpoints ? 1 : 0

  name                = "pe-${module.appconfig.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints[0].id

  private_service_connection {
    name                           = "psc-app-config"
    private_connection_resource_id = module.appconfig.id
    subresource_names              = ["configurationStores"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.private["app_config"].id]
  }

  tags = local.tags
}

resource "azurerm_private_endpoint" "container_registry" {
  count = var.enable_private_endpoints ? 1 : 0

  name                = "pe-${azurerm_container_registry.main.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints[0].id

  private_service_connection {
    name                           = "psc-acr"
    private_connection_resource_id = azurerm_container_registry.main.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.private["acr"].id]
  }

  tags = local.tags
}

resource "azurerm_private_endpoint" "blob_storage" {
  count = var.enable_private_endpoints ? 1 : 0

  name                = "pe-${azurerm_storage_account.main.name}-blob"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints[0].id

  private_service_connection {
    name                           = "psc-blob"
    private_connection_resource_id = azurerm_storage_account.main.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.private["blob"].id]
  }

  tags = local.tags
}

resource "azurerm_private_endpoint" "mongo_cluster" {
  count = var.enable_private_endpoints ? 1 : 0

  name                = "pe-${azapi_resource.mongoCluster.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints[0].id

  private_service_connection {
    name                           = "psc-mongo"
    private_connection_resource_id = azapi_resource.mongoCluster.id
    subresource_names              = ["MongoCluster"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.private["mongo"].id]
  }

  tags = local.tags
}

resource "azurerm_private_endpoint" "redis" {
  count = var.enable_private_endpoints ? 1 : 0

  name                = "pe-${azapi_resource.redisEnterprise.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints[0].id

  private_service_connection {
    name                           = "psc-redis"
    private_connection_resource_id = azapi_resource.redisEnterprise.id
    subresource_names              = ["redisEnterprise"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.private["redis"].id]
  }

  tags = local.tags
}

resource "azurerm_private_endpoint" "ai_foundry" {
  count = var.enable_private_endpoints ? 1 : 0

  name                = "pe-${module.ai_foundry.account_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints[0].id

  private_service_connection {
    name                           = "psc-ai-foundry"
    private_connection_resource_id = module.ai_foundry.account_id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "default"
    private_dns_zone_ids = [
      azurerm_private_dns_zone.private["cognitive"].id,
      azurerm_private_dns_zone.private["openai"].id,
      azurerm_private_dns_zone.private["ai_services"].id,
    ]
  }

  tags = local.tags
}

resource "azurerm_private_endpoint" "voice_live" {
  count = var.enable_private_endpoints && local.should_create_voice_live_account ? 1 : 0

  name                = "pe-${module.ai_foundry_voice_live[0].account_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints[0].id

  private_service_connection {
    name                           = "psc-voice-live"
    private_connection_resource_id = module.ai_foundry_voice_live[0].account_id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "default"
    private_dns_zone_ids = [
      azurerm_private_dns_zone.private["cognitive"].id,
      azurerm_private_dns_zone.private["openai"].id,
      azurerm_private_dns_zone.private["ai_services"].id,
    ]
  }

  tags = local.tags
}
