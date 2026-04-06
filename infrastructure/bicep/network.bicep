@description('Azure region for all resources.')
param location string

@description('Name prefix for all resources.')
param namePrefix string

@description('Source IP CIDR allowed to RDP. Restrict to your public IP for security.')
param allowedRdpSourceAddressPrefix string = '*'

var vnetName = '${namePrefix}-vnet'
var nsgName  = '${namePrefix}-vm-nsg'

// ── Network Security Group (attached to vm-subnet only) ───────────────────────
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        // RDP access for demo setup — restrict allowedRdpSourceAddressPrefix to your IP
        name: 'Allow-RDP-Inbound'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: allowedRdpSourceAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        // Allow Fabric VNet Data Gateway (gateway-subnet) to reach SQL Server on 1433
        name: 'Allow-SQL-From-Gateway-Subnet'
        properties: {
          priority: 110
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '10.0.2.0/24'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '1433'
        }
      }
      {
        // Block all other inbound internet traffic
        name: 'Deny-All-Other-Inbound'
        properties: {
          priority: 4000
          protocol: '*'
          access: 'Deny'
          direction: 'Inbound'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ── Virtual Network with two subnets ──────────────────────────────────────────
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        // SQL Server VM lives here
        name: 'vm-subnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
      {
        // Delegated to Microsoft Fabric VNet Data Gateway
        // This subnet must be /24 or larger and have no other resources
        name: 'gateway-subnet'
        properties: {
          addressPrefix: '10.0.2.0/24'
          delegations: [
            {
              name: 'fabric-vnet-dg-delegation'
              properties: {
                serviceName: 'Microsoft.PowerPlatform/vnetaccesslinks'
              }
            }
          ]
        }
      }
    ]
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
output vnetId          string = vnet.id
output vnetName        string = vnet.name
output vmSubnetId      string = vnet.properties.subnets[0].id
output gatewaySubnetId string = vnet.properties.subnets[1].id
