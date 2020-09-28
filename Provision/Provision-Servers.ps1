param([parameter(Mandatory = $false)][string]$ConfigurationFile = "C:\BizTalk2020-IaaS\Configuration.json")


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
    Creates and returns a resource group
.Description
    Creates and returns a resource group, if it already exists the existing is returned.
#>
function Set-ResourceGroup 
{
    param(
        # rgName Name of the resource group
        [parameter(Mandatory = $true)][string]$rgName,
        # location Location of the resource group
        [parameter(Mandatory = $true)][string]$location )
    $rg = Get-AzResourceGroup -Name $rgName -Location $location -ErrorAction SilentlyContinue
    if ($null -eq $rg)
    {
        Write-Log -Level Information -message  "Creating Resource group '$rgName'"
        $rg = New-AzResourceGroup -Name $rgName -Location $location 
        return $rg
    }
    else
    {
        Write-Log -Level Warning -message  "Resource group '$rgName' already exists"
        return $rg
    }
}

<#
.Synopsis
    Creates and returns a Proximity Glacement Group
.Description
    Creates and returns a Proximity Glacement Group, if the group exists it will return the existing.
#>
function Set-ProximityGroup 
{
    param(
        # rgName Resource group name where Proximity Glacement Group is created.
        [parameter(Mandatory = $true)][string]$rgName,
        # location Location where the Proximity Glacement Group is created
        [parameter(Mandatory = $true)][string]$location, 
        # prefix Prefix part of the Proximity Glacement Group name, ignored if name is provided
        [parameter(Mandatory = $false)][string]$prefix,
        # suffix Suffix part of the Proximity Glacement Group name, ignored if name is provided
        [parameter(Mandatory = $false)][string]$suffix,
        # name Name of the Proximity Glacement Group
        [parameter(Mandatory = $false)][string]$name )
    $ppgName = "$prefix$suffix-ppg"  
    if ([string]::IsNullOrWhiteSpace($name) -eq $false)
    {
        $ppgName = $name
    }  
    $ppg = Get-AzProximityPlacementGroup -ResourceGroupName $rgName -Name $ppgName -ErrorAction SilentlyContinue
    if ($null -eq $ppg)
    {
        Write-Log -Level Information -message  "Creating Proximity Placement Group '$ppgName'"
        $ppg = New-AzProximityPlacementGroup -ResourceGroupName $rgName -Name $ppgName -ProximityPlacementGroupType Standard -Location $location
        return $ppg
    }
    else
    {
        Write-Log -Level Warning -message  "Proximity Placement Group '$ppgName' already exists"
        return $ppg
    }
}

<#
.Synopsis
    Creates and returns a Storage account for vm diagnostics
.Description
    Creates and returns a Storage account for vm diagnostics, if the account exists it will return the existing.
    The account will be named "%Prefix%%Suffix%vmdiag"
#>
function Set-DiagStorageAccount
{
    param(
        # rgName Resource group name where the account will be place or retrieved
        [parameter(Mandatory = $true)][string]$rgName,
        # location Location  where the account will be place or retrieved
        [parameter(Mandatory = $true)][string]$location, 
        # prefix First part of the storage account name
        [parameter(Mandatory = $true)][string]$prefix,
        # suffix Second part of the storage account name
        [parameter(Mandatory = $false)][string]$suffix
        )
    $saName = "$($prefix)$($suffix)vmdiag".ToLower().Replace("-","")    
    $sAccount = Get-AzStorageAccount -ResourceGroupName $rgName -Name $saName -ErrorAction SilentlyContinue
    if ($null -eq $sAccount)
    {
        Write-Log -Level Information -message  "Creating Storage Account'$saName'"
        $sAccount = New-AzStorageAccount -ResourceGroupName $rgName -Name $saName -Location $location -SkuName Standard_LRS -Kind Storage  
        return $sAccount
    }
    else
    {
        Write-Log -Level Warning -message  "Storage Account'$saName' already exists"
        return $sAccount
    }
}

<#
.Synopsis
    Creates and returns a Storage account for vm diagnostics
.Description
    Creates and returns a Storage account for vm diagnostics, if the account exists it will return the existing.
    The account will be named "%Prefix%%Suffix%vmdiag"
