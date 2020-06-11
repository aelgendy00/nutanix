<#
.SYNOPSIS
  Start a Nutanix Files failover (planned or unplanned) from one Nutanix cluster to another.
.DESCRIPTION
  Given a file server name, assuming protection domain and replication to another site is already in place, do a planned or unplanned failover of a Nutanix Files file server instance from one site to another.  The script will migrate or activate the protection domain, activate the file server and can also trigger DNS update.  The script is designed to be able to work also with a reference file so that it can be used to facilitate DR automation.
.PARAMETER help
  Displays a help message (seriously, what did you think this was?)
.PARAMETER history
  Displays a release history for this script (provided the editors were smart enough to document this...)
.PARAMETER log
  Specifies that you want the output messages to be written in a log file as well as on the screen.
.PARAMETER debugme
  Turns off SilentlyContinue on unexpected error messages.
.PARAMETER prism
  Nutanix cluster fully qualified domain name or IP address (source or target; the script will figure out which is which).
.PARAMETER username
  Username used to connect to the Nutanix cluster.
.PARAMETER password
  Password used to connect to the Nutanix cluster.
.PARAMETER prismCreds
  Specifies a custom credentials file name (will look for %USERPROFILE\Documents\WindowsPowerShell\CustomCredentials\$prismCreds.txt). These credentials can be created using the Powershell command 'Set-CustomCredentials -credname <credentials name>'. See https://blog.kloud.com.au/2016/04/21/using-saved-credentials-securely-in-powershell-scripts/ for more details.
.PARAMETER failover
  Specifies the type of failover (valid entries are planned or unplanned).
.PARAMETER fsname
  Name of the file server instance you want to failover.
.PARAMETER reference
  (Optional) Path to the reference file containing the following information in csv format: fsname,prism-primary,prism-dr,primary-client-network-name,primary-client-network-subnet,primary-client-network-gateway,primary-client-network-startip,primary-client-network-endip,primary-storage-network-name,primary-storage-network-subnet,primary-storage-network-gateway,primary-storage-network-startip,primary-storage-network-endip,dr-client-network-name,dr-client-network-subnet,dr-client-network-gateway,dr-client-network-startip,dr-client-network-endip,dr-storage-network-name,dr-storage-network-subnet,dr-storage-network-gateway,dr-storage-network-startip,dr-storage-network-endip,prismcreds,adcreds,pd,smtp,email,primary-dns-servers,primary-ntp-servers,dr-dns-servers,dr-ntp-servers
  If any of the client or storage networks are AHV managed, you do not need to specify values for the network name, subnet, gateway, startip and endip.
  The script will always look for a reference file in the current directory called <fsname>-reference.csv and use it if available.  Otherwise, it will prompt the user for the necessary information.
.PARAMETER pd
  (Optional) Name of protection domain for the file server instance (assumed name if NTNX-<file-server-name>).
.PARAMETER dns
  (Optional) Specifies that you want to trigger a DNS update after the file server has been activated (works only if your DNS server is a Microsoft DNS server).
.PARAMETER adcreds
  (Required if -dns) Name of credentials file for Active Directory (required for DNS update).  If the credentials file does not exist, you will be prompted for credentials.
.PARAMETER mail
  (Optional) Specifies that you want to notify by email when the script takes action.
.PARAMETER smtp
  (Required if -mail) FQDN or IP of the SMTP server to use for sending emails.
.PARAMETER email
  (Required if -mail) Comma separated list of email addresses to notify.
.EXAMPLE
.\Invoke-NutanixFilesDr.ps1 -fsname myfileserver -failover unplanned
Do an unplanned failover of a file server called myfileserver.  All reference information will be obtained from myfileserver.csv in the current directory:
.LINK
  http://www.nutanix.com/services
.NOTES
  Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
  Revision: June 8th 2020
#>

#region parameters
    Param
    (
        #[parameter(valuefrompipeline = $true, mandatory = $true)] [PSObject]$myParam1,
        [parameter(mandatory = $false)] [switch]$help,
        [parameter(mandatory = $false)] [switch]$history,
        [parameter(mandatory = $false)] [switch]$log,
        [parameter(mandatory = $false)] [switch]$debugme,
        [parameter(mandatory = $false)] [string]$prism,
        [parameter(mandatory = $false)] [string]$username,
        [parameter(mandatory = $false)] [string]$password,
        [parameter(mandatory = $false)] $prismCreds,
        [parameter(mandatory = $true)] [ValidateSet("planned","unplanned","deactivate")] [string]$failover,
        [parameter(mandatory = $false)] [string]$fsname,
        [parameter(mandatory = $false)] [string]$reference,
        [parameter(mandatory = $false)] [string]$pd,
        [parameter(mandatory = $false)] [switch]$dns,
        [parameter(mandatory = $false)] $adCreds,
        [parameter(mandatory = $false)] [switch]$mail,
        [parameter(mandatory = $false)] [string]$smtp,
        [parameter(mandatory = $false)] [string]$email,
        [parameter(mandatory = $false)] [switch]$force
    )
#endregion

