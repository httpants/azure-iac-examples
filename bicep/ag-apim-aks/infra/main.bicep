param tags object
param location string
param cert object
param rootCert object
param vNets array
param aksAdminGroupObjectId string
param orderApiYaml string
param productApiYaml string
param orderApiPoicyXml string
param productApiPoicyXml string
param kubernetesSpaIpAddress string
param childPublicDnsZoneName string
param privateDnsZoneName string
param publicDnsZoneResourceGroup string

var suffix = uniqueString(resourceGroup().id)
var appGwySeparatedAddressprefix = split(vNets[0].subnets[0].addressPrefix, '.')
var appGwyPrivateIpAddress = '${appGwySeparatedAddressprefix[0]}.${appGwySeparatedAddressprefix[1]}.${appGwySeparatedAddressprefix[2]}.200'
var acrPullRoleDefinitionName = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var acrPullRoleId = '${subscription().id}/providers/Microsoft.Authorization/roleDefinitions/${acrPullRoleDefinitionName}'
var networkContributorRoleDefinitionName = '4d97b98b-1d4f-4787-a291-c67834d212e7'
var networkContributorRoleId = '${subscription().id}/providers/Microsoft.Authorization/roleDefinitions/${networkContributorRoleDefinitionName}'

// create public DNS zone
module publicDnsZone 'modules/publicDnsZone.bicep' = {
  name: 'module-public-dns-zone'
  params: {
    zoneName: childPublicDnsZoneName
    tags: tags
  }
}

// Azure Monitor Workspace
module azMonitorModule './modules/azmon.bicep' = {
  name: 'modules-azmon'
  params: {
    suffix: suffix
    location: location
  }
}

// Network Security Groups
module nsgModule './modules/nsg.bicep' = {
  name: 'module-nsg'
  params: {
    location: location
    appGatewayPublicIpAddress: '1.1.1.1'
    suffix: suffix
  }
}

// Virtual Networks
module vNetsModule './modules/vnets.bicep' = [for (item, i) in vNets: {
  name: 'module-vnet-${i}'
  params: {
    suffix: suffix
    location: location
    vNet: item
    tags: tags
  }
  dependsOn: [
    nsgModule
  ]
}]

// Virtual Network Peering
module peeringModule './modules/peering.bicep' = {
  name: 'module-peering'
  params: {
    suffix: suffix
    vNets: vNets
    isGatewayDeployed: false
  }
  dependsOn: [
    vNetsModule
  ]
}

// Azure Container Registry
module acr 'modules/acr.bicep' = {
  name: 'module-acr'
  params: {
    location: location
    tags: tags
    prefix: suffix
  }
}

// Private DNS zones
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  location: 'global'
  tags: tags
  name: privateDnsZoneName
}

// API Management
module apiManagementModule './modules/apim.bicep' = {
  dependsOn: [
    azMonitorModule
    vNetsModule
  ]
  name: 'module-apim'
  params: {
    tags: tags
    location: location
    retentionInDays: 30
    workspaceId: azMonitorModule.outputs.workspaceId
    privateDnsZoneName: privateDnsZone.name
    hubVnetId: vNetsModule[0].outputs.vnetRef
    spokeVnetId: vNetsModule[1].outputs.vnetRef
    apimSku: {
      name: 'Developer'
      capacity: 1
    }
    deployCertificates: true
    gatewayHostName: 'gateway.${privateDnsZoneName}'
    certificate: cert.CertValue
    certificatePassword: cert.CertPassword
    subnetId: vNetsModule[0].outputs.subnetRefs[4].id
  }
}

// Import Open Api Definitions
module orderOpenApiDefinition 'modules/api.bicep' = {
  name: 'module-order-api'
  params: {
    apimName: apiManagementModule.outputs.apimName
    apiName: 'order-api'
    apiPath: 'api/order'
    displayName: 'Order API'
    isSubscriptionRequired: false
    openApiYaml: orderApiYaml
    xmlPolicy: orderApiPoicyXml
  }
}