#>
function Set-VirtualMachines
{
    param(
        [parameter(Mandatory = $true)][string]$rgName,
        [parameter(Mandatory = $true)][string]$location, 
        [parameter(Mandatory = $true)][string]$prefix,
        [parameter(Mandatory = $false)][string]$suffix,
        [parameter(Mandatory = $false)][int]$vmCount = 2,
        [parameter(Mandatory = $true)][string]$vnetName,
        [parameter(Mandatory = $true)][string]$vnetResourceGroup,
        [parameter(Mandatory = $true)][string]$subnetName,
        [parameter(Mandatory = $true)][string]$proximityGroupId,
        [parameter(Mandatory = $true)][ValidateSet('Standard_E4s_v3','Standard_DS12_v2')]$size,
        [parameter(Mandatory = $false)][int]$offset
        )
        $errorsFound = $false
        $vnet = Get-AzVirtualNetwork -Name $VnetName -ResourceGroupName $VnetResourceGroup -ErrorAction SilentlyContinue
        if ($null -eq $vnet)
        {
            Write-Log -Level Error -message  "Set-VirtualMachines, failed finding Virtual Network $vnet"
            $errorsFound = $true
            return $errorsFound
        }

        $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $SubnetName }
        if ($null -eq $subnet)
        {
            Write-Log -Level Error -message  "Set-VirtualMachines, failed finding Virtual Network $vnet Subnet $SubnetName"
            $errorsFound = $true
            return $errorsFound 
        }

        $cred = Get-Credential -Message "Local Username and password for the VMs"

        for ($i = $offset+1; $i -le ($vmCount+$offset); $i++)
        { 
            $vmName = "$($prefix)$($i.ToString("000"))$suffix".ToLower()    
            Write-Log -Level Information -message  "Processing VM: '$vmName'"
            $vm = Get-AzVM -ResourceGroupName $rgName -Name $vmName -ErrorAction SilentlyContinue
            if ($null -eq $vm)
            {
                Write-Log -Level Information -message  "Creating Virtual Maching '$vmName'"
                
                $NIC = New-AzNetworkInterface -Name "$vmName-nic" -ResourceGroupName $rgName -Location $location -SubnetId $subnet.Id 

                # Windows_Server licensetype = BYOL https://docs.microsoft.com/en-us/azure/virtual-machines/windows/hybrid-use-benefit-licensing#create-a-vm-with-azure-hybrid-benefit-for-windows-server
                $VirtualMachine = New-AzVMConfig -VMName $vmName -VMSize $size -LicenseType "Windows_Server" -Zone "3" -ProximityPlacementGroupId $proximityGroupId -EnableUltraSSD 
                if ($size -eq 'Standard_DS12_v2')
                {
                    $VirtualMachine = New-AzVMConfig -VMName $vmName -VMSize $size -LicenseType "Windows_Server" -Zone "3" -ProximityPlacementGroupId $proximityGroupId  
                }
                $VirtualMachine = Set-AzVMOperatingSystem -VM $VirtualMachine -Windows -ComputerName $vmName -Credential $cred -ProvisionVMAgent -EnableAutoUpdate -TimeZone "W. Europe Standard Time" 
                $VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $NIC.Id

                $VirtualMachine = Set-AzVMSourceImage -VM $VirtualMachine -PublisherName 'MicrosoftWindowsServer' -Offer 'WindowsServer' -Skus '2019-datacenter-gensecond' -Version latest  

                $vm = New-AzVM -ResourceGroupName $rgName -Location $location -VM $VirtualMachine -Verbose             
            }
            else
            {
                Write-Log -Level Error -message  "Virtual Maching '$vmName' already exists. Review the log to find provisioned resources."             
                $errorsFound = $true
                return $errorsFound
            }
        }
}


<#
.Synopsis
    Provisions BizTalk Servers
.Description
    Provisions BizTalk Servers based on provided configuration
#>
function New-BizTalkServers {
    param (
        # config Configuration object
        [parameter(Mandatory = $true)]$configuration
    )
    $resourceGroupName = "$($configuration.CommonSettings.ResourceGroupRoot)-$($configuration.BizTalk.ResourceGroupSuffix)"
    $location = $configuration.CommonSettings.Location
    $rg = Set-ResourceGroup -rgName $resourceGroupName `
                            -location $configuration.CommonSettings.Location
    $ppg = Set-ProximityGroup -name $configuration.BizTalk.ProximityGroup `
                              -rgName $ResourceGroupName `
                              -location $location
    $diagsa = Set-DiagStorageAccount -rgName $resourceGroupName `
                                     -location $location `
                                     -prefix $resourceGroupName     
    $errors = Set-VirtualMachines -rgName $resourceGroupName `
                    -location $location `
                    -prefix $configuration.BizTalk.ServerNamePrefix `
                    -suffix $configuration.BizTalk.ServerNameSuffix `
                    -vmCount $configuration.BizTalk.ServerCount `
                    -vnetName $configuration.CommonSettings.VirtualNetwork `
                    -vnetResourceGroup $configuration.CommonSettings.VirtualNetworkResourceGroup `
                    -subnetName $configuration.CommonSettings.Subnet `
                    -proximityGroupId $ppg.Id `
                    -size $configuration.BizTalk.MachineSize `
                    -offset $configuration.BizTalk.ServerStartOffset 
    return $errors
}

<#
.Synopsis
    Provisions SQL Servers
.Description
    Provisions SQL Servers based on provided configuration
#>
function New-SQLServers {
    param (
        # config Configuration object
        [parameter(Mandatory = $true)]$configuration
    )
    $resourceGroupName = "$($configuration.CommonSettings.ResourceGroupRoot)-$($configuration.SQL.ResourceGroupSuffix)"
    $location = $configuration.CommonSettings.Location
    $rg = Set-ResourceGroup -rgName $resourceGroupName `
                            -location $configuration.CommonSettings.Location
    $ppg = Set-ProximityGroup -name $configuration.SQL.ProximityGroup `
                              -rgName $ResourceGroupName `
                              -location $location
    $diagsa = Set-DiagStorageAccount -rgName $resourceGroupName `
                                     -location $location `
                                     -prefix $resourceGroupName     
    $errors = Set-VirtualMachines -rgName $resourceGroupName `
                    -location $location `
                    -prefix $configuration.SQL.ServerNamePrefix `
                    -suffix $configuration.SQL.ServerNameSuffix `
                    -vmCount $configuration.SQL.ServerCount `
                    -vnetName $configuration.CommonSettings.VirtualNetwork `
                    -vnetResourceGroup $configuration.CommonSettings.VirtualNetworkResourceGroup `
                    -subnetName $configuration.CommonSettings.Subnet `
                    -proximityGroupId $ppg.Id `
                    -size $configuration.SQL.MachineSize `
                    -offset $configuration.SQL.ServerStartOffset 
    if ($false -eq $errors) {
        Write-Log -message "SQL VMs provisioned, continuing with disk configuration." -level Information
    }
    else {
        Write-Log -message "SQL VMs provisioned, skipping disk configuration." -level Warning
    }
}

