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
  az group create --name rg-rtidemo --location westus3
  ```

> ⚠️ **Region availability:** `Standard_D4s_v3` may not be available in all regions. If deployment fails with a capacity error, try `westus3`, `eastus2`, or `northeurope`. Update `location` in `parameters.json` accordingly.

  ```bash
  ```

### Deploy

```bash
az deployment group create \
  --resource-group rg-rtidemo \
  --template-file infrastructure/bicep/main.bicep \
  --parameters infrastructure/bicep/parameters.json \
  --parameters adminPassword="<YourStrongPassword>"
```

> **Password requirements:** Minimum 12 characters, must include uppercase, lowercase, digit, and symbol.  
> Example: `DemoP@ss2026!`

### Get outputs (note these for later steps)

```bash
az deployment group show \
  --resource-group rg-rtidemo \
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

> Creates `GasPlantDB` on `F:\data\` (the dedicated data disk), sets FULL recovery model.
>
> ⚠️ **Data disk drive letter:** On Windows Server 2022 VMs, `D:` is typically the temporary/CD-ROM disk and `E:` may already be assigned. You likely need to initialize the 256 GB data disk (Disk 2) manually and assign it `F:\`:
> ```powershell
> # Run as Administrator in PowerShell on the VM
> Initialize-Disk -Number 2 -PartitionStyle GPT -ErrorAction SilentlyContinue
> New-Partition -DiskNumber 2 -DriveLetter F -UseMaximumSize
> Format-Volume -DriveLetter F -FileSystem NTFS -NewFileSystemLabel "SQLData" -Confirm:$false
> New-Item -ItemType Directory -Path F:\data
> ```
> Then verify the drive letter with `Get-PSDrive` before running Script 1. Update paths in `sql/schema/01-create-database.sql` if needed.

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
> 
> Set it to start automatically so it survives VM reboots:
> ```powershell
> Set-Service SQLSERVERAGENT -StartupType Automatic
> Start-Service SQLSERVERAGENT
> ```

### Script 5 — Create Fabric Login

```
infrastructure/scripts/02-create-login.sql
```

> Creates `FabricMirrorLogin` with minimum required permissions. Use `02-create-login.example.sql` as your template — copy it to `02-create-login.sql` (gitignored) and replace `<FABRIC-MIRROR-PASSWORD>` with a strong password.
>
> ⚠️ **Mixed Authentication mode required:** SQL Server Developer edition defaults to Windows Authentication only. Before running this script:
> 1. SSMS → right-click server → **Properties** → **Security** → Server Authentication → **SQL Server and Windows Authentication mode** → OK
> 2. Restart the SQL Server service (Services app or `Restart-Service MSSQLSERVER`)
>
> ⚠️ **CDC stored proc grants must run in `master` context:** `sp_cdc_get_captured_columns` and `sp_cdc_help_change_data_capture` live in `master`. The example script already handles this correctly — it creates a user in `master` for the login first:
> ```sql
> USE master;
> CREATE USER FabricMirrorUser FOR LOGIN FabricMirrorLogin;
> GRANT EXECUTE ON sp_cdc_get_captured_columns TO FabricMirrorLogin;
> GRANT EXECUTE ON sp_cdc_help_change_data_capture TO FabricMirrorLogin;
> ```
> Running these grants in `GasPlantDB` context will fail silently — Mirroring will show tables as "Running with warnings".

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

4. **Disable Force Encryption** (required for Fabric VNet Data Gateway connectivity over private VNet without a trusted CA certificate):
   - Open **Registry Editor** → `HKLM\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQLServer\SuperSocketNetLib`
   - Set `ForceEncryption` = `0`
   - Restart SQL Server service

5. In SSMS when connecting locally: **Encryption = Optional**, **Trust Server Certificate = true**.

---

## Step 5 — Run the IoT Simulator

On the VM, open PowerShell:

```powershell
# Install Python — winget is NOT available on Windows Server 2022 by default.
# Download the installer directly:
Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe" `
  -OutFile "C:\Temp\python-3.11.9.exe"
Start-Process -Wait -FilePath "C:\Temp\python-3.11.9.exe" `
  -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1"
# Re-open PowerShell after install to pick up PATH

# Copy simulator files to VM (or clone the repo)
# Assuming repo is at C:\demo\
cd C:\demo\simulator

pip install -r requirements.txt

# Set connection string (Windows Integrated Auth — simplest for demo)
# ODBC Driver 17 is pre-installed on the SQL Server marketplace image.
# ODBC Driver 18 requires a separate download — use 17 unless you need newer features.
$env:SQL_CONN_STR = "DRIVER={ODBC Driver 17 for SQL Server};SERVER=localhost;DATABASE=GasPlantDB;Trusted_Connection=yes;TrustServerCertificate=yes"

python sensor_simulator.py
```

