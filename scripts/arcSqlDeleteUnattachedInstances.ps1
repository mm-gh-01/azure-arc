param(
    [Parameter(Mandatory=$true)]
    [string]$tenantId,

    [Parameter(Mandatory=$true)]
    [string]$subscriptionId,

    [Parameter(Mandatory=$false)]
    [string]$resourceGroup,

    [Parameter(Mandatory=$false)]
    [switch]$deleteUnattachedSqlInstances,

    [Parameter(Mandatory=$false)]
    [string]$sqlInstancesOutputFile
)

# Record script start time
$scriptStartTime = Get-Date

# Set the Azure subscription context
$subContext = Set-AzContext -SubscriptionId $subscriptionId -Tenant $tenantId

#Enumerate all Arc machines
$arcMachines = @()
$sqlInstances = @()

if (-not [string]::IsNullOrEmpty($resourceGroup)) {
    Write-Output "[$(Get-Date -Format 'HH:mm:ss yyyy-MM-dd')] Targeting subscription $($subContext.Subscription.Name), resource group $resourceGroup"
    $arcMachines = Get-AzResource -ResourceType "Microsoft.HybridCompute/machines" -ResourceGroupName $resourceGroup -ExpandProperties
    Write-Output "[$(Get-Date -Format 'HH:mm:ss yyyy-MM-dd')] Enumerating Arc SQL instances"
    $sqlInstances = Get-AzResource -ResourceType "Microsoft.AzureArcData/sqlServerInstances" -ResourceGroupName $resourceGroup -ExpandProperties
} else {
    Write-Output "[$(Get-Date -Format 'HH:mm:ss yyyy-MM-dd')] Targeting subscription $($subContext.Subscription.Name), resource group not specified"
    Write-Output "[$(Get-Date -Format 'HH:mm:ss yyyy-MM-dd')] Enumerating Arc machines"
    $arcMachines = Get-AzResource -ResourceType "Microsoft.HybridCompute/machines" -ExpandProperties
    Write-Output "[$(Get-Date -Format 'HH:mm:ss yyyy-MM-dd')] Enumerating Arc SQL instances"
    $sqlInstances = Get-AzResource -ResourceType "Microsoft.AzureArcData/sqlServerInstances" -ExpandProperties
}

Write-Output "[$(Get-Date -Format 'HH:mm:ss yyyy-MM-dd')] Arc machines found: $($arcMachines.Count)"
Write-Output "[$(Get-Date -Format 'HH:mm:ss yyyy-MM-dd')] Arc SQL instances found: $($sqlInstances.Count)"

#Load machines list in a HashSet for quick lookup when processing SQL instances
Write-Output "[$(Get-Date -Format 'HH:mm:ss yyyy-MM-dd')] Processing Arc machines for unattached SQL instance detection"
$machineIdSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach($arcMachine in $arcMachines) {
    $machineId = $arcMachine.ResourceId.Trim().TrimEnd('/')
    [void]$machineIdSet.Add($machineId)
}

Write-Output "[$(Get-Date -Format 'HH:mm:ss yyyy-MM-dd')] Detecting unattached SQL instances"

#Preallocate array for performance to max possible size of all SQL instances, will be filtered down to actual unattached instances at the end
$missingChildInstanceIds = [System.Collections.ArrayList]::new($sqlInstances.Count)

[int]$missingCount = 0
for($i = 0; $i -lt $sqlInstances.Count; $i++) {
    $sqlInstance = $sqlInstances[$i]
    $id = $sqlInstance.Properties.containerResourceId.Trim().TrimEnd('/')
    if (-not $machineIdSet.Contains($id)) {
        [void]$missingChildInstanceIds.Add($sqlInstance.ResourceId)
        $missingCount++
    }
}

$missingChildInstanceIds.RemoveRange($missingCount, $missingChildInstanceIds.Count - $missingCount) #Trim the preallocated array to actual size of missing instances

Write-Output "[$(Get-Date -Format 'HH:mm:ss yyyy-MM-dd')] Unattached SQL instances found: $($missingChildInstanceIds.Count)"

if ($missingChildInstanceIds.Count -gt 0 -and -not $deleteUnattachedSqlInstances -and -not [string]::IsNullOrEmpty($sqlInstancesOutputFile)) {
    Write-Output "[$(Get-Date -Format 'HH:mm:ss yyyy-MM-dd')] Exporting unattached SQL instances to $sqlInstancesOutputFile"
    $missingChildInstanceIds |
        Select-Object @{ Name = 'Arc SQL instance ResourceId'; Expression = { $_ } } |
        Export-Csv -Path $sqlInstancesOutputFile -NoTypeInformation
}

if ($missingChildInstanceIds.Count -gt 0 -and $deleteUnattachedSqlInstances) {
    Write-Output "[$(Get-Date -Format 'HH:mm:ss yyyy-MM-dd')] Deleting unattached SQL instances"
    for($i = 0; $i -lt $missingChildInstanceIds.Count; $i++) {
        Write-Output "[$(Get-Date -Format 'HH:mm:ss yyyy-MM-dd')] Deleting SQL instance $($missingChildInstanceIds[$i])"
        #Remove-AzResource -ResourceId $missingChildInstanceIds[$i] -Force
    }
}

Write-Output "[$(Get-Date -Format 'HH:mm:ss yyyy-MM-dd')] Script execution completed in $([math]::Round($((Get-Date) - $scriptStartTime).TotalSeconds, 2)) seconds"
