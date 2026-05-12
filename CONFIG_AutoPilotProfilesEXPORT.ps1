# ======================================================================
# AUTOPILOT PROFILE ASSIGNMENTS BACKUP
# ======================================================================

# This script pulls all Autopilot profiles and exports them to a CSV for backup

$csvExportPath = "Output/BACKUP_AutopilotAssignments.csv"

# Base exit code variable
$ScriptExitCode = 0

# --- Custom Administrative Logging ---
Function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $FormattedMessage = "$Timestamp - [$Level] - $Message"
    
    switch ($Level) {
        "ERROR"   { Write-Host $FormattedMessage -ForegroundColor Red }
        "SUCCESS" { Write-Host $FormattedMessage -ForegroundColor Green }
        "WARN"    { Write-Host $FormattedMessage -ForegroundColor Yellow }
        "SKIP"    { Write-Host $FormattedMessage -ForegroundColor DarkGray }
        Default   { Write-Host $FormattedMessage -ForegroundColor Cyan }
    }
}
# --------------------------------------

Write-Log "Starting Autopilot Assignment Backup..." -Level "INFO"

# Microsoft Graph
try {
    Write-Log "Connecting to Microsoft Graph (Read-Only)..."
    Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All", "Group.Read.All" -ErrorAction Stop
} catch {
    Write-Log "Failed to connect to Microsoft Graph. Exception: $_" -Level "ERROR"
    exit 1
}

# Pull Autopilot Profiles
Write-Log "Pulling all Autopilot profiles..."
$allProfiles = @(Get-MgBetaDeviceManagementWindowsAutopilotDeploymentProfile -All)

if ($allProfiles.Count -eq 0) {
    Write-Log "No profiles found in the tenant. Exiting." -Level "ERROR"
    exit 1
}

Write-Log "Found $($allProfiles.Count) profiles. Scanning for assignments..." -Level "SUCCESS"

# Initialize CSV report array
$backupReport = [System.Collections.Generic.List[PSCustomObject]]::new()

# loop Profiles
foreach ($profile in $allProfiles) {
    $profileName = $profile.DisplayName
    $profileId = $profile.Id

    Write-Log "Scanning: '$profileName'..." -Level "INFO"

    # assignments
    $assignments = @(Get-MgBetaDeviceManagementWindowsAutopilotDeploymentProfileAssignment -WindowsAutopilotDeploymentProfileId $profileId)

    if ($assignments.Count -eq 0) {
        $backupReport.Add([PSCustomObject]@{
            ProfileName    = $profileName
            ProfileId      = $profileId
            AssignmentType = "None"
            GroupName      = "N/A"
            GroupId        = "N/A"
        })
    } else {
        foreach ($assignment in $assignments) {
            $target = $assignment.Target
            
            # Extract OdataType
            $targetType = $target.OdataType
            if (-not $targetType -and $null -ne $target.AdditionalProperties) {
                $targetType = $target.AdditionalProperties["@odata.type"]
            }

            # Extract GroupId
            $groupId = $target.GroupId
            if (-not $groupId -and $null -ne $target.AdditionalProperties) {
                $groupId = $target.AdditionalProperties["groupId"]
            }

            $groupName = "N/A"
            $displayType = "Unknown"

            # Parse Assignment Type
            if ($groupId) {
                $displayType = "Group Assignment"
                try {
                    $group = Get-MgGroup -GroupId $groupId -Property "DisplayName" -ErrorAction Stop
                    $groupName = $group.DisplayName
                } catch {
                    $groupName = "GROUP DELETED OR UNKNOWN"
                }
            }
            elseif ($targetType -match "allDevices") {
                $displayType = "All Devices"
                $groupName = "All Devices"
                $groupId = "All Devices"
            }
            elseif ($targetType -match "allLicensedUsers") {
                $displayType = "All Users"
                $groupName = "All Users"
                $groupId = "All Users"
            }
            else {
                $displayType = $targetType 
            }

            # Add to report
            $backupReport.Add([PSCustomObject]@{
                ProfileName    = $profileName
                ProfileId      = $profileId
                AssignmentType = $displayType
                GroupName      = $groupName
                GroupId        = $groupId
            })
        }
    }
}

# Export to CSV
$outDir = Split-Path $csvExportPath
if (-not (Test-Path $outDir) -and $outDir -ne "") { 
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null 
}

try {
    $backupReport | Export-Csv -Path $csvExportPath -NoTypeInformation
    Write-Log "Backup Complete! Exported to: $csvExportPath" -Level "SUCCESS"
} catch {
    Write-Log "Failed to export CSV: $_" -Level "ERROR"
    $ScriptExitCode = 1
}

exit $ScriptExitCode