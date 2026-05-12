# ======================================================================
# AUTOPILOT GROUP ASSIGNMENT AUTOMATION
# ======================================================================

# This script takes existing autopilot profiles, looks at entra, and tries to find a group with the same name
# If a group with the same name is found, it adds that group as an assignment to autopilot

# --- Auditing ---
$WhatIf = $true 
$Config = Get-Content -Path "$PSScriptRoot\config.json" | ConvertFrom-Json
$TargetProfiles = $Config.AutoPilotNames

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

if ($WhatIf) {
    Write-Log "Starting Assignment Automation (WHAT-IF / DRY RUN)..." -Level "WARN"
} else {
    Write-Log "Starting Assignment Automation (LIVE EXECUTION)..." -Level "ERROR"
}

# Microsoft Graph
try {
    Write-Log "Connecting to Microsoft Graph..."
    Connect-MgGraph -Scopes "DeviceManagementServiceConfig.ReadWrite.All", "Group.Read.All" -ErrorAction Stop
} catch {
    Write-Log "Failed to connect to Microsoft Graph. Exception: $_" -Level "ERROR"
    exit 1
}

# Pull the target Autopilot Profiles
Write-Log "Pulling Autopilot profiles from targeted configuration"
# Wrapping in @() to ensure .Count works
$profiles = @(Get-MgBetaDeviceManagementWindowsAutopilotDeploymentProfile -Filter "startswith(displayName, '$TargetProfiles')" -All)

if ($profiles.Count -eq 0) {
    Write-Log "No profiles found matching the criteria. Exiting." -Level "ERROR"
    exit 1
}

Write-Log "Found $($profiles.Count) Autopilot profiles. Beginning group matching..." -Level "SUCCESS"


foreach ($profile in $profiles) {
    $profileName = $profile.DisplayName
    $profileId = $profile.Id

    # Graph API OData filter requires single quotes to be escaped
    $safeName = $profileName -replace "'", "''"

    # Wrap in @() again
    $group = @(Get-MgGroup -Filter "displayName eq '$safeName'" -All -Property "Id,DisplayName")

    
    if ($group.Count -eq 0) {
        Write-Log "No Entra Group match found for '$profileName'" -Level "SKIP"
    }
    elseif ($group.Count -gt 1) {
        Write-Log "Multiple Entra Groups found matching '$profileName'. Skipping for safety." -Level "WARN"
    }
    else {
        $groupId = $group[0].Id
        Write-Log "MATCH: Profile '$profileName' <--> Group ID $groupId" -Level "INFO"

        # Build Payload
        $assignmentParams = @{
            Target = @{
                "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                groupId       = $groupId
            }
        }

        #Execute 
        if ($WhatIf) {
            Write-Log "Would assign group to this profile." -Level "WARN"
        } else {
            try {
                New-MgBetaDeviceManagementWindowsAutopilotDeploymentProfileAssignment `
                    -WindowsAutopilotDeploymentProfileId $profileId `
                    -BodyParameter $assignmentParams -ErrorAction Stop | Out-Null
                
                Write-Log "Assignment attached successfully." -Level "SUCCESS"
            } catch {
                Write-Log "Failed to assign: $($_.Exception.Message)" -Level "ERROR"
                $ScriptExitCode = 1
            }
        }
    }
    Write-Log "------------------------------------------------------" -Level "SKIP"
}

Write-Log "Process Complete!" -Level "INFO"

exit $ScriptExitCode