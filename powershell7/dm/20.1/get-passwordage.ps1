# Connect to the following servers
# Data Manager Servers
$dms = @(
    @{
        name = "192.168.xxx.xxx"
    }
)
# Report
$ReportName = "Password Aging Report"
$ReportOutPath = ".\"
$ReportOutFile = "$($ReportOutPath)\$((Get-Date).
    ToString("yyy-MM-dd"))_$($ReportName).csv"

# Get the current date time
# Subtract the look back
# Convert to UTC
$sDate = (Get-Date).
AddDays(-$lookBack).
ToUniversalTime()

# Number of days to look back
$lookBack = 1

# Email Settings
$EmailSend = $false
$EmailHtml = $false
$EmailFrom = "sender@fake.com"
$EmailTo = "recipient1@fake.com, recipient2@fake.com"
$EmailSubject = "Daily | $($ReportName)"

# SMTP Relay Settings
$SmtpRelay = "smtpmail.fake.com"
$Port = 25

# FUNCTIONS
# DO NOT MODIFY BELOW THIS LINE
function connect-dmapi {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$Server,
        [Parameter(Mandatory=$true)]
        [int]$Port,
        [Parameter(Mandatory=$true)]
        [int]$Version,
        [switch]$Refresh
    )
    begin {
            # CHECK TO SEE IF CREDENTIALS EXISTS IF NOT CREATE THEM
            $Exists = Test-Path -Path ".\$($Server).xml" -PathType Leaf
            if($Exists) {
                $Credential = Import-CliXml ".\$($Server).xml"
            } else {
                $Credential = Get-Credential
                $Credential | Export-CliXml ".\$($Server).xml"
            }  
    }
    process {
        if(!$Refresh) {
            try {
                # Build the request body
                $body = @{
                    username="$($Credential.username)"
                    password="$(
                        ConvertFrom-SecureString `
                        -SecureString $Credential.password `
                        -AsPlainText
                    )"
                }
                # Request a bearer token 
                $auth = `
                Invoke-RestMethod `
                -Uri "https://$($Server):$($Port)/api/v$($Version)/login" `
                -Method POST `
                -ContentType 'application/json' `
                -Body (ConvertTo-Json $body) `
                -SkipCertificateCheck

                # Create the response object
                $object = [ordered]@{
                    dm = "https://$($Server):$($Port)/api"
                    dmFqdn = $Server
                    dmPort = $Port
                    tokenApi = $auth.access_token
                    tokenType = $auth.token_type
                    tokenRefresh = $auth.refresh_token
                    headerToken = @{
                        authorization = "$($auth.token_type) $($auth.access_token)"
                    }
                    headerRefresh = @{
                        authorization = "$($auth.token_type) $($auth.refresh_token)"
                    }
                } # End Object
                $global:dmAuthObject = (
                    New-Object -TypeName psobject -Property $object
                )
                # $global:dmAuthObject | format-table

            } catch {
                throw "[$($Server)]: Unable to connect to: $($Server)`n$($_.ErrorDetails)"
            }
        } else {
            try {
                # Build the request body
                $body = [ordered]@{
                    grant_type = "refresh_token"
                    refresh_token = $dmAuthObject.tokenRefresh
                    scope = "aaa"
                }
                # Refresh the bearer token 
                $auth = `
                    Invoke-RestMethod `
                    -Uri "https://$($Server):$($Port)/api/v$($Version)/token" `
                    -Method POST `
                    -ContentType 'application/json' `
                    -Headers ($dmAuthObject.headerRefresh) `
                    -Body (ConvertTo-Json $body) `
                    -SkipCertificateCheck

                # Update authentication properties
                $global:dmAuthObject.tokenApi = $auth.access_token
                $global:dmAuthObject.headerToken = @{
                    authorization = "$($auth.token_type) $($auth.access_token)"
                }
                # $global:dmAuthObject | format-table
            }
            catch {
                throw "[powerprotect]: Unable to refresh token on: $($Server)`n$($_.ErrorDetails)"
            }
        } # End if / else
    } # End Process
} # End Function
function get-dm {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [int]$Version,
        [Parameter(Mandatory=$true)]
        [string]$Endpoint
    )
    begin {
        $Page = 1
        $results = @()
        $retries = @(1..3)  
    }
    process {
        try {
                $Color = "Cyan"
                Write-Host "`n[METHOD]: GET" `
                -ForegroundColor $Color
                Write-Host "[BASE]: $($dmAuthObject.dm)" `
                -ForegroundColor $Color
                Write-Host "[VERSION]: v$($Version)" `
                -ForegroundColor $Color
                Write-Host "[URI]: $($Endpoint)" `
                -ForegroundColor $Color
                Write-Host "[PAGING]: Random" `
                -ForegroundColor $Color                

                $query = Invoke-RestMethod `
                -Uri "$($dmAuthObject.dm)/v$($Version)/$($Endpoint)" `
                -Method GET `
                -ContentType 'application/json' `
                -Headers ($dmAuthObject.headerToken) `
                -SkipCertificateCheck

                # Try and match the different content arrays
                $match = $query.psobject.Properties.name
                if($match -match "results") {
                    $results = $query.results
                } elseif($match -match "datastores") {
                    $results = $query.datastores
                } elseif($match -match "content") {
                    $results = $query.content
                } else {
                    $results = $query
                }
        }
        catch {
            if($query.code -eq 401 `
                -and $query.reason -eq "Invalid authentication token"){
                # Refresh the bearer token
                Write-Host "[$($dmAuthObject.dmFqdn)]: Refreshing bearer token..." -ForegroundColor Cyan
                connect-dmapi `
                -Server $dmAuthObject.dmFqdn `
                -Port $dmAuthObject.dmPort `
                -Version 2 `
                -Refresh
                Start-Sleep -Seconds 2
            } else {
                [int]$Seconds = 15
                foreach($retry in $retries){
                    Write-Host "[$($dmAuthObject.dmFqdn)]: ERROR: `n$($_) `nAttempt: $($retry) of $($retries.length)" -ForegroundColor Red
                    Write-Host "[$($dmAuthObject.dmFqdn)]: Attempting to recover in $($Seconds) seconds...`n" -ForegroundColor Yellow
                    Start-Sleep -Seconds $Seconds

                    $query = Invoke-RestMethod `
                    -Uri "$($dmAuthObject.dm)/v$($Version)/$($Endpoint)" `
                    -Method GET `
                    -ContentType 'application/json' `
                    -Headers ($dmAuthObject.headerToken) `
                    -SkipCertificateCheck

                    # Try and match the different content arrays
                    $match = $query.psobject.Properties.name
                    if($match -match "results") {
                        $results = $query.results
                    } elseif($match -match "datastores") {
                        $results = $query.datastores
                    } elseif($match -match "content") {
                        $results = $query.content
                    } else {
                        $results = $query
                    }

                    if($retry -eq $retries.length) {
                        throw "[ERROR]: Could not recover from: `n$($_) in $($retries.length) attempts!"
                    }
                }
                
            }
        } # End try / catch

        try {
            if($query.page.totalPages -gt 1) {
                # Increment the page number
                $Page++
                # Page through the results
                do {
                    $Paging = Invoke-RestMethod `
                    -Uri "$($dmAuthObject.dm)/v$($Version)/$($Endpoint)&page=$($Page)" `
                    -Method GET `
                    -ContentType 'application/json' `
                    -Headers ($dmAuthObject.headerToken) `
                    -SkipCertificateCheck
                
                    # Try and match the different content arrays
                    $match = $Paging.psobject.Properties.name
                    if($match -match "results") {
                        $results += $Paging.results
                    } elseif($match -match "datastores") {
                        $results += $Paging.datastores
                    } elseif($match -match "content") {
                        $results += $Paging.content
                    } else {
                        $results += $Paging
                    }
                    # Increment the page number
                    $Page++
                } 
                until ($Paging.page.number -eq $Query.page.totalPages)
            }
        }
        catch {
            if($Paging.code -eq 401 `
                -and $Paging.reason -eq "Invalid authentication token"){
                # Refresh the bearer token
                Write-Host "[$($dmAuthObject.dmFqdn)]: Refreshing bearer token..." -ForegroundColor Cyan
                connect-dmapi `
                -Server $dmAuthObject.dmFqdn `
                -Port $dmAuthObject.dmPort `
                -Version 2 `
                -Refresh
                Start-Sleep -Seconds 2
            } else {
                [int]$Seconds = 15
                foreach($retry in $retries){
                    Write-Host "[$($dmAuthObject.dmFqdn)]: ERROR: `n$($_) `nAttempt: $($retry) of $($retries.length)" -ForegroundColor Red
                    Write-Host "[$($dmAuthObject.dmFqdn)]: Attempting to recover in $($Seconds) seconds...`n" -ForegroundColor Yellow
                    Start-Sleep -Seconds $Seconds

                    $Paging = Invoke-RestMethod `
                    -Uri "$($dmAuthObject.dm)/v$($Version)/$($Endpoint)&page=$($Page)" `
                    -Method GET `
                    -ContentType 'application/json' `
                    -Headers ($dmAuthObject.headerToken) `
                    -SkipCertificateCheck

                    # Try and match the different content arrays
                    $match = $Paging.psobject.Properties.name
                    if($match -match "results") {
                        $results += $Paging.results
                    } elseif($match -match "datastores") {
                        $results += $Paging.datastores
                    } elseif($match -match "content") {
                        $results += $Paging.content
                    } else {
                        $results += $Paging
                    }
                    # Increment the page number
                    $Page++

                    if($retry -eq $retries.length) {
                        throw "[ERROR]: Could not recover from: `n$($_) in $($retries.length) attempts!"
                    }
                }
            }
        } # End try / catch
        return $results  
    } # End process
} # End function