module productOpenApiDefinition 'modules/api.bicep' = {
  name: 'module-product-api'
  params: {
    apimName: apiManagementModule.outputs.apimName
    apiName: 'product-api'
    apiPath: 'api/product'
    displayName: 'Product API'
    isSubscriptionRequired: false
    openApiYaml: productApiYaml
    xmlPolicy: productApiPoicyXml
  }
}

// Application Gateway
module applicationGatewayModule './modules/appgateway.bicep' = {
  dependsOn: [
    vNetsModule
    azMonitorModule
    privateDnsZone
  ]
  name: 'module-applicationGateway'
  params: {
    suffix: suffix
    location: location
    kubernetesSpaIpAddress: kubernetesSpaIpAddress
    privateDnsZoneName: privateDnsZoneName
    workspaceId: azMonitorModule.outputs.workspaceId
    apimGatewaySslCertPassword: cert.CertPassword
    frontEndPort: 443
    internalFrontendPort: 8080
    retentionInDays: 7
    externalGatewayHostName: 'api.${childPublicDnsZoneName}'
    internalGatewayHostName: 'gateway.${privateDnsZoneName}'
    rootSslCert: rootCert.CertValue
    apimGatewaySslCert: cert.CertValue
    apimPrivateIpAddress: appGwyPrivateIpAddress
    gatewaySku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
      capacity: '1'
    }
    requestTimeOut: 180
    skuName: 'Standard'
    subnetId: vNetsModule[0].outputs.subnetRefs[0].id
  }
}

// Azure Kubernetes Service
module aks 'modules/aks.bicep' = {
  name: 'module-aks'
  params: {
    location: location
    tags: tags
    addOns: {}
    enablePrivateCluster: false
    aksSystemSubnetId: vNetsModule[1].outputs.subnetRefs[1].id
    aksUserSubnetId: vNetsModule[1].outputs.subnetRefs[1].id
    prefix: suffix
    logAnalyticsWorkspaceId: azMonitorModule.outputs.workspaceId
    adminGroupObjectID: aksAdminGroupObjectId
  }
}

// Assign 'AcrPull' role to AKS cluster kubelet identity
resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2020-10-01-preview' = {
  name: guid(resourceGroup().id, aks.name, 'acrPullRoleAssignment')
  properties: {
    principalId: aks.outputs.aksKubeletIdentityObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleId
    description: 'Assign AcrPull role to AKS cluster'
  }
}

// Assign 'Network Contributor' role to AKS cluster system managed identity
resource aksNetworkContributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2020-10-01-preview' = {
  name: guid(resourceGroup().id, aks.name, 'aksNetworkContributorRoleAssignment')
  properties: {
    principalId: aks.outputs.aksClusterManagedIdentity
    principalType: 'ServicePrincipal'
    roleDefinitionId: networkContributorRoleId
    description: 'Assign Netowkr Contributor role to AKS cluster Managed Identity'
  }
}

// Update Application Gateway Public IP in NSG
module networkSecurityGroupUpdateModule './modules/nsg.bicep' = {
  name: 'module-nsgupdate'
  params: {
    location: location
    suffix: suffix
    appGatewayPublicIpAddress: applicationGatewayModule.outputs.appGwyPublicIpAddress
  }
}

// Azure Public DNS records
module appGwyApiPublicDnsRecord 'modules/publicDnsRecord.bicep' = {
  scope: resourceGroup(publicDnsZoneResourceGroup)
  name: 'module-appgwy-public-dns-record'
  params: {
    zoneName: childPublicDnsZoneName
    ipAddress: applicationGatewayModule.outputs.appGwyPublicIpAddress
    recordName: 'api'
  }
}

output appGwyName string = applicationGatewayModule.outputs.appGwyName
output appGwyId string = applicationGatewayModule.outputs.appGwyId
output appGwyFqdn string = applicationGatewayModule.outputs.appGwyPublicDnsName
output appGwyPublicIpAddress string = applicationGatewayModule.outputs.appGwyPublicIpAddress
output apimPrivateIpAddress string = apiManagementModule.outputs.apimPrivateIpAddress
output apimName string = apiManagementModule.outputs.apimName
output apimManagedIdentity string = apiManagementModule.outputs.apimManagedIdentityPrincipalId
output aksClusterName string = aks.outputs.aksClusterName
output acrName string = acr.outputs.registryName
