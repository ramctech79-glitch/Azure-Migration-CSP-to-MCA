param(
    [string]$SubscriptionId = '',
    [string]$OutputPath = '',
    [switch]$IncludeManagedIdentity,
    [switch]$SkipOnPermissionError,
    [switch]$RedactSensitive = $true
)

# ===============================
# 1. Ensure Az module is available
# ===============================
function Ensure-AzModule {
    if (-not (Get-Module -ListAvailable -Name Az)) {
        Write-Host "Installing Az module..." -ForegroundColor Yellow
        try {
            Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
            Write-Host "Az module installed successfully." -ForegroundColor Green
        } catch {
            Write-Error "Failed to install Az module: $($_.Exception.Message)"
            throw
        }
    }
}

# ===============================
# 2. Ensure we are connected to Azure
# ===============================
function Ensure-Connected {
    try {
        $acct = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $acct) {
            Write-Host "No Azure context detected. Signing in..."
            Connect-AzAccount -ErrorAction Stop
        }
    } catch {
        Write-Error "Failed to connect to Azure: $($_.Exception.Message)"
        throw
    }
}

# ===============================
# 3. Redact sensitive data
# ===============================
function Redact-Properties {
    param([Parameter(Mandatory = $true)][object]$InputObj)

    $sensitiveKeys = @('connectionString','password','secret','apiKey','accessKey','clientSecret','PrimaryKey','secondaryKey')
    if ($null -eq $InputObj) { return $null }

    $json = $InputObj | ConvertTo-Json -Depth 10 -Compress
    foreach ($key in $sensitiveKeys) {
        $json = $json -replace "(?i)($key)\s*[:=]\s*[""']?[^,""'\s}]+", "`$1=REDACTED"
    }

    return ($json | ConvertFrom-Json)
}

# ===============================
# 4. Main execution
# ===============================
Ensure-AzModule
Import-Module Az -ErrorAction Stop
Ensure-Connected

if ($SubscriptionId) {
    $subs = Get-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop
} else {
    $subs = Get-AzSubscription -ErrorAction Stop
}

$allResults = [System.Collections.Generic.List[object]]::new()
$timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
if (-not $OutputPath) {
    $OutputPath = Join-Path -Path (Get-Location) -ChildPath "AzureResourcesInventory_$timestamp"
}

foreach ($sub in $subs) {
    Write-Host "`nProcessing subscription: $($sub.Name) ($($sub.Id))" -ForegroundColor Cyan

    try {
        Set-AzContext -Subscription $sub.Id -ErrorAction Stop
        $resources = Get-AzResource -ErrorAction Stop
    } catch {
        Write-Warning "Failed to list resources in $($sub.Id): $($_.Exception.Message)"
        continue
    }

    foreach ($r in $resources) {
        try {
            $full = Get-AzResource -ResourceId $r.ResourceId -ExpandProperties -ErrorAction SilentlyContinue
            $props = $full.Properties
            if ($RedactSensitive -and $props) { $props = Redact-Properties $props }

            $obj = [PSCustomObject]@{
                SubscriptionName  = $sub.Name
                SubscriptionId    = $sub.Id
                ResourceGroupName = $r.ResourceGroupName
                Name              = $r.Name
                Type              = $r.ResourceType
                Location          = $r.Location
                Properties        = if ($props) { ($props | ConvertTo-Json -Depth 6 -Compress) } else { $null }
            }

            $allResults.Add($obj)
        } catch {
            Write-Warning "Error processing $($r.Name): $($_.Exception.Message)"
            continue
        }
    }
}

# ===============================
# 5. Save results
# ===============================
$csv = "${OutputPath}.csv"
$json = "${OutputPath}.json"

$allResults | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
$allResults | ConvertTo-Json -Depth 10 | Out-File -FilePath $json -Encoding UTF8

Write-Host "`nCompleted successfully!" -ForegroundColor Green
Write-Host "CSV: $csv"
Write-Host "JSON: $json"
 
