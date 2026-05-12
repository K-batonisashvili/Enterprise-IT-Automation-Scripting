# ======================================================================
# AUTOPILOT PROFILE ASSIGNMENT WIPE (CLEANUP)
# ======================================================================

# This script pulls all Autopilot profiles, filters them against predefined targets in config.json and
# removes all Entra group assignments attached to those profiles

# --- CONFIGURATION ---
$WhatIf = $true  # Set to $false to LIVE WIPE assignments

# Base exit code variable
$ScriptExitCode = 0

# Pull info from config files
$Config = Get-Content -Path "$PSScriptRoot\config.json" | ConvertFrom-Json
$AutoPilotNamesRemove = $Config.EntraGroupNames.AutoPilotNamesRemove

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

if ($WhatIf) {
    Write-Log "Starting Assignment Wipe Mode (WHAT-IF / DRY RUN)..." -Level "WARN"
} else {
    Write-Log "Starting Assignment Wipe Mode (LIVE EXECUTION)..." -Level "ERROR"
}

# Microsoft Graph
try {
    Write-Log "Connecting to Microsoft Graph..."
    Connect-MgGraph -Scopes "DeviceManagementServiceConfig.ReadWrite.All" -ErrorAction Stop
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

# dynamic regex pattern from config.json
$regexPattern = "^($($AutoPilotNamesRemove -join '|'))"
$targetProfiles = $allProfiles | Where-Object { $_.DisplayName -match $regexPattern }

if (-not $targetProfiles) {
    Write-Log "No profiles matched the target prefixes. Exiting." -Level "SKIP"
    exit 0
}

Write-Log "Found $($targetProfiles.Count) matching profiles. Checking assignments..." -Level "SUCCESS"

foreach ($profile in $targetProfiles) {
    $profileName = $profile.DisplayName
    $profileId = $profile.Id

    Write-Log "Checking: '$profileName'..." -Level "INFO"

    # Fetch assignments
    $assignments = @(Get-MgBetaDeviceManagementWindowsAutopilotDeploymentProfileAssignment -WindowsAutopilotDeploymentProfileId $profileId)

    if ($assignments.Count -eq 0) {
        Write-Log "No assignments found." -Level "SKIP"
    } else {
        Write-Log "Found $($assignments.Count) assignment(s). Attempting removal..." -Level "WARN"
        
        foreach ($assignment in $assignments) {
            $assignmentId = $assignment.Id
            
            if ($WhatIf) {
                Write-Log "Would delete assignment ID: $assignmentId" -Level "SKIP"
            } else {
                try {
                    Remove-MgBetaDeviceManagementWindowsAutopilotDeploymentProfileAssignment `
                        -WindowsAutopilotDeploymentProfileId $profileId `
                        -WindowsAutopilotDeploymentProfileAssignmentId $assignmentId `
                        -ErrorAction Stop

                    Write-Log "Assignment removed successfully." -Level "SUCCESS"
                } catch {
                    Write-Log "Failed to remove assignment: $($_.Exception.Message)" -Level "ERROR"
                    $ScriptExitCode = 1
                }
            }
        }
    }
    Write-Log "------------------------------------------------------" -Level "SKIP"
}

Write-Log "Cleanup Process Complete!" -Level "INFO"

exit $ScriptExitCode