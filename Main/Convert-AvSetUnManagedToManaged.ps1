<#
    .SYNOPSIS
	    Convert-AvSetUnManagedToManaged converts an existing un-managed Availability Set to managed 
		**PLEASE BE ADVISED THERE WILL BE VM DOWNTIME **
            
    .DESCRIPTION
        Convert-AvSetUnManagedToManaged can be used in a scenario where one needs to convert the un-managed disks of the VM's in an availability set to managed.

        The typical workflow of this process is as follows.
            - Get the Availability set object and update the AV set type to managed 
			- Stop's each unmanaged VM in the AV set
            - converts the VM disks to managed & turns VM on.  
    
    .EXAMPLE
        Converts the VM disks in the Availability set called "MY-AVSet" from unm-managed (blob VHD) to manaaged.
		
		PS | C:\Users > Convert-AvSetUnManagedToManaged -AvailabilitySetName "MY-AVSet" -ResourceGroupName "MY-RG" -Verbose
#>

function Convert-AvSetUnmanagedToManaged {

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
		[string]$AvailabilitySetName
	)

	################################ MAIN #################################################################

	#variable intializations
	$subscription = $null
	$avsObject = $null
	$logf = $PWD.Path + "\$($AvailabilitySetName)-UnmanagedToManaged-" + $(Get-Date -uFormat %m%d%Y-%H%M%S) + ".TXT"

	Write-Log "Parameters:" -Path $logf
	Write-Log "ResourceGroupName: $RGName" -Path $logf
	Write-Log "AV-SetName: $AvailabilitySetName" -Path $logf

	#Get the av-set
	Write-Log "Getting AV-Set: $AvailabilitySetName in resource group: $RGName" -Path $logf
	$avsObject = Get-AzureRmAvailabilitySet -ResourceGroupName $RGName -Name $AvailabilitySetName

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

			#update the AV-set type
			Update-AzureRmAvailabilitySet -AvailabilitySet $avsObject -Managed

			#starting the conversion process for each VM in the availability set. 
			foreach ($avsVM in $avsVMs) {

				$vmObject = $null
				$vmObject = Get-AzureRmVM -ResourceGroupName $RGName | Where-Object {$_.Id -eq $avsVM.Id}

				#stopping the VM
				$stopVM = Invoke-VMTask -vmobj $vmObject -Operation Stop
				if ($stopVM -eq $false) {
					exit
				}
            
				try {
					#converting the VM disks
					Write-log "Converting VM - $($vmObject.Name) to managed disk" -Path $logf
					ConvertTo-AzureRmVMManagedDisk -ResourceGroupName $RGName -VMName $vmObject.Name -Verbose
				} catch {
					$_ | Write-Log -Level Error -Path $logf
					exit
				}
            
			}

		}
	}
}