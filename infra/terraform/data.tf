# ============================================================================
# AZURE STORAGE ACCOUNT
# ============================================================================

resource "azurerm_storage_account" "main" {
  name                = local.resource_names.storage
  resource_group_name = azurerm_resource_group.main.name
  location            = coalesce(var.cosmosdb_location, var.location)
  account_tier        = "Standard"
  # Snyk ignore: poc, geo-replication not required
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = !local.private_endpoints_only
  allow_nested_items_to_be_public = false

  # Enable blob properties
  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }

  tags = local.tags
}

# Storage containers are deployed through ARM so provisioning works when
# organizational policy disables the storage account's public data endpoint.
resource "azapi_resource" "storage_containers" {
  for_each = toset(["audioagent", "prompt"])

  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2025-06-01"
  name      = each.value
  parent_id = "${azurerm_storage_account.main.id}/blobServices/default"
  body = {
    properties = {
      publicAccess = "None"
    }
  }
}

# RBAC assignments for Storage
resource "azurerm_role_assignment" "storage_backend_contributor" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.backend.principal_id
}

resource "azurerm_role_assignment" "storage_principal_reader" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = local.principal_id
  principal_type       = local.principal_type
}

resource "azurerm_role_assignment" "storage_principal_contributor" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = local.principal_id
  principal_type       = local.principal_type
}

# ============================================================================
# COSMOS DB (MONGODB API)
# ============================================================================
resource "azapi_resource" "mongoCluster" {
  type                      = "Microsoft.DocumentDB/mongoClusters@2025-08-01-preview"
  parent_id                 = azurerm_resource_group.main.id
  schema_validation_enabled = false
  ignore_missing_property   = true
  name                      = local.resource_names.cosmos
  location                  = var.location
  body = {
    properties = {
      administrator = {
        userName = "cosmosadmin"
        password = random_password.cosmos_admin.result
      }
      authConfig = {
        # Ensure the order is always the same and matches the API's default
        allowedModes = [
          "MicrosoftEntraID",
          "NativeAuth"
        ]
      }
      backup = {}
      compute = {
        tier = var.cosmosdb_sku
      }
      createMode = "Default"
      dataApi = {
        mode = "Disabled"
      }
      highAvailability = {
        targetMode = "Disabled"
      }
      publicNetworkAccess = local.private_endpoints_only ? "Disabled" : (var.cosmosdb_public_network_access_enabled ? "Enabled" : "Disabled")
      serverVersion       = "8.0"
      sharding = {
        shardCount = 1
      }
      storage = {
        sizeGb = 128
        type   = "PremiumSSD"
      }
    }
  }
  tags = local.tags

  # Suppress diffs for volatile properties
  lifecycle {
    ignore_changes = [
      tags,
      body["properties"]["authConfig"]["allowedModes"],
      output["properties"]["authConfig"]["allowedModes"],
      output["properties"]["backup"]["earliestRestoreTime"],
      output["properties"]["clusterStatus"],
      output["properties"]["connectionString"],
      output["properties"]["infrastructureVersion"],
      output["properties"]["provisioningState"],
      output["properties"]["replica"]["replicationState"],
      output["properties"]["replica"]["role"],
      output["tags"]
    ]
  }
}

# MongoDB firewall rule to allow all IP addresses
resource "azapi_resource" "mongo_firewall_all" {
  count     = !local.private_endpoints_only && var.cosmosdb_public_network_access_enabled ? 1 : 0
  type      = "Microsoft.DocumentDB/mongoClusters/firewallRules@2025-04-01-preview"
  parent_id = azapi_resource.mongoCluster.id
  name      = "allowAll"
  body = {
    properties = {
      startIpAddress = "0.0.0.0"
      endIpAddress   = "255.255.255.255"
    }
  }

  depends_on = [azapi_resource.mongoCluster]
}