<#
.Synopsis
    Validates configuration
.Description
    Validates the provided configuration, failure should stop further execution.
    Checks: 
        - VMs don't exist
        - Virtual network exist
        - Subnet exist
        - Credential files exist and are readable
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
    Write-Log -message "Validating BizTalk Servers don't exist." -level Information
    $resourceGroupName = "$($configuration.CommonSettings.ResourceGroupRoot)-$($configuration.BizTalk.ResourceGroupSuffix)"
    foreach ($btServer in $configuration.BizTalk.Servers) 
    {       
        $vm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $btServer -ErrorAction SilentlyContinue
        if ($null -ne $vm) 
        {
            Write-Log -message "BizTalk Server '$btServer' already exists in '$resourceGroupName'" -level Error
            $configIsValid = $false
        }
    }
    #SQL
    Write-Log -message "Validating SQL Servers don't exist." -level Information
    $resourceGroupName = "$($configuration.CommonSettings.ResourceGroupRoot)-$($configuration.SQL.ResourceGroupSuffix)"
    foreach ($btServer in $configuration.SQL.Servers) 
    {       
        $vm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $btServer -ErrorAction SilentlyContinue
        if ($null -ne $vm) 
        {
            Write-Log -message "SQL Server '$btServer' already exists in '$resourceGroupName'" -level Error
            $configIsValid = $false
        }
    }
    #Virtual network
    Write-Log -message "Validating Virtual network." -level Information
    $vnet = Get-AzVirtualNetwork -Name $configuration.CommonSettings.VirtualNetwork -ResourceGroupName $configuration.CommonSettings.VirtualNetworkResourceGroup -ErrorAction SilentlyContinue
    if ($null -eq $vnet) 
    {
        Write-Log -message "Virtual network '$($configuration.CommonSettings.VirtualNetwork)' not found in '$($configuration.CommonSettings.VirtualNetworkResourceGroup)'" -level Error
        $configIsValid = $false
    }
    else {
        Write-Log -message "Validating Subnet." -level Information
        $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $configuration.CommonSettings.Subnet }
        if ($null -eq $subnet) {
            Write-Log -message "Virtual network '$($configuration.CommonSettings.VirtualNetwork)' in '$($configuration.CommonSettings.VirtualNetworkResourceGroup)' don't contain subnet '$($configuration.CommonSettings.Subnet)'" -level Error
            $configIsValid = $false
        }
    }

    return $configIsValid
}
##################################
# Main code
##################################

# Load modules, MinimumVersion is the one used when the script was created
Import-Module Az.Accounts -MinimumVersion 1.9.2 -Force
Import-Module Az.Compute -MinimumVersion 4.2.1 -Force
Import-Module Az.Storage -MinimumVersion 2.4.0 -Force
Import-Module Az.Resources -MinimumVersion 2.3.0 -Force
Import-Module Az.Network -MinimumVersion 3.3.0 -Force


# Timestamp string used for logfiles etc.
$timestamp = [System.DateTime]::Now.ToString("yyyyMMdd_HHmmss")

$configuration = Get-Configuration -fullPathToFile $ConfigurationFile  -exitOnError
$configIsValid = Confirm-Configuration -configuration $configuration
if ($configIsValid) {
    Write-Log -message "Configuration file $ConfigurationFile is valid." -level Information
    #New-BizTalkServers -configuration $configuration
    #New-SQLServers -configuration $configuration
}
else {
    Write-Log -message "Configuration file $ConfigurationFile is not valid." -level Error
}



