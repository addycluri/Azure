﻿<#
    .SYNOPSIS
        Convert-AvSetManagedToUnManaged converts existing un-managed Availability Set to managed
		**PLEASE BE ADVISED THERE WILL BE VM DOWNTIME **
        
    .DESCRIPTION
        Convert-AvSetManagedToUnManaged can be used in a scenario where one needs to convert the managed disks of the VM's in an availability set to un-managed (ex: for migrating across 

        The typical workflow of this process is as follows.
            - Get the Availability set object
			- Create a new unmanaged AV set (AVSetName will have -unmanaged appended)
			- Gets the current VM Object and deletes the VM (to release disk locks)
            - converts the VM disks to unmanaged binds them to the AVSet & turns them on.         
    
    .EXAMPLE
        Converts the VM disks in the Availability set called "MY-AVSet" from managed to to un-manaaged (blob VHD) 
		PS | C:\Users> Convert-AvSetManagedToUnManaged -AvailabilitySetName "MY-AVSet" -ResourceGroupName "MY-RG" -verbose

#>

function Convert-AVSetManagedToUnManaged {

	[CmdletBinding( 
		SupportsShouldProcess=$True, 
		ConfirmImpact="Low"  
	)]

	Param(
		[Parameter(Mandatory=$true)]
		[Alias("ResourceGroupName")] 
		[string]$RGName,

		[Parameter(Mandatory=$true)]
		[Alias("AVSet")]
		[string]$AvailabilitySetName,

		[Parameter(ValueFromPipelineByPropertyName=$true)]
		[string]$Logfile

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
			[PSObject]$diskObject,

			[Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
			[ValidateSet("OSDISK","DATADISK")]
			[PSObject]$diskPurpose,

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
			$diskType = $null
			$vhdURI = $null
			$newVMObject = $null

			# getting the container object
			try {
				$storageAccountContainer = Get-AzureStorageContainer -Context $StorageAccContext -Name "vhds"
			} catch {
				Write-Log $_ -Level Error -Path $logf
				break
			}

			#creating a new VMObject to map the disk properties
			$newVMObject = $OldVMObject
		}

		process {

			# If disk is managed we convert to unmanaged.
			if ($diskObject.ManagedDisk -ne $null) {
            
				$diskType = "MANAGED"

				try {
					Write-Log "$diskPurpose of type $diskType Found - $($diskObject.Name). Will convert this to an unmanaged disk" -Level Warn -Path $logf
                        
					#granting access to managed disk and initiating copy process to new temp storage account
					Write-Log "Granting access to managed Disk: $($diskObject.ManagedDisk.Id)" -Path $logf
					$mDiskObj = $ManagedDisks | Where-Object {$_.Id -eq $diskObject.ManagedDisk.Id }
					$vhdname = $mDiskObj.Name + ".vhd"
					$sasUri = (Grant-AzureRmDiskAccess -ResourceGroupName $mDiskObj.ResourceGroupName -DiskName $mDiskObj.Name -Access Read -DurationInSecond 7200).AccessSAS
					Write-Log "SASUri generated for managed Disk: $($diskObject.Name)" -Path $logf
					Write-Log "Copying managed disk to temporary storage account - $($StorageAccount.StorageAccountName) " -Path $logf
					$copy = Start-AzureStorageBlobCopy -AbsoluteUri $sasUri -DestContainer $storageAccountContainer.Name -DestContext $StorageAccContext -DestBlob $vhdname
        
					Do {
						$state = Get-AzureStorageBlobCopyState -Blob $vhdname -Container $storageAccountContainer.Name -Context $StorageAccContext
						Sleep -s 10
					}
					Until ($state.Status -ne "Pending")
        
					if ($state.Status -ne "Success") {
						Write-Log "Copy job failed" -Level Error -Path $logf
						$state | ConvertTo-Json | Write-Log
						break
					}
                
					Write-Log "Copy job complete" -Path $logf
					$vhdURI = $StorageAccount.PrimaryEndpoints.Blob + $storageAccountContainer.Name + "/" + $vhdname
					Write-Log "$diskPurpose VHDURI: $vhdURI" -Path $logf
					
				} catch {
					Write-Log $_ -Level Error -Path $logf
					break                
				}
			} else {
				# If the disks are UN-MANAGED. We do nothing
				$diskType = "UN-MANAGED"
				Write-Log "$diskPurpose of type $diskType Found: $($diskObject.Name). No changes required" -Level Warn -Path $logf
				$vhdURI = $diskObject.Vhd.Uri
				Write-Log "$diskPurpose VHDURI: $vhduri" -Path $logf
			}

			# Attaching / handling the new un-managed disks
			try {
				$name = $null
				$name = $vhdURI.ToString().Substring($vhdURI.lastIndexOf("/")+1)

				if ($diskPurpose -eq "OSDISK") {
					if($diskObject.OSType -eq "Windows") {
						Write-Log "Attaching WINDOWS `"$diskPurpose`" - $vhdURI to $($newVMObject.Name)" -Path $logf
						$newVMObject =  Set-AzureRmVMOSDisk -VM $newVMObject -Name $name -VhdUri $vhdURI -DiskSizeInGB $diskObject.DiskSizeGB -CreateOption Attach -Windows -ErrorAction Stop
                        
					} else {
						Write-Log "Attaching LINUX `"$diskPurpose`" -  $vhdURI to $($newVMObject.Name)" -Path $logf
						$newVMObject =  Set-AzureRmVMOSDisk -VM $newVMObject -Name $name -VhdUri $vhdURI -DiskSizeInGB $diskObject.DiskSizeGB -CreateOption Attach -Linux -ErrorAction Stop
					}

					return $newVMObject
				}
				if ($diskPurpose -eq "DATADISK") {
					Write-Log "Adding $vhdURI to VM - $($newVMObject.Name)" -Path $logf
					Add-AzureRmVMDataDisk -VM $newVMObject -Name $name -VhdUri $vhdURI -Lun $DataDiskLun -DiskSizeInGB $diskObject.DiskSizeGB -CreateOption Attach -ErrorAction Continue
					Update-AzureRmVM -ResourceGroupName $newVMObject.ResourceGroupName -VM $newVMObject -ErrorAction Stop
				}
			} 
			catch {
				Write-Log $_ -Level Error -Path $logf
				break
			}			
		}
	}


	################################ MAIN #################################################################

	#variable intializations
	$subscription = $null
	$avsObject = $null
	if (-not $logfile) {
		$logf = $PWD.Path + "\$($AvailabilitySetName)-ManagedToUnmanaged-" + $(Get-Date -uFormat %m%d%Y-%H%M%S) + ".TXT"
	}

	Write-Log "Parameters:" -Path $logf
	Write-Log "ResourceGroupName: $RGName" -Path $logf
	Write-Log "AV-SetName: $AvailabilitySetName" -Path $logf

	#Get the av-set
	Write-Log "Getting AV-Set: $AvailabilitySetName in resource group: $RGName" -Path $logf
	$avsObject = Get-AzureRmAvailabilitySet -ResourceGroupName $RGName -Name $AvailabilitySetName

	#proceed with the execution only if the AV-Object is returned
	if($avsObject -eq $null) {
		Write-Log "Error getting AV-Set object: $AvailabilitySetName" -Level Error -Path $logf
		break
	} else {    
		Write-log "AV-set Object:" -Path $logf
		$avsObject | ConvertTo-Json | Write-Log -Path $logf
      
		#check for VMs in the AV-Set
		$avsVMs = $avsObject.VirtualMachinesReferences
		if ($avsVMs.Count -eq 0) {
			Write-Log "No VMs found in the AV-Set : $AvailabilitySetName. breaking" -Path $logf
			break
		} else {
			#create a new un-managed AV-set
			try {            
				$newAvsObject = New-AzureRmAvailabilitySet -Location $avsObject.location -Name ($avsObject.Name + "-unmanaged") -ResourceGroupName $avsObject.ResourceGroupName -PlatformFaultDomainCount $avsObject.PlatformFaultDomainCount -PlatformUpdateDomainCount $avsObject.PlatformUpdateDomainCount
				Write-log "Created an un-managed Availability Set to support un-managed disks - $($newAvsObject.Name)" -Path $logf            
			}  catch {
				$_ | Write-Log -Level Error -Path $logf
				break
			}

			#starting the conversion process for each VM in the availability set. 
			Write-log "converting $($avsVMs.Count) VMs in $AvailabilitySetName" -Path $logf
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
				             
				#proceed with the execution only if the VMObject is returned
				Write-log "converting VM $($avsVM.Id) in $AvailabilitySetName" -Path $logf
				$vmObject = Get-AzureRmVM -ResourceGroupName $RGName | Where-Object {$_.Id -eq $avsVM.Id}
				if($vmObject -eq $null) {
					Write-Log "Error getting VM object: $($avsVM.Id)" -Level Error -Path $logf
					break
				} 

				Write-log "vmObject:" -Path $logf
				$vmObject | ConvertTo-Json | Write-Log -Path $logf

				#Check VM agent status
				Write-Log "Checking VM agent status for $($vmObject.Name)" -Path $logf
				$vmStatus = Get-AzureRmVM -ResourceGroupName $RGName -Name $vmObject.Name -Status
				if($vmStatus.vmAgent -ne $null) {
					if($vmStatus.VMAgent.Statuses.Code -Match "ProvisioningState/succeeded" -and $vmStatus.VMAgent.Statuses.DisplayStatus -eq "Ready") {
						Write-Log "VM agent is in Ready state. Proceeding." -Path $logf
					}
					else {
						Write-Log "VM agent is not in Ready state. Please logonto the VM and ensure that the `"Windows Azure Guest Agent`" service is running. breaking." -Path $logf
						break
					}
				}
				else {
					Write-Log "Cannot determine VM agent status. Confirm that the agent is installed and communicating with Azure - https://docs.microsoft.com/en-us/azure/virtual-machines/windows/agent-user-guide. breaking." -Path $logf
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
					Write-Log "Removing VM: $($vmObject.Name)" -Level Warn -Path $logf
					$vmResult = Remove-AzureRmVM -ResourceGroupName $vmObject.ResourceGroupName -Name $vmObject.Name -Force
				} catch {
					Write-Log "Error deleting VM." -Level Error -Path $logf
					$vmResult | ConvertTo-Json | Write-Log -Level Error -Path $logf
					break
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
				$newVM = Convert-ToUnManagedDisk -DiskObject $osDisk -DiskPurpose "OSDISK" -StorageAccount $tempStorageAcc -StorageAccContext $tempStorageAccountContext -managedDisks $mDiskList -OldVMObject $vmObject

				#updating the AvailabilitySetReference for the $newVM to attach to the av-set during creation time.
				$newVM.AvailabilitySetReference.Id = $newAvsObject.Id

				# re-create the VM with the new OS disk. (Since creating VM with un-managed "data" disks is not supported using the CLI)
				Write-Log "Re-Creating the VM using the new un-managed OS Disk and referencing the unmanaged AV-set $($newAvsObject.Id)" -Path $logf
				New-AzureRmVM -VM $newVM -ResourceGroupName $newVM.ResourceGroupName -Location $newVM.Location -ErrorAction Stop
				if (!$?) {
					Write-Log $_ -Level Error -Path $logf
					break
				}
				Write-Log "VM $($newVM.Name) created" -Path $logf
				Write-Log "sleep 75 Seconds for the VM properties to be refreshed" -Path $logf
				Start-Sleep -Seconds 75

				#Get the new VMobject
				$newVM = Get-AzureRmVM -ResourceGroupName $newVM.ResourceGroupName -Name $newVM.Name
				$newVM.StorageProfile.DataDisks = $null
				
				# converting DATA disks from managed to unmanaged disks, attach them to the $newVM object(already has the OSDisk attached) and restart the VM
				$lun = 0
				$umDataDisk = $null
				foreach ($dataDisk in $dataDisks) {
					Write-Log "converting $($dataDisk.Name) to unmanaged" -Path $logf
					Convert-ToUnManagedDisk -DiskObject $dataDisk -DiskPurpose "DATADISK" -StorageAccount $tempStorageAcc -StorageAccContext $tempStorageAccountContext -managedDisks $mDiskList -DataDiskLun $lun -OldVMObject $newVM
					$lun++
				}
			}
			Write-Log "Recommended to clean up the old AV-Set, Managed Disks AND add/reconfigure VM extensions, other dependencies if present earlier" -Path $logf
			Write-Log "--END: Convert-AVSetManagedToUnManaged for $AvailabilitySetName" -Path $logf
		}
	}
}