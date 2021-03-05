param(
    [parameter(Mandatory = $false)][string]$ConfigurationFile = "C:\BizTalk2020-IaaS\Configuration.json",
    [parameter(Mandatory=$false)][switch]$configureBizTalk,
    [parameter(Mandatory=$false)][switch]$configureSQL
    )

##################################
# Functions
##################################

function Write-Log ($message, [ValidateSet('Information','Warning','Error')]$level )
{
    $timestamp = [System.DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss")
    switch ($level)
    {
        'Warning' 
        {
            Write-Host "$timestamp $message" -ForegroundColor DarkYellow
        }
        'Error' 
        {
            Write-Host "$timestamp $message" -ForegroundColor Red
        }
        Default 
        {
            Write-Host "$timestamp $message" -ForegroundColor Gray
        }
    }

}

function Get-Configuration($fullPathToFile, [switch]$exitOnError )
{
    Write-Log -message "Start Load-ConfigFile $fullPathToFile" -level Information
    if ((Test-Path -Path $fullPathToFile)-eq $false ) 
    {
        if ($exitOnError)
        {
            Write-Log -message "Load-ConfigFile '$fullPathToFile' Not found. Quit selected." -level Error
            Exit    
        }
        else
        {
            Write-Log -message "Load-ConfigFile '$fullPathToFile' Not found." -level Warning
            return $null
        }
    }
    else
    {
        $configuration = Get-Content $fullPathToFile -Encoding UTF8 | ConvertFrom-Json 
        return $configuration
    }
        Write-Log -message "End Load-ConfigFile $fullPathToFile" -level Information
}

<#
.Synopsis
    Validates configuration
.Description
    Validates the provided configuration, failure should stop further execution.
    Checks: 
        - VMs exist
        - Virtual network exist
        - Subnet exist
#>
function Confirm-Configuration {
    param (
        # config Configuration object
        [parameter(Mandatory = $true)]$configuration
    )
    $configIsValid = $true
    # Validate that we have essential properties
    if ($null -eq $configuration.CommonSettings -or $null -eq $configuration.BizTalk -or $null -eq $configuration.SQL) 
    {
        return $false
    }
    #BizTalk
    Write-Log -message "Validating BizTalk Servers exist." -level Information
    $resourceGroupName = "$($configuration.CommonSettings.ResourceGroupRoot)-$($configuration.BizTalk.ResourceGroupSuffix)"
    foreach ($btServer in $configuration.BizTalk.Servers) 
    {       
        $vm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $btServer -ErrorAction SilentlyContinue
        if ($null -eq $vm) 
        {
            Write-Log -message "BizTalk Server '$btServer' don't exist in '$resourceGroupName'" -level Error
            $configIsValid = $false
        }
    }
    
    
    #SQL
    Write-Log -message "Validating SQL Servers exist." -level Information
    $resourceGroupName = "$($configuration.CommonSettings.ResourceGroupRoot)-$($configuration.SQL.ResourceGroupSuffix)"
    foreach ($btServer in $configuration.SQL.Servers) 
    {       
        $vm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $btServer -ErrorAction SilentlyContinue
        if ($null -eq $vm) 
        {
            Write-Log -message "SQL Server '$btServer' don't exist in '$resourceGroupName'" -level Error
            $configIsValid = $false
        }
    }
    #Virtual network
    Write-Log -message "Validating Virtual network exists." -level Information
    $vnet = Get-AzVirtualNetwork -Name $configuration.CommonSettings.VirtualNetwork -ResourceGroupName $configuration.CommonSettings.VirtualNetworkResourceGroup -ErrorAction SilentlyContinue
    if ($null -eq $vnet) 
    {
        Write-Log -message "Virtual network '$($configuration.CommonSettings.VirtualNetwork)' not found in '$($configuration.CommonSettings.VirtualNetworkResourceGroup)'" -level Error
        $configIsValid = $false
    }
    else {
        Write-Log -message "Validating Subnet exists." -level Information
        $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $configuration.CommonSettings.Subnet }
        if ($null -eq $subnet) {
            Write-Log -message "Virtual network '$($configuration.CommonSettings.VirtualNetwork)' in '$($configuration.CommonSettings.VirtualNetworkResourceGroup)' don't contain subnet '$($configuration.CommonSettings.Subnet)'" -level Error
            $configIsValid = $false
        }
    }

    return $configIsValid
}

