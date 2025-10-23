# ===========================================
# Script: Find Empty Resource Groups in a Specific Subscription
# ===========================================

#  Connect to Azure
Connect-AzAccount

#  Set your subscription details here
$SubscriptionId = "<YOUR_SUBSCRIPTION_ID>"      # Example: "12345678-abcd-9876-efgh-1234567890ab"
# OR
# $SubscriptionName = "<YOUR_SUBSCRIPTION_NAME>" # Example: "Production-Environment"

#  Set context (by ID or Name)
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
# If using name instead:
# Set-AzContext -SubscriptionName $SubscriptionName | Out-Null

Write-Host "`nChecking subscription: $SubscriptionId" -ForegroundColor Yellow
Write-Host "-------------------------------------------------------------"

#  Get all resource groups
$resourceGroups = Get-AzResourceGroup

#  Initialize list for empty RGs
$emptyGroups = @()

#  Check each resource group
foreach ($rg in $resourceGroups) {
    $resources = Get-AzResource -ResourceGroupName $rg.ResourceGroupName
    if ($resources.Count -eq 0) {
        $emptyGroups += [PSCustomObject]@{
            SubscriptionId    = $SubscriptionId
            ResourceGroupName = $rg.ResourceGroupName
            Location          = $rg.Location
        }
    }
}

#  Display and export results
if ($emptyGroups.Count -gt 0) {
    Write-Host "`nEmpty Resource Groups Found:" -ForegroundColor Cyan
    $emptyGroups | Format-Table -AutoSize

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $outputFile = "EmptyResourceGroups_$SubscriptionId`_$timestamp.csv"
    $emptyGroups | Export-Csv -Path $outputFile -NoTypeInformation

    Write-Host "`nResults exported to: $outputFile" -ForegroundColor Green
} else {
    Write-Host "No empty resource groups found in this subscription." -ForegroundColor Green
}
