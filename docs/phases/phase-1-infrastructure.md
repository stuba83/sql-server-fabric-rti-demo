# Phase 1 — Azure Infrastructure + SQL Server + IoT Simulator + VNet Data Gateway + Mirroring

**Duration:** ~2–3 hours (first time) | **Cost:** ~$5–10 for the session

---

## What you will have at the end of this phase

- Azure VM running **SQL Server 2022 Developer** in a private VNet
- Python **IoT Simulator** streaming 40 LP Gas sensor tags into SQL Server every 5 seconds
- **CDC** enabled on 4 tables (`SensorReadings`, `Alarms`, `EquipmentStatus`, `GasQuality`)
- **Fabric VNet Data Gateway** provisioned in the gateway subnet
- **Fabric Mirrored Database** replicating all 6 tables from SQL Server to OneLake Delta

---

## Step 1 — Deploy Azure Infrastructure (Bicep)

### Prerequisites
- Azure CLI logged in: `az login`
- A resource group created (or let the script create one):
  ```bash
  az group create --name rg-fabric-rti-demo --location eastus
  ```

### Deploy

```bash
az deployment group create \
  --resource-group rg-fabric-rti-demo \
  --template-file infrastructure/bicep/main.bicep \
  --parameters infrastructure/bicep/parameters.json \
  --parameters adminPassword="<YourStrongPassword>"
```

> **Password requirements:** Minimum 12 characters, must include uppercase, lowercase, digit, and symbol.  
> Example: `DemoP@ss2026!`

### Get outputs (note these for later steps)

```bash
az deployment group show \
  --resource-group rg-fabric-rti-demo \
  --name main \
  --query properties.outputs
```

Key outputs:
| Output | Used for |
|---|---|
| `vmPublicIp` | RDP connection |
| `vmPrivateIp` | Fabric Mirroring source IP |
| `gatewaySubnetId` | VNet Data Gateway provisioning |

### Verify deployment
- In Azure Portal → Resource Group → you should see: VNet, NSG, NIC, Public IP, VM, Auto-shutdown schedule

---

## Step 2 — Connect to the VM via RDP

```
mstsc /v:<vmPublicIp>
```

- Username: `sqladmin` (or whatever you set in `parameters.json`)
- Password: the one you passed in Step 1

---

## Step 3 — Set Up SQL Server

Open **SQL Server Management Studio** (SSMS) — preinstalled on the SQL Server marketplace image.  
Connect to: `localhost` | Windows Authentication.

Run the SQL scripts **in this exact order**:

### Script 1 — Create Database

```
sql/schema/01-create-database.sql
```

> Creates `GasPlantDB` on `D:\data\` (the dedicated data disk), sets FULL recovery model.

### Script 2 — Create Tables

```
sql/schema/02-create-tables.sql
```

> Creates 6 tables: `ProcessUnits`, `Sensors`, `SensorReadings`, `EquipmentStatus`, `Alarms`, `GasQuality`.

### Script 3 — Seed Static Data

```
sql/schema/03-seed-static-data.sql
```

> Inserts 13 process units and 40 sensor tags. Verify output:
> - `unit_type` summary: 1 Plant, 2 Trains, 6 Compressors, 2 Separators, 2 Meters
> - `parameter_type` summary: 12 Pressure, 11 Temperature, 8 Power, 8 RPM, 4 Flow, 3 Level

### Script 4 — Enable CDC

```
infrastructure/scripts/01-enable-cdc.sql
```

> Enables CDC at DB level and on all 4 high-frequency tables.  
> Verify: last query in the script shows `is_cdc_enabled = 1` and 4 tracked tables.

> **Requirement:** SQL Server Agent must be running. In SSMS Object Explorer → SQL Server Agent → if stopped, right-click → Start.

### Script 5 — Create Fabric Login

```
infrastructure/scripts/02-create-login.sql
```

> Creates `FabricMirrorLogin` with minimum required permissions.  
> **Change the password** in the script before running if this environment will be shared.

---

## Step 4 — Configure SQL Server for Network Access

Fabric VNet Data Gateway connects over TCP 1433. Verify:

1. **Open SSMS** → Server Properties → Connections → "Allow remote connections" = checked
2. **SQL Server Configuration Manager** → SQL Server Network Configuration → Protocols for MSSQLSERVER → **TCP/IP = Enabled**. Restart SQL Server service.
3. **Windows Firewall** — inbound rule for TCP 1433 from `10.0.2.0/24` (already set by NSG, but Windows Firewall is separate):
   ```powershell
   New-NetFirewallRule -DisplayName "Allow SQL from Gateway Subnet" `
     -Direction Inbound -Protocol TCP -LocalPort 1433 `
     -RemoteAddress 10.0.2.0/24 -Action Allow
   ```

---

## Step 5 — Run the IoT Simulator

On the VM, open PowerShell:

```powershell
# Install Python (if not present — download from python.org or winget)
winget install Python.Python.3.11

