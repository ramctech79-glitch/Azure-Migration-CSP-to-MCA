<#
.SYNOPSIS
Azure Resource Dependency Mapper - All Subscriptions
Finds app resource dependencies, database links, and private/public endpoints across all subscriptions.

.DESCRIPTION
This script uses Azure Resource Graph and REST APIs to map resource dependencies
for all accessible subscriptions. Outputs results as a single CSV for migration planning.
#>

param(
    [string]$OutputPath = "C:\Temp\AzureDependencyOutput_AllSubscriptions.csv",
    [string]$ResourceGroup = "",
    [int]$ResultLimit = 10000,  # Maximum results to retrieve per subscription
    [string[]]$SubscriptionFilter = @()  # Optional: Specify subscription IDs to include
)

$ErrorActionPreference = "Stop"

# --- Ensure required Az modules ---
try {
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Install-Module Az.Accounts -Scope CurrentUser -Force
    }
    if (-not (Get-Module -ListAvailable -Name Az.ResourceGraph)) {
        Install-Module Az.ResourceGraph -Scope CurrentUser -Force
    }
    Import-Module Az.Accounts
    Import-Module Az.ResourceGraph
}
catch {
    Write-Host "Error loading Az modules: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# --- Connect to Azure ---
try {
    Write-Host "Connecting to Azure..." -ForegroundColor Cyan
    Connect-AzAccount -ErrorAction Stop | Out-Null
}
catch {
    Write-Host "Azure login failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# --- Get all subscriptions ---
try {
    Write-Host "Retrieving all accessible subscriptions..." -ForegroundColor Cyan
    $allSubscriptions = Get-AzSubscription -ErrorAction Stop
    
    # Filter subscriptions if specified
    if ($SubscriptionFilter.Count -gt 0) {
        $allSubscriptions = $allSubscriptions | Where-Object { $_.Id -in $SubscriptionFilter }
        Write-Host "Filtered to $($allSubscriptions.Count) specified subscription(s)" -ForegroundColor Yellow
    }
    
    Write-Host "Found $($allSubscriptions.Count) subscription(s) to scan" -ForegroundColor Green
}
catch {
    Write-Host "Failed to retrieve subscriptions: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if ($allSubscriptions.Count -eq 0) {
    Write-Host "No subscriptions found or accessible." -ForegroundColor Yellow
    exit 0
}

# --- Build Resource Graph Query for all subscriptions ---
if ([string]::IsNullOrEmpty($ResourceGroup)) {
    $query = @"
resources
| where type =~ 'microsoft.web/sites' 
    or type =~ 'microsoft.sql/servers/databases' 
    or type =~ 'microsoft.network/privateendpoints' 
    or type =~ 'microsoft.network/publicipaddresses'
    or type =~ 'microsoft.storage/storageaccounts'
    or type =~ 'microsoft.cache/redis'
    or type =~ 'microsoft.servicebus/namespaces'
| project id, name, type, resourceGroup, location, properties, subscriptionId, tags
"@
}
else {
    $query = @"
resources
| where resourceGroup =~ '$ResourceGroup'
| where type =~ 'microsoft.web/sites' 
    or type =~ 'microsoft.sql/servers/databases' 
    or type =~ 'microsoft.network/privateendpoints' 
    or type =~ 'microsoft.network/publicipaddresses'
    or type =~ 'microsoft.storage/storageaccounts'
    or type =~ 'microsoft.cache/redis'
    or type =~ 'microsoft.servicebus/namespaces'
| project id, name, type, resourceGroup, location, properties, subscriptionId, tags
"@
}

# --- Run Query across all subscriptions with Pagination ---
try {
    Write-Host "`nRunning Azure Resource Graph query across all subscriptions..." -ForegroundColor Cyan
    
    $allResults = @()
    $skipToken = $null
    $pageSize = 1000  # Max allowed by Resource Graph
    $retrievedCount = 0
    
    # Get subscription IDs for the query
    $subscriptionIds = $allSubscriptions | Select-Object -ExpandProperty Id
    
    do {
        if ($skipToken) {
            $results = Search-AzGraph -Query $query -First $pageSize -SkipToken $skipToken -Subscription $subscriptionIds -ErrorAction Stop
        }
        else {
            $results = Search-AzGraph -Query $query -First $pageSize -Subscription $subscriptionIds -ErrorAction Stop
        }
        
        if ($results) {
            $allResults += $results
            $retrievedCount += $results.Count
            Write-Host "Retrieved $retrievedCount resources so far..." -ForegroundColor Cyan
            
            # Get skip token for next page
            $skipToken = $results.SkipToken
        }
        
        # Stop if we've reached the result limit
        if ($retrievedCount -ge $ResultLimit) {
            Write-Host "Reached result limit of $ResultLimit" -ForegroundColor Yellow
            break
        }
        
    } while ($skipToken)
    
    Write-Host "Total resources retrieved: $($allResults.Count)" -ForegroundColor Green
}
catch {
    Write-Host "Resource Graph query failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if (-not $allResults -or $allResults.Count -eq 0) {
    Write-Host "No resources found across subscriptions." -ForegroundColor Yellow
    exit 0
}

# --- Create subscription name lookup ---
$subLookup = @{}
foreach ($sub in $allSubscriptions) {
    $subLookup[$sub.Id] = $sub.Name
}

# --- Process Results ---
Write-Host "`nProcessing resources..." -ForegroundColor Cyan
$output = @()
$processedCount = 0

foreach ($r in $allResults) {
    $processedCount++
    if ($processedCount % 100 -eq 0) {
        Write-Host "Processing resource $processedCount of $($allResults.Count)..." -ForegroundColor Cyan
    }
    
    $item = [PSCustomObject]@{
        SubscriptionId   = $r.subscriptionId
        SubscriptionName = $subLookup[$r.subscriptionId]
        ResourceGroup    = $r.resourceGroup
        ResourceName     = $r.name
        ResourceType     = $r.type
        Location         = $r.location
        PrivateEndpoint  = ""
        PrivateIP        = ""
        PublicEndpoint   = ""
        PublicIP         = ""
        DatabaseLink     = ""
        AppServicePlan   = ""
        RuntimeStack     = ""
        StorageAccount   = ""
        RedisCache       = ""
        ServiceBus       = ""
        Tags             = ""
    }

    # --- Tags ---
    if ($r.tags) {
        $tagStrings = @()
        foreach ($key in $r.tags.PSObject.Properties.Name) {
            $tagStrings += "$key=$($r.tags.$key)"
        }
        $item.Tags = $tagStrings -join "; "
    }

    # --- Private Endpoint Info ---
    if ($r.type -eq "microsoft.network/privateendpoints") {
        $props = $r.properties
        if ($props.networkInterfaces) {
            foreach ($iface in $props.networkInterfaces) {
                $ifaceId = $iface.id
                try {
                    # Set context to the correct subscription
                    $ifaceSubId = ($ifaceId -split "/")[2]
                    Select-AzSubscription -SubscriptionId $ifaceSubId -ErrorAction SilentlyContinue | Out-Null
                    
                    $ifaceData = Get-AzResource -ResourceId $ifaceId -ErrorAction SilentlyContinue
                    if ($ifaceData -and $ifaceData.Properties.ipConfigurations) {
                        $ip = $ifaceData.Properties.ipConfigurations[0].Properties.privateIPAddress
                        $item.PrivateEndpoint = $ifaceData.Name
                        $item.PrivateIP = $ip
                    }
                }
                catch {
                    Write-Warning "Could not fetch NIC info for $ifaceId"
                }
            }
        }
    }

    # --- Public IP Info ---
    if ($r.type -eq "microsoft.network/publicipaddresses") {
        $props = $r.properties
        $item.PublicEndpoint = $r.name
        $item.PublicIP = $props.ipAddress
    }

    # --- SQL Database Link ---
    if ($r.type -eq "microsoft.sql/servers/databases") {
        $dbName = $r.name
        $serverName = ($r.id -split "/")[8]
        $item.DatabaseLink = "$serverName.database.windows.net;Initial Catalog=$dbName"
    }
    
    # --- App Service Info ---
    if ($r.type -eq "microsoft.web/sites") {
        $props = $r.properties
        if ($props.serverFarmId) {
            $item.AppServicePlan = ($props.serverFarmId -split "/")[-1]
        }
        if ($props.siteConfig.linuxFxVersion) {
            $item.RuntimeStack = $props.siteConfig.linuxFxVersion
        }
        elseif ($props.siteConfig.windowsFxVersion) {
            $item.RuntimeStack = $props.siteConfig.windowsFxVersion
        }
    }
    
    # --- Storage Account Info ---
    if ($r.type -eq "microsoft.storage/storageaccounts") {
        $props = $r.properties
        $item.StorageAccount = "$($r.name).blob.core.windows.net"
    }
    
    # --- Redis Cache Info ---
    if ($r.type -eq "microsoft.cache/redis") {
        $props = $r.properties
        $item.RedisCache = "$($r.name).redis.cache.windows.net"
    }
    
    # --- Service Bus Info ---
    if ($r.type -eq "microsoft.servicebus/namespaces") {
        $props = $r.properties
        $item.ServiceBus = "$($r.name).servicebus.windows.net"
    }

    $output += $item
}

# --- Export to CSV ---
try {
    $dir = Split-Path $OutputPath
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    $output | Export-Csv -Path $OutputPath -NoTypeInformation -Force
    Write-Host "`nResults exported to $OutputPath" -ForegroundColor Green
    Write-Host "Total records exported: $($output.Count)" -ForegroundColor Green
}
catch {
    Write-Host "Failed to export CSV: $($_.Exception.Message)" -ForegroundColor Red
}

# --- Summary by Subscription ---
Write-Host "`n=== Summary by Subscription ===" -ForegroundColor Cyan
foreach ($sub in $allSubscriptions) {
    $subResources = $output | Where-Object { $_.SubscriptionId -eq $sub.Id }
    if ($subResources.Count -gt 0) {
        Write-Host "`n$($sub.Name) ($($sub.Id)):" -ForegroundColor Yellow
        Write-Host "  Web Apps: $(($subResources | Where-Object {$_.ResourceType -eq 'microsoft.web/sites'}).Count)" -ForegroundColor White
        Write-Host "  SQL Databases: $(($subResources | Where-Object {$_.ResourceType -eq 'microsoft.sql/servers/databases'}).Count)" -ForegroundColor White
        Write-Host "  Storage Accounts: $(($subResources | Where-Object {$_.ResourceType -eq 'microsoft.storage/storageaccounts'}).Count)" -ForegroundColor White
        Write-Host "  Private Endpoints: $(($subResources | Where-Object {$_.ResourceType -eq 'microsoft.network/privateendpoints'}).Count)" -ForegroundColor White
        Write-Host "  Public IPs: $(($subResources | Where-Object {$_.ResourceType -eq 'microsoft.network/publicipaddresses'}).Count)" -ForegroundColor White
        Write-Host "  Redis Caches: $(($subResources | Where-Object {$_.ResourceType -eq 'microsoft.cache/redis'}).Count)" -ForegroundColor White
        Write-Host "  Service Bus: $(($subResources | Where-Object {$_.ResourceType -eq 'microsoft.servicebus/namespaces'}).Count)" -ForegroundColor White
    }
}

# --- Overall Summary ---
Write-Host "`n=== Overall Summary ===" -ForegroundColor Cyan
Write-Host "Total Subscriptions Scanned: $($allSubscriptions.Count)" -ForegroundColor White
Write-Host "Total Resources Found: $($output.Count)" -ForegroundColor White
Write-Host "  Web Apps: $(($output | Where-Object {$_.ResourceType -eq 'microsoft.web/sites'}).Count)" -ForegroundColor White
Write-Host "  SQL Databases: $(($output | Where-Object {$_.ResourceType -eq 'microsoft.sql/servers/databases'}).Count)" -ForegroundColor White
Write-Host "  Storage Accounts: $(($output | Where-Object {$_.ResourceType -eq 'microsoft.storage/storageaccounts'}).Count)" -ForegroundColor White
Write-Host "  Private Endpoints: $(($output | Where-Object {$_.ResourceType -eq 'microsoft.network/privateendpoints'}).Count)" -ForegroundColor White
Write-Host "  Public IPs: $(($output | Where-Object {$_.ResourceType -eq 'microsoft.network/publicipaddresses'}).Count)" -ForegroundColor White
Write-Host "  Redis Caches: $(($output | Where-Object {$_.ResourceType -eq 'microsoft.cache/redis'}).Count)" -ForegroundColor White
Write-Host "  Service Bus: $(($output | Where-Object {$_.ResourceType -eq 'microsoft.servicebus/namespaces'}).Count)" -ForegroundColor White