#region functions
    function Invoke-NtnxPdMigration
    {
        <#
        .SYNOPSIS
        Triggers an asynchronous protection domain migration.
        .DESCRIPTION
        Triggers an asynchronous protection domain migration which (1)shuts down VMs, (2)syncs data with the remote site defined in its schedule, (3)unregisters VMs at the source and (4)registers VM on the remote site.
        .NOTES
        Author: Stephane Bourdeaud
        .PARAMETER pd
        Asynchronous protection domain name.
        .PARAMETER cluster
        FQDN or IP of Nutanix cluster.
        .PARAMETER credential
        PowerShell credential object for Nutanix cluster API user.
        .EXAMPLE
        Invoke-NtnxPdMigration -pd <pd_name> -cluster ntnx1.local -credential $credential
        #>
        [CmdletBinding()]
        param
        (
            $pd,

            [Parameter(Mandatory)]
            [String]
            $cluster,
            
            [parameter(mandatory = $true)]
            [System.Management.Automation.PSCredential]
            $credential            
        )

        begin
        {
            
        }

        process
        { 
            #region get data
                #let's retrieve the list of protection domains
                Write-Host "$(get-date) [INFO] Retrieving protection domains from Nutanix cluster $cluster ..." -ForegroundColor Green
                $url = "https://$($cluster):9440/PrismGateway/services/rest/v2.0/protection_domains/"
                $method = "GET"
                $PdList = Invoke-PrismAPICall -method $method -url $url -credential $credential
                Write-Host "$(get-date) [SUCCESS] Successfully retrieved protection domains from Nutanix cluster $cluster" -ForegroundColor Cyan

                #first, we need to figure out which protection domains need to be failed over. If none have been specified, we'll assume all of them which are active.
                if (!$pd) 
                {#no pd specified
                    $pd = ($PdList.entities | Where-Object {$_.active -eq $true} | Select-Object -Property name).name
                } 
                else 
                {#fetch specified pd
                    $pd = ($PdList.entities | Where-Object {$_.active -eq $true} | Select-Object -Property name).name | Where-Object {$pd -contains $_}
                }

                if (!$pd) 
                {
                    Write-Host "$(get-date) [ERROR] There are no protection domains in the correct status on $cluster!" -ForegroundColor Red
                    Exit
                }
            #endregion

            #region process
                #now let's call the migrate workflow
                ForEach ($pd2migrate in $pd) 
                {
                    #figure out if there is more than one remote site defined for the protection domain
                    $remoteSite = $PdList.entities | Where-Object {$_.name -eq $pd2migrate} | Select-Object -Property remote_site_names
                    if (!$remoteSite.remote_site_names) 
                    {#no remote site defined or no schedule on the pd with a remote site
                        Write-Host "$(get-date) [ERROR] There is no remote site defined for protection domain $pd2migrate" -ForegroundColor Red
                        Exit
                    }
                    if ($remoteSite -is [array]) 
                    {#more than 1 remote site target defined on the pd schedule
                        Write-Host "$(get-date) [ERROR] There is more than one remote site for protection domain $pd2migrate" -ForegroundColor Red
                        Exit
                    }

                    #region migrate the protection domain
                        Write-Host ""
                        Write-Host "$(get-date) [INFO] Migrating $pd2migrate to $($remoteSite.remote_site_names) ..." -ForegroundColor Green
                        $url = "https://$($cluster):9440/PrismGateway/services/rest/v2.0/protection_domains/$pd2migrate/migrate"
                        $method = "POST"
                        $content = @{
                                        value = $($remoteSite.remote_site_names)
                                    }
                        $body = (ConvertTo-Json $content -Depth 4)
                        $response = Invoke-PrismAPICall -method $method -url $url -credential $credential -payload $body
                        if ($debugme) {Write-LogOutput -Category "DEBUG" -LogFile $myvarOutputLogFile -Message "Migration request response is: $($response.metadata)"}
                        if ($response.metadata.count -ne 0)
                        {#something went wrong with our migration request
                            Write-Host "$(get-date) [ERROR] Could not start migration of $pd2migrate to $($remoteSite.remote_site_names). Try to trigger it manually in Prism and see why it won't work (this could be caused ny NGT being disabled on some VMs, or by delta disks due to old snapshots)." -ForegroundColor Red
                            Exit
                        }
                        Write-Host "$(get-date) [SUCCESS] Successfully started migration of $pd2migrate to $($remoteSite.remote_site_names)" -ForegroundColor Cyan
                    #endregion

                }
            #endregion
        }

        end
        {
        return $pd #list of protection domains which were processed 
        }
    }

    function Invoke-NtnxPdActivation
    {
        <#
        .SYNOPSIS
        Activates a Nutanix asynchronous protection domain (as part of an unplanned failover).
        .DESCRIPTION
        Activates a Nutanix asynchronous protection domain (as part of an unplanned failover), which will register VMs on the Nutanix cluster.
        .NOTES
        Author: Stephane Bourdeaud
        .PARAMETER pd
        Asynchronous protection domain name.
        .PARAMETER cluster
        FQDN or IP of Nutanix cluster.
        .PARAMETER credential
        PowerShell credential object for Nutanix cluster API user.
        .EXAMPLE
        Invoke-NtnxPdActivation -pd <pd_name> -cluster ntnx1.local -credential $prism_credential
        #>
        [CmdletBinding()]
        param
        (
            $pd,

            [Parameter(Mandatory)]
            [String]
            $cluster,
            
            [parameter(mandatory = $true)]
            [System.Management.Automation.PSCredential]
            $credential  
        )

        begin
        {
            
        }

        process
        {            
            #region get data
                #let's retrieve the list of protection domains
                Write-Host "$(get-date) [INFO] Retrieving protection domains from Nutanix cluster $cluster ..." -ForegroundColor Green
                $url = "https://$($cluster):9440/PrismGateway/services/rest/v2.0/protection_domains/"
                $method = "GET"
                $PdList = Invoke-PrismAPICall -method $method -url $url -credential $credential
                Write-Host "$(get-date) [SUCCESS] Successfully retrieved protection domains from Nutanix cluster $cluster" -ForegroundColor Cyan

                #first, we need to figure out which protection domains need to be failed over. If none have been specified, we'll assume all of them which are active.
                if (!$pd) 
                {#no pd specified
                    $pd = ($PdList.entities | Where-Object {$_.active -eq $false} | Select-Object -Property name).name
                } 
                else 
                {#fetch specified pd
                    $pd = ($PdList.entities | Where-Object {$_.active -eq $false} | Select-Object -Property name).name | Where-Object {$pd -contains $_}
                }

                if (!$pd) 
                {
                    Write-Host "$(get-date) [ERROR] There are no protection domains in the correct status on $cluster!" -ForegroundColor Red
                    Exit
                }
            #endregion

            #now let's call the activate workflow
            ForEach ($pd2activate in $pd) 
            {#activate each pd
                #region activate the protection domain
                    Write-Host ""
                    Write-Host "$(get-date) [INFO] Activating protection domain $($pd2activate) on $cluster ..." -ForegroundColor Green
                    $url = "https://$($cluster):9440/PrismGateway/services/rest/v2.0/protection_domains/$($pd2activate)/activate"
                    $method = "POST"
                    $content = @{}
                    $body = (ConvertTo-Json $content -Depth 4)
                    $response = Invoke-PrismAPICall -method $method -url $url -credential $credential -payload $body
                    Write-Host "$(get-date) [SUCCESS] Successfully activated protection domain $($pd2activate) on $cluster" -ForegroundColor Cyan
                #endregion    
            }
        }

        end
        {
            return $pd #list of protection domains which were processed
        }
    }

    function Get-PrismPdTaskStatus
    {
        <#
        .SYNOPSIS
        Retrieves the status of all protection domain deactivation tasks created after a specific time.

        .DESCRIPTION
        Retrieves the status of all protection domain deactivation tasks created after a specific time.

        .PARAMETER time
        Time in epoch seconds.
        .PARAMETER cluster
        Prism IP or fqdn.
        .PARAMETER credential
        PowerShell credential object for Nutanix cluster API user.

        .NOTES
        Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)

        .EXAMPLE
        .\Get-PrismTaskStatus -Task $task -Cluster $cluster -credential $prism_credential
        Prints progress on task $task until successfull completion. If the task fails, print the status and error code and details and exits.

        .LINK
        https://github.com/sbourdeaud
        #>
        [CmdletBinding(DefaultParameterSetName = 'None')] #make this function advanced

        param
        (
            [Parameter(Mandatory)]
            $time,
            
            [Parameter(Mandatory)]
            [String]
            [ValidateSet('activate','deactivate')]
            $operation,

            [Parameter(Mandatory)]
            [String]
            $cluster,
            
            [parameter(mandatory = $true)]
            [System.Management.Automation.PSCredential]
            $credential   
        )

        begin
        {
            
        }

        process 
        {
            Write-Host ""
            Write-Host "$(get-date) [INFO] Retrieving list of tasks on the cluster $cluster ..." -ForegroundColor Green
            Start-Sleep 10
            
            $url = "https://$($cluster):9440/PrismGateway/services/rest/v1/progress_monitors"
            $method = "GET"
            $response = Invoke-PrismRESTCall -method $method -url $url -credential $credential
            Write-Host "$(get-date) [SUCCESS] Retrieved list of tasks on the cluster $cluster" -ForegroundColor Cyan
            
            Do
            {
                $pdTasks = $response.entities | Where-Object {$_.operation -eq $operation} | Where-Object {($_.createTimeUsecs / 1000000) -ge $time}
            }
            While (!$pdTasks)

            #let's loop now until the task status is completed and successfull. If a task fails, we'll throw an exception.
            ForEach ($pdTask in $pdTasks) 
            {
                if ($pdTask.percentageCompleted -ne "100") 
                {
                    Do 
                    {
                        Write-Host "$(get-date) [WARNING] Waiting 5 seconds for task $($pdTask.taskName) to complete : $($pdTask.percentageCompleted)%" -ForegroundColor Yellow
                        Start-Sleep 5
                        $url = "https://$($cluster):9440/PrismGateway/services/rest/v1/progress_monitors"
                        $method = "GET"
                        $response = Invoke-PrismRESTCall -method $method -url $url -credential $credential
                        $task = $response.entities | Where-Object {$_.taskName -eq $pdTask.taskName} | Where-Object {($_.createTimeUsecs / 1000000) -ge $StartEpochSeconds}
                        if ($task.status -ne "running") 
                        {#task is no longer running
                            if ($task.status -ne "succeeded") 
                            {#task failed
                                Write-Host "$(get-date) [ERROR] Task $($pdTask.taskName) failed with the following status and error code : $($task.status) : $($task.errorCode)" -ForegroundColor Red
                                Exit
                            }
                        }
                    }
                    While ($task.percentageCompleted -ne "100")
                    
                    Write-Host "$(get-date) [SUCCESS] Protection domain migration task $($pdTask.taskName) completed on the cluster $cluster" -ForegroundColor Cyan
                    Write-Host ""
                } 
                else 
                {
                    Write-Host "$(get-date) [SUCCESS] Protection domain migration task $($pdTask.taskName) completed on the cluster $cluster" -ForegroundColor Cyan
                    Write-Host ""
                }
            }
        }
        
        end
        {

        }
    }

    function New-PercentageBar
    {
        
    <#
    .SYNOPSIS
        Create percentage bar.
    .DESCRIPTION
        This cmdlet creates percentage bar.
    .PARAMETER Percent
        Value in percents (%).
    .PARAMETER Value
        Value in arbitrary units.
    .PARAMETER MaxValue
        100% value.
    .PARAMETER BarLength
        Bar length in chars.
    .PARAMETER BarView
        Different char sets to build the bar.
    .PARAMETER GreenBorder
        Percent value to change bar color from green to yellow (relevant with -DrawBar parameter only).
    .PARAMETER YellowBorder
        Percent value to change bar color from yellow to red (relevant with -DrawBar parameter only).
    .PARAMETER NoPercent
        Exclude percentage number from the bar.
    .PARAMETER DrawBar
        Directly draw the colored bar onto the PowerShell console (unsuitable for calculated properties).
    .EXAMPLE
        PS C:\> New-PercentageBar -Percent 90 -DrawBar
        Draw single bar with all default settings.
    .EXAMPLE
        PS C:\> New-PercentageBar -Percent 95 -DrawBar -GreenBorder 70 -YellowBorder 90
        Draw the bar and move the both color change borders.
    .EXAMPLE
        PS C:\> 85 |New-PercentageBar -DrawBar -NoPercent
        Pipeline the percent value to the function and exclude percent number from the bar.
    .EXAMPLE
        PS C:\> For ($i=0; $i -le 100; $i+=10) {New-PercentageBar -Percent $i -DrawBar -Length 100 -BarView AdvancedThin2; "`r"}
        Demonstrates advanced bar view with custom bar length and different percent values.
    .EXAMPLE
        PS C:\> $Folder = 'C:\reports\'
        PS C:\> $FolderSize = (Get-ChildItem -Path $Folder |measure -Property Length -Sum).Sum
        PS C:\> Get-ChildItem -Path $Folder -File |sort Length -Descending |select -First 10 |select Name,Length,@{N='SizeBar';E={New-PercentageBar -Value $_.Length -MaxValue $FolderSize}} |ft -au
        Get file size report and add calculated property 'SizeBar' that contains the percent of each file size from the folder size.
    .EXAMPLE
        PS C:\> $VolumeC = gwmi Win32_LogicalDisk |? {$_.DeviceID -eq 'c:'}
        PS C:\> Write-Host -NoNewline "Volume C Usage:" -ForegroundColor Yellow; `
        PS C:\> New-PercentageBar -Value ($VolumeC.Size-$VolumeC.Freespace) -MaxValue $VolumeC.Size -DrawBar; "`r"
        Get system volume usage report.
    .NOTES
        Author      :: Roman Gelman @rgelman75
        Version 1.0 :: 04-Jul-2016 :: [Release] :: Publicly available
    .LINK
        https://ps1code.com/2016/07/16/percentage-bar-powershell
    #>
        
        [CmdletBinding(DefaultParameterSetName = 'PERCENT')]
        Param (
            [Parameter(Mandatory, Position = 1, ValueFromPipeline, ParameterSetName = 'PERCENT')]
            [ValidateRange(0, 100)]
            [int]$Percent
            ,
            [Parameter(Mandatory, Position = 1, ValueFromPipeline, ParameterSetName = 'VALUE')]
            [ValidateRange(0, [double]::MaxValue)]
            [double]$Value
            ,
            [Parameter(Mandatory, Position = 2, ParameterSetName = 'VALUE')]
            [ValidateRange(1, [double]::MaxValue)]
            [double]$MaxValue
            ,
            [Parameter(Mandatory = $false, Position = 3)]
            [Alias("BarSize", "Length")]
            [ValidateRange(10, 100)]
            [int]$BarLength = 20
            ,
            [Parameter(Mandatory = $false, Position = 4)]
            [ValidateSet("SimpleThin", "SimpleThick1", "SimpleThick2", "AdvancedThin1", "AdvancedThin2", "AdvancedThick")]
            [string]$BarView = "SimpleThin"
            ,
            [Parameter(Mandatory = $false, Position = 5)]
            [ValidateRange(50, 80)]
            [int]$GreenBorder = 60
            ,
            [Parameter(Mandatory = $false, Position = 6)]
            [ValidateRange(80, 90)]
            [int]$YellowBorder = 80
            ,
            [Parameter(Mandatory = $false)]
            [switch]$NoPercent
            ,
            [Parameter(Mandatory = $false)]
            [switch]$DrawBar
        )
        
        Begin
        {
            
            If ($PSBoundParameters.ContainsKey('VALUE'))
            {
                
                If ($Value -gt $MaxValue)
                {
                    Throw "The [-Value] parameter cannot be greater than [-MaxValue]!"
                }
                Else
                {
                    $Percent = $Value/$MaxValue * 100 -as [int]
                }
            }
            
            If ($YellowBorder -le $GreenBorder) { Throw "The [-YellowBorder] value must be greater than [-GreenBorder]!" }
            
            Function Set-BarView ($View)
            {
                Switch -exact ($View)
                {
                    "SimpleThin"	{ $GreenChar = [char]9632; $YellowChar = [char]9632; $RedChar = [char]9632; $EmptyChar = "-"; Break }
                    "SimpleThick1"	{ $GreenChar = [char]9608; $YellowChar = [char]9608; $RedChar = [char]9608; $EmptyChar = "-"; Break }
                    "SimpleThick2"	{ $GreenChar = [char]9612; $YellowChar = [char]9612; $RedChar = [char]9612; $EmptyChar = "-"; Break }
                    "AdvancedThin1"	{ $GreenChar = [char]9632; $YellowChar = [char]9632; $RedChar = [char]9632; $EmptyChar = [char]9476; Break }
                    "AdvancedThin2"	{ $GreenChar = [char]9642; $YellowChar = [char]9642; $RedChar = [char]9642; $EmptyChar = [char]9643; Break }
                    "AdvancedThick"	{ $GreenChar = [char]9617; $YellowChar = [char]9618; $RedChar = [char]9619; $EmptyChar = [char]9482; Break }
                }
                $Properties = [ordered]@{
                    Char1 = $GreenChar
                    Char2 = $YellowChar
                    Char3 = $RedChar
                    Char4 = $EmptyChar
                }
                $Object = New-Object PSObject -Property $Properties
                $Object
            } #End Function Set-BarView
            
            $BarChars = Set-BarView -View $BarView
            $Bar = $null
            
            Function Draw-Bar
            {
                
                Param (
                    [Parameter(Mandatory)]
                    [string]$Char
                    ,
                    [Parameter(Mandatory = $false)]
                    [string]$Color = 'White'
                    ,
                    [Parameter(Mandatory = $false)]
                    [boolean]$Draw
                )
                
                If ($Draw)
                {
                    Write-Host -NoNewline -ForegroundColor ([System.ConsoleColor]$Color) $Char
                }
                Else
                {
                    return $Char
                }
                
            } #End Function Draw-Bar
            
        } #End Begin
        
        Process
        {
            
            If ($NoPercent)
            {
                $Bar += Draw-Bar -Char "[ " -Draw $DrawBar
            }
            Else
            {
                If ($Percent -eq 100) { $Bar += Draw-Bar -Char "$Percent% [ " -Draw $DrawBar }
                ElseIf ($Percent -ge 10) { $Bar += Draw-Bar -Char " $Percent% [ " -Draw $DrawBar }
                Else { $Bar += Draw-Bar -Char "  $Percent% [ " -Draw $DrawBar }
            }
            
            For ($i = 1; $i -le ($BarValue = ([Math]::Round($Percent * $BarLength / 100))); $i++)
            {
                
                If ($i -le ($GreenBorder * $BarLength / 100)) { $Bar += Draw-Bar -Char ($BarChars.Char1) -Color 'DarkGreen' -Draw $DrawBar }
                ElseIf ($i -le ($YellowBorder * $BarLength / 100)) { $Bar += Draw-Bar -Char ($BarChars.Char2) -Color 'Yellow' -Draw $DrawBar }
                Else { $Bar += Draw-Bar -Char ($BarChars.Char3) -Color 'Red' -Draw $DrawBar }
            }
            For ($i = 1; $i -le ($EmptyValue = $BarLength - $BarValue); $i++) { $Bar += Draw-Bar -Char ($BarChars.Char4) -Draw $DrawBar }
            $Bar += Draw-Bar -Char " ]" -Draw $DrawBar
            
        } #End Process
        
        End
        {
            If (!$DrawBar) { return $Bar }
        } #End End
        
    } #EndFunction New-PercentageBar
    
    function Get-PrismTaskStatus
    {
        <#
        .SYNOPSIS
        Retrieves the status of a given task uuid from Prism and loops until it is completed.

        .DESCRIPTION
        Retrieves the status of a given task uuid from Prism and loops until it is completed.

        .PARAMETER task
        Prism task uuid.
        .PARAMETER cluster
        Prism IP or fqdn.
        .PARAMETER credential
        PowerShell credential object for Nutanix cluster API user.

        .NOTES
        Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)

        .EXAMPLE
        .\Get-PrismTaskStatus -Task $task -Cluster $cluster -credential $prism_credential
        Prints progress on task $task until successfull completion. If the task fails, print the status and error code and details and exits.

        .LINK
        https://github.com/sbourdeaud
        #>
        [CmdletBinding(DefaultParameterSetName = 'None')] #make this function advanced

        param
        (
            [Parameter(Mandatory)]
            [String]
            $task,
            
            [Parameter(Mandatory)]
            [String]
            $cluster,
            
            [parameter(mandatory = $true)]
            [System.Management.Automation.PSCredential]
            $credential   
        )

        begin
        {
            
        }

        process 
        {
            #region get initial task details
                Write-LogOutput -Category "INFO" -LogFile $myvarOutputLogFile -Message "Retrieving details of task $task..."
                $url = "https://$($cluster):9440/PrismGateway/services/rest/v2.0/tasks/$task"
                $method = "GET"
                $taskDetails = Invoke-PrismAPICall -method $method -url $url -credential $credential
                Write-LogOutput -Category "SUCCESS" -LogFile $myvarOutputLogFile -Message "Retrieved details of task $task"
            #endregion

            if ($taskDetails.percentage_complete -ne "100") 
            {
                Do 
                {
                    New-PercentageBar -Percent $taskDetails.percentage_complete -DrawBar -Length 100 -BarView AdvancedThin2; "`r"
                    Start-Sleep 5
                    $url = "https://$($cluster):9440/PrismGateway/services/rest/v2.0/tasks/$task"
                    $method = "GET"
                    $taskDetails = Invoke-PrismRESTCall -method $method -url $url -credential $credential
                    
                    if ($taskDetails.progress_status -ne "Running") 
                    {
                        if ($taskDetails.progress_status -ne "Succeeded")
                        {
                            Write-LogOutput -Category "ERROR" -LogFile $myvarOutputLogFile -Message "Task $($taskDetails.meta_request.method_name) failed with the following status and error code : $($taskDetails.progress_status) : $($taskDetails.meta_response.error_code)"
                            $userChoice = Write-CustomPrompt
                            if ($userChoice -eq "n")
                            {
                                Exit
                            }
                        }
                    }
                }
                While ($taskDetails.percentage_complete -ne "100")
                
                New-PercentageBar -Percent $taskDetails.percentage_complete -DrawBar -Length 100 -BarView AdvancedThin2; "`r"
                Write-LogOutput -Category "SUCCESS" -LogFile $myvarOutputLogFile -Message "Task $($taskDetails.meta_request.method_name) completed successfully!"
            } 
            else 
            {
                if ($taskDetails.progress_status -ne "Succeeded")
                {
                    Write-LogOutput -Category "ERROR" -LogFile $myvarOutputLogFile -Message "Task $($taskDetails.meta_request.method_name) failed with the following status and error code : $($taskDetails.progress_status) : $($taskDetails.meta_response.error_code)"
                    $userChoice = Write-CustomPrompt
                    if ($userChoice -eq "n")
                    {
                        Exit
                    }
                }
                else 
                {
                    New-PercentageBar -Percent $taskDetails.percentage_complete -DrawBar -Length 100 -BarView AdvancedThin2; "`r"
                    Write-LogOutput -Category "SUCCESS" -LogFile $myvarOutputLogFile -Message "Task $($taskDetails.meta_request.method_name) completed successfully!"   
                }
            }
        }
        
        end
        {

        }
    }
