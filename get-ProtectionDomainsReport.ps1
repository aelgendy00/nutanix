<#
.SYNOPSIS
  This script retrieves the list of protection domains from a given Nutanix cluster.
.DESCRIPTION
  The script uses v2 REST API in Prism to GET the list of protection_domains from Prism Element.
.PARAMETER help
  Displays a help message (seriously, what did you think this was?)
.PARAMETER history
  Displays a release history for this script (provided the editors were smart enough to document this...)
.PARAMETER log
  Specifies that you want the output messages to be written in a log file as well as on the screen.
.PARAMETER debugme
  Turns off SilentlyContinue on unexpected error messages.
.PARAMETER cluster
  Nutanix cluster fully qualified domain name or IP address.
.PARAMETER username
  Username used to connect to the Nutanix cluster.
.PARAMETER password
  Password used to connect to the Nutanix cluster.
.PARAMETER prismCreds
  Specifies a custom credentials file name (will look for %USERPROFILE\Documents\WindowsPowerShell\CustomCredentials\$prismCreds.txt). These credentials can be created using the Powershell command 'Set-CustomCredentials -credname <credentials name>'. See https://blog.kloud.com.au/2016/04/21/using-saved-credentials-securely-in-powershell-scripts/ for more details.
.PARAMETER email
  Specifies that you want to email the output. This requires that you set up variables inside the script for smtp gateway and recipients.

.EXAMPLE
.\get-ProtectionDomainsReport.ps1 -cluster ntnxc1.local -username admin -password admin
Retrieve the list of unprotected VMs from cluster ntnxc1.local

.LINK
  http://www.nutanix.com/services
.LINK
  https://github.com/sbourdeaud/nutanix
.NOTES
  Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
  Revision: Mar 25th 2020
#>

#region parameters
######################################
##   parameters and initial setup   ##
######################################
#let's start with some command line parsing
Param
(
    #[parameter(valuefrompipeline = $true, mandatory = $true)] [PSObject]$myParam1,
    [parameter(mandatory = $false)] [switch]$help,
    [parameter(mandatory = $false)] [switch]$history,
    [parameter(mandatory = $false)] [switch]$log,
    [parameter(mandatory = $false)] [switch]$debugme,
    [parameter(mandatory = $true)] [string]$cluster,
    [parameter(mandatory = $false)] [string]$username,
    [parameter(mandatory = $false)] [string]$password,
    [parameter(mandatory = $false)] $prismCreds,
    [parameter(mandatory = $false)] [switch]$email
)
#endregion

#region functions
#this function is used to create saved credentials for the current user
function Set-CustomCredentials 
{
#input: path, credname
	#output: saved credentials file
<#
.SYNOPSIS
  Creates a saved credential file using DAPI for the current user on the local machine.
.DESCRIPTION
  This function is used to create a saved credential file using DAPI for the current user on the local machine.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER path
  Specifies the custom path where to save the credential file. By default, this will be %USERPROFILE%\Documents\WindowsPowershell\CustomCredentials.
.PARAMETER credname
  Specifies the credential file name.
.EXAMPLE
.\Set-CustomCredentials -path c:\creds -credname prism-apiuser
Will prompt for user credentials and create a file called prism-apiuser.txt in c:\creds
#>
	param
	(
		[parameter(mandatory = $false)]
        [string] 
        $path,
		
        [parameter(mandatory = $true)]
        [string] 
        $credname
	)

    begin
    {
        if (!$path)
        {
            if ($IsLinux -or $IsMacOS) 
            {
                $path = $home
            }
            else 
            {
                $path = "$Env:USERPROFILE\Documents\WindowsPowerShell\CustomCredentials"
            }
            Write-Host "$(get-date) [INFO] Set path to $path" -ForegroundColor Green
        } 
    }
    process
    {
        #prompt for credentials
        $credentialsFilePath = "$path\$credname.txt"
		$credentials = Get-Credential -Message "Enter the credentials to save in $path\$credname.txt"
		
		#put details in hashed format
		$user = $credentials.UserName
		$securePassword = $credentials.Password
        
        #convert secureString to text
        try 
        {
            $password = $securePassword | ConvertFrom-SecureString -ErrorAction Stop
        }
        catch 
        {
            throw "$(get-date) [ERROR] Could not convert password : $($_.Exception.Message)"
        }

        #create directory to store creds if it does not already exist
        if(!(Test-Path $path))
		{
            try 
            {
                $result = New-Item -type Directory $path -ErrorAction Stop
            } 
            catch 
            {
                throw "$(get-date) [ERROR] Could not create directory $path : $($_.Exception.Message)"
            }
		}

        #save creds to file
        try 
        {
            Set-Content $credentialsFilePath $user -ErrorAction Stop
        } 
        catch 
        {
            throw "$(get-date) [ERROR] Could not write username to $credentialsFilePath : $($_.Exception.Message)"
        }
        try 
        {
            Add-Content $credentialsFilePath $password -ErrorAction Stop
        } 
        catch 
        {
            throw "$(get-date) [ERROR] Could not write password to $credentialsFilePath : $($_.Exception.Message)"
        }

        Write-Host "$(get-date) [SUCCESS] Saved credentials to $credentialsFilePath" -ForegroundColor Cyan                
    }
    end
    {}
}

