<#
    .SYNOPSIS
        Convert-AvSetManagedToUnManaged converts existing managed Availability Set to un-managed
		**PLEASE BE ADVISED THERE WILL BE VM DOWNTIME **
        
    .DESCRIPTION
        Convert-AvSetManagedToUnManaged can be used in a scenario where one needs to convert the managed disks of the VM's in an availability set to un-managed (EX: for migrating across subscriptions / ETC)

        The typical workflow of this process is as follows.
            - Get the Availability set object and the list of VMs present
			- Creates a new un-managed AV-set with "-latest" appended to the AV-set.
			- Delete the current VM(s) in the AV set to release the locks/Leases on the managed disks. (All data like OS & Data disks are preserved although some aspects like VM extensions, ETC. have to be reconfigured later on)
            - converts the VM disks to unmanaged, recreates the VM with the latest VHD URI's and adds them to an av-set         
    
    .EXAMPLE
        Converts the VM disks in the Availability set called "MY-AVSet" from managed to to un-managed (blob VHD) 
		PS | C:\Users> Convert-AvSetManagedToUnManaged -AvailabilitySetName "MY-AVSet" -ResourceGroupName "MY-RG" -TenantId blahacb5-a79a-4ca7-87eb-c5e6ebbbcd00 -SubscriptionId bl9ahe24-769d-44f2-92ff-4e0fb55d2f01 -verbose

#>

