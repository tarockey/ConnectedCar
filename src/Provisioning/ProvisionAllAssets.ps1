#Requires -Version 3.0
<#
.SYNOPSI
Provision an Azure Storage Account and a Service Bus Event Hub.

.DESCRIPTION
This script will create and configure the required Event Hub And Azure storage assets to be able to run the sample. The script outputs the configuration keys and values that need to be replaced in the mysettings.config configuration file.
Important: Make sure you use these values in the mysettings.config and the service configuration files before running the sample with the Azure Emulator or deploying the sample to Azure.

.PARAMETER SubscriptionName
The name of the subscription to use.

.PARAMETER ServiceBusNamespace
The name of Service Bus namespace.

.PARAMETER ServiceBusEventHubPath
The name of the event hub.

.PARAMETER Location
The location of the storage account.

.PARAMETER PartitionCount
The number of partitions to use. Defaults to 16.

.PARAMETER MessageRetentionInDays
The number of days the messages will be retained.

.PARAMETER ColdStorageCounsumerGroupName
The name of the consumer group for the Cold Storage processor.

.PARAMETER ColdStorageContainerName
the name of the blob container where cold data will be stored.

.PARAMETER PoisonMessagesContainerName
The name of the blob container where poison messages will be stored.

.PARAMETER DispatcherConsumerGroupName
The name of the consumer group used by the dispatcher.

.PARAMETER StorageAccountName
The name of the storage account used by the sample.

#>

[CmdletBinding(PositionalBinding=$True)]
Param(
  [string] [Parameter(Mandatory=$true)] $ResourceGroupLocation,
  [string] $ResourceGroupName = 'ContosoStorage',  
  [switch] $UploadArtifacts,
  [string] $StorageAccountResourceGroupName, 
  [string] $StorageContainerName = $ResourceGroupName.ToLowerInvariant() + '-stageartifacts',
  [string] $TemplateFile = '..\Templates\DeploymentTemplate.json',
  [string] $TemplateParametersFile = '..\Templates\DeploymentTemplate.param.dev.json',
  [string] $ArtifactStagingDirectory = '..\bin\Debug\staging',
  [string] $AzCopyPath = '..\Tools\AzCopy.exe',
  
  [Parameter (Mandatory = $true)]
  [string] $SubscriptionName,

  [Parameter (Mandatory = $true)]
  [ValidatePattern("^[A-Za-z][-A-Za-z0-9]*[A-Za-z0-9]$")] 
  [string] $ServiceBusNamespace,

  [Parameter (Mandatory = $true)]
  [ValidatePattern("^[A-Za-z0-9]$|^[A-Za-z0-9][\w-\.\/]*[A-Za-z0-9]$")] 
  [string] $ServiceBusEventHubPath,

  [Parameter (Mandatory = $true)]
  [ValidatePattern("^[a-z0-9]*$")]
  [String]$StorageAccountName,

  [Parameter (Mandatory = $true)]
  [string] $Location,
  
  [String]$ColdStorageConsumerGroupName = "ColdStorage.Processor",
  
  [String]$ColdStorageContainerName = "coldstorage",

  [String]$PoisonMessagesContainerName = "poison-messages",

  [String]$DispatcherConsumerGroupName = "Dispatcher",

  [Int]$PartitionCount = 16,

  [Int]$MessageRetentionInDays = 1    
      
)


Import-Module Azure -ErrorAction SilentlyContinue

try {
  [Microsoft.Azure.Common.Authentication.AzureSession]::ClientFactory.AddUserAgent("VSAzureTools-$UI$($host.name)".replace(" ","_"), "2.7")
} catch { }

Set-StrictMode -Version 3

$OptionalParameters = New-Object -TypeName Hashtable
$TemplateFile = [System.IO.Path]::Combine($PSScriptRoot, $TemplateFile)
$TemplateParametersFile = [System.IO.Path]::Combine($PSScriptRoot, $TemplateParametersFile)

