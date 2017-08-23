<#PSScriptInfo

.VERSION 1.0.0.2

.GUID 7269a91a-eab7-43c7-ae64-1722ff9a15cd

.AUTHOR Microsoft Corporation

.COMPANYNAME Microsoft Corporation

.EXTERNALMODULEDEPENDENCIES

.TAGS Windows,ReverseDSC,PSDesiredStateConfiguration

.RELEASENOTES

* Added support for Files and Folders;
#>

#Requires -Modules @{ModuleName="ReverseDSC";ModuleVersion="1.7.3.0"}

<# 

.DESCRIPTION 
 Extracts the DSC Configuration of an existing environment, allowing you to analyze it or to replicate it.

#> 

param(
    [System.String[]] $RegistryPaths,
    [Hashtable[]] $Folders
    )

<## Script Settings #>
$VerbosePreference = "SilentlyContinue"

<## Scripts Variables #>
$Script:allEntries = @()
$Script:dscConfigContent = ""
$Script:DSCPath = "C:\Windows\system32\WindowsPowerShell\v1.0\Modules\PSDesiredStateConfiguration\" 
$Script:configName = "CoreEnvironment"

<# Retrieves Information about the current script from the PSScriptInfo section above #>
try {
    $currentScript = Test-ScriptFileInfo $SCRIPT:MyInvocation.MyCommand.Path
    $Script:version = $currentScript.Version.ToString()
}
catch {
    $Script:version = "N/A"
}

<## This is the main function for this script. It acts as a call dispatcher, calling the various functions required in the proper order to 
    get the full picture of the environment; #>
function Orchestrator
{        
    <# Import the ReverseDSC Core Engine #>
    $ReverseDSCModule = "ReverseDSC.Core.psm1"
    $module = (Join-Path -Path $PSScriptRoot -ChildPath $ReverseDSCModule -Resolve -ErrorAction SilentlyContinue)
    if($module -eq $null)
    {
        $module = "ReverseDSC"
    }    
    Import-Module -Name $module -Force
    
    
    $Script:dscConfigContent += "<# Generated with SQLServer.Reverse " + $script:version + " #>`r`n"   
    $Script:dscConfigContent += "Configuration $Script:configName`r`n"
    $Script:dscConfigContent += "{`r`n"

    Write-Host "Configuring Dependencies..." -BackgroundColor DarkGreen -ForegroundColor White
    Set-Imports

    $Script:dscConfigContent += "    Node $env:COMPUTERNAME`r`n"
    $Script:dscConfigContent += "    {`r`n"
    
    if($null -ne $RegistryPaths)
    {
        Write-Host "Scanning [Registry]..." -BackgroundColor DarkGreen -ForegroundColor White
        Read-Registry -Paths $RegistryPaths
    }

    if($null -ne $Folders)
    {
        Write-Host "Scanning [Files and Folders]..." -BackgroundColor DarkGreen -ForegroundColor White
        Read-FilesAndFolders -Paths $Folders
    }

    Write-Host "Configuring Local Configuration Manager (LCM)..." -BackgroundColor DarkGreen -ForegroundColor White
    Set-LCM

    $Script:dscConfigContent += "`r`n    }`r`n"           
    $Script:dscConfigContent += "}`r`n"

    Write-Host "Setting Configuration Data..." -BackgroundColor DarkGreen -ForegroundColor White
    Set-ConfigurationData

    $Script:dscConfigContent += "$Script:configName -ConfigurationData `$ConfigData"
}

