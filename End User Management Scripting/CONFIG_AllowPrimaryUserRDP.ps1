param (
    [switch]$Uninstall
)

# --- 32-bit to 64-bit Escape Hatch ---
if ($env:PROCESSOR_ARCHITECTURE -eq 'x86' -and (Test-Path "$env:windir\sysnative\WindowsPowerShell\v1.0\powershell.exe")) {
    $64bitPS = "$env:windir\sysnative\WindowsPowerShell\v1.0\powershell.exe"
    
    if ($Uninstall) {
        & $64bitPS -ExecutionPolicy Bypass -WindowStyle Hidden -File $PSCommandPath -Uninstall
    } else {
        & $64bitPS -ExecutionPolicy Bypass -WindowStyle Hidden -File $PSCommandPath
    }
    
    exit $LASTEXITCODE
}

# Base exit code variable
$ScriptExitCode = 0

# Pull all info from main config files
$Config = Get-Content -Path "$PSScriptRoot\config.json" | ConvertFrom-Json
$TempDir = $Config.Directories.TempDir
$LogDir = $Config.Directories.LogDir
$SuccessDir = $Config.Directories.SuccessDir
$LogFile = "$LogDir\RDP_Log.txt"
$SuccessFile = "$SuccessDir\RDP_Success.txt"
$GoogleWebhookUrl = $Config.APIs.GoogleWebhookUrl

$Group = "Remote Desktop Users"