#this function is used to retrieve saved credentials for the current user
function Get-CustomCredentials 
{
#input: path, credname
	#output: credential object
<#
.SYNOPSIS
  Retrieves saved credential file using DAPI for the current user on the local machine.
.DESCRIPTION
  This function is used to retrieve a saved credential file using DAPI for the current user on the local machine.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER path
  Specifies the custom path where the credential file is. By default, this will be %USERPROFILE%\Documents\WindowsPowershell\CustomCredentials.
.PARAMETER credname
  Specifies the credential file name.
.EXAMPLE
.\Get-CustomCredentials -path c:\creds -credname prism-apiuser
Will retrieve credentials from the file called prism-apiuser.txt in c:\creds
#>
	param
	(
        [parameter(mandatory = $false)]
		[string] 
        $path,
		
        [parameter(mandatory = $true)]
        [string] 
        $credname
	)

    begin
    {
        if (!$path)
        {
            if ($IsLinux -or $IsMacOS) 
            {
                $path = $home
            }
            else 
            {
                $path = "$Env:USERPROFILE\Documents\WindowsPowerShell\CustomCredentials"
            }
            Write-Host "$(get-date) [INFO] Retrieving credentials from $path" -ForegroundColor Green
        } 
    }
    process
    {
        $credentialsFilePath = "$path\$credname.txt"
        if(!(Test-Path $credentialsFilePath))
	    {
            throw "$(get-date) [ERROR] Could not access file $credentialsFilePath : $($_.Exception.Message)"
        }

        $credFile = Get-Content $credentialsFilePath
		$user = $credFile[0]
		$securePassword = $credFile[1] | ConvertTo-SecureString

        $customCredentials = New-Object System.Management.Automation.PSCredential -ArgumentList $user, $securePassword

        Write-Host "$(get-date) [SUCCESS] Returning credentials from $credentialsFilePath" -ForegroundColor Cyan 
    }
    end
    {
        return $customCredentials
    }
}

