param location string
param suffix string
param azureFirewallPrivateIpAddress string

resource default_firewall_rt 'Microsoft.Network/routeTables@2018-11-01' = {
  name: 'default-firewall-rt-${suffix}'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'default-firewall-route'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: azureFirewallPrivateIpAddress
        }
      }
    ]
  }
}

output name string = default_firewall_rt.name
