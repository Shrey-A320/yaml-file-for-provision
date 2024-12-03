targetScope = 'subscription'

param prefix string = 'app'
param appName string = ''
param technicalserviceid string = ''
param keyVaultShortName string = ''
param appConfigName string = ''
param appConfigResourceGroup string = ''
param appConfigSubscriptionId string = ''

@allowed(['True', 'False'])
param enableBlueGreenDeploymentSupport string = 'False'

@description('Deployment environment')
@allowed(['dev', 'qa', 'test', 'uat', 'prod'])
param env string = 'test'

@allowed(['True', 'False'])
param useStorage string = 'False'
param storageName string = ''
param customAppSettings array = []
param customFunctionSettings array = []
param isManagedIdentity string = 'False'

@allowed(['True', 'False'])
param useSearch string = 'False'

@allowed(['True', 'False'])
param useFunctions string = 'False'

@allowed(['True', 'False'])
param useAppService string = 'True'

@description('If deploying to a shared resource group with other applications, specify the name of the resource group without prefixes or suffixes')
// @allowed(['', 'dataservices', 'reporteng'])
param sharedResourceGroupName string = ''

@description('If deploying to a specific app service plan, specify the name of the service plan without prefixes or suffixes')
param specifiedAppServicePlan string = ''

param location string = deployment().location

param shouldCreateResourceGroup bool = true

var shortLocationMappings = {
  uksouth: 'uks'
  northeurope : 'ne'
  westeurope: 'we'
}

var longLocationMappings = {
  uksouth: 'UK South'
  northeurope : 'North Europe'
  westeurope: 'West Europe'
}

var resouceSubjectName = sharedResourceGroupName != '' ? sharedResourceGroupName : appName
var resourceGroupName = 'rg-iwpt-${resouceSubjectName}-${env}'

var servicePlanSubjectName = specifiedAppServicePlan != '' ? specifiedAppServicePlan : appName
var servicePlanName = 'asp-${servicePlanSubjectName}-${env}-${shortLocation}'

var shortLocation = shortLocationMappings[location]
var useStorageBool = bool(useStorage)
var useSearchBool = bool(useSearch)
var useFunctionsBool = bool(useFunctions)
var useAppServiceBool = bool(useAppService)
var storageAccountName = storageName != '' ? storageName : appName
var servicePlanSkuName = env == 'prod' ? 'P1V3' : 'B1'

// Create resource group if it doesn't exist
resource appResourceGroup 'Microsoft.Resources/resourceGroups@2022-09-01' = if (shouldCreateResourceGroup) {
  name: resourceGroupName
  location: location
  tags: {
    ENVIRONMENT: env
    SERVICEID: technicalserviceid
  }
}

module appServicePlan 'utility/morningstar-create-or-get-appServicePlan.bicep' = {
  scope: resourceGroup(appResourceGroup.name)
  name: 'fetch-app-service-plan'
  params: {
    ServicePlanName: servicePlanName
    servicePlanSkuName: servicePlanSkuName
    location: longLocationMappings[location]
  }
}

module storageAccount 'modules/morningstar-provision-storage.bicep' = if(useStorageBool) {
  name: 'provision-storage-account'
  scope: resourceGroup(appResourceGroup.name)
  params: {
    shortLocation: shortLocationMappings[location]
    location: location
    appName: storageAccountName
    env: env
    enableTable: true
    enableBlob: true
  }
}

var appSettings = customAppSettings
var functionAppSettings = customFunctionSettings

module searchService 'modules/morningstar-provision-search.bicep' = if(useSearchBool) {
  name: 'provision-search'
  scope: resourceGroup(appResourceGroup.name)
  params: {
    name: appName
    location: location
    prefix: prefix
    env: env
  }
}

module functions 'modules/morningstar-provision-functions.bicep' = if(useFunctionsBool) {
  name: 'provision-function'
  scope: resourceGroup(appResourceGroup.name)
  dependsOn: [
    appService
    searchService
  ]
  params: {
    appName: appName
    storageAccountName: storageAccount.outputs.storageAccountName
    location: location
    customAppSettings: functionAppSettings
    appInsightsName: appService.outputs.appinsightsName
    env: env
  }
}

var enableBlueGreenDeploymentSupportBool = bool(enableBlueGreenDeploymentSupport)
module appService 'modules/morningstar-provision-webapp.bicep' = if(useAppServiceBool) {
  name: 'provision-webapp'
  scope: resourceGroup(appResourceGroup.name)
  dependsOn: [
    storageAccount
    searchService
  ]
  params: {
    location: location
    shortLocation: shortLocation
    appName: appName
    env: env
    customAppSettings: appSettings
    appServicePlanId: appServicePlan.outputs.appServicePlanId
    storageAccountName: useStorageBool ? storageAccount.outputs.storageAccountName : ''
    searchServiceName: useSearchBool ? searchService.outputs.name : ''
    isManagedIdentity: isManagedIdentity
    enableBlueGreenDeploymentSupport: enableBlueGreenDeploymentSupportBool
  }
}