# Store Entra ID connection string in Key Vault
# NOTE: We construct this manually because the Azure-provided connectionString
# includes password credentials, which conflict with MONGODB-OIDC auth.
resource "azapi_resource_action" "cosmos_entra_connection_string" {
  type        = "Microsoft.KeyVault/vaults/secrets@2025-05-01"
  resource_id = "${azurerm_key_vault.main.id}/secrets/cosmos-entra-connection-string"
  action      = ""
  method      = "PUT"
  when        = "apply"
  body = {
    properties = {
      value       = "mongodb+srv://${azapi_resource.mongoCluster.name}.mongocluster.cosmos.azure.com/?tls=true&authMechanism=MONGODB-OIDC&retrywrites=false&maxIdleTimeMS=120000"
      contentType = "text/plain"
      attributes = {
        enabled = true
      }
    }
  }
  depends_on = [azurerm_role_assignment.keyvault_admin, azapi_resource.mongoCluster]
}

# Generate random password for Cosmos DB admin
# NOTE: Limited special chars to avoid URL/connection string issues
resource "random_password" "cosmos_admin" {
  length           = 24
  special          = true
  override_special = "!#$^*()-_=+"
}

# Store Cosmos DB admin password in Key Vault
resource "azapi_resource_action" "cosmos_admin_password" {
  type        = "Microsoft.KeyVault/vaults/secrets@2025-05-01"
  resource_id = "${azurerm_key_vault.main.id}/secrets/cosmos-admin-password"
  action      = ""
  method      = "PUT"
  when        = "apply"
  body = {
    properties = {
      value       = random_password.cosmos_admin.result
      contentType = "text/plain"
      attributes = {
        enabled = true
      }
    }
  }
  depends_on = [azurerm_role_assignment.keyvault_admin]
}
# RBAC assignments for Cosmos DB vCore cluster
resource "azapi_resource" "cosmos_backend_db_user" {
  type      = "Microsoft.DocumentDB/mongoClusters/users@2025-04-01-preview"
  name      = azurerm_user_assigned_identity.backend.principal_id
  parent_id = azapi_resource.mongoCluster.id
  body = {
    properties = {
      identityProvider = {
        properties = {
          principalType = "ServicePrincipal"
        }
        type = "MicrosoftEntraID"
        // For remaining properties, see IdentityProvider objects
      }
      roles = [
        {
          db   = "admin"
          role = "dbOwner"
        }
      ]
    }
  }
  lifecycle {
    ignore_changes = [
      body["properties"]["identityProvider"]["properties"]["principalType"],
      output["properties"]["provisioningState"],
      output["properties"]["roles"],
      output["id"],
      output["type"]
    ]
  }
}

# RBAC assignments for Cosmos DB vCore cluster
resource "azapi_resource" "cosmos_principal_user" {
  type      = "Microsoft.DocumentDB/mongoClusters/users@2025-04-01-preview"
  name      = data.azuread_client_config.current.object_id
  parent_id = azapi_resource.mongoCluster.id
  body = {
    properties = {
      identityProvider = {
        properties = {
          principalType = var.principal_type
        }
        type = "MicrosoftEntraID"
        // For remaining properties, see IdentityProvider objects
      }
      roles = [
        {
          db   = "admin"
          role = "dbOwner"
        }
      ]
    }
  }
  lifecycle {
    ignore_changes = [
      body["properties"]["identityProvider"]["properties"]["principalType"],
      output["properties"]["provisioningState"],
      output["properties"]["roles"],
      output["id"],
      output["type"]
    ]
    prevent_destroy = false
  }
}

# Data sources to retrieve MongoDB cluster information
data "azapi_resource" "mongo_cluster_info" {
  type      = "Microsoft.DocumentDB/mongoClusters@2025-04-01-preview"
  parent_id = azurerm_resource_group.main.id
  name      = azapi_resource.mongoCluster.name

  depends_on = [azapi_resource.mongoCluster]
}


# Store MongoDB connection details in Key Vault
resource "azapi_resource_action" "cosmos_connection_string" {
  type        = "Microsoft.KeyVault/vaults/secrets@2025-05-01"
  resource_id = "${azurerm_key_vault.main.id}/secrets/cosmos-connection-string"
  action      = ""
  method      = "PUT"
  when        = "apply"
  body = {
    properties = {
      value       = data.azapi_resource.mongo_cluster_info.output.properties.connectionString
      contentType = "text/plain"
      attributes = {
        enabled = true
      }
    }
  }
  depends_on = [azurerm_role_assignment.keyvault_admin, data.azapi_resource.mongo_cluster_info]
}