function get-serial {
    [CmdletBinding()]
    param (
        [Parameter( Mandatory=$true)]
        [string]$Endpoint,
        [Parameter( Mandatory=$true)]
        [int]$Version
    )
    begin {}
    process {
        $Page = 1
        $results = @()

        $Color = "Cyan"
        Write-Host "`n[METHOD]: GET" `
        -ForegroundColor $Color
        Write-Host "[BASE]: $($dmAuthObject.dm)" `
        -ForegroundColor $Color
        Write-Host "[VERSION]: v$($Version)" `
        -ForegroundColor $Color
        Write-Host "[URI]: $($Endpoint)" `
        -ForegroundColor $Color
        Write-Host "[PAGING]: Serial" `
        -ForegroundColor $Color

        $query =  Invoke-RestMethod -Uri "$($dmAuthObject.dm)/v$($Version)/$($Endpoint)&queryState=BEGIN" `
        -Method GET `
        -ContentType 'application/json' `
        -Headers ($dmAuthObject.headerToken) `
        -SkipCertificateCheck
        $results = $query.content
   
        do {
            $Token = $query.page.queryState
            if($Page -gt 1) {
                $Token = $Paging.page.queryState
            }
            $Paging = Invoke-RestMethod -Uri "$($dmAuthObject.dm)/v$($Version)/$($Endpoint)&queryState=$($Token)" `
            -Method GET `
            -ContentType 'application/json' `
            -Headers ($dmAuthObject.headerToken) `
            -SkipCertificateCheck
            $Results += $Paging.content

            $Page++;
        } 
        until ($Paging.page.queryState -eq "END")
        return $results
    }
} # End function

function set-dm {
    [CmdletBinding()]
     param (
        [Parameter(Mandatory=$true)]
        [string]$Endpoint,
        [Parameter(Mandatory=$true)]
        [ValidateSet('PUT','POST','PATCH')]
        [string]$Method,
        [Parameter(Mandatory=$true)]
        [int]$Version,
        [Parameter(Mandatory=$false)]
        [object]$Body,
        [Parameter(Mandatory=$true)]
        [string]$Message
    )
    begin {}
    process {
        $retries = @(1..5)
        foreach($retry in $retries) {
            try {
                Write-Host "[$($dmAuthObject.dmFqdn)]: $($Message)" -ForegroundColor Yellow 
                if($null -eq $Body) {
                    $action = Invoke-RestMethod -Uri "$($dmAuthObject.dm)/v$($Version)/$($Endpoint)" `
                    -Method $Method `
                    -ContentType 'application/json' `
                    -Headers ($dmAuthObject.headerToken) `
                    -SkipCertificateCheck
                } else {
                    $action = Invoke-RestMethod -Uri "$($dmAuthObject.dm)/v$($Version)/$($Endpoint)" `
                    -Method $Method `
                    -ContentType 'application/json' `
                    -Body ($Body | ConvertTo-Json -Depth 20) `
                    -Headers ($dmAuthObject.headerToken) `
                    -SkipCertificateCheck
                }
                break;   
            } catch {
                Write-Host "[$($dmAuthObject.dmFqdn)]: ERROR: $($Message)`n$($_) `nAttempt: $($retry) of $($retries.length)" -ForegroundColor Red
                Write-Host "[$($dmAuthObject.dmFqdn)]: Attempting to recover in 60 seconds...`n" -ForegroundColor Yellow
                Start-Sleep -Seconds 60
                if($retry -eq $retries.length) {
                    throw "[ERROR]: Could not recover from: `n$($_) in $($retries.length) attempts!"
                }
            }
        }
        
        Write-Host "[$($dmAuthObject.dmFqdn)]: SUCCESS: $($Message)" -ForegroundColor Green
        $match = $action.psobject.Properties.name
        if($match -match "results") {
            return $action.results
        } else {
            return $action
        }
    } # END PROCESS
} # End function