#endregion

#region prepwork
    $HistoryText = @'
Maintenance Log
Date       By   Updates (newest updates at the top)
---------- ---- ---------------------------------------------------------------
06/08/2020 sb   Initial release.
################################################################################
'@
    $myvarScriptName = ".\Invoke-NutanixFilesDr.ps1"

    if ($help) {get-help $myvarScriptName; exit}
    if ($History) {$HistoryText; exit}

    #check PoSH version
    if ($PSVersionTable.PSVersion.Major -lt 5) {throw "$(get-date) [ERROR] Please upgrade to Powershell v5 or above (https://www.microsoft.com/en-us/download/details.aspx?id=50395)"}

    #check if we have all the required PoSH modules
    Write-LogOutput -Category "INFO" -LogFile $myvarOutputLogFile -Message "Checking for required Powershell modules..."

    #region module sbourdeaud is used for facilitating Prism REST calls
        $required_version = "3.0.8"
        if (!(Get-Module -Name sbourdeaud)) {
            Write-Host "$(get-date) [INFO] Importing module 'sbourdeaud'..." -ForegroundColor Green
            try
            {
                Import-Module -Name sbourdeaud -MinimumVersion $required_version -ErrorAction Stop
                Write-Host "$(get-date) [SUCCESS] Imported module 'sbourdeaud'!" -ForegroundColor Cyan
            }#end try
            catch #we couldn't import the module, so let's install it
            {
                Write-Host "$(get-date) [INFO] Installing module 'sbourdeaud' from the Powershell Gallery..." -ForegroundColor Green
                try {Install-Module -Name sbourdeaud -Scope CurrentUser -Force -ErrorAction Stop}
                catch {throw "$(get-date) [ERROR] Could not install module 'sbourdeaud': $($_.Exception.Message)"}

                try
                {
                    Import-Module -Name sbourdeaud -MinimumVersion $required_version -ErrorAction Stop
                    Write-Host "$(get-date) [SUCCESS] Imported module 'sbourdeaud'!" -ForegroundColor Cyan
                }#end try
                catch #we couldn't import the module
                {
                    Write-Host "$(get-date) [ERROR] Unable to import the module sbourdeaud.psm1 : $($_.Exception.Message)" -ForegroundColor Red
                    Write-Host "$(get-date) [WARNING] Please download and install from https://www.powershellgallery.com/packages/sbourdeaud/1.1" -ForegroundColor Yellow
                    Exit
                }#end catch
            }#end catch
        }#endif module sbourdeaud
        $MyVarModuleVersion = Get-Module -Name sbourdeaud | Select-Object -Property Version
        if (($MyVarModuleVersion.Version.Major -lt $($required_version.split('.')[0])) -or (($MyVarModuleVersion.Version.Major -eq $($required_version.split('.')[0])) -and ($MyVarModuleVersion.Version.Minor -eq $($required_version.split('.')[1])) -and ($MyVarModuleVersion.Version.Build -lt $($required_version.split('.')[2])))) {
            Write-Host "$(get-date) [INFO] Updating module 'sbourdeaud'..." -ForegroundColor Green
            Remove-Module -Name sbourdeaud -ErrorAction SilentlyContinue
            Uninstall-Module -Name sbourdeaud -ErrorAction SilentlyContinue
            try {
                Update-Module -Name sbourdeaud -Scope CurrentUser -ErrorAction Stop
                Import-Module -Name sbourdeaud -ErrorAction Stop
            }
            catch {throw "$(get-date) [ERROR] Could not update module 'sbourdeaud': $($_.Exception.Message)"}
        }
    #endregion
    Set-PoSHSSLCerts
    Set-PoshTls
