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
$Secrets = Get-Content -Path "$PSScriptRoot\secrets.json" | ConvertFrom-Json
$TempDir = $Config.Directories.TempDir
$LogDir = $Config.Directories.LogDir
$SuccessDir = $Config.Directories.SuccessDir
$LogFile = "$LogDir\Local_Admin_Log.txt"
$SuccessFile = "$SuccessDir\Local_Admin_Success.txt"
$GoogleWebhookUrl = $Secrets.GoogleWebhookUrl

$Group = "Administrators"

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
        [string]$Title = "Temporary Admin Privileges",
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
Write-Log "STARTING JIT LOCAL ADMIN SCRIPT EXECUTION"
Write-Log "========================================"

try {
    # Pre-fetch the user details
    $ActiveUser = Get-ConsoleUser
    $AdminUser = $ActiveUser.FullName
    $UsernameOnly = $ActiveUser.BaseName
    $RevokeTaskName = "RevokeLocalAdmin_$UsernameOnly"

    if ($Uninstall) {
        # ----- UNINSTALL LOGIC -----
        Write-Log "Action: Uninstall switch detected. Commencing removal logic."
        
        $UserAlreadyInGroup = Test-GroupMembership -TargetGroup $Group -TargetUser $UsernameOnly

        if ($UserAlreadyInGroup) {
            Write-Log "Target user is currently in the local admin group. Executing removal..."
            Remove-LocalGroupMember -Group $Group -Member $AdminUser -ErrorAction Stop
            Write-Log "User successfully removed from the local admin group."
        } else {
            Write-Log "Target user is NOT in the local admin group. No removal action required."
        }

        # Clean up the scheduled task if it's still pending
        if (Get-ScheduledTask -TaskName $RevokeTaskName -ErrorAction SilentlyContinue) {
            Write-Log "Pending 2-hour revocation task found. Unregistering task..."
            Unregister-ScheduledTask -TaskName $RevokeTaskName -Confirm:$false -ErrorAction SilentlyContinue
        }

        if (Test-Path $SuccessFile) { 
            Write-Log "Success file found. Removing it to reset Intune detection."
            Remove-Item $SuccessFile -Force 
        }
        
        Show-Popup -Message "Your Local Administrator rights have been successfully revoked." -TargetUser $AdminUser
        Write-Log "Uninstall logic completed successfully."
        
    } else {
        # ----- INSTALL LOGIC -----
        Write-Log "Action: Install logic starting."
        
        $UserAlreadyInGroup = Test-GroupMembership -TargetGroup $Group -TargetUser $UsernameOnly

        if (-not $UserAlreadyInGroup) {
            Write-Log "Target user is not in the group. Executing Add-LocalGroupMember..."
            Add-LocalGroupMember -Group $Group -Member $AdminUser -ErrorAction Stop
            Write-Log "User successfully added to the local admin group."
            
            # --- 2-HOUR REVOCATION TIMER LOGIC ---
            Write-Log "Creating 2-hour revocation timer..."
            $RevokeTime = (Get-Date).AddHours(2)
            
            $TaskScript = "Remove-LocalGroupMember -Group '$Group' -Member '$AdminUser' -ErrorAction SilentlyContinue; 'Admin rights revoked for $AdminUser' | Out-File -FilePath '$LogFile' -Append; Unregister-ScheduledTask -TaskName '$RevokeTaskName' -Confirm:`$false"
            $EncodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($TaskScript))
            
            $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -EncodedCommand $EncodedCommand"
            $Trigger = New-ScheduledTaskTrigger -Once -At $RevokeTime
            $Principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
            $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable
            $Task = New-ScheduledTask -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings
            
            Register-ScheduledTask -TaskName $RevokeTaskName -InputObject $Task -Force | Out-Null
            Write-Log "Scheduled task '$RevokeTaskName' created. Admin rights will be revoked at $RevokeTime."
            
        } else {
            Write-Log "Target user is already in the admin group. Skipping timer creation."
        }
        
        Write-Log "Creating Intune Success File..."
        "SUCCESS" | Out-File -FilePath $SuccessFile -Force
        
        Show-Popup -Message "You have been temporarily granted Local Administrator rights for 2 hours." -TargetUser $AdminUser
        Write-Log "Install logic completed successfully."
    }

} catch {
    Write-Log "FAILED: FATAL EXCEPTION CAUGHT: $_"
    $ScriptExitCode = 1 
    
    if ($AdminUser) {
        Show-Popup -Message "An error occurred while modifying your access. Error code: $_. Please contact Endpoint Support." -TargetUser $AdminUser -Title "IT Access Error"
    }
}

Write-Log "========================================"
Write-Log "ENDING JIT LOCAL ADMIN SCRIPT EXECUTION"
Write-Log "========================================"
Write-Log "Uploading log to Google Drive..."

# ----- WEBHOOK UPLOAD LOGIC -----
$DatePart = Get-Date -Format "yyyyMMdd_HHmmss"
$UploadName = "LocalAdmin2HR_Log_{0}_{1}.txt" -f $env:COMPUTERNAME, $DatePart
$TargetUrl = "$GoogleWebhookUrl`?filename=$UploadName"

$LogContent = Get-Content -Path $LogFile -Raw

try {
    Invoke-RestMethod -Uri $TargetUrl -Method Post -Body $LogContent | Out-Null
    Write-Log "Upload successful."
} catch {
    Write-Log "Failed to upload to Google Drive: $_"
}

exit $ScriptExitCode