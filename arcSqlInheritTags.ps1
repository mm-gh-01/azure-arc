param(
    [Parameter(Mandatory=$true)]
    [string]$subscriptionId,

    [Parameter(Mandatory=$false)]
    [string]$resourceGroup
)

$tenantId = "16b3c013-d300-468d-ac64-7eda0820b6d3"

# Set the Azure subscription context
$subContext = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId

#Enumerate all Arc machines in the resource group
$arcMachines = @()
if (-not [string]::IsNullOrEmpty($resourceGroup)) {
    Write-Output "Enumerating Arc machines in resource group $resourceGroup, subscription $($subContext.Subscription.Name)"
    $arcMachines = Get-AzResource -ResourceType "Microsoft.HybridCompute/machines" -ResourceGroupName $resourceGroup -ExpandProperties
} else {
    Write-Output "No resource group specified. Enumerating Arc machines in subscription $($subContext.Subscription.Name)"
    $arcMachines = Get-AzResource -ResourceType "Microsoft.HybridCompute/machines" -ExpandProperties
}

Write-Output "Total Arc machines found: $($arcMachines.Count)"

[int]$machineIndex = 1

foreach($arcMachine in $arcMachines) {
    Write-Output "$machineIndex of $($arcMachines.Count) [$($arcMachine.Name)] ResourceId: $($arcMachine.ResourceId)"

    #Get tags for the Arc machine
    $tags = $arcMachine.Tags

    #Get Arc SQL instances associated with the Arc machine
    $sqlInstances = @()
    if (-not [string]::IsNullOrEmpty($resourceGroup)) {

        $sqlInstances = Get-AzResource -ResourceType "Microsoft.AzureArcData/sqlServerInstances" -ResourceGroupName $resourceGroup -ExpandProperties | Where-Object {$_.Properties.containerResourceId -eq $arcMachine.ResourceId}
    } else {
        $sqlInstances = Get-AzResource -ResourceType "Microsoft.AzureArcData/sqlServerInstances" -ExpandProperties | Where-Object {$_.Properties.containerResourceId -eq $arcMachine.ResourceId}
    }

    Write-Output "[$($arcMachine.Name)] $($sqlInstances.Count) SQL instance(s) associated. Applying tags..."

    foreach($sqlInstance in $sqlInstances) {
        Write-Output "[$($arcMachine.Name)] SQL instance $($sqlInstance.Name)"
        # Apply the same tags from the Arc machine to the SQL instance
        New-AzTag -ResourceId $sqlInstance.ResourceId -Tag $tags
    }

    Write-Output "[$($arcMachine.Name)] Tags applied to all associated SQL instances."
    Write-Output "--------------------------------------------------"
    $machineIndex++
}

Write-Output "Finished applying tags to all SQL Server instances for $($arcMachines.Count) Arc machines."
