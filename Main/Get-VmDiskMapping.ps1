<#
    .SYNOPSIS
        Get-VMDiskMapping Gets the VM to Disk mapping details.
            
    .DESCRIPTION
        Get-VMDiskMapping Gets the list of Virtual Machinnes <--> attached Disk type information from the Azure ternant or a specific Resource Group. 
		There is console output along with data exported to a CSV.
     
    .EXAMPLE
		Get the VM-Disk mapping for all virtual machines in a particular subscription
		
		PS | C:\Users\ > Get-VMDiskMapping -Verbose
                    
    .EXAMPLE
        Get the VM-Disk mapping for all virtual machines in Resource group called MY-RG
		
		PS | C:\Users\ > Get-VMDiskMapping -ResourceGroupName "My-RG" -Verbose    
#>

function Get-VmDiskMapping {
	
	[CmdletBinding( 
		SupportsShouldProcess=$True, 
		ConfirmImpact="Low"  
	)]

	Param(
		[Parameter()]
		[Alias("ResourceGroupName")]
		[string]$RGName
	)

	$Logf = $PWD.Path + "\GetVMDiskMapping-$RGName" + ".CSV"
	Write-Output "VMNAME,VM-RG,DISK-NAME,DISK-PURPOSE,DISK-TYPE,VHD-URI,DISK-RG,DISK-SIZE(GB)" | Write-Log -Path $logf -NoFormat

	function GetDiskDetails {
    
		[CmdletBinding( 
				SupportsShouldProcess=$True, 
				ConfirmImpact="Low"  
		)]

		param(
			[Parameter(Mandatory=$true)] 
			[PSObject]$diskObject,

			[Parameter(Mandatory=$true)] 
			[PSObject]$VMDetail
        
		)

		begin {
			$disk = $null
			$diskName = $null
			$diskPurpose = $null
			$diskSize = $null
			$diskURI = $null
			$diskType = $null
			$diskRG = $null
        
			#get the Storage accounts in the susbscription
			$storageAcc = Get-AzureRmStorageAccount
		}

		process {

			# getting disk information
			foreach ($disk in $diskObject) {
            
				$finalDiskDetails = $null
				$diskName = $disk.Name
            
				if ($disk.OsType -ne $null) {
					$diskPurpose = "OS DISK"
				} else {
					$diskPurpose = "DATA DISK"
				}

				if ($disk.ManagedDisk -ne $null) {

					$managedDiskObj = $null
					$diskType = "MANAGED"
					$diskURI = $disk.ManagedDisk.Id
					$managedDiskObj = Get-AzureRmDisk | Where-Object {$_.Name -match $diskName }
					$diskRG = $managedDiskObj.ResourceGroupName
					$diskSize = $managedDiskObj.DiskSizeGB

				} else {
					$diskType = "UN-MANAGED"
					$diskURI = $disk.VHD.Uri
					$diskSize = $disk.DiskSizeGB
                    
					foreach ($acc in $storageAcc) {
						if ($diskURI -match $acc.StorageAccountName) {
							$diskRG = $acc.ResourceGroupName
							break
					   } else {
							$diskRG = "NOT FOUND"
						}
					}
				}
            
				$finalDiskDetails = New-Object -TypeName PSObject
				$finalDiskDetails | Add-Member -MemberType NoteProperty -Name DiskName -Value $diskName
				$finalDiskDetails | Add-Member -MemberType NoteProperty -Name DiskPurpose -Value $diskPurpose
				$finalDiskDetails | Add-Member -MemberType NoteProperty -Name DiskType -Value $diskType
				$finalDiskDetails | Add-Member -MemberType NoteProperty -Name DiskURI -Value $diskURI
				$finalDiskDetails | Add-Member -MemberType NoteProperty -Name DiskSize -Value $diskSize
				$finalDiskDetails | Add-Member -MemberType NoteProperty -Name DiskRG -Value $diskRG
            
				Write-Host "DISK NAME - "  $finalDiskDetails.DiskName
				Write-Host "DISK PURPOSE - "  $finalDiskDetails.DiskPurpose
				Write-Host "DISK TYPE - "   $finalDiskDetails.DiskType
				Write-Host "DISK VHD URI - "  $finalDiskDetails.DiskURI
				Write-Host "DISK SIZE - "  $finalDiskDetails.DiskSize
				Write-Host "DISK RG - "   $finalDiskDetails.DiskRG
				Write-Host " "
				Write-Output "$($VMDetail.Name),$($VMDetail.ResourceGroupName),$( $finalDiskDetails.DiskName),$( $finalDiskDetails.DiskPurpose),$( $finalDiskDetails.DiskType),$( $finalDiskDetails.DiskURI),$( $finalDiskDetails.DiskRG),$( $finalDiskDetails.DiskSize)" | Write-Log -Path $logf -Noformat
			}   
		}
	}

################################ MAIN #################################################################

	#Get ALL VMs or the ones in the RG specified
	if ($RGName) {
		$VMs = Get-AzureRmVM -ResourceGroupName $RGName
	}
	else {
		$VMs = Get-AzureRmVM
	}

	foreach ($VM in $VMs) {
    
		Write-Host " "
		Write-Host "VMNAME - " $VM.Name
		Write-Host "VM-RG - " $VM.ResourceGroupName
    
		if(($VM.StorageProfile).Count -gt 0) {

			# getting disk(s) information
			$ODisks = $VM.StorageProfile.OsDisk
			$DataDisks = $VM.StorageProfile.DataDisks
        
			GetDiskDetails -diskObject $ODisks -VMDetail $VM
			GetDiskDetails -diskObject $DataDisks -VMDetail $VM
        
			Write-Host "***********************************************************************************"
		} else {
			Write-Host "No Storage Profile found for VM - $($VM.Name)" -ForegroundColor Red
		}         
	}

	#Open the downloaded CSV Report
	Invoke-Item -Path $Logf
}