#this function is used to make a REST api call to Prism
function Invoke-PrismAPICall
{
<#
.SYNOPSIS
  Makes api call to prism based on passed parameters. Returns the json response.
.DESCRIPTION
  Makes api call to prism based on passed parameters. Returns the json response.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER path
  Specifies the custom path where the credential file is. By default, this will be %USERPROFILE%\Documents\WindowsPowershell\CustomCredentials.
.PARAMETER credname
  Specifies the credential file name.
.EXAMPLE
.\Get-CustomCredentials -path c:\creds -credname prism-apiuser
Will retrieve credentials from the file called prism-apiuser.txt in c:\creds
#>
param
(
    [parameter(mandatory = $true)]
    [ValidateSet("POST","GET","DELETE","PUT")]
    [string] 
    $method,
    
    [parameter(mandatory = $true)]
    [string] 
    $url,

    [parameter(mandatory = $false)]
    [string] 
    $payload,
    
    [parameter(mandatory = $true)]
    [System.Management.Automation.PSCredential]
    $credential
)

begin
{
    if (($PSVersionTable.PSVersion.Major -gt 5) -and (!$credential)) {
        throw "$(get-date) [ERROR] You must specify a credential object when using Powershell Core!"
    }
    if (($PSVersionTable.PSVersion.Major -le 5) -and (!$username) -and (!$password))  {
        throw "$(get-date) [ERROR] You must specify a username and password (as a secure string)!"
    }   
}
process
{
    Write-Host "$(Get-Date) [INFO] Making a $method call to $url" -ForegroundColor Green
    try {
        #check powershell version as PoSH 6 Invoke-RestMethod can natively skip SSL certificates checks and enforce Tls12 as well as use basic authentication with a pscredential object
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            $headers = @{
                "Content-Type"="application/json";
                "Accept"="application/json"
            }
            if ($payload) {
                $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -Body $payload -SkipCertificateCheck -SslProtocol Tls12 -Authentication Basic -Credential $credential -ErrorAction Stop
            } else {
                $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -SkipCertificateCheck -SslProtocol Tls12 -Authentication Basic -Credential $credential -ErrorAction Stop
            }
        } else {
            $headers = @{
                "Authorization" = "Basic "+[System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($username+":"+([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) ));
                "Content-Type"="application/json";
                "Accept"="application/json"
            }
            if ($payload) {
                $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -Body $payload -ErrorAction Stop
            } else {
                $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -ErrorAction Stop
            }
        }
        Write-Host "$(get-date) [SUCCESS] Call $method to $url succeeded." -ForegroundColor Cyan 
        if ($debugme) {Write-Host "$(Get-Date) [DEBUG] Response Metadata: $($resp.metadata | ConvertTo-Json)" -ForegroundColor White}
    }
    catch {
        $saved_error = $_.Exception.Message
        # Write-Host "$(Get-Date) [INFO] Headers: $($headers | ConvertTo-Json)"
        Write-Host "$(Get-Date) [INFO] Payload: $payload" -ForegroundColor Green
        Throw "$(get-date) [ERROR] $saved_error"
    }
    finally {
        #add any last words here; this gets processed no matter what
    }
}
end
{
    return $resp
}    
}
#endregion

#region prepwork
# get rid of annoying error messages
if (!$debugme) {$ErrorActionPreference = "SilentlyContinue"}
#check if we need to display help and/or history
$HistoryText = @'
 Maintenance Log
 Date       By   Updates (newest updates at the top)
 ---------- ---- ---------------------------------------------------------------
 03/25/2020 sb   Initial release.
################################################################################
'@
$myvarScriptName = ".\get-UnprotectedVms.ps1"
 
if ($help) {get-help $myvarScriptName; exit}
if ($History) {$HistoryText; exit}

#check PoSH version
if ($PSVersionTable.PSVersion.Major -lt 5) {throw "$(get-date) [ERROR] Please upgrade to Powershell v5 or above (https://www.microsoft.com/en-us/download/details.aspx?id=50395)"}

# ignore SSL warnings
Write-Host "$(Get-Date) [INFO] Ignoring invalid certificates" -ForegroundColor Green
if (-not ([System.Management.Automation.PSTypeName]'ServerCertificateValidationCallback').Type) {
    $certCallback = @"
    using System;
    using System.Net;
    using System.Net.Security;
    using System.Security.Cryptography.X509Certificates;
    public class ServerCertificateValidationCallback
    {
        public static void Ignore()
        {
            if(ServicePointManager.ServerCertificateValidationCallback ==null)
            {
                ServicePointManager.ServerCertificateValidationCallback += 
                    delegate
                    (
                        Object obj, 
                        X509Certificate certificate, 
                        X509Chain chain, 
                        SslPolicyErrors errors
                    )
                    {
                        return true;
                    };
            }
        }
    }
"@
    Add-Type $certCallback
}
[ServerCertificateValidationCallback]::Ignore()

