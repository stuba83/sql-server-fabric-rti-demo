@description('Azure region for all resources.')
param location string

@description('Name prefix for all resources.')
param namePrefix string

@description('Resource ID of the subnet where the VM NIC will be placed.')
param subnetId string

@description('VM administrator username.')
param adminUsername string

@description('VM administrator password.')
@secure()
param adminPassword string

@description('Azure VM size.')
param vmSize string = 'Standard_D4s_v3'

var vmName   = '${namePrefix}-vm'
var nicName  = '${namePrefix}-nic'
var pipName  = '${namePrefix}-pip'

// ── Public IP (Standard SKU required for zone support + stable allocation) ────
resource publicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: pipName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: '${namePrefix}-sqlvm'
    }
  }
}

// ── Network Interface ─────────────────────────────────────────────────────────
resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

// ── Virtual Machine — Windows Server 2022 + SQL Server 2022 Developer ─────────
// SQL Server 2022 Developer edition is free and has all Enterprise features.
// Marketplace image: MicrosoftSQLServer / sql2022-ws2022 / sqldev-gen2
resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
        patchSettings: {
          patchMode: 'AutomaticByOS'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftSQLServer'
        offer:     'sql2022-ws2022'
        sku:       'sqldev-gen2'
        version:   'latest'
      }
      osDisk: {
        name:         '${namePrefix}-osdisk'
        caching:      'ReadWrite'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        diskSizeGB: 128
      }
      dataDisks: [
        {
          // Dedicated data disk for SQL Server data + log files
          name:       '${namePrefix}-datadisk'
          lun:        0
          caching:    'ReadOnly'
          createOption: 'Empty'
          diskSizeGB: 256
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// ── Auto-Shutdown at 22:00 UTC — keeps demo costs low ─────────────────────────
resource autoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${vmName}'
  location: location
  properties: {
    status:    'Enabled'
    taskType:  'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: '2200'
    }
    timeZoneId:      'UTC'
    targetResourceId: vm.id
    notificationSettings: {
      status: 'Disabled'
    }
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
output vmId             string = vm.id
output vmName           string = vm.name
output publicIpAddress  string = publicIp.properties.ipAddress
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output fqdn             string = publicIp.properties.dnsSettings.fqdn