#region Reverse Functions
function Read-Registry($Paths)
{    
    $module = Resolve-Path ($Script:DSCPath + "\DSCResources\MSFT_RegistryResource\MSFT_RegistryResource.psm1")
    Import-Module $module
    $params = Get-DSCFakeParameters -ModulePath $module
    
    foreach($path in $Paths)
    {
        SetupProvider -KeyName ([ref]$path)
        $keys = Get-Item $path    
        foreach($key in $keys)
        {
            <# Setting Primary Keys #>
            $params.Key = $key.Name      

            foreach($prop in $key.Property)
            {
                $params.ValueName = $prop
                $results = Get-TargetResource @params

                if($results.Ensure -ne "Absent")
                {
                    $fullEntryName = $key.Name + "\" + $prop
                    if(!$Script:allEntries.Contains($fullEntryName))
                    {
                        $Script:allEntries += $fullEntryName
                        Write-Host "$key.Name\$prop"
                        $Script:dscConfigContent += "        Registry " + [System.Guid]::NewGuid().toString() + "`r`n"
                        $Script:dscConfigContent += "        {`r`n"
                        $Script:dscConfigContent += Get-DSCBlock -Params $results -ModulePath $module
                        $Script:dscConfigContent += "        }`r`n"
                    }
                }
            }
        }

        $subKeys = Get-ChildItem $Path
        foreach($subkey in $subKeys)
        {
            Read-Registry -Path $subkey.Name
        }
    }
}

function Read-FilesAndFolders($Paths)
{    
    foreach($path in $Paths)
    {        
        $root = Get-Item $path.Source # For Verification
        if($null -ne $root)
        {
            $files = Get-ChildItem -Path $path.Source -Recurse
            
            foreach($file in $files)
            {
                Read-SubFilesAndFolders $file -Source $path.Source -Shared $path.SharedSource
            }
        }
    }
}

function Read-SubFilesAndFolders($file, $Source, $Shared)
{
    Write-Host $file.FullName
    $root = Get-Item $file.FullName # For Verification
    $Script:dscConfigContent += "        File " + [System.Guid]::NewGuid().toString() + "`r`n"
    $Script:dscConfigContent += "        {`r`n"
    $Script:dscConfigContent += "            DestinationPath = '" + $file.FullName + "';`r`n"        
    if($root.PSIsContainer)
    {
        $Script:dscConfigContent += "            Type = 'Directory';`r`n"
        $Script:dscConfigContent += "            Recurse = `$True;`r`n"
    }
    else
    {
        $Script:dscConfigContent += "            Type = 'File';`r`n"
    }

    # Do a check to see if we need to replace the source path with a SharedSource instead;
    if($null -ne $Shared)
    {
        $Source = $file.FullName.Replace($Source, $Shared)
    }

    $Script:dscConfigContent += "            SourcePath = '" + $Source + "';`r`n"
    $Script:dscConfigContent += "            Ensure = 'Present';`r`n"
    $Script:dscConfigContent += "        }`r`n"
}
#endregion

# Sets the DSC Configuration Data for the current server;
function Set-ConfigurationData
{
    $Script:dscConfigContent += "`$ConfigData = @{`r`n"
    $Script:dscConfigContent += "    AllNodes = @(`r`n"    

    $tempConfigDataContent += "    @{`r`n"
    $tempConfigDataContent += "        NodeName = `"$env:COMPUTERNAME`";`r`n"
    $tempConfigDataContent += "        PSDscAllowPlainTextPassword = `$true;`r`n"
    $tempConfigDataContent += "        PSDscAllowDomainUser = `$true;`r`n"
    $tempConfigDataContent += "    }`r`n"    

    $Script:dscConfigContent += $tempConfigDataContent
    $Script:dscConfigContent += ")}`r`n"
}

<## This function ensures all required DSC Modules are properly loaded into the current PowerShell session. #>
function Set-Imports
{
    $Script:dscConfigContent += "    Import-DscResource -ModuleName PSDesiredStateConfiguration`r`n"
}

<## This function sets the settings for the Local Configuration Manager (LCM) component on the server we will be configuring using our resulting DSC Configuration script. The LCM component is the one responsible for orchestrating all DSC configuration related activities and processes on a server. This method specifies settings telling the LCM to not hesitate rebooting the server we are configurating automatically if it requires a reboot (i.e. During the SharePoint Prerequisites installation). Setting this value helps reduce the amount of manual interaction that is required to automate the configuration of our SharePoint farm using our resulting DSC Configuration script. #>
function Set-LCM
{
    $Script:dscConfigContent += "        LocalConfigurationManager"  + "`r`n"
    $Script:dscConfigContent += "        {`r`n"
    $Script:dscConfigContent += "            RebootNodeIfNeeded = `$True`r`n"
    $Script:dscConfigContent += "        }`r`n"
}


