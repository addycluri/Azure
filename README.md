# README
This is a powershell module with custom functions designed for specific Azure related tasks rangiing from simple to complicated workflows. Users are expected to be familiar with Powershell, Azure Powershell and the ability to work with powershell modules in general.

# Pre-requisites
* Always have the latest powershell version installed. [Reference article](https://docs.microsoft.com/en-us/powershell/scripting/setup/installing-powershell?view=powershell-6)
* Install Azure powershell modules using the instructions from [here](https://docs.microsoft.com/en-us/powershell/azure/install-azurerm-ps?view=azurermps-6.8.1)

# Module Details
* Module Name = **MyAzurePowershell.psd1**
* Download / clone the repo locally to any path `EX- c:\myrepo\`
* Open powershell and import the module using `Import-Module c:\myrepo\MyAzurePowershell.psd1`
* You can now check the list of functions available to you with `Get-Command -Module MyAzurePowershell`
* To get usage help or instructions with a particular function, just type `Get-Help Function-Name -Full`

# Functions Included
**To get usage help with any function, just type  Get-Help Function-Name -Full (Ex:Get-Help Write-Log -Full)**
* **Convert-AVSetManagedToUnManaged** : converts an existing managed Availability Set to un-managed
* **Convert-AvSetUnManagedToManaged** : converts an existing un-managed Availability Set to managed
* **Convert-ManagedDiskToUnManaged** : converts the attached storage of a VM from managed --> unmanaged
* **Get-VmDiskMapping** : Gets the VM to Disk mapping details.
* **New-AzFileShare** : create a new Azure File share
* **Invoke-VMTask** : Execute operations on an Azure VM.
* **Write-Log** : Logs/writes data to an external file.

# Disclaimer
I hope that the information provided here is valuable to you. Your use of the information contained in these pages, however, is at your sole risk. All information on these pages is provided "as -is", without any warranty, whether express or implied, of its accuracy, completeness, fitness for a particular purpose, title or non-infringement, and none of the third-party products or information mentioned in the work are authored, recommended, supported or guaranteed by me. Further, I shall not be liable for any damages you may sustain by using this information, whether direct, indirect, special, incidental or consequential, even if it has been advised of the possibility of such damages. 

