# BoUnvToUnx

Bulk repoint SAP BusinessObjects WebI reports from UNV to UNX universe using the Raylight REST API.

## Requirements
- SAP BusinessObjects BI 4.2 SP5+ / 4.3 SP5
- PowerShell 5.1+
- Network access to BO server on port 6405

## Usage

1. Edit config block at top of `Repoint-UnvToUnx.ps1`
2. Set `DRY_RUN = $true` and run to verify reports found
3. Set `DRY_RUN = $false` to apply changes

`powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Repoint-UnvToUnx.ps1
`

## Notes
- Always take a BIAR backup before running with DRY_RUN = false
- Target UNX must already be published to the CMS
- Tested on SAP BO 4.3 SP5