function Import-AzModules {
    # Load modules, MinimumVersion is the one used when the script was created
    Import-Module Az.Accounts -MinimumVersion 1.9.2 -Force 
    Import-Module Az.Compute -MinimumVersion 4.2.1 -Force
    Import-Module Az.Storage -MinimumVersion 2.4.0 -Force
    Import-Module Az.Resources -MinimumVersion 2.3.0 -Force
    Import-Module Az.Network -MinimumVersion 3.3.0 -Force

}

function New-Loadbalancer 
{
    param(
        [parameter(Mandatory = $true)][string]$resourceGroupName,
        [parameter(Mandatory = $true)][string]$location,
        [parameter(Mandatory = $true)][string]$loadbalancerName,
        [parameter(Mandatory = $true)][string]$vnetName,
        [parameter(Mandatory = $true)][string]$vnetResourceGroup,
        [parameter(Mandatory = $true)][string]$subnetName,
        [parameter(Mandatory = $true)][string]$frontendIpAddress,
        [parameter(Mandatory = $true)][int]$probePort,
        [parameter(Mandatory = $true)][string]$zone,
        [parameter(Mandatory = $true)][string[]]$virtualMachines)

#region GetResources
    # Get Network resources 
    $vnet = Get-AzVirtualNetwork -Name $VnetName -ResourceGroupName $VnetResourceGroup -ErrorAction SilentlyContinue
    if ($null -eq $vnet)
    {
        Write-Log  -Level Error -message  "Failed finding Virtual Network $VnetName"
        return $null 
    }
    else
    {
        Write-Log  -Level Information -message  "Found Virtual Network $VnetName"
    }

    $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $SubnetName }
    if ($null -eq $subnet)
    {
        Write-Log  -Level Error -message  "Failed finding Virtual Network $VnetName Subnet $SubnetName"
        return $null 
    }
    else
    {
        Write-Log  -Level Information -message  "Found Virtual Network $VnetName, Subnet $SubnetName"
    }
#endregion GetResources
    $vms = @($VirtualMachines | ForEach-Object { Get-AzVM -ResourceGroupName $resourceGroupName -Name $_ })
    $lb = Get-AzLoadBalancer -ResourceGroupName $resourceGroupName -Name $LoadbalancerName -ErrorAction SilentlyContinue
    if ($null -eq $lb)
    {
        Write-Log  -Level Information -message  "Load balancer $LoadbalancerName in $ResourceGroupName not found, creating."
        Write-Log  -Level Information -message  "Load balancer $LoadbalancerName configuring $FrontendIpAddress to $LoadbalancerName-Frontend"
        $frontendIP = New-AzLoadBalancerFrontendIpConfig -Name "$LoadbalancerName-Frontend" -PrivateIpAddress $FrontendIpAddress -SubnetId $subnet.Id -Zone $zone
        Write-Log  -Level Information -message  "Load balancer $LoadbalancerName creating $LoadbalancerName-backend"
        $beaddresspool= New-AzLoadBalancerBackendAddressPoolConfig -Name "$LoadbalancerName-backend"
        Write-Log  -Level Information -message  "Load balancer $LoadbalancerName creating Prefix-Probe"
        $healthProbe = New-AzLoadBalancerProbeConfig -Name "$LoadbalancerName-Probe" -Protocol Tcp -Port $probePort -IntervalInSeconds 5 -ProbeCount 2
        Write-Log  -Level Information -message  "Load balancer $LoadbalancerName creating HAPortsRule"
        $haportslbrule = New-AzLoadBalancerRuleConfig -Name "HAPortsRule" -FrontendIpConfiguration $frontendIP -BackendAddressPool $beAddressPool -Probe $healthProbe -Protocol "All" -FrontendPort 0 -BackendPort 0 -EnableFloatingIP 
    
        Write-Log  -Level Information -message  "Load balancer $LoadbalancerName saving."
    
        New-AzLoadBalancer -ResourceGroupName $ResourceGroupName -Name $LoadbalancerName -Location $Location -Sku Standard -FrontendIpConfiguration $frontendIP -BackendAddressPool $beaddresspool -Probe $healthProbe -LoadBalancingRule $haportslbrule | Out-Null
        foreach ($vm in $vms)
        {
            $a = $vm.NetworkProfile.NetworkInterfaces[0] 
            Write-Log  -Level Information -message  "Adding $($vm.Name) to $LoadbalancerName-backend"
            $nic = Get-AzNetworkInterface -ResourceId $a.Id
            $nic | Set-AzNetworkInterfaceIpConfig -LoadBalancerBackendAddressPool $beaddresspool -Name ipconfig1 | Out-Null
            $nic | Set-AzNetworkInterface | Out-Null
        }  
        
        Write-Log  -Level Information -message  "Load balancer $LoadbalancerName in $ResourceGroupName created."
    }
    else
    {
        Write-Log  -Level Warning -message  "Load balancer $LoadbalancerName in $ResourceGroupName found, no change."
    }
}



