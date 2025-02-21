targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name which is used to generate a short unique hash for each resource')
param name string

@minLength(1)
@description('Primary location for all resources')
param location string

param acaExists bool = false

// A token store is only needed if the app needs to access the Entra access tokens
// https://learn.microsoft.com/azure/container-apps/token-store
param includeTokenStore bool = true

param tokenStorageContainerName string = 'tokens'

@description('Service Management Reference for the app registration')
param serviceManagementReference string = ''

var resourceToken = toLower(uniqueString(subscription().id, name, location))
var tags = { 'azd-env-name': name }

resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: '${name}-rg'
  location: location
  tags: tags
}

var prefix = '${name}-${resourceToken}'


// Container apps environment (including container registry)
module containerApps 'core/host/container-apps.bicep' = {
  name: 'container-apps'
  scope: resourceGroup
  params: {
    name: 'app'
    location: location
    tags: tags
    containerAppsEnvironmentName: '${prefix}-containerapps-env'
    containerRegistryName: '${replace(prefix, '-', '')}registry'
    logAnalyticsWorkspaceName: logAnalyticsWorkspace.outputs.name
  }
}

module aca 'aca.bicep' = {
  name: 'aca'
  scope: resourceGroup
  params: {
    name: replace('${take(prefix,19)}-ca', '--', '-')
    location: location
    tags: tags
    identityName: '${prefix}-id-aca'
    containerAppsEnvironmentName: containerApps.outputs.environmentName
    containerRegistryName: containerApps.outputs.registryName
    exists: acaExists
  }
}

module logAnalyticsWorkspace 'core/monitor/loganalytics.bicep' = {
  name: 'loganalytics'
  scope: resourceGroup
  params: {
    name: '${prefix}-loganalytics'
    location: location
    tags: tags
  }
}


var issuer = '${environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'
module registration 'appregistration.bicep' = {
  name: 'reg'
  scope: resourceGroup
  params: {
    clientAppName: '${prefix}-entra-client-app'
    clientAppDisplayName: 'Simple Flask Server Client App'
    webAppEndpoint: aca.outputs.uri
    webAppIdentityId: aca.outputs.identityPrincipalId
    issuer: issuer
    serviceManagementReference: serviceManagementReference
  }
}


module storage 'br/public:avm/res/storage/storage-account:0.9.1' = if (includeTokenStore) {
  name: 'storage'
  scope: resourceGroup
  params: {
    name: '${take(replace(prefix, '-', ''), 17)}storage'
    location: location
    tags: tags

    kind: 'StorageV2'
    skuName: 'Standard_LRS'
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    blobServices: {
      deleteRetentionPolicyDays: 2
      deleteRetentionPolicyEnabled: true
      containers: [
        {
          name: tokenStorageContainerName
          publicAccess: 'None'
        }
      ]
    }
  }
}

module appupdate 'appupdate.bicep' = {
  name: 'appupdate'
  scope: resourceGroup
  params: {
    containerAppName: aca.outputs.name
    clientId: registration.outputs.clientAppId
    openIdIssuer: issuer
    includeTokenStore: includeTokenStore
    blobContainerUri: includeTokenStore ? 'https://${storage.outputs.name}.blob.${environment().suffixes.storage}/${tokenStorageContainerName}' : ''
    appIdentityResourceId: includeTokenStore ? aca.outputs.identityResourceId : ''
  }
}


output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId

output SERVICE_ACA_IDENTITY_PRINCIPAL_ID string = aca.outputs.identityPrincipalId
output SERVICE_ACA_NAME string = aca.outputs.name
output SERVICE_ACA_URI string = aca.outputs.uri
output SERVICE_ACA_IMAGE_NAME string = aca.outputs.imageName

output AZURE_CONTAINER_ENVIRONMENT_NAME string = containerApps.outputs.environmentName
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerApps.outputs.registryLoginServer
output AZURE_CONTAINER_REGISTRY_NAME string = containerApps.outputs.registryName