if ($UploadArtifacts)
{
    # Convert relative paths to absolute paths if needed
    $AzCopyPath = [System.IO.Path]::Combine($PSScriptRoot, $AzCopyPath)
    $ArtifactStagingDirectory = [System.IO.Path]::Combine($PSScriptRoot, $ArtifactStagingDirectory)

    Set-Variable ArtifactsLocationName '_artifactsLocation' -Option ReadOnly
    Set-Variable ArtifactsLocationSasTokenName '_artifactsLocationSasToken' -Option ReadOnly

    $OptionalParameters.Add($ArtifactsLocationName, $null)
    $OptionalParameters.Add($ArtifactsLocationSasTokenName, $null)

    # Parse the parameter file and update the values of artifacts location and artifacts location SAS token if they are present
    $JsonContent = Get-Content $TemplateParametersFile -Raw | ConvertFrom-Json
    $JsonParameters = $JsonContent | Get-Member -Type NoteProperty | Where-Object {$_.Name -eq "parameters"}

    if ($JsonParameters -eq $null)
    {
        $JsonParameters = $JsonContent
    }
    else
    {
        $JsonParameters = $JsonContent.parameters
    }

    $JsonParameters | Get-Member -Type NoteProperty | ForEach-Object {
        $ParameterValue = $JsonParameters | Select-Object -ExpandProperty $_.Name

        if ($_.Name -eq $ArtifactsLocationName -or $_.Name -eq $ArtifactsLocationSasTokenName)
        {
            $OptionalParameters[$_.Name] = $ParameterValue.value
        }
    }

    if ($StorageAccountResourceGroupName)
	{
		Switch-AzureMode AzureResourceManager
	    $StorageAccountKey = (Get-AzureStorageAccountKey -ResourceGroupName $StorageAccountResourceGroupName -Name $StorageAccountName).Key1
    }
    else
	{
		Switch-AzureMode AzureServiceManagement
	    $StorageAccountKey = (Get-AzureStorageKey -StorageAccountName $StorageAccountName).Primary 
    }
    
    $StorageAccountContext = New-AzureStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey

    # Generate the value for artifacts location if it is not provided in the parameter file
    $ArtifactsLocation = $OptionalParameters[$ArtifactsLocationName]
    if ($ArtifactsLocation -eq $null)
    {
        $ArtifactsLocation = $StorageAccountContext.BlobEndPoint + $StorageContainerName
        $OptionalParameters[$ArtifactsLocationName] = $ArtifactsLocation
    }

    # Use AzCopy to copy files from the local storage drop path to the storage account container
    & "$AzCopyPath" """$ArtifactStagingDirectory"" $ArtifactsLocation /DestKey:$StorageAccountKey /S /Y /Z:""$env:LocalAppData\Microsoft\Azure\AzCopy\$ResourceGroupName"""

    # Generate the value for artifacts location SAS token if it is not provided in the parameter file
    $ArtifactsLocationSasToken = $OptionalParameters[$ArtifactsLocationSasTokenName]
    if ($ArtifactsLocationSasToken -eq $null)
    {
       # Create a SAS token for the storage container - this gives temporary read-only access to the container (defaults to 1 hour).
       $ArtifactsLocationSasToken = New-AzureStorageContainerSASToken -Container $StorageContainerName -Context $StorageAccountContext -Permission r
       $ArtifactsLocationSasToken = ConvertTo-SecureString $ArtifactsLocationSasToken -AsPlainText -Force
       $OptionalParameters[$ArtifactsLocationSasTokenName] = $ArtifactsLocationSasToken
    }
}

