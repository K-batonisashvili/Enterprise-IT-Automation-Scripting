# Enterprise MDM Powershell Scripting

A collection of enterprise-grade PowerShell scripts designed to automate Microsoft Intune Autopilot profile management and handle secure, audited, local privilege escalation on Windows endpoints. 

These scripts are built with strict enterprise guardrails, including 32-bit to 64-bit escape hatches, detailed webhook logging, graphical user pop-ups, and dry-run auditing capabilities.

## Repository Structure

### Autopilot Overhaul Project
These scripts were deployed to entirely overhaul AutoPilot profiles and standardize all to a single naming scheme across organization departments via the Microsoft Graph REST API. 

* **`CONFIG_AutoPilotProfiles.ps1`**
  * **Create Tool:** First script created. Mass-creates standardized, User-Driven Autopilot profiles based on department arrays defined in your `config.json`. Enforces standardized OOBE settings across majority of organizatin departments.
* **`CONFIG_AutoPilotProfilesEDIT.ps1`**
  * **Edit Tool:** Automates group assignment. Scans existing Autopilot profiles, matches them to Entra ID groups with identical names, and binds the group to the profile.
* **`CONFIG_AutoPilotProfilesEXPORT.ps1`**
  * **Backup Tool:** This is a backup script. Extracts all Autopilot profiles and their current group assignments, exporting them to a consolidated CSV report. 
* **`CONFIG_AutoPilotProfilesREMOVE.ps1`**
  * **Cleanup Tool:** Strips Entra group assignments from predefined Autopilot profiles to cleanly unassign configurations without deleting the core profile. This is meant as a way to un-assign AutoPilot profiles from all devices.
* **`CONFIG_AutoPilotProfilesREVIEW.ps1`**
  * **Audit Tool:** Auditing and reviewing tool.Evaluates target Autopilot profiles, identifies assigned Entra groups, counts the exact number of active members in those groups, and exports the data to a CSV.

> **⚠️ Safety Note:** All Autopilot modification scripts (`Create`, `Edit`, `Remove`) feature a built-in `$WhatIf = $true` variable at the top of the script. By default, they will only log what *would* happen without making live changes to your Intune tenant. Changing this to `$false` executes in production.

### Endpoint Access Suite
These scripts are designed to be deployed directly to endpoints (e.g., via Intune Win32 Apps or Remediations) to handle local machine group membership dynamically.

* **`CONFIG_LoggedInUserAdmin.ps1`**
  * **Permanent Local Admin:** Grants the logged-in user permanent Local Administrator rights, featuring a user-facing pop-up and Google webhook logging.
* **`CONFIG_LoggedInUserAdmin2HR.ps1`**
  * **Just-In-Time Local Admin:** Grants the currently logged-in user Local Administrator rights by creating a secure scheduled task to revoke the rights after exactly 2 hours. Logs the steps to a central Google webhook.
* **`CONFIG_AllowPrimaryUserRDP.ps1`**
  * **RDP Script:** Automatically detects the active console user and adds them to the local `Remote Desktop Users` group to facilitate secure remote access. Logs the steps to a central Google webhook.