#endregion

#region variables
    $myvarElapsedTime = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp
    $StartEpochSeconds = Get-Date (Get-Date).ToUniversalTime() -UFormat %s #used to get tasks generated in Prism after the script was invoked
    $remote_site_ips = @() #initialize array here to collect remote site ips
#endregion

#region parameters validation
    if (!$reference) {
        if (!$fsname) {$fsname = Read-Host "Enter the name of the file server you want to failover"}
        #check if there is a default reference file for this file server in the current directory
        if ((Test-Path ./$($fsname)-reference.csv -PathType Leaf) -and !$prism) {
            Write-Host "$(get-date) [INFO] Found a reference file called $($fsname)-reference.csv in the current directory." -ForegroundColor Green
            $reference_data = Import-Csv -Path ./$($fsname)-reference.csv
        } else {
            Write-Host "$(get-date) [WARN] Could not find a reference file for file server $($fsname) in the current directory or you specified a Prism cluster." -ForegroundColor Yellow
            if (!$prism) {$prism = Read-Host "Enter the FQDN or IP address of a Nutanix cluster"}
            if (!$prismCreds) 
            {#we are not using custom credentials, so let's ask for a username and password if they have not already been specified
                if (!$username) 
                {#if Prism username has not been specified ask for it
                    $username = Read-Host "Enter the Prism username"
                } 

                if (!$password) 
                {#if password was not passed as an argument, let's prompt for it
                    $PrismSecurePassword = Read-Host "Enter the Prism user $username password" -AsSecureString
                }
                else 
                {#if password was passed as an argument, let's convert the string to a secure string and flush the memory
                    $PrismSecurePassword = ConvertTo-SecureString $password –asplaintext –force
                    Remove-Variable password
                }
                $prismCredentials = New-Object PSCredential $username, $PrismSecurePassword
            } 
            else 
            { #we are using custom credentials, so let's grab the username and password from that
                try 
                {
                    $prismCredentials = Get-CustomCredentials -credname $prismCreds -ErrorAction Stop
                    $username = $prismCredentials.UserName
                    $PrismSecurePassword = $prismCredentials.Password
                }
                catch 
                {
                    $credname = Read-Host "Enter the credentials name"
                    Set-CustomCredentials -credname $credname
                    $prismCredentials = Get-CustomCredentials -credname $prismCreds -ErrorAction Stop
                    $username = $prismCredentials.UserName
                    $PrismSecurePassword = $prismCredentials.Password
                }
                $prismCredentials = New-Object PSCredential $username, $PrismSecurePassword
            }
            if (!$pd) {$pd = "NTNX-$($fsname)"}
        }
    } else {
        $reference_data = Import-Csv -Path ./$($reference)
    }
    if ($dns) {
        if (!$reference_data) {
            if (!$adCreds) 
            {#we are not using custom credentials, so let's ask for a username and password if they have not already been specified
                $ad_username = Read-Host "Enter the Active Directory username for DNS updates"
                $ad_secure_password = Read-Host "Enter the Active Directory user $ad_username password" -AsSecureString
                $ad_credentials = New-Object PSCredential $ad_username, $ad_secure_password
            } 
            else 
            { #we are using custom credentials, so let's grab the username and password from that
                try 
                {
                    $ad_credentials = Get-CustomCredentials -credname $adCreds -ErrorAction Stop
                    $ad_username = $ad_credentials.UserName
                    $ad_secure_password = $ad_credentials.Password
                }
                catch 
                {
                    $credname = Read-Host "Enter the credentials name"
                    Set-CustomCredentials -credname $credname
                    $ad_credentials = Get-CustomCredentials -credname $adCreds -ErrorAction Stop
                    $ad_username = $ad_credentials.UserName
                    $ad_secure_password = $ad_credentials.Password
                }
                $ad_credentials = New-Object PSCredential $ad_username, $ad_secure_password
            }
        }
    }
    if ($mail) {
        if (!$smtp) {$smtp = Read-Host "Enter the FQDN or IP address of an SMTP server"}
        if (!$email) {$email = Read-Host "Enter a comma separated list of email addresses to notify"}
    }
#endregion