function disconnect-dmapi {
    [CmdletBinding()]
    param (
    )
    begin {}
    process {
        # Log off the rest api
        Invoke-RestMethod -Uri "$($dmAuthObject.dm)/v2/logout" `
        -Method POST `
        -ContentType 'application/json' `
        -Headers ($dmAuthObject.headerToken) `
        -SkipCertificateCheck

        $global:dmAuthObject = $null
    } # End process
} # End function

function send-emailnotification {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$SmtpRelay,
        [Parameter(Mandatory=$true)]
        [int]$Port,
        [Parameter(Mandatory=$true)]
        [string]$From,
        [Parameter(Mandatory=$true)]
        [string]$To,
        [Parameter(Mandatory=$true)]
        [string]$Subject,
        [Parameter(Mandatory=$true)]
        [string]$FilePath,
        [Parameter(Mandatory=$true)]
        [string]$ReportName,
        [Parameter(Mandatory=$false)]
        [bool]$EmailHtml,
        [Parameter(Mandatory=$false)]
        [switch]$Test

    )
    begin {
        $Client = New-Object Net.Mail.SmtpClient($SmtpRelay, $Port)
        if ($Port -eq 25) {
            $Client.EnableSsl = $false
        }
        else {
            $Exists = Test-Path -Path ".\$($SmtpRelay).xml" -PathType Leaf
            if ($Exists) {
                $Credential = Import-CliXml ".\$($SmtpRelay).xml"
            }
            else {
                $Credential = Get-Credential
                $Credential | Export-CliXml ".\$($SmtpRelay).xml"
            } 
            $Client.EnableSsl = $true
            $Client.Credentials = `
            New-Object System.Net.NetworkCredential($Credential.UserName, `
            "$(ConvertFrom-SecureString -SecureString $Credential.password -AsPlainText)");
        }
    }
    process {
        # HTML Style
        $HtmlParams = @{
            Title       = "PowerProtect Data Manager"
            Body        = "<h4 style=`"font-family: system-ui;`">$(Get-Date)</h4>"
            PreContent  = "<h1 style=`"font-family: system-ui;`">$($ReportName)</h1>"
            PostContent = "<h4 style=`"font-family: system-ui;`">Generated by PowerProtect Data Manager.</h4>"
        }
        $Css="
        <style>
            Table {
            font-family: system-ui;
            background-color: #EEEEEE;
            border-collapse: collapse;
            width: 100%;
            }
            Table td, Table th {
            border: 1px solid #ddd;
            padding: 3px 3px;
            }
            Table tr:nth-child(even) {
            background-color: lightgray
            } 
            Table th {
            font-size: 15px;
            font-weight: bold;
            padding-top: 12px;
            padding-bottom: 12px;
            text-align: left;
            background-color: #0075ce;
            color: white;
            }
        </style>        
        "
        $Report = Import-Csv -Path $FilePath
        
        # SEND MAIL MESSAGE
        
        if($EmailHtml){
            # Convert the report to html
            $Html = ($Report | ConvertTo-Html @HtmlParams -Head $Css)
            # Embed the html into the body of the message
            $Message = New-Object System.Net.Mail.Mailmessage $From, $To, $Subject, $Html

        } else {
            # Create a blank message body
            $Message = New-Object System.Net.Mail.Mailmessage $From, $To, $Subject, $null
            # Attach the csv to the message
            $Message.Attachments.Add($FilePath)
        }

        # Set the body of the mail message
        $Message.IsBodyHTML = $true
        try {
            if($Test) {
                $Message | format-list
            } else {
                $Client.Send($Message)
            }
        }
        catch {
            $_.ErrorDetails
        }      

    } # End process
} # End function

# END FUNCTIONS

$report = @()
# Interate over the data manager servers
foreach($dm in $dms){

    Write-Host "`n[$($dm.name)]: Connecting to the rest api"
    # Connect to the rest api
    connect-dmapi `
    -Server $dm.name `
    -Port 8443 `
    -Version 2

    # Get the local accounts
    $endpoint = "local-identity-providers/default/auth-entries"
    $query1 = get-dm `
    -Endpoint "$($endpoint)" `
    -Version 3

    foreach($row in $query1) {
        $changed = get-date($row.lastPasswordChangeTimestamp).tolocaltime()
        $today =  Get-Date
        $timespan = New-TimeSpan -Start $changed -End $today

        $object = [ordered]@{
            accountName = $row.accountName
            enabled = $row.enabled
            locked = $row.locked
            lastPasswordChangeTimestamp = $row.lastPasswordChangeTimestamp
            agePassword = '{0:dd}d:{0:hh}h:{0:mm}m:{0:ss}s' -f $timespan
        }

        $report += (New-Object -TypeName psobject -Property $object)
    }
    
    # Disconnect from the rest api
    disconnect-dmapi  
} # End foreach $dm in $dms

if ($report.length -gt 0) {
    # Export the report to csv format
    $report | `
    Export-Csv -Path $ReportOutFile `
    -NoTypeInformation

    if($EmailSend){
        # Send the email notification
        send-emailnotification `
        -SmtpRelay $SmtpRelay `
        -Port $Port `
        -From $EmailFrom `
        -To $EmailTo `
        -Subject $EmailSubject `
        -FilePath $ReportOutFile `
        -ReportName $ReportName `
        -EmailHtml $EmailHtml
    }
}