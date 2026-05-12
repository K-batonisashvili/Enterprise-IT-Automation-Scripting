# --- AUDITING ---
$WhatIf = $true  # intune push flag

# custom personal exit code
$ScriptExitCode = 0

# Pull info from config files
$Config = Get-Content -Path "$PSScriptRoot\config.json" | ConvertFrom-Json
$DeptNames = $Config.EntraGroupNames.Depts
$AutoPilotPrefix = $Config.AutoPilotNames.Prefix
$NameTemplate = $Config.AutoPilotNames.DeviceNameTemplate

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
        Default   { Write-Host $FormattedMessage -ForegroundColor Cyan }
    }
}
# --------------------------------------

Write-Log "========================================"
Write-Log "STARTING AUTOPILOT MASS-CREATION SCRIPT"
Write-Log "========================================"

if ($WhatIf) { Write-Log "RUNNING IN WHAT-IF MODE: No changes will be made to the tenant." -Level "WARN" }

# Microsoft Graph
try {
    Write-Log "Authenticating to Microsoft Graph..."
    Connect-MgGraph -Scopes "DeviceManagementServiceConfig.ReadWrite.All" -ErrorAction Stop
} catch {
    Write-Log "Failed to connect to Microsoft Graph. Exception: $_" -Level "ERROR"
    exit 1
}

$uri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles"


foreach ($Dept in $DeptNames) {
    
    # Clean up 
    $ProfileName = "$AutoPilotPrefix $Dept"
    Write-Log "Preparing payload for profile: '$ProfileName'..."
    
    $profilePayload = @{
        "@odata.type"                = "#microsoft.graph.azureADWindowsAutopilotDeploymentProfile"
        displayName                  = $ProfileName
        deviceNameTemplate           = $NameTemplate
        description                  = "Autopilot profile created for all departmental devices (Laptops, Kiosks, Shared Devices, etc). Assigned to: $Dept."
        language                     = "os-default"
        extractHardwareHash          = $true # allow pre-provisioning
        preprovisioningAllowed       = $true
        outOfBoxExperienceSettings   = @{
            "@odata.type"             = "microsoft.graph.outOfBoxExperienceSettings"
            hidePrivacySettings       = $true
            hideEULA                  = $true
            userType                  = "standard" 
            deviceUsageType           = "singleUser"
            skipKeyboardSelectionPage = $true
            hideEscapeLink            = $true 
        }
    }

    $jsonBody = $profilePayload | ConvertTo-Json -Depth 5

    if ($WhatIf) {
        Write-Log "[WHAT-IF] Would POST to $uri for '$ProfileName'" -Level "WARN"
    } else {
        try {
            Write-Log "Sending POST request to Intune..."
            $response = Invoke-MgGraphRequest -Method POST -Uri $uri -Body $jsonBody -ContentType "application/json" -ErrorAction Stop
            Write-Log "Success! Profile '$ProfileName' created with ID: $($response.id)" -Level "SUCCESS"
        }
        catch {
            Write-Log "CRITICAL ERROR: Failed to create profile '$ProfileName'." -Level "ERROR"
            Write-Log $_.Exception.Message -Level "ERROR"
            $ScriptExitCode = 1
        }
    }
}

Write-Log "========================================"
Write-Log "ENDING AUTOPILOT MASS-CREATION SCRIPT"
Write-Log "========================================"

exit $ScriptExitCode