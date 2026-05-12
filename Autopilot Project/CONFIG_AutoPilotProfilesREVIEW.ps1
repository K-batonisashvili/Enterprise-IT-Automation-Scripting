# ======================================================================
# AUTOPILOT PROFILE GROUP MEMBERSHIP COUNTER
# ======================================================================

# This script pulls target Autopilot profiles, identifies assigned Entra groups,
# counts the members in each group, and exports the data to a CSV report. This is just for auditing.

$csvExportPath = "Output/REPORT_AutopilotGroupMemberCounts.csv"
$Config = Get-Content -Path "$PSScriptRoot\config.json" | ConvertFrom-Json
$TargetProfiles = $Config.AutoPilotNames

# custom exit code variable
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

Write-Log "Starting Autopilot Group Member Audit..." -Level "INFO"

# Microsoft Graph
try {
    Write-Log "Connecting to Microsoft Graph (Read-Only)..."
    Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All", "GroupMember.Read.All", "Group.Read.All" -ErrorAction Stop
} catch {
    Write-Log "Failed to connect to Microsoft Graph. Exception: $_" -Level "ERROR"
    exit 1
}

# Pull target Autopilot Profiles
Write-Log "Pulling Autopilot profiles..."
$profiles = @(Get-MgBetaDeviceManagementWindowsAutopilotDeploymentProfile -Filter "startswith(displayName, '$TargetProfiles')" -All)

if ($profiles.Count -eq 0) {
    Write-Log "No profiles found matching the prefix. Exiting." -Level "ERROR"
    exit 1
}

Write-Log "Found $($profiles.Count) profiles. Scanning assignments and counting members..." -Level "SUCCESS"

# Initialize CSV report array
$report = [System.Collections.Generic.List[PSCustomObject]]::new()

# Iterate Profiles
foreach ($profile in $profiles) {
    $profileName = $profile.DisplayName
    $profileId = $profile.Id

    Write-Log "Analyzing: '$profileName'..." -Level "INFO"

    # Pull assignments
    $assignments = @(Get-MgBetaDeviceManagementWindowsAutopilotDeploymentProfileAssignment -WindowsAutopilotDeploymentProfileId $profileId)

    if ($assignments.Count -eq 0) {
        Write-Log "No assignments attached." -Level "SKIP"
        $report.Add([PSCustomObject]@{
            ProfileName = $profileName
            GroupName   = "No Assignment"
            GroupId     = "N/A"
            MemberCount = 0
        })
    } else {
        foreach ($assignment in $assignments) {
            $target = $assignment.Target
            
            # Extract GroupId
            $groupId = $target.GroupId
            if (-not $groupId -and $null -ne $target.AdditionalProperties) {
                $groupId = $target.AdditionalProperties["groupId"]
            }

            if ($groupId) {
                $groupName = "N/A"
                $memberCount = 0

                try {
                    # Get Group Name
                    $group = Get-MgGroup -GroupId $groupId -Property "DisplayName" -ErrorAction Stop
                    $groupName = $group.DisplayName

                    # Get Member Count
                    $members = @(Get-MgGroupMember -GroupId $groupId -All -ErrorAction Stop)
                    $memberCount = $members.Count
                    
                    Write-Log "Group: $groupName | Members: $memberCount" -Level "SUCCESS"
                } catch {
                    $groupName = "GROUP DELETED OR UNKNOWN"
                    Write-Log "Error reading group or members for ID: $groupId" -Level "ERROR"
                }

                $report.Add([PSCustomObject]@{
                    ProfileName = $profileName
                    GroupName   = $groupName
                    GroupId     = $groupId
                    MemberCount = $memberCount
                })
            } else {
                Write-Log "Assignment is not an Entra Group (Skipping member count)." -Level "WARN"
                $report.Add([PSCustomObject]@{
                    ProfileName = $profileName
                    GroupName   = "Not a Group Assignment"
                    GroupId     = "N/A"
                    MemberCount = 0
                })
            }
        }
    }
}

# Export to CSV
$outDir = Split-Path $csvExportPath
if (-not (Test-Path $outDir) -and $outDir -ne "") { 
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null 
}

try {
    $report | Export-Csv -Path $csvExportPath -NoTypeInformation
    Write-Log "Audit Complete! Exported to: $csvExportPath" -Level "SUCCESS"
} catch {
    Write-Log "Failed to export CSV: $_" -Level "ERROR"
    $ScriptExitCode = 1
}

exit $ScriptExitCode