function Convert-AVSetManagedToUnManaged {

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
		[Alias("AVSet")]
		[string]$AvailabilitySetName

	)

	function Generate-AzureStorageAccountName {
		Param()

		$tempName = $null
		$available = $false

		Write-Log "Generating Temporary Storage Account Name" -Path $logf

		Do {
			$tempName = (New-Guid).Guid.ToString().Replace("-","").Substring(0,6)
			$available = (Get-AzureRmStorageAccountNameAvailability -Name $tempName).NameAvailable
		}
		Until ($available)
   
		return $tempName
	}

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
			$newVMObject.StorageProfile.DataDisks = $null
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
	$avsObject = $null
	$logf = $PWD.Path + "\$($AvailabilitySetName)-ManagedToUnmanaged-" + $(Get-Date -uFormat %m%d%Y-%H%M%S) + ".TXT"

	Write-Log "Parameters:" -Path $logf
	Write-Log "tenandId: $TenantId" -Path $logf
	Write-Log "subscriptionId: $subscriptionId" -Path $logf
	Write-Log "ResourceGroupName: $RGName" -Path $logf
	Write-Log "AV-SetName: $AvailabilitySetName" -Path $logf

	#Select Subscription
	Write-Log "Getting subscription: $subscriptionId for tenant: $TenantId"  -Path $logf
	$subscription = Select-AzureRmSubscription -TenantId $TenantId -SubscriptionId $subscriptionId

	if($subscription -eq $null) {
		Write-Log "Error getting subscription: $subscriptionId" -Level Error -Path $logf
		Exit
	}

	#Get the av-set
	Write-Log "Getting AV-Set: $AvailabilitySetName in resource group: $RGName" -Path $logf
	$avsObject = Get-AzureRmAvailabilitySet -ResourceGroupName $RGName -Name $AvailabilitySetName

	#proceed with the execution only if the AV-Object is returned
	if($avsObject -eq $null) {
		Write-Log "Error getting AV-Set object: $AvailabilitySetName" -Level Error -Path $logf
		Exit
	} else {
    
		Write-log "AV-set Object:" -Path $logf
		$avsObject | ConvertTo-Json | Write-Log -Path $logf
      
		#check for VMs in the AV-Set
		$avsVMs = $avsObject.VirtualMachinesReferences
		if ($avsVMs.Count -eq 0) {
			Write-Log "No VMs found in the AV-Set : $AvailabilitySetName. Exiting" -Path $logf
			Exit
		} else {

			#create a new un-managed AV-set
			try {
            
				$newAvsObject = New-AzureRmAvailabilitySet -Location $avsObject.location -Name ($avsObject.Name + "-updated") -ResourceGroupName $avsObject.ResourceGroupName -PlatformFaultDomainCount $avsObject.PlatformFaultDomainCount -PlatformUpdateDomainCount $avsObject.PlatformUpdateDomainCount
				Write-log "Created an un-managed Availability Set to support un-managed disks - $($newAvsObject.Name)" -Path $logf
            
			}  catch {
				$_ | Write-Log -Level Error -Path $logf
				exit
			}

			#starting the conversion process for each VM in the availability set. 
			Write-log "coonverting $($avsVMs.Count) VMs in $AvailabilitySetName" -Path $logf
			foreach ($avsVM in $avsVMs) {
            
				$vmObject = $null
				$vmResult = $null
				$vmStatus = $null
				$mDiskList = $null
				$managedDisk = $null
				$vhdSku = $null
				$osDisk = $null
				$dataDisks = $null
				$newVM = $null
				$tempStorName = $null
				$tempStorageAcc = $null
				$tempStorageAccountKey = $null
				$tempStorageAccountContext = $null
				$tempStorageAccountContainer = $null
				$vmObject = Get-AzureRmVM -ResourceGroupName $rgName | Where-Object {$_.Id -eq $avsVM.Id}
                                   
				#Check VM agent status
				Write-Log "Checking VM agent status for $($vmObject.Name)" -Path $logf
				$vmStatus = Get-AzureRmVM -ResourceGroupName $rgName -Name $vmObject.Name -Status
				if($vmStatus.vmAgent -ne $null) {
					if($vmStatus.VMAgent.Statuses.Code -Match "ProvisioningState/succeeded" -and $vmStatus.VMAgent.Statuses.DisplayStatus -eq "Ready") {
						Write-Log "VM agent is in Ready state. Proceeding." -Path $logf
					}
					else {
						Write-Log "VM agent is not in Ready state. Please logonto the VM and ensure that the `"Windows Azure Guest Agent`" service is running. Exiting." -Path $logf
						Exit
					}
				}
				else {
					Write-Log "Cannot determine VM agent status. Confirm that the agent is installed and communicating with Azure - https://docs.microsoft.com/en-us/azure/virtual-machines/windows/agent-user-guide. Exiting." -Path $logf
					Exit
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
					Write-Log "Removing VM: $($vmObject.Name)" -Level Warn -Path $logf
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
           
				#converting OS disk from  managed to unmanaged disks and attaaching new disks to the VM
				$newVM = Convert-ToUnManagedDisk -DiskProfile $osDisk -StorageAccount $tempStorageAcc -StorageAccContext $tempStorageAccountContext -managedDisks $mDiskList -OldVMObject $vmObject

				#converting DATA disks from managed to unmanaged disks and attaching them to the $newVM object(already has the OSDisk attached)
				$lun = 0
				foreach ($dataDisk in $dataDisks) {
					$newVM = Convert-ToUnManagedDisk -DiskProfile $dataDisk -StorageAccount $tempStorageAcc -StorageAccContext $tempStorageAccountContext -managedDisks $mDiskList -OldVMObject $newVM -DataDiskLun $lun
					$lun++
				}

				#updating the AvailabilitySetReference for the $newVM to attach to the av-set during creation time.
				$newVM.AvailabilitySetReference.Id = $newAvsObject.Id

				#re-create the VM
				Write-Log "Re-Creating the VM using the new un-managed OS + Data Disks + attaching to unmanaged AV-Set - $($newAvsObject.Name)" -Path $logf
				New-AzureRmVM -VM $newVM -ResourceGroupName $newVM.ResourceGroupName -Location $newVM.Location
				if (!$?) {
					Write-Log $_ -Level Error -Path $logf
					Exit
				}
				Write-Log "VM -- $($newVM.Name) created" -Path $logf            
			}
			Write-Log "Recommended to clean up the old AV-Set & Managed Disks" -Path $logf
			Write-Log "--END: Convert-AVSetManagedToUnManaged for $AvailabilitySetName" -Path $logf
		}
	}
}