# --- Manually Created Logging Function ---
Function Write-Log {
    param([string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$Timestamp - $Message" | Out-File -FilePath $LogFile -Append -Force
}
# --------------------------------------

# --- Console User Detection Function ---
Function Get-ConsoleUser {
    $ConsoleUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
    
    if ([string]::IsNullOrWhiteSpace($ConsoleUser)) {
        Write-Log "CRITICAL: No active user session detected. The script must be run while a user is logged in."
        exit 1
    }
    
    Write-Log "File explorer user detected: $ConsoleUser"
    
    if ($ConsoleUser -match "\\") {
        $RawName = ($ConsoleUser -split "\\")[1]
    } else {
        $RawName = $ConsoleUser
    }
    $UsernameOnly = $RawName.Split("@")[0]

    return [PSCustomObject]@{
        FullName = $ConsoleUser
        BaseName = $UsernameOnly
    }
}
# --------------------------------------

# --- Group Membership Check Function ---
Function Test-GroupMembership {
    param(
        [string]$TargetGroup,
        [string]$TargetUser
    )
    
    Write-Log "Querying current membership of $TargetGroup..."
    $CurrentMembers = Get-LocalGroupMember -Group $TargetGroup -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
    
    if ($CurrentMembers) {
        Write-Log "Current members: $($CurrentMembers -join ', ')"
    } else {
        Write-Log "Group is currently empty."
    }

    $IsMember = $CurrentMembers | Where-Object { $_ -match [regex]::Escape($TargetUser) }
    
    if ($IsMember) { return $true } else { return $false }
}
# --------------------------------------

# --- On-Screen Pop-Up Function ---
Function Show-Popup {
    param(
        [string]$Message,
        [string]$Title = $Group,
        [string]$TargetUser
    )
    
    Write-Log "Triggering on-screen pop-up for $TargetUser..."
    
    $PopupCode = @"
    `$wshell = New-Object -ComObject Wscript.Shell
    `$wshell.Popup('$Message', 0, '$Title', 64)
"@
    $EncodedPopup = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($PopupCode))
    
    $TaskName = "IT_Notification_$([guid]::NewGuid().Guid.Substring(0,8))"
    
    $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -EncodedCommand $EncodedPopup"
    $Principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive
    $Task = New-ScheduledTask -Action $Action -Principal $Principal
    
    Register-ScheduledTask -TaskName $TaskName -InputObject $Task -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 2
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false | Out-Null

    Write-Log "Pop-up triggered and task cleaned up."
}
# --------------------------------------

# verify directories exists
if (-not (Test-Path -Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }
if (-not (Test-Path -Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
if (-not (Test-Path -Path $SuccessDir)) { New-Item -ItemType Directory -Path $SuccessDir -Force | Out-Null }

Write-Log "========================================"
Write-Log "STARTING RDP USER SCRIPT EXECUTION"
Write-Log "========================================"

try {
    # Pre-fetch the user details since both Install and Uninstall will need it
    $ActiveUser = Get-ConsoleUser
    $RdpUser = $ActiveUser.FullName
    $UsernameOnly = $ActiveUser.BaseName

    if ($Uninstall) {
        # ----- UNINSTALL LOGIC -----
        Write-Log "Action: Uninstall switch detected."
        Write-Log "Base username to verify against: $UsernameOnly"
        
        $UserAlreadyInGroup = Test-GroupMembership -TargetGroup $Group -TargetUser $UsernameOnly

        if ($UserAlreadyInGroup) {
            Write-Log "User is in the group. Executing Remove-LocalGroupMember..."
            Remove-LocalGroupMember -Group $Group -Member $RdpUser -ErrorAction Stop
            Write-Log "User successfully removed from the group."
        } else {
            Write-Log "Desired state already met. $UsernameOnly is not in the group."
        }

        if (Test-Path $SuccessFile) { 
            Write-Log "Success file found. Removing it to reset Intune detection."
            Remove-Item $SuccessFile -Force 
        } else {
            Write-Log "No success file found to remove."
        }
        
        Show-Popup -Message "You have been successfully removed from the Remote Desktop Users group." -TargetUser $RdpUser
        Write-Log "Uninstall complete. Exiting with code 0."
        
    } else {
        # ----- INSTALL LOGIC -----
        Write-Log "Action: Install logic starting."
        
        Write-Log "Formatted RDP identity to add: $RdpUser"
        Write-Log "Base username to verify against: $UsernameOnly"
        
        $UserAlreadyInGroup = Test-GroupMembership -TargetGroup $Group -TargetUser $UsernameOnly

        if (-not $UserAlreadyInGroup) {
            Write-Log "User is not in the group. Executing Add-LocalGroupMember..."
            Add-LocalGroupMember -Group $Group -Member $RdpUser -ErrorAction Stop
            Write-Log "User successfully added to the group."
        } else {
            Write-Log "$UsernameOnly is already in the group."
        }
        
        Write-Log "Creating Intune Success File..."
        "SUCCESS" | Out-File -FilePath $SuccessFile -Force
        
        Show-Popup -Message "You have been successfully added to the Remote Desktop Users group." -TargetUser $RdpUser
        Write-Log "INSTALLATION COMPLETE."
    }

} catch {
    Write-Log "FAILED: FATAL EXCEPTION CAUGHT: $_"
    $ScriptExitCode = 1 # Mark the script as failed for Intune
    
    # try to show the error pop-up only if we found the user before the crash
    if ($RdpUser) {
        Show-Popup -Message "An error occurred while modifying your access. Error code: $_. Please contact Endpoint Support." -TargetUser $RdpUser -Title "IT Access Error"
    }
}

Write-Log "========================================"
Write-Log "ENDING RDP USER SCRIPT EXECUTION"
Write-Log "========================================"
Write-Log "Uploading log to Google Drive..."

# ----- WEBHOOK UPLOAD LOGIC -----

$DatePart = Get-Date -Format "yyyyMMdd_HHmmss"
$UploadName = "RDPAccess_Log_{0}_{1}.txt" -f $env:COMPUTERNAME, $DatePart
$TargetUrl = "$GoogleWebhookUrl`?filename=$UploadName"

$LogContent = Get-Content -Path $LogFile -Raw

try {
    Invoke-RestMethod -Uri $TargetUrl -Method Post -Body $LogContent | Out-Null
    Write-Log "Upload successful."
} catch {
    Write-Log "Failed to upload to Google Drive: $_"
}

# Exit with our personal manual exit code
exit $ScriptExitCode