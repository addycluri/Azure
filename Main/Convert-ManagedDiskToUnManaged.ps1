<#
    .SYNOPSIS
        Convert-ManagedToUnManaged converts the attached storage of a VM from managed --> unmanaged
		**PLEASE BE ADVISED THERE WILL BE DOWNTIME INCURRED ON THE VM **
            
    .DESCRIPTION
        Convert-ManagedToUnManaged can be used in a scenario where one needs to  change the storage type of a VM from Managed To Unmanaged either for a migration temporarily or for any other purposes.

        The typical workflow of this process is as follows.
            - Get the current VMObject
            - Delete the current VM to release the locks/Leases on the managed disks. (All data like OS & Data disks are preserved although some aspects like VM extensions, ETC. have to be reconfigured later on)
            - Create a temporary storage account to store the VHD's in the same resource group where the OS disk currently resides.
            - COPY all OS & Data disks to the temp storage account
            - update the VMObject with the new VHD URI's
            - re-create the VM using VMobject       
    
    .EXAMPLE
        Convert the attached disks from managed --> unmanaged for a VM called MY-VM in the MY-RG resourceGroup.
		
		PS | C:\Users\ > Convert-ManagedToUnManaged -TenantId blahacb5-a79a-4ca7-87eb-c5e6ebbbcd00 -SubscriptionId bl9ahe24-769d-44f2-92ff-4e0fb55d2f01 -VMName "MY-VM" -ResourceGroupName "MY-RG" -verbose
#>

