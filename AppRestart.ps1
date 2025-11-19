<#
.NOTES
    File Name         : AppRestart.ps1
    Developer         : amold
    Created           : 17 November 2025   
    Purpose           : Manage IIS Application Pools with retry logic and user-friendly file selection
.SYNOPSIS
    IIS Application Pool Management Script

.DESCRIPTION
    This script provides automated management of IIS Application Pools including
    stop, start, and restart operations with retry logic and file-based pool selection.
    
.PARAMETER Action
    Specifies the action to perform on the application pools (Stop, Start, Restart)
    Default is Restart

.EXAMPLE
    .\AppRestart.ps1 -Action Restart
    .\AppRestart.ps1 -Action Stop
#>


param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("Stop", "Start", "Restart")]
    [string]$Action = "Restart"
)

Import-Module WebAdministration

# Function to show file browser dialog
function Get-AppPoolListFile {
    Add-Type -AssemblyName System.Windows.Forms
    
    $fileBrowser = New-Object System.Windows.Forms.OpenFileDialog
    $fileBrowser.Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*"
    $fileBrowser.Title = "Select App Pool List File"
    $fileBrowser.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    
    if ($fileBrowser.ShowDialog() -eq 'OK') {
        return $fileBrowser.FileName
    }
    else {
        Write-Host "No file selected. Exiting..." -ForegroundColor Red
        exit 1
    }
}

# Get file path and read app pool names
$filePath = Get-AppPoolListFile
Write-Host "Selected file: $filePath" -ForegroundColor Cyan

$AppPoolNames = Get-Content -Path $filePath | Where-Object { $_.Trim() -ne "" }

if ($AppPoolNames.Count -eq 0) {
    Write-Host "No app pool names found in the file. Exiting..." -ForegroundColor Red
    exit 1
}

Write-Host "`nApp Pools to process:" -ForegroundColor Cyan
$AppPoolNames | ForEach-Object { Write-Host "  - $_" -ForegroundColor White }

function Wait-AndRetry {
    param(
        [scriptblock]$Command,
        [string]$ActionName,
        [string]$AppPoolName
    )
    
    $maxRetries = 10
    $retryCount = 0
    
    do {
        try {
            Write-Host "Attempting to $ActionName application pool: $AppPoolName" -ForegroundColor Yellow
            & $Command
            Write-Host "$ActionName completed successfully for: $AppPoolName" -ForegroundColor Green
            return $true
        }
        catch {
            $retryCount++
            Write-Host "Error during $ActionName : $($_.Exception.Message)" -ForegroundColor Red
            
            if ($retryCount -lt $maxRetries) {
                Write-Host "Waiting 30 seconds before retry ($retryCount/$maxRetries)..." -ForegroundColor Yellow
                Start-Sleep -Seconds 30
            }
        }
    } while ($retryCount -lt $maxRetries)
    
    Write-Host "Failed to $ActionName application pool after $maxRetries attempts" -ForegroundColor Red
    return $false
}

# Process each app pool
switch ($Action) {
    "Stop" {
        foreach ($AppPoolName in $AppPoolNames) {
            Write-Host "`nProcessing: $AppPoolName" -ForegroundColor Cyan
            if (-not (Wait-AndRetry -Command { Stop-WebAppPool -Name $AppPoolName } -ActionName "stop" -AppPoolName $AppPoolName)) {
                exit 1
            }
        }
    }
    "Start" {
        foreach ($AppPoolName in $AppPoolNames) {
            Write-Host "`nProcessing: $AppPoolName" -ForegroundColor Cyan
            if (-not (Wait-AndRetry -Command { Start-WebAppPool -Name $AppPoolName } -ActionName "start" -AppPoolName $AppPoolName)) {
                exit 1
            }
        }
    }
    "Restart" {
        # Stop all app pools first
        foreach ($AppPoolName in $AppPoolNames) {
            Write-Host "`nStopping: $AppPoolName" -ForegroundColor Cyan
            if (-not (Wait-AndRetry -Command { Stop-WebAppPool -Name $AppPoolName } -ActionName "stop" -AppPoolName $AppPoolName)) {
                exit 1
            }
        }
        
        # Wait 2 minutes before starting
        Write-Host "`nWaiting 2 minutes before starting app pools..." -ForegroundColor Yellow
        Start-Sleep -Seconds 120
        
        # Start all app pools
        foreach ($AppPoolName in $AppPoolNames) {
            Write-Host "`nStarting: $AppPoolName" -ForegroundColor Cyan
            if (-not (Wait-AndRetry -Command { Start-WebAppPool -Name $AppPoolName } -ActionName "start" -AppPoolName $AppPoolName)) {
                exit 1
            }
        }
    }
}
