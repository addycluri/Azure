<#
    .SYNOPSIS
        Function to help start/stop a VM
            
     
    .EXAMPLE
		Start a VM 
		PS | C:\Users\ > $vmObject = Get-AzureRmVM -ResourceGroupName "my-rg" -Name "my-vm"
		PS | C:\Users\ > Invoke-VMTask -vmobj $vmObject -operation Start

	.EXAMPLE
		Stop a VM 
		PS | C:\Users\ > $vmObject = Get-AzureRmVM -ResourceGroupName "my-rg" -Name "my-vm"
		PS | C:\Users\ > Invoke-VMTask -vmobj $vmObject -operation Stop
#>

function Invoke-VMTask {
    Param(
        [Parameter(Mandatory,ValueFromPipeline,ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()] 
        [PSObject]$vmobj,

        [Parameter(Mandatory=$true)] 
        [ValidateSet("Start","Stop")] 
        [string]$operation
    )

    #variable initialize
    $vmTask = $null

    try {
        switch ($operation) {
            "Start" {
				Write-Verbose "Starting VM - $($vmobj.Name)"
                $vmTask = $vmobj | Start-AzureRmVM -AsJob
            }
            "Stop" {
                Write-Verbose "Stopping VM - $($vmobj.Name)"
                $vmTask = $vmobj | Stop-AzureRmVM -AsJob -Force
            }
        }
    
        do {
            $vmstate = $vmobj | Get-AzureRmVM -Status
			Write-Verbose $vmstate.Statuses[1].Code
            Start-Sleep -Seconds 10
        }
        until ($vmTask.State -eq "Completed")
        Write-Verbose "Operation - $operation on VM $($vmobj.Name) successful"
    }
    catch {
        $_
        return $false
    }    
}