function Convert-ManagedDiskToUnmanaged {
	
	[CmdletBinding( 
		SupportsShouldProcess=$True, 
		ConfirmImpact="Low"  
	)]

	Param(
		[Parameter(Mandatory=$true)] 
		[string]$TenantId,

		[Parameter(Mandatory=$true)]
		[string]$SubscriptionId,

		[Parameter(Mandatory=$true)]
		[Alias("ResourceGroupName")] 
		[string]$RGName,

		[Parameter(Mandatory=$true)]
		[string]$VMName,

		[Parameter(Mandatory=$false)]
		[string]$Clenaup

	)


	function Convert-ToUnManagedDisk {
		Param(
			[Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
			[ValidateNotNullOrEmpty()]
			[PSObject]$diskProfile,

			[Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
			[ValidateNotNullOrEmpty()]
			[PSObject]$StorageAccount,

			[Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
			[ValidateNotNullOrEmpty()]
			[PSObject]$StorageAccContext,

			[Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
			[ValidateNotNullOrEmpty()]
			[Array]$ManagedDisks,

			[Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
			[ValidateNotNullOrEmpty()]
			[PSObject]$OldVMObject,

			[Parameter(ValueFromPipelineByPropertyName=$true)]
			[ValidateNotNullOrEmpty()]
			[int]$DataDiskLun

		)

		begin {
			$diskPurpose = $null
			$diskType = $null
			$vhdURI = $null
			$newVMObject = $null

			# getting the container object
			try {
				$storageAccountContainer = Get-AzureStorageContainer -Context $StorageAccContext -Name "vhds"
			} catch {
				Write-Log $_ -Level Error -Path $logf
				Exit
			}

			#settting disk profiles
			if ($diskProfile.OSType -ne $null) {
				$diskPurpose = "OS DISK"
			} else {
				$diskPurpose = "DATA DISK"
			}

			#creating a new VMObject to map the disk properties
			$newVMObject = $OldVMObject
			$newVMObject.StorageProfile.OsDisk = $null
		}

		process {

			if ($diskProfile.ManagedDisk -ne $null) {
            
				$diskType = "MANAGED"

				try {
					Write-Log "$diskPurpose of type $diskType Found - $($diskProfile.Name). Will convert this to an unmanaged disk" -Level Warn -Path $logf
                        
					#granting access to managed disk and initiating copy process to new temp storage account
					Write-Log "Granting access to managed Disk: $($DiskProfile.ManagedDisk.Id)" -Path $logf
					$mDiskObj = $ManagedDisks | Where-Object {$_.Id -eq $DiskProfile.ManagedDisk.Id }
					$vhdname = $mDiskObj.Name + ".vhd"

					$DebugPreference = 'Continue'
					$sas = Grant-AzureRmDiskAccess -ResourceGroupName $mDiskObj.ResourceGroupName -DiskName $mDiskObj.Name -Access Read -DurationInSecond 7200 5>&1
					$DebugPreference = 'SilentlyContinue'
					$sasUri = ((($sas | where {$_ -match "accessSAS"})[-1].ToString().Split("`n") | where {$_ -match "accessSAS"}).Split(' ') | where {$_ -match "https"}).Replace('"','')

					Write-Log "Copying managed disk to temporary storage account - $($StorageAccount.Name) " -Path $logf
					$copy = Start-AzureStorageBlobCopy -AbsoluteUri $sasUri -DestContainer $storageAccountContainer.Name -DestContext $StorageAccContext -DestBlob $vhdname
        
					Do {
						$state = Get-AzureStorageBlobCopyState -Blob $vhdname -Container $storageAccountContainer.Name -Context $StorageAccContext
						Sleep -s 10
					}
					Until ($state.Status -ne "Pending")
        
					if ($state.Status -ne "Success") {
						Write-Log "Copy job failed" -Level Error -Path $logf
						$state | ConvertTo-Json | Write-Log
						Exit
					}
                
					Write-Log "Copy job complete" -Path $logf
					$vhdURI = $StorageAccount.PrimaryEndpoints.Blob + $storageAccountContainer.Name + "/" + $vhdname
					Write-Log "Temp Disk VHDURI: $vhdURI" -Path $logf

				} catch {
					Write-Log $_ -Level Error -Path $logf
					Exit                
				}
			}

			# If the disks are UN-MANAGED. We do nothing
			else {
				$diskType = "UN-MANAGED"
				Write-Log "$diskPurpose of type $diskType Found: $($diskProfile.Name). NO action item so skipping" -Level Warn -Path $logf
				$vhdURI = $diskProfile.Vhd.Uri
				Write-Log "$diskPurpose VHDURI: $vhduri" -Path $logf
			}

			#updating $newVMObject with the new Disks
			try {
				$name = $null
				$name = $vhdURI.ToString().Substring($vhdURI.lastIndexOf("/")+1)
                
				#Attaching OS disks
				if ($diskPurpose -eq "OS DISK") {
					if($diskProfile.OSType -eq "Windows") {
						Write-Log "Attaching WINDOWS `"$diskPurpose`" - $vhdURI to $($newVMObject.Name)" -Path $logf
						$newVMObject =  Set-AzureRmVMOSDisk -VM $newVMObject -Name $name -VhdUri $vhdURI -DiskSizeInGB $diskProfile.DiskSizeGB -CreateOption Attach -Windows
                        
					} else {
						Write-Log "Attaching LINUX `"$diskPurpose`" -  $vhdURI to $($newVMObject.Name)" -Path $logf
						$newVMObject =  Set-AzureRmVMOSDisk -VM $newVMObject -Name $name -VhdUri $vhdURI -DiskSizeInGB $diskProfile.DiskSizeGB -CreateOption Attach -Linux
					}
				} 
				#Attaching Data disks
				elseif ($diskPurpose -eq "DATA DISK") {
					Write-Log "Attaching $vhdURI to $($newVMObject.Name) at LUN - $DataDiskLun" -Path $logf
					$newVMObject =  Add-AzureRmVMDataDisk -VM $newVMObject -Name $name -VhdUri $vhdURI -Lun $DataDiskLun -DiskSizeInGB $diskProfile.DiskSizeGB -CreateOption Attach
				}
            
			} catch {
				Write-Log $_ -Level Error -Path $logf
				Exit
			}
			#return the newdisk object
			return $newVMObject
		}
	}


	################################ MAIN #################################################################

	#variable intializations
	$subscription = $null
	$vmObject = $null
	$vmResult = $null
	$mDiskList = $null
	$managedDisk = $null

	function Generate-AzureStorageAccountName {
		Param()

		$tempName = $null
		$available = $false

		Write-Log "Generating Temporary Storage Account Name" -Path $logf

		Do {
			$tempName = (New-Guid).Guid.ToString().Replace("-","").Substring(0,3) + $VMName.Replace("-","").ToLower()
			$available = (Get-AzureRmStorageAccountNameAvailability -Name $tempName).NameAvailable
		}
		Until ($available)
   
		return $tempName
	}
	$vhdSku = $null
	$vmStatus = $null
	$logf = $PWD.Path + "\$($VMName)-ManagedToUnmanaged-" + $(Get-Date -uFormat %m%d%Y-%H%M%S) + ".TXT"

	Write-Log "Parameters:" -Path $logf
	Write-Log "tenandId: $TenantId" -Path $logf
	Write-Log "subscriptionId: $subscriptionId" -Path $logf
	Write-Log "ResourceGroupName: $RGName" -Path $logf
	Write-Log "VMName: $VMName" -Path $logf

	#Select Subscription
	Write-Log "Getting subscription: $subscriptionId for tenant: $TenantId"  -Path $logf
	$subscription = Select-AzureRmSubscription -TenantId $TenantId -SubscriptionId $subscriptionId

	if($subscription -eq $null) {
		Write-Log "Error getting subscription: $subscriptionId" -Level Error -Path $logf
		Exit
	}

	#Get VM
	Write-Log "Getting vm: $VMName in resource group: $RGName" -Path $logf
	$vmObject = Get-AzureRmVM -ResourceGroupName $RGName -Name $VMName

	#proceed with the execution only if the VMObject is returned
	if($vmObject -eq $null) {
		Write-Log "Error getting VM object: $VMName" -Level Error -Path $logf
		break
	} else {
		Write-log "vmObject:" -Path $logf
		$vmObject | ConvertTo-Json | Write-Log -Path $logf

		#Check VM agent status
		Write-Log "Checking VM agent status" -Path $logf
		$vmStatus = Get-AzureRmVM -ResourceGroupName $rgName -Name $vmName -Status
		if($vmStatus.vmAgent -ne $null) {
			if($vmStatus.VMAgent.Statuses.Code -Match "ProvisioningState/succeeded" -and $vmStatus.VMAgent.Statuses.DisplayStatus -eq "Ready") {
				Write-Log "VM agent is in Ready state. Proceeding." -Path $logf
			}
			else {
				Write-Log "VM agent is not in Ready state. Please logonto the VM and ensure that the `"Windows Azure Guest Agent`" service is running. Exiting." -Path $logf
				break
			}
		}
		else {
			Write-Log "Cannot determine VM agent status. Confirm that the agent is installed and communicating with Azure - https://docs.microsoft.com/en-us/azure/virtual-machines/windows/agent-user-guide. Exiting." -Path $logf
			break
		}

		if($vmObject.StorageProfile.ImageReference -ne $null) {
			Write-Log "VM has image reference. Reference will be removed for the storage conversion process" -Level Warn -Path $logf
			$vmObject.StorageProfile.ImageReference = $null
		}

		if($vmObject.OSProfile -ne $null) {
			Write-Log "VM has OS profile. Settings will be removed for the storage conversion process" -Level Warn -Path $logf
			$vmObject.OSProfile = $null
		}

		#setting the disk Objects
		$osDisk = $vmObject.StorageProfile.OSDisk
		$dataDisks = $vmObject.StorageProfile.DataDisks
		$mDiskList = Get-AzureRmDisk

		#deleting the existing VM and release all Locks / ETC.
		try {
			Write-Log "Removing VM: $VMName" -Level Warn -Path $logf
			$vmResult = Remove-AzureRmVM -ResourceGroupName $vmObject.ResourceGroupName -Name $vmObject.Name -Force
		} catch {
			Write-Log "Error deleting VM." -Level Error -Path $logf
			$vmResult | ConvertTo-Json | Write-Log -Level Error -Path $logf
			Exit
		}

		#creating a temporary storage account using the properties of the OS disk to host the un-managed VHDs
		$tempStorName = Generate-AzureStorageAccountName
		$managedDisk =  $mDiskList | Where-Object {$_.Id -eq $osDisk.ManagedDisk.Id }
		$vhdSku = $managedDisk.Sku.Name
		Write-Log "Creating temporary storage account: $tempStorName in ResourceGroup: $($managedDisk.ResourceGroupName) of Sku:$vhdSku" -Path $logf
		$tempStorageAcc = New-AzureRmStorageAccount -ResourceGroupName "$($managedDisk.ResourceGroupName)" -Name $tempStorName -Location $managedDisk.Location -SkuName $vhdSku -Kind Storage
		$tempStorageAccountKey = (Get-AzureRmStorageAccountKey -ResourceGroupname $tempStorageAcc.ResourceGroupName -Name $tempStorageAcc.StorageAccountName).value[0]
		$tempStorageAccountContext = New-AzureStorageContext -StorageAccountName $tempStorageAcc.StorageAccountName -StorageAccountKey $tempStorageAccountKey
		$tempStorageAccountContainer = New-AzureStorageContainer -Context $tempStorageAccountContext -Name "vhds"

		#resetting the $vmObject.StorageProfile properties
		$vmObject.StorageProfile.OsDisk = $null
		$vmObject.StorageProfile.DataDisks = $null
        
		#converting OS disk from  managed to unmanaged disks and attaaching new disks to the VM
		$newVM = Convert-ToUnManagedDisk -DiskProfile $osDisk -StorageAccount $tempStorageAcc -StorageAccContext $tempStorageAccountContext -managedDisks $mDiskList -OldVMObject $vmObject

		#converting DATA disks from managed to unmanaged disks and attaching them to the $newVM object(already has the OSDisk attached)
		$lun = 0
		foreach ($dataDisk in $dataDisks) {
			$newVM = Convert-ToUnManagedDisk -DiskProfile $dataDisk -StorageAccount $tempStorageAcc -StorageAccContext $tempStorageAccountContext -managedDisks $mDiskList -OldVMObject $newVM -DataDiskLun $lun
			$lun++
		}
    
		#re-create the VM
		Write-Log "Re-Creating the VM using the new un-managed OS + Data Disks" -Path $logf
		New-AzureRmVM -VM $newVM -ResourceGroupName $newVM.ResourceGroupName -Location $newVM.Location
		if (!$?) {
			Write-Log $_ -Level Error -Path $logf
			Exit
		}
		Write-Log "VM $($newVM.Name) created" -Path $logf
		Write-Log "Recommended to clean up the old Managed Disks" -Path $logf
		Write-Log "--END: Convert-ManagedToUnManaged for $VMName" -Path $logf
	}
}