// ################################## Key Vault ##################################

var provisionKeyVault = keyVaultShortName != '' && bool(isManagedIdentity)
var grantBlueGreenAccessToKeyVault = provisionKeyVault && enableBlueGreenDeploymentSupportBool

//This resource will only be provisioned for a webapp with managed identity.
module keyvault 'modules/morningstar-provision-keyvault.bicep' = if(provisionKeyVault) {
  name: 'provision-keyvault'
  scope: resourceGroup(appResourceGroup.name)
  dependsOn: [
    appService
  ]
  params: {
    shortLocation: shortLocation
    env: env
    appName: appName
    keyVaultShortName: keyVaultShortName
  }
}

// only include blue-green principal ids if the flag has been set
var principalIds = concat(
  [appService.outputs.principalId],
  grantBlueGreenAccessToKeyVault ? [appService.outputs.stagingSlotPrincipalId] : []
)

module keyVaultAccessPolicyAssignmentApp 'modules/morningstar-provision-keyvault-access-policies.bicep' = if (provisionKeyVault) {
  name: 'provision-key-vault-access-policy-app'
  dependsOn: [ 
    keyvault
    appService
  ]
  scope: resourceGroup(appResourceGroup.name)
  params: {
    keyVaultName: keyvault.outputs.name
    principalIds: principalIds
  }
}

// ########################### RBAC - App Configuration ###########################

var provisionAppConfig = appConfigResourceGroup != '' && appConfigName != '' && bool(isManagedIdentity)

//This resource will only be provisioned for a webapp with managed identity.
module appConfig 'modules/morningstar-provision-app-config-roles.bicep' = if(provisionAppConfig) {
    name: 'provision-app-configuration-roles'
    scope: resourceGroup(appConfigSubscriptionId, appConfigResourceGroup)
    dependsOn: [
      appService
    ]
    params: {
      appConfigName: appConfigName
      principalId: appService.outputs.principalId
    }
  }

var grantBlueBreenAccessToAppConfiguration = provisionAppConfig && enableBlueGreenDeploymentSupportBool

module blueAppConfigRoleAssignment 'modules/morningstar-provision-app-config-roles.bicep' = if(grantBlueBreenAccessToAppConfiguration) {
  name: 'blue-slot-app-config-roles'
  scope: resourceGroup(appConfigSubscriptionId, appConfigResourceGroup)
  dependsOn: [
    appService
  ]
  params: {
    appConfigName: appConfigName
    principalId: appService.outputs.stagingSlotPrincipalId
  }
}

// ############################ RBAC - Storage Accounts ############################

var enableRoleBasedStorageAccountAccess = useStorageBool && bool(isManagedIdentity)

// -- look up role ids
module blobContributorRole 'lookups/azure-role-lookup.bicep' = if(enableRoleBasedStorageAccountAccess) {
  name: 'lookup-storage-blob-data-contributor-role'
  scope: resourceGroup(appResourceGroup.name)
  params: {
    roleName: 'Storage Blob Data Contributor'
  }
}

module tableContributorRole 'lookups/azure-role-lookup.bicep' = if(enableRoleBasedStorageAccountAccess) {
  name: 'lookup-storage-table-data-contributor-role'
  scope: resourceGroup(appResourceGroup.name)
  params: {
    roleName: 'Storage Table Data Contributor'
  }
}

var grantAccessToSlots = enableRoleBasedStorageAccountAccess && enableBlueGreenDeploymentSupportBool

// -- Assign data roles to App Service
module appServiceBlobStorageRoleAssignment 'modules/morningstar-provision-storage-account-role-assignments.bicep' = if(enableRoleBasedStorageAccountAccess) {
  name: 'storage-role-assignment-app'
  scope: resourceGroup(appResourceGroup.name)
  params: {
    storageAccountName: storageAccount.outputs.storageAccountName
    principalId: appService.outputs.principalId
    roleIds: [
      blobContributorRole.outputs.roleId
      tableContributorRole.outputs.roleId
    ]
  }
}

// -- Assign data roles to staging deployment slot
module stagingSlotBlobStorageRoleAssignment 'modules/morningstar-provision-storage-account-role-assignments.bicep' = if(grantAccessToSlots) {
    name: 'storage-role-assignment-staging'
    scope: resourceGroup(appResourceGroup.name)
    dependsOn: [
      appService
      blobContributorRole
      tableContributorRole
    ]
    params: {
      storageAccountName: storageAccount.outputs.storageAccountName
      principalId: appService.outputs.stagingSlotPrincipalId
      roleIds: [
        blobContributorRole.outputs.roleId
        tableContributorRole.outputs.roleId
      ]
    }
}
