param(
  [Parameter(Mandatory=$True)]
  [string]
  $domainName,
  [Parameter(Mandatory=$True)]
  [string]
  $adminuser,
  [Parameter(Mandatory=$True)]
  [string]
  $adminpassword
)

# Variables
$domainAdmin = "$domainName\$adminuser"

# Credential for domain
$secPassword = $adminpassword | ConvertTo-SecureString -AsPlainText -Force
$cred = New-Object –TypeName System.Management.Automation.PSCredential –ArgumentList $domainAdmin, $secPassword

Add-Computer -ComputerName $env:COMPUTERNAME -DomainName $domainName -Credential $cred -Restart 