<#
    .SYNOPSIS
        Convert-UnManagedToManaged converts the attached storage of a VM from unmanaged-->managed. 
		**please be advised there will be VM downtime**
		
    .DESCRIPTION
        Convert-UnManagedToManaged can be used in a scenario where one needs to change the storage type of a VM either for a migration or for any other purposes.
        
		The typical workflow is as follows.
            - Stop the current VM 
			- Break the disk lease to release all locks
            - Disk conversion by creating a new managed disk VM object from blob.VHD
            - Update the VMObject with the new ManagedDiskId
            - Start the VM back up
    
    .EXAMPLE
        Convert the attached disks of VM "MY-VM" from unmanaged --> managed in the MY-RG resourceGroup.
		
		PS | C:\Users\ > Convert-UnManagedToManaged -TenantId blahacb5-a79a-4ca7-87eb-c5e6ebbbcd00 -SubscriptionId bl9ahe24-769d-44f2-92ff-4e0fb55d2f01 -VMName "MY-VM" -ResourceGroupName "MY-RG" -verbose
#>

function Convert-UnManagedDiskToManaged {

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
		[string]$VMName
	)

	function Convert-ToManagedDisk {
		Param(
			[Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
			[ValidateNotNullOrEmpty()]
			[PSObject]$diskProfile,

			[Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
			[ValidateNotNullOrEmpty()]
			[PSObject]$OldVMObject,

			[Parameter(ValueFromPipelineByPropertyName=$true)]
			[ValidateNotNullOrEmpty()]
			[int]$DataDiskLun,

			[Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
			[ValidateNotNullOrEmpty()]
			[Array]$vhdList
		)

		begin {
			$diskPurpose = $null
			$diskType = $null
			$newVMObject = $null
			$storageAcc = $null
			$vhdURI = $null
			$vhdSKU = $null
			$managedDiskConfig = $null
			$newManagedDisk = $null
        
			#settting disk profiles
			if ($diskProfile.OSType -ne $null) {
				$diskPurpose = "OS DISK"
			} else {
				$diskPurpose = "DATA DISK"
			}

			#creating a new VMObject to map the disk properties
			$newVMObject = $OldVMObject
			$newVMObject.StorageProfile.OSDisk = $null
			$newVMObject.StorageProfile.DataDisks = $null
		}

		process {

			if ($diskProfile.ManagedDisk -eq $null) {            
				$diskType = "UN-MANAGED"
				try {
					#get the storage account name & SKU
					$vhdURI = $diskProfile.VHD.URI.ToString()
					$storageAccName = $vhdURI.Split(".")[0].Replace("https://","") 
					#$storageAccName = ($vhdURI.Substring(0,$vhdURI.IndexOf("."))).Replace("https://","")
					$containerName = $vhdURI.Split("/")[3]
					$blobName = $vhdURI.Split("/")[4]
					$storageAcc = $vhdList | ? {$_.StorageAccountName -eq "$storageAccName" }
					$vhdSKU = $storageAcc.Sku.Name.ToString().Insert($storageAcc.Sku.Name.ToString().Length-3,"_")
                
				} catch {
					Write-Log "Error Getting Storage account details" -Level Error -Path $logf
					Write-Log $_ -Level Error -Path $logf
					Exit
				}

				#breaking the lease on the VHD blob
				try {
					$storageAccessKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $storageAcc.ResourceGroupName -Name $storageAcc.StorageAccountName).Value[0]
					$storageContext = New-AzureStorageContext -StorageAccountName $storageAcc.StorageAccountName -StorageAccountKey $storageAccessKey -ErrorAction Stop
					$blob = Get-AzureStorageBlob -Context $storageContext -Container $containerName -Blob $blobName -ErrorAction Stop
					$leaseStatus = $blob.ICloudBlob.Properties.LeaseStatus

					If($leaseStatus -eq "Locked") {
						$blob.ICloudBlob.BreakLease() 
						Write-Host "Successfully broken lease on $BlobName" 
					} else { 
						#$blob.ICloudBlob.AcquireLease($null, $null, $null, $null, $null) 
						Write-Host "The $BlobName lease is already unlocked" 
					}
				} catch {
					$_ | Write-Log -Path $logf -Level Error
					Exit
				}
            
				Write-Log "Converting unmanaged disk to managed disk + Building Disk configuration " -Path $logf
				try {
                
					$managedDiskConfig = New-AzureRmDiskConfig -AccountType $vhdSKU -Location $storageAcc.Location -CreateOption Import -StorageAccountId $storageAcc.id -SourceUri $vhdURI       
					$newManagedDisk = New-AzureRmDisk -Disk $managedDiskConfig -ResourceGroupName $storageAcc.ResourceGroupname -DiskName $($diskProfile.Name)
                
					if ($diskPurpose = "OS DISK") {                
						if ($diskProfile.OsType -eq "Windows") {
							Write-Log "Attaching WINDOWS `"$diskPurpose`" - $($newManagedDisk.Name) to $($newVMObject.Name)" -Path $logf
							$newVMObject = Set-AzureRmVMOSDisk -VM $newVMObject -ManagedDiskId $newManagedDisk.Id -StorageAccountType $vhdSKU -DiskSizeInGB $diskProfile.DiskSizeGB -CreateOption Attach -Windows
						}
						else {
							Write-Log "Attaching LINUX `"$diskPurpose`" -  $($newManagedDisk.Name) to $($newVMObject.Name)" -Path $logf
							$newVMObject = Set-AzureRmVMOSDisk -VM $newVMObject -ManagedDiskId $newManagedDisk.Id -StorageAccountType $vhdSKU -DiskSizeInGB $diskProfile.DiskSizeGB -CreateOption Attach -Linux
						}
					}
					elseif ($diskPurpose = "DATA DISK") {
						Write-Log "Attaching $vhdURI to $($newVMObject.Name) at LUN - $DataDiskLun" -Path $logf
						$newVMObject = Add-AzureRmVMDataDisk -VM $newVMObject -ManagedDiskId $newManagedDisk.Id -StorageAccountType $vhdSKU -Lun $DataDiskLun -DiskSizeInGB $diskProfile.DiskSizeGB -CreateOption Attach
					}
				} catch {
					Write-Log $_ -Level Error -Path $logf
					continue
				} 
			} else {
				$diskType = "MANAGED"
				Write-Log "$diskPurpose of type $diskType Found: $($diskProfile.Name). NO action item so skipping" -Level Warn -Path $logf
				$vhdURI = $diskProfile.ManagedDisk.Id
				Write-Log "$diskPurpose VHDURI: $vhduri" -Path $logf
			}

			#return the updated VMObject
			return $newVMObject                   
		}
	}

################################ MAIN #################################################################

	#variable intializations
	$subscription = $null
	$vmObject = $null
	$vmResult = $null
	$logf = $PWD.Path + "\$($VMName)-UnmanagedToManaged-" + $(Get-Date -uFormat %m%d%Y-%H%M%S) + ".TXT"

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

	#Get VMObject
	Write-Log "Getting vm: $VMName in resource group: $RGName" -Path $logf
	$vmObject = Get-AzureRmVM -ResourceGroupName $RGName -Name $VMName
	if($vmObject -eq $null) {
		Write-Log "Error getting VM: $VMName" -Level Error -Path $logf
		Exit
	} 
	
	Write-log "vmObject:" -Path $logf
	$vmObject | ConvertTo-Json | Write-Log -Path $logf

	#Stop the VM if it is running
	$vmstatus = $vmObject | Get-AzureRmVM -Status
	if ($vmstatus.Statuses[1].Code -ne "PowerState/deallocated") {
		$stopVM = Invoke-VMTask -vmobj $vmObject -operation Stop
		if ($stopVM -eq $false) {
			exit
		}
	}

	#setting the disk Objects
	$osDisk = $vmObject.StorageProfile.OSDisk
	$dataDisks = $vmObject.StorageProfile.DataDisks
	$vhds = Get-AzureRmStorageAccount
	
	#converting OS disk from  un-managed to managed disks and attaaching to the VM
	$newVM = Convert-ToManagedDisk -DiskProfile $osDisk -OldVMObject $vmObject -VHDList $vhds

	#converting DATA disks from un-managed to managed disks and attaching them to the $newVM object(already has the OSDisk attached)
	$lun = 0
	foreach ($dataDisk in $dataDisks) {
		$newVM = Convert-ToManagedDisk -DiskProfile $dataDisk -OldVMObject $newVM -VHDList $vhds -DataDiskLun $lun 
		$lun++
	}
    
	#re-create the VM
	Write-Log "Re-Creating the VM using the new managed OS + Data Disks" -Path $logf
	New-AzureRmVM -VM $newVM -ResourceGroupName $newVM.ResourceGroupName -Location $newVM.Location
	if (!$?) {
		Write-Log $_ -Level Error -Path $logf
		Exit
	}
	Write-Log "VM $($newVM.Name) created" -Path $logf
	Write-Log "Recommended to clean up the old un-Managed Disks from the storage accounts" -Path $logf
	Write-Log "--END: Convert-UnManagedToManaged for $VMName" -Path $logf
}