# add Tls12 support
Write-Host "$(Get-Date) [INFO] Adding Tls12 support" -ForegroundColor Green
[Net.ServicePointManager]::SecurityProtocol = `
    ([Net.ServicePointManager]::SecurityProtocol -bor `
    [Net.SecurityProtocolType]::Tls12)

#endregion

#region variables

    #! Constants (for -email)
    $smtp_gateway = "" #add your smtp gateway address here
    $smtp_port = 25 #customize the smtp port here if necessary
    $recipients = "" #add a comma separated value of valid email addresses here
    $from = "" #add the from email address here
    $subject = "WARNING: Protection domains in Nutanix cluster $cluster" #customize the subject here
    $body = "Please open the attached csv file and review protection domains on cluster $cluster"

    #initialize variables
	$ElapsedTime = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp

    [System.Collections.ArrayList]$myvarResults = New-Object System.Collections.ArrayList($null)
#endregion

#region parameters validation
	############################################################################
	# command line arguments initialization
	############################################################################
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
    
#endregion

#region processing	
	################################
	##  Main execution here       ##
	################################
   
    #retrieving all protection domains
    Write-Host "$(get-date) [INFO] Retrieving list of protection domains..." -ForegroundColor Green
    $url = "https://$($cluster):9440/api/nutanix/v2.0/protection_domains"
    $method = "GET"
    $pdList = Invoke-PrismAPICall -method $method -url $url -credential $prismCredentials
    Write-Host "$(get-date) [SUCCESS] Successfully retrieved protection domains list from $cluster!" -ForegroundColor Cyan

    
    Foreach ($entity in $pdList.entities) {
        $myvarPdInfo = [ordered]@{
            "name" = $entity.name;
            "metro_avail" = $entity.metro_avail;
            "total_user_written_bytes" = $entity.total_user_written_bytes;
            "exclusive_snapshot_usage_bytes" = $entity.usage_stats."dr.exclusive_snapshot_usage_bytes";
            "vms" = (($entity.vms | Select-Object -Property vm_name).vm_name) -join ',';
            "remote_site_names" = $entity.remote_site_names -join ',';
            "cron_schedules" = (($entity.cron_schedules | Select-Object -Property type).type) -join ',';
            "schedules_suspended" = $entity.schedules_suspended;
        }
        #store the results for this entity in our overall result variable
        $myvarResults.Add((New-Object PSObject -Property $myvarPdInfo)) | Out-Null
    }#end foreach vm

    Write-Host "$(Get-Date) [INFO] Writing results to $(Get-Date -UFormat "%Y_%m_%d_%H_%M_")PdList.csv" -ForegroundColor Green
    $myvarResults | export-csv -NoTypeInformation $($(Get-Date -UFormat "%Y_%m_%d_%H_%M_")+"PdList.csv")

    if ($email -and ($pdList.metadata.count -ge 1))
    {#user wants to send email and we have results
        Write-Host "$(get-date) [INFO] Emailing unprotected-vms.csv..." -ForegroundColor Green
        if ((!$smtp_gateway) -and (!$recipients) -and (!$from))
        {#user hasn't customized the script to enable email
            Write-Host "$(get-date) [ERROR] You must configure the smtp_gateway, recipients and from constants in the script (search for Constants in the script source code)!" -ForegroundColor Red
            Exit
        }
        else 
        {
            $attachment = ".\$($(Get-Date -UFormat "%Y_%m_%d_%H_%M_")+"PdList.csv")"
            Send-MailMessage -From $from -to $recipients -Subject $subject -Body $body -SmtpServer $smtp_gateway -port $smtp_port -Attachments $attachment 
        }
    }


#endregion

#region cleanup
#########################
##       cleanup       ##
#########################

	#let's figure out how much time this all took
    Write-Host "$(get-date) [SUM] total processing time: $($ElapsedTime.Elapsed.ToString())" -ForegroundColor Magenta
	
#endregion