### Run as a Windows Scheduled Task (recommended for persistence across logins)

To keep the simulator running after you close the RDP session:

```powershell
# Set SQL_CONN_STR as a Machine-level environment variable (persists across sessions)
[System.Environment]::SetEnvironmentVariable(
    'SQL_CONN_STR',
    'DRIVER={ODBC Driver 17 for SQL Server};SERVER=localhost;DATABASE=GasPlantDB;Trusted_Connection=yes;TrustServerCertificate=yes',
    'Machine'
)

# Create a Scheduled Task that starts on system boot, runs as sqladmin
$action  = New-ScheduledTaskAction -Execute 'python' `
             -Argument 'C:\demo\simulator\sensor_simulator.py' `
             -WorkingDirectory 'C:\demo\simulator'
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'SensorSimulator' `
    -Action $action -Trigger $trigger -Settings $settings `
    -RunLevel Highest -Force

# Start immediately
Start-ScheduledTask -TaskName 'SensorSimulator'
```

> The task runs as the `sqladmin` user (who owns the SQL Server service), ensuring `Trusted_Connection=yes` resolves correctly.

### Verify and manage the simulator

```powershell
# Check if running (should show State = Running)
Get-ScheduledTask -TaskName 'SensorSimulator' | Select-Object TaskName, State

# Check last run result (LastTaskResult = 0 means success)
Get-ScheduledTaskInfo -TaskName 'SensorSimulator' | Select-Object LastRunTime, LastTaskResult

# Start manually if State = Ready (not running)
Start-ScheduledTask -TaskName 'SensorSimulator'

# Stop if needed
Stop-ScheduledTask -TaskName 'SensorSimulator'
```

Confirm data is flowing into SQL Server (run in SSMS):
```sql
SELECT TOP 5 reading_id, sensor_id, ts, value
FROM GasPlantDB.dbo.SensorReadings
ORDER BY reading_id DESC;
```
The `reading_id` should increase by 40 every 5 seconds (one reading per sensor per tick).

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
>
> ⚠️ If `ProcessUnits` or `Sensors` show **"Running with warnings"**: `FabricMirrorLogin` needs `db_owner` role on `GasPlantDB`:
> ```sql
> USE GasPlantDB;
> ALTER ROLE db_owner ADD MEMBER FabricMirrorUser;
> ```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Bicep deployment fails with capacity error | SKU not available in region | Change `location` to `westus3` or `westus2` in `parameters.json` |
| `D:\data\` path error in Script 1 | D: is CD-ROM, not data disk | Initialize Disk 2 as `F:\` (see Step 3 Script 1 note) |
| `Initialize-Disk` fails (disk already GPT) | Disk already initialized | Skip `Initialize-Disk`, run `New-Partition -DiskNumber 2 -DriveLetter F -UseMaximumSize` directly |
| SQL Login creation fails | Windows Auth only mode | Enable Mixed Auth in Server Properties → Security, restart SQL Server |
| Mirroring SSL error / connection refused | ForceEncryption=1 | Set `ForceEncryption=0` in registry (see Step 4), restart SQL Server |
| CDC grant fails (`Cannot find the object`) | Wrong database context | Run CDC grants in `master` context (see Script 5 note) |
| `ProcessUnits`/`Sensors` show "Running with warnings" | Missing db_owner | `ALTER ROLE db_owner ADD MEMBER FabricMirrorUser` in GasPlantDB |
| Simulator fails with "ODBC Driver 18 not found" | Driver not installed | Use `ODBC Driver 17 for SQL Server` (pre-installed on marketplace image) |
| Simulator exits after RDP session closes | Running interactively | Set up Windows Scheduled Task (see Step 5) |
| Mirroring stalls — rows stop replicating, status shows "Running" but count doesn't advance | SQL Server Agent stopped (CDC capture job hangs) | `Start-Service SQLSERVERAGENT` on VM, then `EXEC msdb.dbo.sp_start_job @job_name = 'cdc.GasPlantDB_capture'` in SSMS. Set Agent to `Automatic` startup. |
| `cdc.GasPlantDB_capture` job never stops (shows NULL stop_execution_date after 24h) | SQL Server Agent crashed while job was running | Stop Agent → Start Agent → job auto-restarts |

---

## Phase 1 Complete ✓

**What you have:**
- Azure VM (`10.0.1.x`) running SQL Server with 40 sensor tags streaming at 5-second intervals
- Fabric Mirrored Database replicating CDC changes to OneLake (Bronze Delta Parquet)
- VNet Data Gateway bridging private network to Fabric

**Next:** [Phase 2 — Medallion Architecture](phase-2-medallion.md)
