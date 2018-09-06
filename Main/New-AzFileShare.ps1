<#
    .SYNOPSIS
        New-AzFileShare helps create a new Azure File share
            
    .DESCRIPTION
        Using the storage account name along with the container/sharename, New-AzFileShare will create Azure file share.
     
    .EXAMPLE
		Create an azure file share called "MyAzFileShare" under the storage account "MyStorageAcc"

		PS | C:\Users\ | 02-28-2018 23:14:27 > New-AzFileShare -ShareName "MyAzFileShare" -StorageAccountName "MyStorageAcc" -ResourceGroupName "MyRG"
#>

function New-AzFileShare {

	[CmdletBinding( 
		SupportsShouldProcess=$True, 
		ConfirmImpact="Low"  
	)]

	Param(
		[Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
		[ValidateNotNullOrEmpty()]
		[string]$StorageAccountName,

		[Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
		[ValidateNotNullOrEmpty()]
		[string]$ResourceGroupName,

		[Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
		[ValidateNotNullOrEmpty()]
		[Alias("Name")]
		[string]$ShareName

	)

	try {
		#getting storage account context & creating the share.
		$storAcc = Get-AzureRmStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
		New-AzureStorageShare -Name $ShareName -Context $storAcc.Context
	} 
	catch {
		throw $__
	}
}