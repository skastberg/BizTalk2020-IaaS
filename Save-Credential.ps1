
$cred = Get-Credential -Message "Credential to save"
$fileName = Read-Host -Prompt "Filename, extension .xml will be added by the script"

$cred | Export-Clixml -path "$PSScriptRoot\$fileName.xml" -Encoding utf8 -Confirm

