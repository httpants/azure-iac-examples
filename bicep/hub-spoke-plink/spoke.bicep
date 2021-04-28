// App Service (containers) + Regional Vnet Integration + limit access by X-AZFD-ID header
// Azure Front Door -> App Service PIP

param spokeVnetName string = 'spoke-vnet'
param spokeVnetAddressPrefix string = '10.1.0.0/16'
param tags object = {
  costcenter: '1234567890'
  environment: 'dev'
}
param spokeSubnets array = [
  {
    name: 'PrivateLink-Subnet'
    addressPrefix: '10.1.0.0/24'
    delegations: []
  }
  {
    name: 'Database-Subnet'
    addressPrefix: '10.1.1.0/24'
    delegations: [
      {
        name: 'delegation'
        properties: {
          serviceName: 'Microsoft.DBforMySQL/flexibleServers'
        }
      }
    ]
  }
  {
    name: 'AppService-Subnet'
    addressPrefix: '10.1.2.0/24'
    delegations: [
      {
        name: 'delegation'
        properties: {
          serviceName: 'Microsoft.Web/serverfarms'
        }
      }
    ]
  }
]
@allowed([
  'P1v2'
  'P2v2'
  'P3v2'
])
param skuName string = 'P1v2'
param mySqlAdminUserName string
param mySqlAdminPassword string
param linuxFxVersion string = 'PHP|7.4'
param containerName string
param hubVnetId string
param hubVnetName string
param hubVnetResourceGroup string

var siteName = 'my-app-${suffix}'
var suffix = uniqueString(resourceGroup().id)
var storageName = 'stor${suffix}'
var mySqlServerName = 'mysql-flexserver-${suffix}'
var storagePrivateDNSZoneName = 'privatelink.blob.core.windows.net'
var mySQLFlexServerName = 'mysqlflex${suffix}'
var mySqlPrivateDNSZoneName = 'mysql.database.azure.com'
var serverFarmName = 'app-svc-${suffix}'

// vnet + subnets
module spokeVnetModule './modules/vnet.bicep' = {
  name: spokeVnetName
  params: {
    tags: tags
    vnetName: spokeVnetName
    subnets: spokeSubnets
    vnetAddressPrefix: spokeVnetAddressPrefix
  }
}

resource vnetPeeringToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2020-08-01' = {
  name: '${spokeVnetName}/peering-to-hub-vnet'
  dependsOn: [
    spokeVnetModule
  ]
  properties: {
    allowForwardedTraffic: true
    allowGatewayTransit: true
    allowVirtualNetworkAccess: true
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: hubVnetId
    }
  }
}

module vnetPeeringFromHub './modules/vnetPeering.bicep' = {
  name: 'hubVnetPeeringDeployment'
  scope: resourceGroup(hubVnetResourceGroup)
  dependsOn: [
    spokeVnetModule
  ]
  params: {
    remoteVnetId: spokeVnetModule.outputs.id
    parentVnetName: hubVnetName
    useRemoteGateways: false
  }
}

// Storage + Private endpoint + DNS Zone
resource storage 'Microsoft.Storage/storageAccounts@2021-02-01' = {
  name: storageName
  tags: tags
  location: resourceGroup().location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: true
    networkAcls: {
      defaultAction: 'Deny'
    }
    supportsHttpsTrafficOnly: true
  }
}

resource blobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2020-11-01' = {
  location: resourceGroup().location
  tags: tags
  name: 'blobPrivateEndpoint'
  properties: {
    subnet: {
      id: resourceId('Microsoft.Network/virtualNetworks/subnets', spokeVnetModule.outputs.vnetName, spokeVnetModule.outputs.subnetArray[0].name)
    }
    privateLinkServiceConnections: [
      {
        name: 'blobStorageConnection'
        properties: {
          groupIds: [
            'blob'
          ]
          privateLinkServiceId: storage.id
        }
      }
    ]
  }
}

resource blobPrivateEndpointDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  location: 'global'
  tags: tags
  name: storagePrivateDNSZoneName
  properties: {}
}

resource virtualNetworkStorageDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: '${blobPrivateEndpointDnsZone.name}/${blobPrivateEndpointDnsZone.name}-link'
  tags: tags
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: spokeVnetModule.outputs.id
    }
  }
}

module mySqlFlexServerModule 'modules/mysql-flex-server.bicep' = {
  name: 'mySqlFlexServerDeployment'
  params: {
    serverName: mySqlServerName
    location: resourceGroup().location
    administratorLogin: 'dbadmin'
    administratorLoginPassword: 'M1cr0soft1234567890'
    subnetArmResourceId: resourceId('Microsoft.Network/virtualNetworks/subnets', spokeVnetModule.outputs.vnetName, spokeVnetModule.outputs.subnetArray[1].name)
    suffix: suffix
  }
}

resource mySqlPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  location: 'global'
  tags: tags
  name: mySqlPrivateDNSZoneName
  properties: {}
}

/* resource mySqlPrivateDnsRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  name: mySqlServerName
  parent: mySqlPrivateDnsZone
  properties: {
    aRecords: [
      {
        ipv4Address: mySqlFlexServerModule.outputs.mySqlServerIpAddress
      }
    ]
  }
}
 */
resource virtualNetworkMySqlDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: '${mySqlPrivateDnsZone.name}/${mySqlPrivateDnsZone.name}-link'
  tags: tags
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: spokeVnetModule.outputs.id
    }
  }
}

resource serverFarm 'Microsoft.Web/serverfarms@2020-12-01' = {
  kind: 'linux'
  location: resourceGroup().location
  name: serverFarmName
  sku: {
    name: skuName
    tier: 'PremiumV2'
    size: skuName
    family: skuName
    capacity: 1
  }
  properties: {
    reserved: true
  }
}

resource webApp1 'Microsoft.Web/sites@2020-06-01' = {
  name: siteName
  location: resourceGroup().location
  kind: 'app,linux,container'
  properties: {
    serverFarmId: serverFarm.id
    siteConfig: {
      linuxFxVersion: 'DOCKER|${containerName}'
    }
  }
}

resource webApp1AppSettings 'Microsoft.Web/sites/config@2020-06-01' = {
  name: '${webApp1.name}/appsettings'
  properties: {
    'WEBSITE_DNS_SERVER': '168.63.129.16'
    'WEBSITE_VNET_ROUTE_ALL': '1'
    'WEBSITES_ENABLE_APP_SERVICE_STORAGE': false
    'DOCKER_REGISTRY_SERVER_URL': 'https://index.docker.io/v1'
  }
}

resource webApp1NetworkConfig 'Microsoft.Web/sites/networkConfig@2020-06-01' = {
  name: '${webApp1.name}/VirtualNetwork'
  properties: {
    subnetResourceId: resourceId('Microsoft.Network/virtualNetworks/subnets', spokeVnetModule.outputs.vnetName, spokeVnetModule.outputs.subnetArray[2].name)
  }
}

output vnetName string = spokeVnetModule.outputs.vnetName
output vnetId string = spokeVnetModule.outputs.id
output storageDnsZoneId string = blobPrivateEndpointDnsZone.id