##################################
# Main code
##################################
Clear-Host

Check-LoadedModule -module az
Set-MyAzureContext

# Timestamp string used for logfiles etc.
$timestamp = [System.DateTime]::Now.ToString("yyyyMMdd_HHmmss")
$configuration = Get-Configuration -fullPathToFile $ConfigurationFile  -exitOnError

$configIsValid = Confirm-Configuration -configuration $configuration
if ($configIsValid) {
    Write-Log -message "Configuration file $ConfigurationFile is valid." -level Information
    if ($true -eq $configureBizTalk) {
        Write-Log -message "Configuring Load balancer for BizTalk Server." -level Information
        if ( $null -ne $configuration.BizTalk.LoadBalancer) {
            $resourceGroupName = "$($configuration.CommonSettings.ResourceGroupRoot)-$($configuration.BizTalk.ResourceGroupSuffix)"
            $location = $configuration.CommonSettings.Location
            New-Loadbalancer -resourceGroupName $resourceGroupName `
                            -location $location `
                            -loadbalancerName $configuration.BizTalk.LoadBalancer.Name `
                            -vnetName $configuration.CommonSettings.VirtualNetwork `
                            -vnetResourceGroup $configuration.CommonSettings.VirtualNetworkResourceGroup `
                            -subnetName $configuration.CommonSettings.Subnet `
                            -frontendIpAddress $configuration.BizTalk.LoadBalancer.FrontEndAddress `
                            -probePort $configuration.BizTalk.LoadBalancer.ProbePort `
                            -zone $configuration.BizTalk.Zone `
                            -virtualMachines $configuration.BizTalk.Servers
            Write-Log -message "Done configuring Load balancer for BizTalk Server." -level Information
        }
        else {
            Write-Log -message "Unable to configure Load balancer for BizTalk Server, configuration information is missing." -level Error
        }

    }
    if ($true -eq $configureSQL) {
        Write-Log -message "Configuring Load balancer for SQL Server." -level Information
        if ( $null -ne $configuration.SQL.LoadBalancer) {
            $resourceGroupName = "$($configuration.CommonSettings.ResourceGroupRoot)-$($configuration.SQL.ResourceGroupSuffix)"
            $location = $configuration.CommonSettings.Location
            New-Loadbalancer -resourceGroupName $resourceGroupName `
                            -location $location `
                            -loadbalancerName $configuration.SQL.LoadBalancer.Name `
                            -vnetName $configuration.CommonSettings.VirtualNetwork `
                            -vnetResourceGroup $configuration.CommonSettings.VirtualNetworkResourceGroup `
                            -subnetName $configuration.CommonSettings.Subnet `
                            -frontendIpAddress $configuration.SQL.LoadBalancer.FrontEndAddress `
                            -probePort $configuration.SQL.LoadBalancer.ProbePort `
                            -zone $configuration.SQL.Zone `
                            -virtualMachines $configuration.SQL.Servers
            Write-Log -message "Done configuring Load balancer for SQL Server." -level Information
        }
        else {
            Write-Log -message "Unable to configure Load balancer for SQL Server, configuration information is missing." -level Error
        }
    }
}
else {
    Write-Log -message "Configuration file $ConfigurationFile is not valid." -level Error
}