# Create or update the resource group using the specified template file and template parameters file
Switch-AzureMode AzureResourceManager
New-AzureResourceGroup -Name $ResourceGroupName `
                       -Location $ResourceGroupLocation `
                       -TemplateFile $TemplateFile `
                       -TemplateParameterFile $TemplateParametersFile `
                        @OptionalParameters `
                        -Force -Verbose

# Add RBAC feature to Storage Admin
# New-AzureRoleAssignment -Mail traz4499@aztp.onmicrosoft.com -RoleDefinitionName "Storage Account Contributor" -ResourceGroupName ContosoStorage




Switch-AzureMode AzureServiceManagement

# Make the script stop on error
$ErrorActionPreference = "Stop"

# Check the azure module is installed
if(-not(Get-Module -name "Azure")) 
{ 
    if(Get-Module -ListAvailable | Where-Object { $_.name -eq "Azure" }) 
    { 
        Import-Module Azure
    }
    else
    {
        "Microsoft Azure Powershell has not been installed, or cannot be found."
        Exit
    }
}

Add-AzureAccount
Select-AzureSubscription -SubscriptionName $SubscriptionName

# Provision Event Hub
.\CreateEventHub.ps1 -Namespace $ServiceBusNamespace -Path $ServiceBusEventHubPath -ColdStorageConsumerGroupName $ColdStorageConsumerGroupName -DispatcherConsumerGroupName $DispatcherConsumerGroupName -Location $Location -PartitionCount $PartitionCount -MessageRetentionInDays $MessageRetentionInDays

# Provision Storage Account
# .\ProvisionStorageAccount.ps1 -Name $StorageAccountName -Location $Location -ColdStorageContainerName $ColdStorageContainerName -PoisonMessagesContainerName $PoisonMessagesContainerName

Switch-AzureMode AzureResourceManager

# Get output
$storageAccountKey = Get-AzureStorageAccountKey -StorageAccountName $StorageAccountName
$saConnectionString = "DefaultEndpointsProtocol=https;AccountName={0};AccountKey={1}" -f $StorageAccountName, $storageAccountKey.Key1;

Switch-AzureMode AzureServiceManagement

$serviceBus = Get-AzureSBNamespace -Name $ServiceBusNamespace
$sbConnectionString = $serviceBus.ConnectionString + ";TransportType=Amqp"

""
# copy config settings to mysettings file.
$settings = @{
    'Simulator.EventHubConnectionString'=$sbConnectionString;
    'Simulator.EventHubPath'=$ServiceBusEventHubPath;
    'Dispatcher.EventHubConnectionString'=$sbConnectionString;
    'Dispatcher.ConsumerGroupName'=$DispatcherConsumerGroupName;
    'Dispatcher.CheckpointStorageAccount'=$saConnectionString;
    'Dispatcher.EventHubName'=$ServiceBusEventHubPath;
    'Dispatcher.PoisonMessageStorageAccount'=$saConnectionString;
    'Dispatcher.PoisonMessageContainer'=$PoisonMessagesContainerName;
    'Coldstorage.ConsumerGroupName'=$ColdStorageConsumerGroupName;
    'Coldstorage.CheckpointStorageAccount'=$saConnectionString;
    'Coldstorage.EventHubConnectionString'=$sbConnectionString;
    'Coldstorage.EventHubName'=$ServiceBusEventHubPath;
    'Coldstorage.BlobWriterStorageAccount'=$saConnectionString;
    'Coldstorage.ContainerName'=$ColdStorageContainerName
}

$scriptPath = Split-Path (Get-Variable MyInvocation -Scope 0).Value.MyCommand.Path

.\CopyOutputToConfigFile.ps1 -configurationFile "..\RunFromConsole\mysettings.config" -appSettings $settings

# get Cloud service configuration files 
$serviceConfigFiles = Get-ChildItem -Include "ServiceConfiguration.Cloud.cscfg" -Path "$($scriptPath)\.." -Recurse
.\CopyOutputToServiceConfigFiles.ps1 -serviceConfigFiles $serviceConfigFiles -appSettings $settings

""
"Provision and configuration complete. Please review your mysettings.config and the ServiceConfiguration.Cloud.cscfg files with the latest configuration settings."