#region processing
#TODO add workflow for deactivate
    #region check we have the data we need
        #check reference_data (if it exists) and validate entries
        if ($reference_data) {
            if (!$reference_data.fsname) {Write-Host "$(get-date) [ERROR] Reference file is missing a value for attribute fsname" -ForegroundColor Error; exit 1}
            if (!$reference_data.{prism-primary}) {Write-Host "$(get-date) [ERROR] Reference file is missing a value for attribute prism-primary" -ForegroundColor Error; exit 1}
            if (!$reference_data.{prism-dr}) {Write-Host "$(get-date) [ERROR] Reference file is missing a value for attribute prism-dr" -ForegroundColor Error; exit 1}
            if (!$reference_data.{primary-client-network-name}) {Write-Host "$(get-date) [ERROR] Reference file is missing a value for attribute primary-client-network-name" -ForegroundColor Error; exit 1}
            if (!$reference_data.{primary-storage-network-name}) {Write-Host "$(get-date) [ERROR] Reference file is missing a value for attribute primary-storage-network-name" -ForegroundColor Error; exit 1}
            if (!$reference_data.{dr-client-network-name}) {Write-Host "$(get-date) [ERROR] Reference file is missing a value for attribute dr-client-network-name" -ForegroundColor Error; exit 1}
            if (!$reference_data.{dr-storage-network-name}) {Write-Host "$(get-date) [ERROR] Reference file is missing a value for attribute dr-storage-network-name" -ForegroundColor Error; exit 1}
            if (!$reference_data.prismcreds) {Write-Host "$(get-date) [ERROR] Reference file is missing a value for attribute prismcreds" -ForegroundColor Error; exit 1}
            if ($dns -and !$reference_data.adcreds) {Write-Host "$(get-date) [ERROR] Reference file is missing a value for attribute adcreds" -ForegroundColor Error; exit 1}
            if ($mail -and (!$smtp -or !$email)) {Write-Host "$(get-date) [ERROR] Reference file is missing a value for attribute smtp and/or email" -ForegroundColor Error; exit 1}

            #import prismcredentials
            try {
                $prismCredentials = Get-CustomCredentials -credname $reference_data.prismcreds -ErrorAction Stop
                $username = $prismCredentials.UserName
                $PrismSecurePassword = $prismCredentials.Password
            }
            catch 
            {
                $credname = Read-Host "Enter the Prism credentials name"
                Set-CustomCredentials -credname $credname
                $prismCredentials = Get-CustomCredentials -credname $reference_data.prismcreds -ErrorAction Stop
                $username = $prismCredentials.UserName
                $PrismSecurePassword = $prismCredentials.Password
            }
            $prismCredentials = New-Object PSCredential $username, $PrismSecurePassword
            
            #import adcredentials
            if ($dns -and $reference_data.adcreds) {
                try {
                    $ad_credentials = Get-CustomCredentials -credname $reference_data.adcreds -ErrorAction Stop
                    $ad_username = $ad_credentials.UserName
                    $ad_secure_password = $ad_credentials.Password
                }
                catch 
                {
                    $credname = Read-Host "Enter the AD credentials name"
                    Set-CustomCredentials -credname $credname
                    $ad_credentials = Get-CustomCredentials -credname $reference_data.adcreds -ErrorAction Stop
                    $ad_username = $ad_credentials.UserName
                    $ad_secure_password = $ad_credentials.Password
                }
                $ad_credentials = New-Object PSCredential $ad_username, $PrismSecurePassword
            }

            $fsname = $reference_data.fsname
            if ($reference_data.pd) {
                $pd = $reference_data.pd
            } else {
                $pd = "NTNX-$($reference_data.fsname)"
            }
        }
    #endregion
    
    #region check prism connectivity and get additional data
        Write-Host ""
        Write-Host "$(get-date) [STEP] --Verifying Connectivity to Prism(s)--" -ForegroundColor Magenta
        #TODO error out based on file server status and requested operation
        if ($reference_data) {
            if ($failover -eq "planned") {
                #region GET cluster (PRIMARY)
                    #check if primary site is available
                    Write-Host "$(get-date) [INFO] Retrieving details of PRIMARY Nutanix cluster $($reference_data.{prism-primary}) ..." -ForegroundColor Green
                    $url = "https://$($reference_data.{prism-primary}):9440/PrismGateway/services/rest/v2.0/cluster/"
                    $method = "GET"
                    $primary_cluster_details = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                    Write-Host "$(get-date) [SUCCESS] Successfully retrieved details of PRIMARY Nutanix cluster $($reference_data.{prism-primary})" -ForegroundColor Cyan
                    Write-Host "$(get-date) [INFO] Hypervisor on PRIMARY Nutanix cluster $($reference_data.{prism-primary}) is of type $($primary_cluster_details.hypervisor_types)." -ForegroundColor Green

                    #grab cluster name and ntp servers if they have not been specified in the reference data
                    if (!$reference_data.{primary-dns-servers}) {
                        $primary_dns_servers = $primary_cluster_details.name_servers
                    } else {
                        $primary_dns_servers = ($reference_data.{primary-dns-servers}).split(",")
                    }
                    if (!$reference_data.{primary-ntp-servers}) {
                        $primary_ntp_servers = $primary_cluster_details.ntp_servers
                    } else {
                        $primary_ntp_servers = ($reference_data.{primary-ntp-servers}).split(",")
                    }
                #endregion
                
                #region GET vfiler (PRIMARY)
                    #check status of file server on primary
                    Write-Host "$(get-date) [INFO] Retrieving details of file server $fsname status from PRIMARY Nutanix cluster $($reference_data.{prism-primary})..." -ForegroundColor Green
                    $url = "https://$($reference_data.{prism-primary}):9440/PrismGateway/services/rest/v1/vfilers/"
                    $method = "GET"
                    $primary_cluster_vfilers = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                    $primary_cluster_vfiler = $primary_cluster_vfilers.entities | Where-Object {$_.Name -eq $fsname}
                    if (!$primary_cluster_vfiler) {Write-Host "$(get-date) [ERROR] Could not find a file server called $fsname on PRIMARY Nutanix cluster $($reference_data.{prism-primary})!" -ForegroundColor Red; Exit 1}
                    Write-Host "$(get-date) [SUCCESS] Successfully retrieved details of file server $fsname status from PRIMARY Nutanix cluster $($reference_data.{prism-primary})" -ForegroundColor Cyan
                    Write-Host "$(get-date) [INFO] File server $fsname on PRIMARY Nutanix cluster $($reference_data.{prism-primary}) has the following status: $($primary_cluster_vfiler.fileServerState)" -ForegroundColor Green
                #endregion

                #region GET protection domains (PRIMARY)
                    #get protection domains from primary
                    Write-Host "$(get-date) [INFO] Retrieving protection domains from PRIMARY Nutanix cluster $($reference_data.{prism-primary})..." -ForegroundColor Green
                    $url = "https://$($reference_data.{prism-primary}):9440/PrismGateway/services/rest/v2.0/protection_domains/"
                    $method = "GET"
                    $primary_pd_list = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                    Write-Host "$(get-date) [SUCCESS] Successfully retrieved protection domains from PRIMARY Nutanix cluster $($reference_data.{prism-primary})" -ForegroundColor Cyan
                    $primary_vfiler_pd = $primary_pd_list.entities | Where-Object {$_.name -eq $pd}
                    if (!$primary_vfiler_pd) {Write-Host "$(get-date) [ERROR] Could not find a protection domain called $pd on PRIMARY Nutanix cluster $($reference_data.{prism-primary})!" -ForegroundColor Red; Exit 1}
                #endregion

                #region GET networks (PRIMARY)
                    #get available networks from primary (/PrismGateway/services/rest/v2.0/networks/)
                    #TODO check this works the same with esxi (testing on ahv for now)
                    Write-Host "$(get-date) [INFO] Retrieving available networks from PRIMARY Nutanix cluster $($reference_data.{prism-primary})..." -ForegroundColor Green
                    $url = "https://$($reference_data.{prism-primary}):9440/PrismGateway/services/rest/v2.0/networks/"
                    $method = "GET"
                    $primary_cluster_networks = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                    Write-Host "$(get-date) [SUCCESS] Successfully retrieved networks from PRIMARY Nutanix cluster $($reference_data.{prism-primary})" -ForegroundColor Cyan
                    $primary_client_network_uuid = ($primary_cluster_networks.entities | Where-Object {$_.name -eq $reference_data.{primary-client-network-name}}).uuid
                    $primary_storage_network_uuid = ($primary_cluster_networks.entities | Where-Object {$_.name -eq $reference_data.{primary-storage-network-name}}).uuid
                    if (!$primary_client_network_uuid) {Write-Host "$(get-date) [ERROR] Could not find a network named $($reference_data.{primary-client-network-name}) on PRIMARY Nutanix cluster $($reference_data.{prism-primary})!" -ForegroundColor Red; Exit 1}
                    if (!$primary_storage_network_uuid) {Write-Host "$(get-date) [ERROR] Could not find a network named $($reference_data.{primary-storage-network-name}) on PRIMARY Nutanix cluster $($reference_data.{prism-primary})!" -ForegroundColor Red; Exit 1}
                    Write-Host "$(get-date) [INFO] Client network uuid on primary cluster is $($primary_client_network_uuid)" -ForegroundColor Green
                    Write-Host "$(get-date) [INFO] Storage network uuid on primary cluster is $($primary_storage_network_uuid)" -ForegroundColor Green
                #endregion
            }
            #region GET cluster (DR)
                #check if dr site is available (IF not, error out)
                Write-Host "$(get-date) [INFO] Retrieving details of DR Nutanix cluster $($reference_data.{prism-dr}) ..." -ForegroundColor Green
                $url = "https://$($reference_data.{prism-dr}):9440/PrismGateway/services/rest/v2.0/cluster/"
                $method = "GET"
                $dr_cluster_details = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                Write-Host "$(get-date) [SUCCESS] Successfully retrieved details of DR Nutanix cluster $($reference_data.{prism-dr})" -ForegroundColor Cyan
                Write-Host "$(get-date) [INFO] Hypervisor on DR Nutanix cluster $($reference_data.{prism-dr}) is of type $($dr_cluster_details.hypervisor_types)." -ForegroundColor Green

                #grab cluster name and ntp servers if they have not been specified in the reference data
                if (!$reference_data.{dr-dns-servers}) {
                    $dr_dns_servers = $dr_cluster_details.name_servers
                } else {
                    $dr_dns_servers = ($reference_data.{dr-dns-servers}).split(",")
                }
                if (!$reference_data.{dr-ntp-servers}) {
                    $dr_ntp_servers = $dr_cluster_details.ntp_servers
                } else {
                    $dr_ntp_servers = ($reference_data.{dr-ntp-servers}).split(",")
                }
            #endregion
            
            #region GET vfiler (DR)
                #check status of file server on dr
                Write-Host "$(get-date) [INFO] Retrieving details of file server $fsname status from DR Nutanix cluster $($reference_data.{prism-dr})..." -ForegroundColor Green
                $url = "https://$($reference_data.{prism-dr}):9440/PrismGateway/services/rest/v1/vfilers/"
                $method = "GET"
                $dr_cluster_vfilers = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                $dr_cluster_vfiler = $dr_cluster_vfilers.entities | Where-Object {$_.Name -eq $fsname}
                if (!$dr_cluster_vfiler) {Write-Host "$(get-date) [ERROR] Could not find a file server called $fsname on DR Nutanix cluster $($reference_data.{prism-dr})!" -ForegroundColor Red; Exit 1}
                Write-Host "$(get-date) [SUCCESS] Successfully retrieved details of file server $fsname status from DR Nutanix cluster $($reference_data.{prism-dr})" -ForegroundColor Cyan
                Write-Host "$(get-date) [INFO] File server $fsname on DR Nutanix cluster $($reference_data.{prism-dr}) has the following status: $($dr_cluster_vfiler.fileServerState)" -ForegroundColor Green
            #endregion

            #region GET protection domains (DR)
                #get protection domains from dr
                Write-Host "$(get-date) [INFO] Retrieving protection domains from DR Nutanix cluster $($reference_data.{prism-dr})..." -ForegroundColor Green
                $url = "https://$($reference_data.{prism-dr}):9440/PrismGateway/services/rest/v2.0/protection_domains/"
                $method = "GET"
                $dr_pd_list = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                Write-Host "$(get-date) [SUCCESS] Successfully retrieved protection domains from DR Nutanix cluster $($reference_data.{prism-dr})" -ForegroundColor Cyan
                $dr_vfiler_pd = $dr_pd_list.entities | Where-Object {$_.name -eq $pd}
                if (!$dr_vfiler_pd) {Write-Host "$(get-date) [ERROR] Could not find a protection domain called $pd on DR Nutanix cluster $($reference_data.{prism-dr})!" -ForegroundColor Red; Exit 1}
            #endregion
            
            #region GET networks (DR)
                #get available networks from primary (/PrismGateway/services/rest/v2.0/networks/)
                #TODO check this works the same with esxi (testing on ahv for now)
                Write-Host "$(get-date) [INFO] Retrieving available networks from DR Nutanix cluster $($reference_data.{prism-dr})..." -ForegroundColor Green
                $url = "https://$($reference_data.{prism-dr}):9440/PrismGateway/services/rest/v2.0/networks/"
                $method = "GET"
                $dr_cluster_networks = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                Write-Host "$(get-date) [SUCCESS] Successfully retrieved networks from DR Nutanix cluster $($reference_data.{prism-dr})" -ForegroundColor Cyan
                $dr_client_network_uuid = ($dr_cluster_networks.entities | Where-Object {$_.name -eq $reference_data.{dr-client-network-name}}).uuid
                $dr_storage_network_uuid = ($dr_cluster_networks.entities | Where-Object {$_.name -eq $reference_data.{dr-storage-network-name}}).uuid
                if (!$dr_client_network_uuid) {Write-Host "$(get-date) [ERROR] Could not find a network named $($reference_data.{dr-client-network-name}) on DR Nutanix cluster $($reference_data.{prism-dr})!" -ForegroundColor Red; Exit 1}
                if (!$dr_storage_network_uuid) {Write-Host "$(get-date) [ERROR] Could not find a network named $($reference_data.{dr-storage-network-name}) on DR Nutanix cluster $($reference_data.{prism-dr})!" -ForegroundColor Red; Exit 1}
                Write-Host "$(get-date) [INFO] Client network uuid on dr cluster is $($dr_client_network_uuid)" -ForegroundColor Green
                Write-Host "$(get-date) [INFO] Storage network uuid on dr cluster is $($dr_storage_network_uuid)" -ForegroundColor Green
            #endregion
            
            #* figuring out here source and target for failover operations
            #if planned failover, based on pd status, determine the direction of the failover and set variable accordingly
            if ($failover -eq "planned") {
                if ($primary_vfiler_pd.active -and $dr_vfiler_pd.active) {
                    Write-Host "$(get-date) [ERROR] Protection domain $pd is active on both PRIMARY and DR clusters. We cannot do a planned migration. Aborting." -ForegroundColor Red
                    Exit 1
                } elseif ($primary_vfiler_pd.active) {#protection domain is active on primary, so this is where we'll trigger migrate. Filer activation will be done on dr.
                    Write-Host "$(get-date) [INFO] Protection domain $pd is active on PRIMARY cluster, so migrating from PRIMARY to DR and doing file server activation on DR." -ForegroundColor Green
                    $migrate_from_cluster = $reference_data.{prism-primary}
                    $migrate_from_cluster_name = $primary_cluster_details.name
                    $filer_activation_cluster = $reference_data.{prism-dr}
                    $filer_activation_cluster_name = $dr_cluster_details.name
                } elseif ($dr_vfiler_pd.active) {
                    Write-Host "$(get-date) [INFO] Protection domain $pd is active on DR cluster, so migrating from DR to PRIMARY and doing file server activation on PRIMARY." -ForegroundColor Green
                    $migrate_from_cluster = $reference_data.{prism-dr}
                    $migrate_from_cluster_name = $dr_cluster_details.name
                    $filer_activation_cluster = $reference_data.{prism-primary}
                    $filer_activation_cluster_name = $primary_cluster_details.name
                }
            } elseif ($failover -eq "unplanned") {
                Write-Host "$(get-date) [INFO] We are doing an unplanned failover, so protection domain $pd will be activated on DR. File server activation will also be done on DR." -ForegroundColor Green
                $filer_activation_cluster = $reference_data.{prism-dr}
                $filer_activation_cluster_name = $dr_cluster_details.name
                if ($dr_vfiler_pd.active) {
                    Write-Host "$(get-date) [ERROR] Protection domain $pd is already active on DR cluster. We cannot do an unplanned migration. Aborting." -ForegroundColor Red
                    Exit 1
                }
            }
        } else {
            #region GET cluster (-prism)
                #check connectivity to prism
                Write-Host "$(get-date) [INFO] Retrieving details of Nutanix cluster $($prism) ..." -ForegroundColor Green
                $url = "https://$($prism):9440/PrismGateway/services/rest/v2.0/cluster/"
                $method = "GET"
                $prism_cluster_details = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                Write-Host "$(get-date) [SUCCESS] Successfully retrieved details of Nutanix cluster $($prism) ($($prism_cluster_details.name))" -ForegroundColor Cyan
                Write-Host "$(get-date) [INFO] Hypervisor on Nutanix cluster $($prism) ($($prism_cluster_details.name)) is of type $($prism_cluster_details.hypervisor_types)." -ForegroundColor Green
            #endregion

            #region GET vfiler (-prism)
                #check status of file server on prism
                Write-Host "$(get-date) [INFO] Retrieving details of file server $fsname status from Nutanix cluster $($prism) ($($prism_cluster_details.name))..." -ForegroundColor Green
                $url = "https://$($prism):9440/PrismGateway/services/rest/v1/vfilers/"
                $method = "GET"
                $prism_cluster_vfilers = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                $prism_cluster_vfiler = $prism_cluster_vfilers.entities | Where-Object {$_.Name -eq $fsname}
                if (!$prism_cluster_vfiler) {Write-Host "$(get-date) [ERROR] Could not find a file server called $fsname on Nutanix cluster $($prism) ($($prism_cluster_details.name))!" -ForegroundColor Red; Exit 1}
                Write-Host "$(get-date) [SUCCESS] Successfully retrieved details of file server $fsname status from Nutanix cluster $($prism) ($($prism_cluster_details.name))" -ForegroundColor Cyan
                Write-Host "$(get-date) [INFO] File server $fsname on Nutanix cluster $($prism) ($($prism_cluster_details.name)) has the following status: $($prism_cluster_vfiler.fileServerState)" -ForegroundColor Green
                $pd = $prism_cluster_vfiler.protectionDomainName
            #endregion

            #region GET protection domains (PRISM)
                #get protection domains from prism
                Write-Host "$(get-date) [INFO] Retrieving protection domains from Nutanix cluster $($prism) ($($prism_cluster_details.name))..." -ForegroundColor Green
                $url = "https://$($prism):9440/PrismGateway/services/rest/v2.0/protection_domains/"
                $method = "GET"
                $prism_pd_list = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                Write-Host "$(get-date) [SUCCESS] Successfully retrieved protection domains from Nutanix cluster $($prism) ($($prism_cluster_details.name))" -ForegroundColor Cyan
                
                $prism_vfiler_pd = $prism_pd_list.entities | Where-Object {$_.name -eq $pd}
                if (!$prism_vfiler_pd) {Write-Host "$(get-date) [ERROR] Could not find a protection domain called $pd on Nutanix cluster $($prism) ($($prism_cluster_details.name))!" -ForegroundColor Red; Exit 1}

                $remoteSite = $prism_vfiler_pd | Select-Object -Property remote_site_names
                if (!$remoteSite.remote_site_names) 
                {#no remote site defined or no schedule on the pd with a remote site
                    Write-Host "$(get-date) [ERROR] There is no remote site defined for protection domain $pd" -ForegroundColor Red
                    Exit 1
                }
                if ($remoteSite -is [array]) 
                {#more than 1 remote site target defined on the pd schedule
                    Write-Host "$(get-date) [ERROR] There is more than one remote site for protection domain $pd" -ForegroundColor Red
                    Exit 1
                }
            #endregion

            #region GET networks (-prism)
                #get available networks from primary (/PrismGateway/services/rest/v2.0/networks/)
                #TODO check this works the same with esxi (testing on ahv for now)
                Write-Host "$(get-date) [INFO] Retrieving available networks from Nutanix cluster $($prism)..." -ForegroundColor Green
                $url = "https://$($prism):9440/PrismGateway/services/rest/v2.0/networks/"
                $method = "GET"
                $prism_cluster_networks = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                Write-Host "$(get-date) [SUCCESS] Successfully retrieved networks from Nutanix cluster $($prism)" -ForegroundColor Cyan

                #TODO enhance this to show list of networks available + capture other network details (gateway, pool, subnet mask)  Also this should be asking/checking on target cluster, not prism
                $prism_client_network_name = Read-Host "Enter the name of the client network to use for the file server"
                $prism_storage_network_name = Read-Host "Enter the name of the storage network to use for the file server"
            #endregion
            
            #region GET remote site details (PRISM)
                #get the remote site IP address
                Write-Host "$(get-date) [INFO] Retrieving details about remote site $($remoteSite.remote_site_names) ..." -ForegroundColor Green
                $url = "https://$($prism):9440/PrismGateway/services/rest/v2.0/remote_sites/$($remoteSite.remote_site_names)"
                $method = "GET"
                $remote_site_details = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                Write-Host "$(get-date) [SUCCESS] Successfully retrieved details about remote site $($remoteSite.remote_site_names)" -ForegroundColor Cyan

                if ($remote_site_details.remote_ip_ports.psobject.properties.count -gt 1)
                {#there are multiple IPs defined for the remote site
                    Write-Host "$(get-date) [ERROR] There is more than 1 IP configured for the remote site $remoteSite" -ForegroundColor Red
                    Exit 1
                }

                $remote_site_ip = $remote_site_details.remote_ip_ports.psobject.properties.name
            #endregion

            if ($failover -eq "planned") {
                $migrate_from_cluster = $prism
                $migrate_from_cluster_name = $prism_cluster_details.name
                $filer_activation_cluster = $remote_site_ip
                $filer_activation_cluster_name = $remote_cluster_details.name

                #region GET remote cluster details
                    #check if remote site is available (IF not, error out)
                    Write-Host "$(get-date) [INFO] Retrieving details of remote Nutanix cluster $($filer_activation_cluster) ..." -ForegroundColor Green
                    $url = "https://$($filer_activation_cluster):9440/PrismGateway/services/rest/v2.0/cluster/"
                    $method = "GET"
                    $remote_cluster_details = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                    Write-Host "$(get-date) [SUCCESS] Successfully retrieved details of remote Nutanix cluster $($filer_activation_cluster)" -ForegroundColor Cyan
                    Write-Host "$(get-date) [INFO] Hypervisor on remote Nutanix cluster $($filer_activation_cluster) is of type $($remote_cluster_details.hypervisor_types)." -ForegroundColor Green

                    #grab cluster name dns and ntp servers if they have not been specified in the reference data
                    $remote_dns_servers = $remote_cluster_details.name_servers
                    $remote_ntp_servers = $remote_cluster_details.ntp_servers
                    $filer_activation_cluster_name = $remote_cluster_details.name
                #endregion

                #region GET remote cluster networks
                    #get available networks from remote cluster (/PrismGateway/services/rest/v2.0/networks/)
                    Write-Host "$(get-date) [INFO] Retrieving available networks from remote Nutanix cluster $($filer_activation_cluster)..." -ForegroundColor Green
                    $url = "https://$($filer_activation_cluster):9440/PrismGateway/services/rest/v2.0/networks/"
                    $method = "GET"
                    $remote_cluster_networks = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                    Write-Host "$(get-date) [SUCCESS] Successfully retrieved networks from remote Nutanix cluster $($filer_activation_cluster)" -ForegroundColor Cyan
                    $remote_client_network_uuid = ($remote_cluster_networks.entities | Where-Object {$_.name -eq $prism_client_network_name}).uuid
                    $remote_storage_network_uuid = ($remote_cluster_networks.entities | Where-Object {$_.name -eq $prism_storage_network_name}).uuid
                    if (!$remote_client_network_uuid) {Write-Host "$(get-date) [ERROR] Could not find a network named $($prism_client_network_name) on remote Nutanix cluster $($filer_activation_cluster)!" -ForegroundColor Red; Exit 1}
                    if (!$remote_storage_network_uuid) {Write-Host "$(get-date) [ERROR] Could not find a network named $($prism_storage_network_name) on remote Nutanix cluster $($filer_activation_cluster)!" -ForegroundColor Red; Exit 1}
                    Write-Host "$(get-date) [INFO] Client network uuid on dr cluster is $($remote_client_network_uuid)" -ForegroundColor Green
                    Write-Host "$(get-date) [INFO] Storage network uuid on dr cluster is $($remote_storage_network_uuid)" -ForegroundColor Green
                #endregion

                #region GET remote cluster vfiler
                    #check status of file server on remote prism
                    Write-Host "$(get-date) [INFO] Retrieving details of file server $fsname status from remote Nutanix cluster $($filer_activation_cluster) ($($filer_activation_cluster_name))..." -ForegroundColor Green
                    $url = "https://$($filer_activation_cluster):9440/PrismGateway/services/rest/v1/vfilers/"
                    $method = "GET"
                    $remote_cluster_vfilers = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                    $remote_cluster_vfiler = $remote_cluster_vfilers.entities | Where-Object {$_.Name -eq $fsname}
                    if (!$remote_cluster_vfiler) {Write-Host "$(get-date) [ERROR] Could not find a file server called $fsname on remote Nutanix cluster $($filer_activation_cluster) ($($filer_activation_cluster_name))!" -ForegroundColor Red; Exit 1}
                    Write-Host "$(get-date) [SUCCESS] Successfully retrieved details of file server $fsname status from remote Nutanix cluster $($filer_activation_cluster) ($($filer_activation_cluster_name))" -ForegroundColor Cyan
                    Write-Host "$(get-date) [INFO] File server $fsname on remote Nutanix cluster $($filer_activation_cluster) ($($filer_activation_cluster_name)) has the following status: $($prism_cluster_vfiler.fileServerState)" -ForegroundColor Green
                #endregion

                #region GET remote cluster protection domain
                    #get protection domains from prism
                    Write-Host "$(get-date) [INFO] Retrieving protection domains from remote Nutanix cluster $($filer_activation_cluster) ($($filer_activation_cluster_name))..." -ForegroundColor Green
                    $url = "https://$($prism):9440/PrismGateway/services/rest/v2.0/protection_domains/"
                    $method = "GET"
                    $remote_pd_list = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                    Write-Host "$(get-date) [SUCCESS] Successfully retrieved protection domains from remote Nutanix cluster $($filer_activation_cluster) ($($filer_activation_cluster_name))" -ForegroundColor Cyan
                    
                    $remote_vfiler_pd = $remote_pd_list.entities | Where-Object {$_.name -eq $pd}
                    if (!$remote_vfiler_pd) {Write-Host "$(get-date) [ERROR] Could not find a protection domain called $pd on remote Nutanix cluster $($filer_activation_cluster) ($($filer_activation_cluster_name))!" -ForegroundColor Red; Exit 1}
                #endregion
            }

            if ($failover -eq "unplanned") {
                $prism_dns_servers = $prism_cluster_details.name_servers
                $prism_ntp_servers = $prism_cluster_details.ntp_servers
                $filer_activation_cluster = $prism
                $filer_activation_cluster_name = $prism_cluster_details.name
                $prism_client_network_uuid = ($prism_cluster_networks.entities | Where-Object {$_.name -eq $prism_client_network_name}).uuid
                $prism_storage_network_uuid = ($prism_cluster_networks.entities | Where-Object {$_.name -eq $prism_storage_network_name}).uuid
                if (!$prism_client_network_uuid) {Write-Host "$(get-date) [ERROR] Could not find a network named $($prism_client_network_name) on Nutanix cluster $($prism)!" -ForegroundColor Red; Exit 1}
                if (!$prism_storage_network_uuid) {Write-Host "$(get-date) [ERROR] Could not find a network named $($prism_storage_network_name) on Nutanix cluster $($prism)!" -ForegroundColor Red; Exit 1}
                Write-Host "$(get-date) [INFO] Client network uuid on cluster is $($prism_client_network_uuid)" -ForegroundColor Green
                Write-Host "$(get-date) [INFO] Storage network uuid on cluster is $($prism_storage_network_uuid)" -ForegroundColor Green
            }
        }
    #endregion

    #region deactivate
    #endregion

    #region failover pd
        if ($failover -eq "planned") {

            Write-Host ""
            Write-Host "$(get-date) [STEP] --Triggering Protection Domain Migration from $($migrate_from_cluster_name)--" -ForegroundColor Magenta 

            $processed_pds = Invoke-NtnxPdMigration -pd $pd -cluster $migrate_from_cluster -credential $prismCredentials
            if ($debugme) {Write-Host "$(get-date) [DEBUG] Processed pds: $processed_pds" -ForegroundColor White}
            Get-PrismPdTaskStatus -time $StartEpochSeconds -cluster $migrate_from_cluster -credential $prismCredentials -operation "deactivate"

            #check status of activation on remote site
            #region check remote
                #let's retrieve the list of protection domains
                Write-Host "$(get-date) [INFO] Retrieving protection domains from Nutanix cluster $migrate_from_cluster ..." -ForegroundColor Green
                $url = "https://$($migrate_from_cluster):9440/PrismGateway/services/rest/v2.0/protection_domains/"
                $method = "GET"
                $PdList = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                Write-Host "$(get-date) [SUCCESS] Successfully retrieved protection domains from Nutanix cluster $migrate_from_cluster" -ForegroundColor Cyan

                ForEach ($protection_domain in $processed_pds)
                {#figure out the remote site ips
                    #region figure out the remote site
                        #figure out if there is more than one remote site defined for the protection domain
                        $remoteSite = $PdList.entities | Where-Object {$_.name -eq $protection_domain} | Select-Object -Property remote_site_names
                        if (!$remoteSite.remote_site_names) 
                        {#no remote site defined or no schedule on the pd with a remote site
                            Write-Host "$(get-date) [ERROR] There is no remote site defined for protection domain $protection_domain" -ForegroundColor Red
                            Exit
                        }
                        if ($remoteSite -is [array]) 
                        {#more than 1 remote site target defined on the pd schedule
                            Write-Host "$(get-date) [ERROR] There is more than one remote site for protection domain $protection_domain" -ForegroundColor Red
                            Exit
                        }

                        #get the remote site IP address
                        Write-Host "$(get-date) [INFO] Retrieving details about remote site $($remoteSite.remote_site_names) ..." -ForegroundColor Green
                        $url = "https://$($migrate_from_cluster):9440/PrismGateway/services/rest/v2.0/remote_sites/$($remoteSite.remote_site_names)"
                        $method = "GET"
                        $remote_site = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
                        Write-Host "$(get-date) [SUCCESS] Successfully retrieved details about remote site $($remoteSite.remote_site_names)" -ForegroundColor Cyan

                        if ($remote_site.remote_ip_ports.psobject.properties.count -gt 1)
                        {#there are multiple IPs defined for the remote site
                            Write-Host "$(get-date) [ERROR] There is more than 1 IP configured for the remote site $remoteSite" -ForegroundColor Red
                            Exit
                        }
                    #endregion
                    
                    if ($remote_site_ips -notcontains $remote_site.remote_ip_ports.psobject.properties.name)
                    {#we haven't had that remote site yet
                        $remote_site_ips += $remote_site.remote_ip_ports.psobject.properties.name #add remote site ip to an array here
                    }
                    
                }

                ForEach ($remote_site_ip in $remote_site_ips)
                {#check the protection domains have been successfully activated on each remote site
                    Get-PrismPdTaskStatus -time $StartEpochSeconds -cluster $remote_site_ip -credential $prismCredentials -operation "activate"
                }
            #endregion

            #TODO check remote site configured on PD matches dr site in reference file
        }

        if ($failover -eq "unplanned") {
            Write-Host ""
            Write-Host "$(get-date) [STEP] --Triggering Protection Domain Activation--" -ForegroundColor Magenta

            if ($reference_data) {
                $cluster = $reference_data.{prism-dr}              
                if ($reference_data.pd) {
                    $pd = $reference_data.pd
                } else {
                    $pd = "NTNX-$($reference_data.fsname)"
                }
                
                #safeguard here to check if primary cluster is responding to ping before triggering activation
                Write-Host "$(get-date) [INFO] Trying to ping IP $($reference_data.{prism-primary}) ..." -ForegroundColor Green
                if ((Test-Connection $reference_data.{prism-primary} -Count 5))
                {#ping was successfull
                    if ($force) {
                        Write-Host "$(get-date) [WARN] Can ping primary site Nutanix cluster IP $($reference_data.{prism-primary}). Continuing with protection domain activation since you used -force..." -ForegroundColor Yellow
                        #TODO add prompt here to continue and enhance warning text
                    } else {
                        Write-Host "$(get-date) [ERROR] Can ping primary site Nutanix cluster IP $($reference_data.{prism-primary}). Aborting protection domain activation!" -ForegroundColor Red
                        Exit 1
                    }
                } 
                else 
                {#ping failed
                    Write-Host "$(get-date) [SUCCESS] Cannot ping primary site Nutanix cluster IP $($reference_data.{prism-primary}). Proceeding with protection domain activation on DR."
                }                
            } else {
                $cluster = $prism
                #TODO: add safeguard here to check if primary cluster is responding to ping before triggering activation

                #safeguard here to check if primary cluster is responding to ping before triggering activation
                Write-Host "$(get-date) [INFO] Trying to ping IP $($reference_data.{prism-primary}) ..." -ForegroundColor Green
                if ((Test-Connection $remote_site_ip -Count 5))
                {#ping was successfull
                    if ($force) {
                        Write-Host "$(get-date) [WARN] Can ping remote site Nutanix cluster IP $($remote_site_ip). Continuing with protection domain activation since you used -force..." -ForegroundColor Yellow
                        #TODO add prompt here to continue and enhance warning text
                    } else {
                        Write-Host "$(get-date) [ERROR] Can ping remote site Nutanix cluster IP $($remote_site_ip). Aborting protection domain activation!" -ForegroundColor Red
                        Exit 1
                    }
                } 
                else 
                {#ping failed
                    Write-Host "$(get-date) [SUCCESS] Cannot ping remote site Nutanix cluster IP $($remote_site_ip). Proceeding with protection domain activation on DR."
                }
            }

            $processed_pds = Invoke-NtnxPdActivation -pd $pd -cluster $cluster -credential $prismCredentials
            if ($debugme) {Write-Host "$(get-date) [DEBUG] Processed pds: $processed_pds" -ForegroundColor White}
            Get-PrismPdTaskStatus -time $StartEpochSeconds -cluster $cluster -credential $prismCredentials -operation "activate"
        }
        #TODO if MAIL, send notification email
    #endregion

    #region activate file server
        Write-Host ""
        Write-Host "$(get-date) [STEP] --Activating vFiler $($fsname) on Nutanix cluster $($filer_activation_cluster) ($($filer_activation_cluster_name))--" -ForegroundColor Magenta
        #get file servers uuids and other network configuration details required for activation
        if ($reference_data) {
            $fsname = "$($reference_data.fsname)"
            if ($filer_activation_cluster -eq $reference_data.{prism-primary}) {
                $vfiler_uuid = $primary_cluster_vfiler.uuid

                $internalNetwork_subnetMask = "$($reference_data.{primary-storage-network-subnet})"
                $internalNetwork_defaultGateway = "$($reference_data.{primary-storage-network-gateway})"
                $internalNetwork_uuid = "$($primary_storage_network_uuid)"
                if ($reference_data.{primary-storage-network-startip} -and $reference_data.{primary-storage-network-endip}) {
                    $internalNetwork_pool = "$($reference_data.{primary-storage-network-startip}) $($reference_data.{primary-storage-network-endip})"
                } else {
                    $internalNetwork_pool = $null
                }

                $externalNetwork_subnetMask = "$($reference_data.{primary-client-network-subnet})"
                $externalNetwork_defaultGateway = "$($reference_data.{primary-client-network-gateway})"
                $externalNetwork_uuid = "$($primary_client_network_uuid)"
                if ($reference_data.{primary-client-network-startip} -and $reference_data.{primary-client-network-endip}) {
                    $externalNetwork_pool = "$($reference_data.{primary-client-network-startip}) $($reference_data.{primary-client-network-endip})"
                } else {
                    $externalNetwork_pool = $null
                }

                $dns_servers = $primary_dns_servers
                $ntp_servers = $primary_ntp_servers
            } elseif ($filer_activation_cluster -eq $reference_data.{prism-dr}) {
                $vfiler_uuid = $dr_cluster_vfiler.uuid

                $internalNetwork_subnetMask = "$($reference_data.{dr-storage-network-subnet})"
                $internalNetwork_defaultGateway = "$($reference_data.{dr-storage-network-gateway})"
                $internalNetwork_uuid = "$($dr_storage_network_uuid)"
                $internalNetwork_pool = "$($reference_data.{dr-storage-network-startip}) $($reference_data.{dr-storage-network-endip})"

                $externalNetwork_subnetMask = "$($reference_data.{dr-client-network-subnet})"
                $externalNetwork_defaultGateway = "$($reference_data.{dr-client-network-gateway})"
                $externalNetwork_uuid = "$($dr_client_network_uuid)"
                $externalNetwork_pool = "$($reference_data.{dr-client-network-startip}) $($reference_data.{dr-client-network-endip})"

                $dns_servers = $dr_dns_servers
                $ntp_servers = $dr_ntp_servers
            }
        } else {
            #figure out which cluster we are activating this on and what the filer uuid is (this will vary based on planned or unplanned)
            if ($failover -eq "planned") {
                $vfiler_uuid = $remote_cluster_vfiler.uuid
                $dns_servers = $remote_dns_servers
                $ntp_servers = $remote_ntp_servers

                $internalNetwork_subnetMask = Read-Host "Enter the subnet mask (exp:255.255.255.0) for the storage network (leave blank if the network is managed)"
                $internalNetwork_defaultGateway = Read-Host "Enter the gateway ip for the storage network (leave blank if the network is managed)"
                $internalNetwork_uuid = "$($remote_storage_network_uuid)"
                $internalNetworkStartIp = Read-Host "Enter the start ip for the storage network (leave blank if the network is managed)"
                $internalNetworkEndIp = Read-Host "Enter the last ip for the storage network (leave blank if the network is managed)"
                $internalNetwork_pool = "$($internalNetworkStartIp) $($internalNetworkEndIp)"

                $externalNetwork_subnetMask = Read-Host "Enter the subnet mask (exp:255.255.255.0) for the client network (leave blank if the network is managed)"
                $externalNetwork_defaultGateway = Read-Host "Enter the gateway ip for the client network (leave blank if the network is managed)"
                $externalNetwork_uuid = "$($remote_client_network_uuid)"
                $externalNetworkStartIp = Read-Host "Enter the start ip for the client network (leave blank if the network is managed)"
                $externalNetworkEndIp = Read-Host "Enter the last ip for the client network (leave blank if the network is managed)"
                $externalNetwork_pool = "$($externalNetworkStartIp) $($externalNetworkEndIp)"
            }
            if ($failover -eq "unplanned") {
                $vfiler_uuid = $prism_cluster_vfiler.uuid
                $dns_servers = $prism_dns_servers
                $ntp_servers = $prism_ntp_servers

                $internalNetwork_subnetMask = Read-Host "Enter the subnet mask (exp:255.255.255.0) for the storage network (leave blank if the network is managed)"
                $internalNetwork_defaultGateway = Read-Host "Enter the gateway ip for the storage network (leave blank if the network is managed)"
                $internalNetwork_uuid = "$($prism_storage_network_uuid)"
                $internalNetworkStartIp = Read-Host "Enter the start ip for the storage network (leave blank if the network is managed)"
                $internalNetworkEndIp = Read-Host "Enter the last ip for the storage network (leave blank if the network is managed)"
                $internalNetwork_pool = "$($internalNetworkStartIp) $($internalNetworkEndIp)"

                $externalNetwork_subnetMask = Read-Host "Enter the subnet mask (exp:255.255.255.0) for the client network (leave blank if the network is managed)"
                $externalNetwork_defaultGateway = Read-Host "Enter the gateway ip for the client network (leave blank if the network is managed)"
                $externalNetwork_uuid = "$($prism_client_network_uuid)"
                $externalNetworkStartIp = Read-Host "Enter the start ip for the client network (leave blank if the network is managed)"
                $externalNetworkEndIp = Read-Host "Enter the last ip for the client network (leave blank if the network is managed)"
                $externalNetwork_pool = "$($externalNetworkStartIp) $($externalNetworkEndIp)"
            }
        }
        
        #build the json payload here
        $content = @{
            name = $fsname;
            internalNetwork = @{
                subnetMask = $internalNetwork_subnetMask;
                defaultGateway = $internalNetwork_defaultGateway;
                uuid = $internalNetwork_uuid;
                pool = @(
                    $(if ($internalNetwork_pool) {$internalNetwork_pool})
                )
            };
            externalNetworks = @(
                @{
                    subnetMask = $externalNetwork_subnetMask;
                    defaultGateway = $externalNetwork_defaultGateway;
                    uuid = $externalNetwork_uuid;
                    pool = @(
                        $(if ($externalNetwork_pool) {$externalNetwork_pool})
                    )
                }
            );
            dnsServerIpAddresses = @(
                $dns_servers
            );
            ntpServers = @(
                $ntp_servers
            )
        }
        $payload = (ConvertTo-Json $content -Depth 4)

        #* activate (POST /v1/vfilers/{$vfiler_uuid}/activate): response is a taskUuid
        Write-Host "$(get-date) [INFO] Activating file server $($fsname) on Nutanix cluster $($filer_activation_cluster) ($($filer_activation_cluster_name))..." -ForegroundColor Green
        $url = "https://$($filer_activation_cluster):9440/PrismGateway/services/rest/v1/vfilers/$($vfiler_uuid)/activate"
        $method = "POST"
        $vfiler_activation_task_uuid = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials -payload $payload
        Write-Host "$(get-date) [SUCCESS] Successfully triggered activation of file server $($fsname) on Nutanix cluster $($filer_activation_cluster) ($($filer_activation_cluster_name)) (task: $($vfiler_activation_task_uuid.taskUuid))" -ForegroundColor Cyan

        #check on file server activation task status
        Get-PrismTaskStatus -task $vfiler_activation_task_uuid.taskUuid -cluster $filer_activation_cluster -credential $prismCredentials
        
        #TODO if MAIL, send notification email
    #endregion
    
    #region update DNS
        if ($dns) {
            Write-Host ""
            Write-Host "$(get-date) [STEP] --Updating DNS records for vFiler $($fsname) on cluster $($filer_activation_cluster) ($($filer_activation_cluster_name))--" -ForegroundColor Magenta
            #if DNS, send API call to update DNS            
            $content = @{
                dnsOpType = "MS_DNS";
                dnsServer= "";
                dnsUserName= $ad_credentials.UserName;
                dnsPassword= $ad_credentials.GetNetworkCredential().password
            }
            $payload = (ConvertTo-Json $content -Depth 4)
    
            #* activate (POST /v1/vfilers/$($file_server_uuid)/addDns): response is a taskUuid
            Write-Host "$(get-date) [INFO] Updating DNS records for file server $($fsname) on Nutanix cluster $($filer_activation_cluster) ($($filer_activation_cluster_name))..." -ForegroundColor Green
            $url = "https://$($filer_activation_cluster):9440/PrismGateway/services/rest/v1/vfilers/$($vfiler_uuid)/addDns"
            $method = "POST"
            $vfiler_dns_update_task_uuid = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials -payload $payload
            Write-Host "$(get-date) [SUCCESS] Successfully triggered update of DNS records for file server $($fsname) on Nutanix cluster $($filer_activation_cluster) ($($filer_activation_cluster_name)) (task: $($vfiler_activation_task_uuid.taskUuid))" -ForegroundColor Cyan

            #check on DNS update task status
            Get-PrismTaskStatus -task $vfiler_dns_update_task_uuid.taskUuid -cluster $filer_activation_cluster -credential $prismCredentials

            #TODO if MAIL, send notification email
        }
    #endregion

    #region print final file server status
        Write-Host ""
        Write-Host "$(get-date) [STEP] --Getting final status for vFiler $($fsname) on cluster $($filer_activation_cluster) ($($filer_activation_cluster_name))--" -ForegroundColor Magenta
        #check status of file server
        Write-Host "$(get-date) [INFO] Retrieving details of file server $fsname status from Nutanix cluster $($filer_activation_cluster) ($($filer_activation_cluster_name))..." -ForegroundColor Green
        $url = "https://$($filer_activation_cluster):9440/PrismGateway/services/rest/v1/vfilers/"
        $method = "GET"
        $vfilers = Invoke-PrismRESTCall -method $method -url $url -credential $prismCredentials
        $vfiler = $vfilers.entities | Where-Object {$_.Name -eq $fsname}
        if (!$vfiler) {Write-Host "$(get-date) [ERROR] Could not find a file server called $fsname on Nutanix cluster $($filer_activation_cluster) ($($filer_activation_cluster_name))!" -ForegroundColor Red; Exit 1}
        Write-Host "$(get-date) [SUCCESS] Successfully retrieved details of file server $fsname status from Nutanix cluster $($filer_activation_cluster) ($($filer_activation_cluster_name))" -ForegroundColor Cyan
        Write-Host "$(get-date) [INFO] File server $fsname on Nutanix cluster $($filer_activation_cluster) ($($filer_activation_cluster_name)) has the following status: $($vfiler.fileServerState)" -ForegroundColor Green
        #TODO if MAIL, send notification email
    #endregion

#endregion

#region cleanup
    #let's figure out how much time this all took
    Write-Host "$(get-date) [SUM] total processing time: $($myvarElapsedTime.Elapsed.ToString())" -ForegroundColor Magenta

    #cleanup after ourselves and delete all custom variables
    Remove-Variable myvar* -ErrorAction SilentlyContinue
    Remove-Variable ErrorActionPreference -ErrorAction SilentlyContinue
    Remove-Variable help -ErrorAction SilentlyContinue
    Remove-Variable history -ErrorAction SilentlyContinue
    Remove-Variable log -ErrorAction SilentlyContinue
    Remove-Variable cluster -ErrorAction SilentlyContinue
    Remove-Variable username -ErrorAction SilentlyContinue
    Remove-Variable password -ErrorAction SilentlyContinue
    Remove-Variable debugme -ErrorAction SilentlyContinue
#endregion