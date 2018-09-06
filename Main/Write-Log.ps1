<#
    .SYNOPSIS
        Function to help log data to a file.
            
    .DESCRIPTION
        Write-Log can be used to append/log data from your operations to a log file (.log/ .txt / .csv) along with data classification (info/warning/error)
     
    .EXAMPLE
		Write "Hello world" as a warning text to HelloWorld.Log at c:\temp with TimeStamp & data classification details.

		PS | C:\Users\ > "Hello world" | Write-Log -Path  c:\temp\HelloWorld.log -Level Warn

		PS | C:\Users\ > Write-Log -Message "Hello World" -Path c:\temp\HelloWorld.log -Level Warn

	.EXAMPLE
		Write "Hello world" as a warning text to HelloWorld.Log at c:\temp without TimeStamp & data classification details.

		PS | C:\Users\ > "Hello world" | Write-Log -Path  c:\temp\HelloWorld.log -Noformat

		PS | C:\Users\ > Write-Log -Message "Hello World" -Path c:\temp\HelloWorld.log -Noformat
#>

function Write-Log {

	[CmdletBinding( 
		SupportsShouldProcess=$True, 
		ConfirmImpact="Low"  
	)]

	Param(
		[Parameter(Mandatory=$true,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)] 
		[ValidateNotNullOrEmpty()]
		[Alias("LogContent")] 
		[string]$Message, 

		[Parameter(Mandatory=$true)] 
		[Alias("LogPath")]
		[string]$Path, 
         
		[Parameter(Mandatory=$false)] 
		[ValidateSet("Error","Warn","Info")] 
		[string]$Level="Info",

		[Parameter(Mandatory=$false)] 
		[Switch]$Noformat
	)

	begin {
		if(!(Test-Path $Path)) {
			Write-Verbose "Creating LogFile: $Path"
			New-Item $Path -Force -ItemType File | Out-Null
		}
	}

	process {
		$FormattedDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
		switch ($Level) { 
			'Error' { 
				Write-Error $Message 
				$LevelText = 'ERROR:' 
				} 
			'Warn' { 
				Write-Warning $Message 
				$LevelText = 'WARNING:' 
				} 
			'Info' { 
				Write-Verbose $Message
				$LevelText = 'INFO:' 
				} 
		}
		
		if ($Noformat) {
			"$Message" | Out-File -FilePath $Path -Encoding default -Append
		} else {
			"$FormattedDate $LevelText $Message" | Out-File -FilePath $Path -Encoding default -Width 17384 -Append
		}		
	}
}