# Copy simulator files to VM (or clone the repo)
# Assuming repo is at C:\demo\
cd C:\demo\simulator

pip install -r requirements.txt

# Set connection string (Windows Integrated Auth — simplest for demo)
$env:SQL_CONN_STR = "DRIVER={ODBC Driver 18 for SQL Server};SERVER=localhost;DATABASE=GasPlantDB;Trusted_Connection=yes;TrustServerCertificate=yes"

python sensor_simulator.py
```

Expected output:
```
2026-04-06T10:00:05 [INFO    ] Connected to SQL Server.
2026-04-06T10:00:05 [INFO    ] Loaded 40 sensors and 13 process units. Starting simulation (interval=5s).
2026-04-06T10:00:05 [INFO    ] tick=0 | readings=40 alarms=0 | 0.041s
2026-04-06T10:00:10 [INFO    ] tick=1 | readings=40 alarms=0 | 0.038s
```

Let the simulator run for **at least 2–3 minutes** before proceeding so there's data for Mirroring initial snapshot.

---

## Step 6 — Provision VNet Data Gateway in Fabric

> Requires: Fabric Admin or Workspace Admin role

1. Go to: **Fabric Admin Portal** → [app.fabric.microsoft.com](https://app.fabric.microsoft.com) → Settings (gear icon) → Admin Portal
2. Navigate to: **Virtual Network data gateways**
3. Click **+ New**
4. Fill in:
   - Name: `rtidemo-vnetdg`
   - Azure Subscription: select your subscription
   - Resource Group: `rg-fabric-rti-demo`
   - Virtual Network: `rtidemo-vnet`
   - Subnet: `gateway-subnet`
5. Click **Save** and wait for status = **Online** (~2–3 minutes)

---

## Step 7 — Create Mirrored Database in Fabric

1. In your Fabric workspace: **+ New item → Mirrored database**
2. Select source: **SQL Server**
3. Connection:
   - Server: `<vmPrivateIp>` (from Step 1 outputs, e.g. `10.0.1.4`)
   - Port: `1433`
   - Database: `GasPlantDB`
   - Authentication: SQL Authentication
   - Username: `FabricMirrorLogin`
   - Password: the password from `02-create-login.sql`
   - Gateway: select `rtidemo-vnetdg`
4. Click **Next** → **Select tables**
5. Select: `SensorReadings`, `Alarms`, `EquipmentStatus`, `GasQuality`, `ProcessUnits`, `Sensors`
6. Click **Save + Start Mirroring**

---

## Step 8 — Verify Mirroring

In the Mirrored Database item:
- Status should change: **Initializing** → **Running** (allow 2–3 minutes for initial snapshot)
- Each table shows green checkmark with row count
- Click on `SensorReadings` → Preview — should show sensor readings from the simulator

> If you see "Replication stopped" on any table: check CDC is enabled (Script 4), SQL Server Agent is running, and the login has correct permissions.

---

## Phase 1 Complete ✓

**What you have:**
- Azure VM (`10.0.1.x`) running SQL Server with 40 sensor tags streaming at 5-second intervals
- Fabric Mirrored Database replicating CDC changes to OneLake (Bronze Delta Parquet)
- VNet Data Gateway bridging private network to Fabric

**Next:** [Phase 2 — Medallion Architecture](phase-2-medallion.md)
