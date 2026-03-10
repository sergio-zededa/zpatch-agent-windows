# ZEDEDA Windows Update Agent

## Overview
This script (`ZededaAgent.ps1`) runs on a Windows guest inside an EVE-OS App Instance. It operates as a continuous background daemon, polling the local EVE-OS metadata server (`169.254.169.254`) for new Patch Envelopes. 

The agent expects a `manifest.json` file (can be Base64 encoded inside the envelope) to direct it to install, remove, or update Windows packages. It tracks previously applied patches to prevent duplicate executions and cleans up downloaded payloads upon success. Finally, it pushes the granular execution results back to the EVE controller via the `appCustomStatus` endpoint.

## File Locations
- **Working Directory:** `C:\ProgramData\ZededaAgent`
- **Logs:** `C:\ProgramData\ZededaAgent\agent.log`
- **Downloads:** `C:\ProgramData\ZededaAgent\Downloads`
- **State File:** `C:\ProgramData\ZededaAgent\applied_patches.json`

## Installation & Auto-Start as a Windows Agent

This script is designed to run automatically in the background as a scheduled task or service. To install and run this script, open an **Administrator PowerShell** prompt.

### Method 1: Running as a Windows Scheduled Task (Recommended)
You can register the script as a Scheduled Task that runs continuously in the background on startup.

```powershell
# Create the scheduled task
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"C:\Path\To\ZededaAgent.ps1`""
$trigger = New-ScheduledTaskTrigger -AtStartup

# Configure settings so it runs indefinitely as a daemon and doesn't rely on AC power
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0

$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "ZededaUpdateAgent" -Action $action -Trigger $trigger -Principal $principal -Settings $settings

# Start the agent manually for the first time
Start-ScheduledTask -TaskName "ZededaUpdateAgent"
```

### Method 2: Using native Windows Service Controller (`sc.exe`)
This is the native way to ensure the script starts automatically in the background.

```powershell
sc.exe create "ZededaUpdateAgent" binpath= "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"C:\Path\To\ZededaAgent.ps1`"" start= auto
sc.exe start "ZededaUpdateAgent"
```
*(Note: Replace `C:\Path\To\ZededaAgent.ps1` with the actual path where you deployed the script on your Windows instance).*

### Method 2: Using NSSM (Non-Sucking Service Manager)
NSSM often provides better handling for wrapping PowerShell scripts as background services.

```powershell
# 1. Download and extract NSSM (https://nssm.cc/release/nssm-2.24.zip)
# 2. Open an Administrative shell in the NSSM extract directory
nssm.exe install ZededaUpdateAgent "powershell.exe" "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"C:\Path\To\ZededaAgent.ps1`""
nssm.exe set ZededaUpdateAgent AppDirectory "C:\Path\To"
nssm.exe start ZededaUpdateAgent
```

## EVE-OS Patch Envelope Manifest Example
The agent executes defined commands within a JSON payload (either a physical `manifest.json` file, or base64-encoded inside the EVE patch description `BinaryBlobs`). 

### Example Manifest:
```json
[
    {
        "action": "install", 
        "id": "CustomApp", 
        "installer_url": "https://example.com/installer.msi", 
        "installer": "installer.msi", 
        "arguments": "/qn /norestart"
    },
    {
        "action": "remove", 
        "id": "GoogleChrome", 
        "local_path": "powershell.exe", 
        "arguments": "-Command \"& { $path = (Get-ItemProperty 'HKLM:\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Google Chrome' -ErrorAction SilentlyContinue).UninstallString; if ($path) { Start-Process -FilePath $path.Split(' ')[0].Trim('\"\"') -ArgumentList '--uninstall --multi-install --chrome --system-level --force-uninstall' -Wait -NoNewWindow } }\""
    }
]
```

### Properties:
- `action`: Can be `install`, `remove`, or `update`.
- `id`: A unique identifier that will be reported back in the status payload.
- `installer_url`: The URL to download the executable/MSI.
- `local_path`: If uninstalling or referencing a pre-existing binary, the exact local path (or a command like `powershell.exe` available in the system PATH).
- `arguments`: Silent/unattended arguments to pass to the binary execution.
