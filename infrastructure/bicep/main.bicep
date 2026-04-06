@description('Azure region for all resources. Defaults to resource group location.')
param location string = resourceGroup().location

@description('Name prefix applied to all resources (e.g. "rtidemo"). 3-10 lowercase alphanumeric chars.')
@minLength(3)
@maxLength(10)
param namePrefix string = 'rtidemo'

@description('VM administrator username.')
param adminUsername string = 'sqladmin'

@description('VM administrator password. Pass via --parameters adminPassword=<value> at deploy time. Do not store in parameters.json.')
@secure()
param adminPassword string

@description('Source IP CIDR allowed to RDP into the VM. Restrict to your public IP for security (e.g. "203.0.113.10/32"). Default "*" is open to all.')
param allowedRdpSourceAddressPrefix string = '*'

@description('Azure VM size. Standard_D4s_v3 (4 vCPU / 16 GB) is suited for SQL Server + simulator.')
param vmSize string = 'Standard_D4s_v3'

// ── Network ───────────────────────────────────────────────────────────────────
module network 'network.bicep' = {
  name: 'network'
  params: {
    location: location
    namePrefix: namePrefix
    allowedRdpSourceAddressPrefix: allowedRdpSourceAddressPrefix
  }
}

// ── Virtual Machine (Windows Server 2022 + SQL Server 2022 Developer) ─────────
module virtualMachine 'vm.bicep' = {
  name: 'virtualMachine'
  params: {
    location: location
    namePrefix: namePrefix
    subnetId: network.outputs.vmSubnetId
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
@description('Public IP of the VM. Use for RDP (port 3389).')
output vmPublicIp string = virtualMachine.outputs.publicIpAddress

@description('Private IP of the VM. Use this address when configuring the SQL Server source in Fabric Mirroring.')
output vmPrivateIp string = virtualMachine.outputs.privateIpAddress

output vmName string = virtualMachine.outputs.vmName

@description('Resource ID of the gateway subnet — needed when creating the VNet Data Gateway in Fabric Admin Portal.')
output gatewaySubnetId string = network.outputs.gatewaySubnetId

output rdpCommand string = 'mstsc /v:${virtualMachine.outputs.publicIpAddress}'
