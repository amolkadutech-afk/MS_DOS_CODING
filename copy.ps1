# File Copy Script with Skip Option
# Function to browse for folder
function Get-FolderPath {
    param([string]$Description)
    
    Add-Type -AssemblyName System.Windows.Forms
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = $Description
    $folderBrowser.ShowNewFolderButton = $true
    
    if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $folderBrowser.SelectedPath
    }
    return $null
}

# Get source folder
Write-Host "Select source folder..." -ForegroundColor Cyan
$SourceFolder = Get-FolderPath "Select the source folder to copy files from"
if (-not $SourceFolder) {
    Write-Host "No source folder selected. Exiting." -ForegroundColor Red
    exit 1
}

# Get destination folder
Write-Host "Select destination folder..." -ForegroundColor Cyan
$DestinationFolder = Get-FolderPath "Select the destination folder to copy files to"
if (-not $DestinationFolder) {
    Write-Host "No destination folder selected. Exiting." -ForegroundColor Red
    exit 1
}

Write-Host "Source: $SourceFolder" -ForegroundColor Green
Write-Host "Destination: $DestinationFolder" -ForegroundColor Green

# Validate source folder exists
if (-not (Test-Path $SourceFolder)) {
    Write-Error "Source folder does not exist: $SourceFolder"
    exit 1
}

# Create destination folder if it doesn't exist
if (-not (Test-Path $DestinationFolder)) {
    New-Item -ItemType Directory -Path $DestinationFolder -Force | Out-Null
    Write-Host "Created destination folder: $DestinationFolder" -ForegroundColor Green
}

# Get all files from source folder
$files = Get-ChildItem -Path $SourceFolder -File -Recurse

if ($files.Count -eq 0) {
    Write-Host "No files found in source folder." -ForegroundColor Yellow
    exit 0
}

# Display all files
Write-Host "`nFiles found in source folder:" -ForegroundColor Cyan
for ($i = 0; $i -lt $files.Count; $i++) {
    Write-Host "[$i] $($files[$i].FullName)" -ForegroundColor White
}

# Ask which files to skip
Write-Host "`nEnter file numbers to skip (comma-separated, or press Enter to copy all):" -ForegroundColor Yellow
$skipInput = Read-Host

$filesToSkip = @()
if ($skipInput -ne "") {
    $skipNumbers = $skipInput -split "," | ForEach-Object { $_.Trim() }
    $filesToSkip = $skipNumbers | Where-Object { $_ -match '^\d+$' -and [int]$_ -lt $files.Count }
}

# Copy files (excluding skipped ones)
$copiedCount = 0
for ($i = 0; $i -lt $files.Count; $i++) {
    if ($i -in $filesToSkip) {
        Write-Host "Skipping: $($files[$i].Name)" -ForegroundColor Yellow
        continue
    }
    
    $sourceFile = $files[$i]
    $relativePath = $sourceFile.FullName.Substring($SourceFolder.Length + 1)
    $destFile = Join-Path $DestinationFolder $relativePath
    $destDir = Split-Path $destFile -Parent
    
    # Create destination directory if needed
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    
    try {
        Copy-Item -Path $sourceFile.FullName -Destination $destFile -Force
        Write-Host "Copied: $($sourceFile.Name)" -ForegroundColor Green
        $copiedCount++
    }
    catch {
        Write-Error "Failed to copy $($sourceFile.Name): $($_.Exception.Message)"
    }
}

Write-Host "`nCopy operation completed. $copiedCount files copied." -ForegroundColor Cyan