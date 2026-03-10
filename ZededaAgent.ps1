<#
.SYNOPSIS
    ZEDEDA Windows Agent for Processing Patch Envelopes and Updating appCustomStatus

.DESCRIPTION
    This script runs on a Windows guest inside an EVE-OS App Instance. 
    It polls the local metadata server (169.254.169.254) for new Patch Envelopes.
    It expects a 'manifest.json' file inside the Patch Envelope to direct it to
    install, remove, or update Windows packages (using winget).
    Finally, it pushes the results back via the appCustomStatus endpoint.

.EXAMPLE
    Expected manifest.json inside the Patch Envelope:
    [
        {"action": "install", "id": "CustomApp", "installer_url": "https://example.com/installer.msi", "installer": "installer.msi", "arguments": "/qn /norestart"},
        {"action": "remove", "id": "CustomApp", "local_path": "C:\Program Files\CustomApp\uninstaller.exe", "arguments": "/S"}
    ]

.NOTES
    To install this script as a continuous background Windows Service, run this from an Administrator PowerShell:
    
    $NssmUrl = "https://nssm.cc/release/nssm-2.24.zip"
    # Or natively using SC.EXE:
    sc.exe create "ZededaUpdateAgent" binpath= "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"C:\Path\To\ZededaAgent.ps1`"" start= auto
    sc.exe start "ZededaUpdateAgent"
#>
# Optimizations for headless web requests
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::DefaultConnectionLimit = 64

# Proxy configuration (set to $null to disable)
$PROXY_URL = "http://usb-ds.local:8080"

$METADATA_IP = "169.254.169.254"
$PATCH_DESC_URL = "http://${METADATA_IP}/eve/v1/patch/description.json"
$CUSTOM_STATUS_URL = "http://${METADATA_IP}/eve/v1/app/appCustomStatus"

$WORKING_DIR = "C:\ProgramData\ZededaAgent"
$DOWNLOAD_DIR = "$WORKING_DIR\Downloads"
$STATE_FILE = "$WORKING_DIR\applied_patches.json"
$LOG_FILE = "$WORKING_DIR\agent.log"
$POLL_INTERVAL_SECONDS = 15 # Service polling interval

# Ensure directories exist
if (-not (Test-Path $DOWNLOAD_DIR)) {
    New-Item -ItemType Directory -Force -Path $DOWNLOAD_DIR | Out-Null
}

function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [ValidateSet("INFO", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Output $logEntry
    
    # Ensure log file can be written to
    try {
        Add-Content -Path $LOG_FILE -Value $logEntry -ErrorAction Stop
    } catch {
        # Fallback if logging fails
        Write-Output "[$timestamp] [ERROR] Failed to write to log file - $_"
    }
}

# Load previously applied patch IDs (PatchID -> Metadata) so we don't process them twice
$appliedPatches = @{}
if (Test-Path $STATE_FILE) {
    try {
        $saved = Get-Content $STATE_FILE -Raw | ConvertFrom-Json
        if ($null -ne $saved) {
            $saved.psobject.properties | ForEach-Object { $appliedPatches[$_.Name] = $_.Value }
        }
    } catch {
        Write-Log -Message "Failed to load state file. Starting fresh." -Level WARNING
    }
}

# The overall state object to post back to appCustomStatus
$agentStatus = @{
    agent_status = "online"
    last_update = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    package_results = @{}
}

function Publish-CustomStatus {
    param ( [hashtable]$StatusPayload )
    try {
        $jsonBody = @{
            # Embedding our detailed agent status inside it
            windows_agent_state = $StatusPayload
        } | ConvertTo-Json -Depth 5 -Compress

        Write-Log -Message "Publishing status to $CUSTOM_STATUS_URL..."
        Write-Log -Message "Payload: $jsonBody"

        Invoke-RestMethod -Uri $CUSTOM_STATUS_URL -Method Post -ContentType "application/json" -Body $jsonBody | Out-Null
        Write-Log -Message "Status published successfully."
    } catch {
        Write-Log -Message "Failed to publish status: $_" -Level WARNING
    }
}

function Invoke-FileDownload {
    param(
        [string]$Url,
        [string]$DestPath,
        [string]$LogLabel,
        [string]$ProxyUrl = $null,
        [int]$TimeoutMs = 30000
    )    
    # Use native curl.exe if available for robust proxy payload streaming
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        Write-Log -Message "Using native Windows curl.exe to download $LogLabel..."
        $curlArgs = @("-L", "--progress-bar", "-o", $DestPath, "--max-time", ($TimeoutMs / 1000))
        if ($ProxyUrl) {
            $curlArgs += "-x"
            $curlArgs += $ProxyUrl
        }
        $curlArgs += $Url
        
        $process = Start-Process -FilePath "curl.exe" -ArgumentList $curlArgs -Wait -NoNewWindow -PassThru
        if ($process.ExitCode -eq 0 -and (Test-Path $DestPath)) {
            Write-Log -Message "Download progress for ${LogLabel}: Finished successfully via curl."
            return
        } else {
            Write-Log -Message "curl.exe failed with exit code $($process.ExitCode). Falling back to .NET WebRequest..."
        }
    }
    $fileStream = $null
    $stream = $null
    $response = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Timeout = $TimeoutMs
        if ($ProxyUrl) { 
            Write-Log -Message "Configuring WebRequest to use proxy: $ProxyUrl"
            $proxy = New-Object System.Net.WebProxy($ProxyUrl)
            
            # Use default system credentials for the proxy if it's required natively
            $proxy.UseDefaultCredentials = $true
            
            $request.Proxy = $proxy 
        }
        $response = $request.GetResponse()
        $totalSize = $response.ContentLength
        $stream = $response.GetResponseStream()
        $buffer = New-Object byte[] 8192
        $fileStream = [System.IO.File]::Create($DestPath)

        $downloaded = 0
        $lastLogPercent = 0
        $lastLogBytes = 0

        do {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -gt 0) {
                $fileStream.Write($buffer, 0, $read)
                $downloaded += $read

                if ($totalSize -gt 0) {
                    $percent = [math]::Floor(($downloaded / $totalSize) * 100)
                    if ($percent -ge ($lastLogPercent + 10) -or $downloaded -eq $totalSize) {
                        Write-Log -Message "Download progress for ${LogLabel}: $percent% ($downloaded of $totalSize bytes)"
                        $lastLogPercent = $percent
                    }
                } else {
                    if (($downloaded - $lastLogBytes) -ge 5242880) {
                        $mb = [math]::Round($downloaded / 1MB, 2)
                        Write-Log -Message "Download progress for ${LogLabel}: $mb MB downloaded..."
                        $lastLogBytes = $downloaded
                    }
                }
            }
        } while ($read -gt 0)

        if ($totalSize -le 0) {
            $mb = [math]::Round($downloaded / 1MB, 2)
            Write-Log -Message "Download progress for ${LogLabel}: Finished ($mb MB total)"
        }

        $fileStream.Close()
        $stream.Close()
        $response.Close()
    } catch {
        if ($null -ne $fileStream) { $fileStream.Close() }
        if ($null -ne $stream) { $stream.Close() }
        if ($null -ne $response) { $response.Close() }
        throw
    }
}

function Process-Manifest {
    param( [string]$ManifestPath )

    $manifest = Get-Content $ManifestPath | ConvertFrom-Json
    $allSuccessful = $true
    
    foreach ($item in $manifest) {
        $action = $item.action # 'install', 'remove', 'update'
        $pkgId = $item.id      # Identifier/Log name
        $installerUrl = $item.installer_url # URL to download the MSI/EXE file
        $installer = $item.installer # MSI/EXE file downloaded from URL
        $localPath = $item.local_path # Local path to an existing executable/uninstaller
        $arguments = $item.arguments # Unattended installation arguments

        Write-Log -Message "Processing Action: $action on Package: $pkgId"

        $actionName = (Get-Culture).TextInfo.ToTitleCase($action.ToLower())

        try {
            $exitCode = -1
            $installerPath = ""

            if (-not [string]::IsNullOrEmpty($localPath)) {
                # If a local path is provided (e.g., for uninstalling), use that directly
                $installerPath = $localPath
                Write-Log -Message "Using provided local path: $installerPath"
            } elseif (-not [string]::IsNullOrEmpty($installerUrl)) {
                # Determine local path for download
                $fileName = if (-not [string]::IsNullOrEmpty($installer)) { $installer } else { Split-Path -Leaf $installerUrl }
                $installerPath = Join-Path $DOWNLOAD_DIR $fileName
                
                # Download from URL with error handling, proxy first then direct fallback
                Write-Log -Message "Downloading custom installer from $installerUrl to $installerPath..."
                try {
                    $downloadedViaProxy = $false
                    if ($PROXY_URL) {
                        try {
                            Invoke-FileDownload -Url $installerUrl -DestPath $installerPath -LogLabel $pkgId -ProxyUrl $PROXY_URL -TimeoutMs 60000
                            $downloadedViaProxy = $true
                        } catch {
                            Write-Log -Message "Proxy download failed, retrying direct. Exception: $_" -Level WARNING
                        }
                    }
                    if (-not $downloadedViaProxy) {
                        Write-Log -Message "Attempting direct download without proxy..."
                        Invoke-FileDownload -Url $installerUrl -DestPath $installerPath -LogLabel $pkgId -TimeoutMs 60000
                    }

                    # Publish status right after download completes
                    $agentStatus.package_results[$pkgId] = "Download Completed. Installing..."
                    Publish-CustomStatus -StatusPayload $agentStatus
                } catch {
                    Write-Log -Message "Failed to download installer from '$installerUrl'. Exception: $_" -Level ERROR
                    $agentStatus.package_results[$pkgId] = "1-Download failed"
                    $allSuccessful = $false
                    Publish-CustomStatus -StatusPayload $agentStatus
                    continue
                }
            } else {
                Write-Log -Message "Neither installer_url nor local_path is provided for $pkgId. Skipping." -Level WARNING
                $agentStatus.package_results[$pkgId] = "3-Installation Failed"
                $allSuccessful = $false
                continue
            }

            # Custom installer execution
            $resolvedPath = ""
            if (Test-Path $installerPath) {
                $resolvedPath = $installerPath
            } else {
                # If it's something like "powershell.exe" or "cmd.exe" registered in PATH, try resolving it
                $cmd = Get-Command $installerPath -ErrorAction SilentlyContinue
                if ($null -ne $cmd -and ($cmd.CommandType -eq 'Application' -or $cmd.CommandType -eq 'Cmdlet')) {
                    $resolvedPath = $installerPath
                } else {
                    Write-Log -Message "Installer/Uninstaller file not found at $installerPath!" -Level WARNING
                    $agentStatus.package_results[$pkgId] = "3-Installation Failed"
                    $allSuccessful = $false
                    continue
                }
            }

            # Wait to ensure file handles are closed from the download process before execution
            Start-Sleep -Seconds 2

            $args = if (-not [string]::IsNullOrEmpty($arguments)) { $arguments } else { "" }
            Write-Log -Message "Executing: $resolvedPath $args"
            
            $process = Start-Process -FilePath $resolvedPath -ArgumentList $args -Wait -NoNewWindow -PassThru
            $exitCode = $process.ExitCode
            
            # Check exit code (commonly 0 or 3010 for success/reboot required in MSIs)
            if ($exitCode -eq 0 -or $exitCode -eq 3010) {
                Write-Log -Message "Successfully processed $action for $pkgId"
                $agentStatus.package_results[$pkgId] = "2-Installation Completed"
                
                # Cleanup the downloaded custom installer to save space
                if (-not [string]::IsNullOrEmpty($installerUrl) -and (Test-Path $installerPath)) {
                    Write-Log -Message "Cleaning up installer file $installerPath..."
                    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
                }
            } else {
                Write-Log -Message "Failed to $action $pkgId. Exit Code: $exitCode" -Level WARNING
                $agentStatus.package_results[$pkgId] = "3-Installation Failed"
                $allSuccessful = $false
            }
        } catch {
            Write-Log -Message "Exception occurred while processing $pkgId : $_" -Level ERROR
            $agentStatus.package_results[$pkgId] = "3-Installation Failed"
            $allSuccessful = $false
        }
    }
    return $allSuccessful
}

Write-Log -Message "Starting ZEDEDA Agent Service..."

while ($true) {
    try {
        Write-Log -Message "Fetching latest Patch Envelopes..."
        $response = Invoke-RestMethod -Uri $PATCH_DESC_URL -Method Get -ErrorAction Stop

        $statusChanged = $false
        $envCount = @($response).Count
        Write-Log -Message "Fetched $envCount envelopes."

        foreach ($envelope in $response) {
            $patchId = $envelope.PatchID
            
            $currentMetadata = ""
            if ($null -ne $envelope.BinaryBlobs) {
                # Combine all metadata fields to detect any true changes in the envelope structure
                $currentMetadata = ($envelope.BinaryBlobs | ForEach-Object { 
                    "$($_.artifactMetaData)-$($_.fileMetaData)-$($_.fileSha)"
                }) -join "|"
            }

            Write-Log -Message "Reviewing Envelope ID: $patchId"

            if ($appliedPatches.ContainsKey($patchId) -and $appliedPatches[$patchId] -eq $currentMetadata) {
                Write-Log -Message "Envelope $patchId matches applied state. Skipping."
                continue
            }

            Write-Log -Message "New or updated Patch Envelope detected: $patchId"
            $statusChanged = $true
            $envelopeSuccess = $true

            $manifestFound = $null

            foreach ($blob in $envelope.BinaryBlobs) {
                $fileName = $blob.fileName
                $downloadUrl = $blob.url
                
                # Try to decode the URL in case it contains URL-encoded characters (like %20, %3A, etc)
                $decodedUrl = [System.Uri]::UnescapeDataString($downloadUrl)
                $outPath = Join-Path $DOWNLOAD_DIR $fileName

                Write-Log -Message "Downloading $fileName to $outPath... (Decoded URL: $decodedUrl)"
                try {
                    # Use HttpWebRequest to get download progress and support chunked downloads
                    $request = [System.Net.HttpWebRequest]::Create($decodedUrl)
                    $request.Timeout = 60000 # 60 seconds timeout
                    $downloadResponse = $request.GetResponse()
                    $totalSize = $downloadResponse.ContentLength
                    $stream = $downloadResponse.GetResponseStream()
                    $buffer = New-Object byte[] 8192
                    $fileStream = [System.IO.File]::Create($outPath)
                    
                    $downloaded = 0
                    $lastLogPercent = 0
                    $lastLogBytes = 0
                    
                    do {
                        $read = $stream.Read($buffer, 0, $buffer.Length)
                        if ($read -gt 0) {
                            $fileStream.Write($buffer, 0, $read)
                            $downloaded += $read
                            
                            if ($totalSize -gt 0) {
                                $percent = [math]::Floor(($downloaded / $totalSize) * 100)
                                if ($percent -ge ($lastLogPercent + 10) -or $downloaded -eq $totalSize) {
                                    Write-Log -Message "Download progress for ${fileName}: $percent% ($downloaded of $totalSize bytes)"
                                    $lastLogPercent = $percent
                                }
                            } else {
                                if (($downloaded - $lastLogBytes) -ge 5242880) {
                                    $mb = [math]::Round($downloaded / 1MB, 2)
                                    Write-Log -Message "Download progress for ${fileName}: $mb MB downloaded..."
                                    $lastLogBytes = $downloaded
                                }
                            }
                        }
                    } while ($read -gt 0)
                    
                    if ($totalSize -le 0) {
                        $mb = [math]::Round($downloaded / 1MB, 2)
                        Write-Log -Message "Download progress for ${fileName}: Finished ($mb MB total)"
                    }
                    
                    $fileStream.Close()
                    $stream.Close()
                    $downloadResponse.Close()
                } catch {
                    if ($null -ne $fileStream) { $fileStream.Close() }
                    if ($null -ne $stream) { $stream.Close() }
                    if ($null -ne $downloadResponse) { $downloadResponse.Close() }
                    
                    Write-Log -Message "Failed to download blob '$fileName' from '$downloadUrl'. Exception: $_" -Level ERROR
                    $envelopeSuccess = $false
                    continue
                }

                if ($fileName -match "manifest.json" -or $fileName -match "packages.json") {
                    $manifestFound = $outPath
                } else {
                    # Attempt to decode the file assuming it might be a Base64 encoded JSON manifest
                    try {
                        $rawContent = Get-Content -Path $outPath -Raw -ErrorAction Stop
                        # Unwrap JSON string encoding if present (e.g. "\"base64...\"")
                        $base64String = try { $rawContent | ConvertFrom-Json -ErrorAction Stop } catch { $rawContent }
                        $decodedBytes = [System.Convert]::FromBase64String($base64String.Trim())
                        $decodedString = [System.Text.Encoding]::UTF8.GetString($decodedBytes)
                        
                        # Validate if it's actual JSON
                        $jsonTest = $decodedString | ConvertFrom-Json -ErrorAction Stop
                        
                        # If parsing succeeded, treat this as the manifest
                        $manifestPath = Join-Path $DOWNLOAD_DIR "$fileName-decoded.json"
                        Set-Content -Path $manifestPath -Value $decodedString -Encoding UTF8
                        $manifestFound = $manifestPath
                        Write-Log -Message "Successfully decoded Base64 JSON manifest from blob '$fileName'"
                    } catch {
                        # Fail silently, it's either not base64 or not JSON, just a normal file
                    }
                }
            }

            # Process the manifest only after ALL files in the envelope are successfully downloaded
            if ($null -ne $manifestFound) {
                Write-Log -Message "Manifest file found. Processing..."
                $manifestSuccess = Process-Manifest -ManifestPath $manifestFound
                if (-not $manifestSuccess) {
                    $envelopeSuccess = $false
                }
            }

            # Handle direct scripts if any
            foreach ($blob in $envelope.BinaryBlobs) {
                $fileName = $blob.fileName
                if ($fileName -match "\.ps1$") {
                    $outPath = Join-Path $DOWNLOAD_DIR $fileName
                    Write-Log -Message "Executing script $fileName..."
                    try {
                        & $outPath
                    } catch {
                        Write-Log -Message "Script execution failed for $fileName. Exception: $_" -Level ERROR
                        $envelopeSuccess = $false
                    }
                }
            }

            # Mark as applied so we don't process it in the next loop, ONLY if entirely successful
            if ($envelopeSuccess) {
                Write-Log -Message "Envelope $patchId processed successfully. Storing state."
                $appliedPatches[$patchId] = $currentMetadata
                $appliedPatches | ConvertTo-Json | Set-Content $STATE_FILE -Encoding UTF8
                
                # Clean up envelope blobs since they are completely finished
                foreach ($blob in $envelope.BinaryBlobs) {
                    $fileName = $blob.fileName
                    $outPath = Join-Path $DOWNLOAD_DIR $fileName
                    if (Test-Path $outPath) {
                        Remove-Item -Path $outPath -Force -ErrorAction SilentlyContinue
                    }
                }
                # Also clean up any decoded manifest
                if ($null -ne $manifestFound -and (Test-Path $manifestFound)) {
                    Remove-Item -Path $manifestFound -Force -ErrorAction SilentlyContinue
                }
            } else {
                Write-Log -Message "Envelope $patchId encountered errors. Fix them to retry, or change metadata." -Level WARNING
            }
        }

        # Finally, publish the status if new envelopes were processed
        if ($statusChanged -or $agentStatus.package_results.Count -gt 0) {
            $agentStatus.last_update = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            Publish-CustomStatus -StatusPayload $agentStatus
        }

    } catch {
        Write-Log -Message "Could not poll patch envelopes or reach metadata server: $_" -Level ERROR
    }

    Start-Sleep -Seconds $POLL_INTERVAL_SECONDS
}