<# This function is responsible for saving the output file onto disk. #>
function Get-ReverseDSC()
{
    <## Call into our main function that is responsible for extracting all the information about our environment; #>
    Orchestrator

    <## Prompts the user to specify the FOLDER path where the resulting PowerShell DSC Configuration Script will be saved. #>
    $fileName = "PSDesiredStateConfiguration.DSC.ps1"
    $OutputDSCPath = Read-Host "Please enter the full path of the output folder for DSC Configuration (will be created as necessary)"
    
    <## Ensures the specified output folder path actually exists; if not, tries to create it and throws an exception if we can't. ##>
    while (!(Test-Path -Path $OutputDSCPath -PathType Container -ErrorAction SilentlyContinue))
    {
        try
        {
            Write-Output "Directory `"$OutputDSCPath`" doesn't exist; creating..."
            New-Item -Path $OutputDSCPath -ItemType Directory | Out-Null
            if ($?) {break}
        }
        catch
        {
            Write-Warning "$($_.Exception.Message)"
            Write-Warning "Could not create folder $OutputDSCPath!"
        }
        $OutputDSCPath = Read-Host "Please Enter Output Folder for DSC Configuration (Will be Created as Necessary)"
    }
    <## Ensures the path we specify ends with a Slash, in order to make sure the resulting file path is properly structured. #>
    if(!$OutputDSCPath.EndsWith("\") -and !$OutputDSCPath.EndsWith("/"))
    {
        $OutputDSCPath += "\"
    }

    <## Save the content of the resulting DSC Configuration file into a file at the specified path. #>
    $outputDSCFile = $OutputDSCPath + $fileName
    $Script:dscConfigContent | Out-File $outputDSCFile
    Write-Output "Done."
    <## Wait a couple of seconds, then open our $outputDSCPath in Windows Explorer so we can review the glorious output. ##>
    Start-Sleep 2
    Invoke-Item -Path $OutputDSCPath
}

FUNCTION SetupProvider
{
    param
	(	        
        [ValidateNotNull()]		
		[ref] $KeyName
    )

    # Fix $KeyName if required
    if (!$KeyName.Value.ToString().Contains(":"))
    {
        if ($KeyName.Value.ToString().StartsWith("hkey_users","OrdinalIgnoreCase"))
        {
	        $KeyName.Value =  $KeyName.Value.ToString() -replace "hkey_users", "HKUS:"	
        }
        elseif ($KeyName.Value.ToString().StartsWith("hkey_current_config","OrdinalIgnoreCase"))
        {            
	        $KeyName.Value =  $KeyName.Value.ToString() -replace "hkey_current_config", "HKCC:"
        }
        elseif ($KeyName.Value.ToString().StartsWith("hkey_classes_root","OrdinalIgnoreCase"))
        {         
	        $KeyName.Value =  $KeyName.Value.ToString() -replace "hkey_classes_root", "HKCR:"
        }
        elseif ($KeyName.Value.ToString().StartsWith("hkey_local_machine","OrdinalIgnoreCase"))
        {         
	        $KeyName.Value =  $KeyName.Value.ToString() -replace "hkey_local_machine", "HKLM:"
        }
        elseif ($KeyName.Value.ToString().StartsWith("hkey_current_user","OrdinalIgnoreCase"))
        {         
	        $KeyName.Value =  $KeyName.Value.ToString() -replace "hkey_current_user", "HKCU:"
        }
        else
        {
            $errorMessage = $localizedData.InvalidRegistryHiveSpecified -f $Key
            ThrowError -ExceptionName "System.ArgumentException" -ExceptionMessage $errorMessage -ExceptionObject $KeyName -ErrorId "InvalidRegistryHive" -ErrorCategory InvalidArgument
        }        
    }            
}

Get-ReverseDSC
