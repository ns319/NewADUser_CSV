# NewADUser_CSV

<#
.SYNOPSIS
    Create new AD users by importing values from a CSV file.
.DESCRIPTION   
    Search a given folder (line 34) for CSV files, import each one and collect user data, run New-ADUser cmdlet for each entry in each CSV. The CSV file can have any name. A log is
    created while running the commands and after completion the log and the CSV are moved to another folder (like 'Complete' or 'Failed') specified on lines 35 and 36.

    For each entry in a CSV the script: checks for CN and SamAccountName availability; sets the Department attribute and uses it to determine OU, HomeDrive specifics, and some AD groups;
    sets the Location attribute and uses it to determine Office, City, State, Zip, and some more AD groups. Once all attributes are established it runs the New-ADUser cmdlet.
    If successful it creates a HomeDrive (if required), adds AD groups from a TemplateUser (if provided), then moves the CSV and the log to the folder specified on line 36 for documentation.
    If the script fails to create a user it moves the CSV file and the log to the folder specified on line 38 for review.    
.NOTES
    The file can have any name, as long as it's in the folder specified on line 34.
    The script runs the Import-Csv cmdlet against any file in that folder and fails if it can't find a CSV file.
    v4.1.7
#>

# Elevate to Admin
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Start-Process powershell.exe "-NoProfile -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Function to write to the log file we create later
function Write-Log
{
    Param ([string]$LogEntry)
    Add-Content -Path $LogFile -Value $LogEntry
}

# Provide paths for Pending, Complete, and Failed folders
$PendingDir = "C:\Temp\New Users - Pending"
$CompleteDir = "C:\Temp\New Users - Complete"
$FailedDir = "C:\Temp\New Users - Failed"

# Get the FileName of all files in the Pending folder...
$FileNames = (Get-ChildItem -Path $PendingDir).Name

# ...then perform the following operations on each one
foreach ($File in $FileNames) {

    # Import the CSV and store all the data in a variable
    $CSV = Import-Csv -Path "$PendingDir\$File"
    if ($? -ne $true) {
        Write-Host "Could not find a CSV file in '$PendingDir!'" -ForegroundColor Red
        Read-Host -Prompt 'Press Enter to exit'
        exit
    }

    # Take each row in the CSV and create variables from the values provided
    # Later we'll use some of these to create more user attributes, then create the account
    foreach ($User in $CSV) {
        $Password = "SuperSecretPassword"
        $FirstName = $User.FirstName
        $Middle = $User.Middle
        $LastName = $User.LastName
        $JobTitle = $User.JobTitle
        $Type = $User.EmploymentType
        $AccountExpires = $User.ExpirationDate
        $Section = $User.Section
        $Location = $User.Location 
        $Phone = $User.PhoneNumber
        $TemplateEmail = $User.TemplateAccount
        $Manager = ($User.ManagerEmail).Split('@')[0] # Split $ManagerEmail at '@' to get the SamAccountName of the Manger

        # If $TemplateEmail exists, split it at '@' like the Manager
        if ($TemplateEmail) {
            $Template = $TemplateEmail.Split('@')[0]
        }

        # If $Middle exists, split it into individual characters and grab the first one. That way even if there's a name in the field, we still end up with an initial
        if ($Middle) {
            $Initial = $Middle.ToCharArray()[0]
        }

        # Add employment status to $JobTitle for Temps and Contractors if it's not already there
        if ( ($Type -eq "Temp") -and ($JobTitle -notlike "*Temp*") ) {
            $JobTitle = "$JobTitle (Temp)"
        } elseif ( ($Type -eq "Contractor") -and ($JobTitle -notlike "*Contract*") ) {
            $JobTitle = "$JobTitle (Contractor)"
        }

        # Create various Name attributes from $FirstName and $LastName, then check to see if we need to add $Initial
        $UserName = "$FirstName.$LastName"
        $FullName = "$LastName $FirstName"
        $DisplayName = "$LastName, $FirstName"

        # Create a log so we can still examine output details if the console window is closed
        if ($Initial) {
            $LogFile = "C:\Temp\New Users - Complete\New DOL User - $LastName, $FirstName $Initial.log"
        } else {
            $LogFile = "C:\Temp\New Users - Complete\New DOL User - $LastName, $FirstName.log"
        }
        
        Write-Host "-----------------------------------------------------------------" -ForegroundColor Cyan
        Write-Log "INFO - Checking if CN and SamAccountName are unique..."

        # Check if CN '$LastName $FirstName' already exists. If so, check for an initial to add and try again
        if (Get-ADUser -Filter ("CN -eq '$FullName'")) {
            if ($Initial) {
                $FullName = "$LastName $FirstName $Initial"
                if (Get-ADUser -Filter ("CN -eq '$FullName'")) {
                    Write-Log "ERR! - Object with CN '$FullName' already exists. Cannot create a unique CN!"
                    Write-Host "ERR! - Object with CN '$FullName' already exists. Cannot create a unique CN!" -ForegroundColor Red
                    $FailToken = $true
                } else {
                    Write-Log "INFO - Object '$LastName $FirstName' already exists. Added Initial to create unique CN '$FullName'"
                    $FailToken = $false
                }
            } else {
                Write-Log "ERR! - Object with CN '$FullName' already exists. No Initial found to create a unique CN!"
                Write-Host "ERR! - Object with CN '$FullName' already exists. No Initial found to create a unique CN!" -ForegroundColor Red
                $FailToken = $true
            }
        } else {
            Write-Log "INFO - CN '$FullName' is available."
            $FailToken = $false
        }

        # Check if SamAccountName $FirstName.$LastName already exists. If so, check for an initial to add and try again
        if (Get-ADUser -Filter ("SamAccountName -eq '$UserName'")) {
            if ($Initial) {
                $Username = "$FirstName$Initial.$LastName"
                if (Get-ADUser -Filter ("SamAccountName -eq '$UserName'")) {
                    Write-Log "ERR! - Object with SamAccountName '$UserName' already exists. Cannot create a unique SamAccountName!"
                    Write-Host "ERR! - Object with SamAccountName '$UserName' already exists. Cannot create a unique SamAccountName!" -ForegroundColor Red
                    $FailToken = $true
                } else {
                    Write-Log "INFO - Object '$FirstName.$LastName' already exists. Added Initial to create SamAccountName '$Username'."
                    $FailToken = $false
                }
            } else {
                Write-Log "ERR! - Object with SamAccountName '$UserName' already exists. No Initial found to create a unique SamAccountName!"
                Write-Host "ERR! - Object with SamAccountName '$UserName' already exists. No Initial found to create a unique SamAccountName!" -ForegroundColor Red
                $FailToken = $true
            }
        } else {
            Write-Log "INFO - SamAccountName '$Username' is available."
            $FailToken = $false
        }

        # Use $Section to find the appropriate FP server for Homedrive, set OU Path, and add some default Section-specific AD groups
        if ($FailToken -eq $false) {
            Write-Log "INFO - Checking for Section and setting HomeDrive, OU, and AD groups..."
            if ($Section -eq "Section 1") {
                $Department = "S1"
                $FPServer = "S1FP"
                $HomeRoot = "Home"
                $HomeDrive = "H:"
                $OU = "OU=Users,OU=S1,DC=dc"
                $SectionADgroups = @("AD_group1","AD_group2")
            } elseif ($Section -eq "Section 2") {
                $Department = "S2"
                $FPServer = "S2FP"
                $HomeRoot = "Home"
                $HomeDrive = "H:"
                $OU = "OU=Users,OU=S2,DC=dc"
                $SectionADgroups = ("AD_group3")
            } elseif ($Section -eq "Section 3") {
                $Department = "S3"
                $FPServer = "S3FP"
                $HomeRoot = "Home"
                $HomeDrive = "H:"
                $OU = "OU=Users,OU=S3,DC=dc"
                $SectionADgroups = @("AD_group2","AD_group4")
            } else {
                Write-Log "ERR! - Section for '$UserName' is unknown or invalid. Cannot create an account without a Section!"
                Write-Host "ERR! - Section for '$UserName' is unknown or invalid. Cannot create an account without a Section!" -ForegroundColor Red
                $FailToken = $true
            }
        }

        # Use $Location to populate Office, Street, City, and Zip, and to set the local AD group
        if ($FailToken -eq $false) {
            Write-Log "INFO - Setting attributes for Office Location..."
            if ($Location -eq "Location 1") {
                $Office = "Office A"
                $Street = "123 StreetName"
                $City = "City"
                $Zip = "12345"
                $LocalADgroup = "AD_groupA"
            } elseif ($Location -eq "Location 2") {
                $Office = "Office B"
                $Street = "456 StreetName"
                $City = "City"
                $Zip = "67890"
                $LocalADgroup = "AD_groupB"
            } elseif ($Location -eq "Location 3") {
                $Office = "Office C"
                $Street = "789 StreetName"
                $City = "City 2"
                $Zip = "34578"
                $LocalADgroup = "AD_groupC"
            } else {
                Write-Log "WARN - Office Location for '$UserName' is unknown or invalid. These attributes will be left blank!"
                Write-Host "WARN - Office Location for '$UserName' is unknown or invalid. These attributes will be left blank!" -ForegroundColor Yellow
                $Office = ""
                $Street = ""
                $City = ""
                $Zip = ""
                $LocalADgroup = ""
            }
        }

        # If we have the necessary attributes, try to create the account with the values we got above
        if ($FailToken -eq $false) {
            Write-Log "INFO - Running New-ADUser cmdlet..."
            New-ADUser `
                -AccountPassword (ConvertTo-SecureString $Password -AsPlainText -Force) `
                -ChangePasswordAtLogon $true `
                -Enabled $true `
                -PasswordNeverExpires $false `
                -City "$City" `
                -Company "Company" `
                -Country "Country" `
                -Department "$Department" `
                -Description "$JobTitle" `
                -DisplayName "$DisplayName" `
                -GivenName "$FirstName" `
                -Initials "$Initial" `
                -Manager "$Manager" `
                -Name "$FullName" `
                -Office "$Office" `
                -OfficePhone "$Phone" `
                -Path "$OU" `
                -PostalCode "$Zip" `
                -SamAccountName "$UserName" `
                -ScriptPath "ScriptPath" `
                -State "ST" `
                -StreetAddress "$Street" `
                -Surname "$LastName" `
                -Title "$JobTitle" `
                -UserPrincipalName "$UserName@someplace.com"

            # If we succeeded, display a SUCCESS message and set HomeDrive, AD groups, etc.
            if ($? -eq $true) {     
                Write-Log "INFO - SUCCESS! User '$UserName' was created as a new $Type $JobTitle for $Section at $Location."
                Write-Host "INFO - SUCCESS! User '$UserName' was created as a new $Type $JobTitle for $Section at $Location." -BackgroundColor Black -ForegroundColor Green
                                
                # Move the CSV to the Complete folder, with the LogFile
                Move-Item -Path "$PendingDir\$File" -Destination $CompleteDir

                # Explicitly remove HomeDrive from Temps and Contractors
                if ( ($Type -eq "Temp") -or ($Type -eq "Contractor") ) {
                    $HomeDrive = ""
                }
                # If we're still supposed to have a HomeDrive, create it and give the User 'Full Control' permissions
                if ($HomeDrive) {
                    Write-Host "INFO - Pausing for 20 seconds to ensure AD DC replication occurs before trying to create HomeDrive..."
                    # We need to ensure the new account is replicated on all DCs before trying to set permissions, or else name resolution may fail
                    # Intrasite replication is supposed to occur within 15 seconds, so I just gave it some wiggle room with 20 seconds
                    Start-Sleep -Seconds 20
                    Write-Log "INFO - Creating HomeDrive and setting permissions..."
                    $HomedrivePath = "\\$FPServer\$HomeRoot\$UserName"
                    New-Item -Path $HomedrivePath -ItemType Directory | Out-Null
                    $Acl = Get-Acl -Path $HomedrivePath
                    $AccessRule = New-Object -TypeName System.Security.AccessControl.FileSystemAccessRule("Domain\$UserName","FullControl","ContainerInherit,ObjectInherit","None","Allow")
                    $Acl.SetAccessRule($AccessRule)
                    if ($? -ne $true){
                        Write-Log "WARN - Unable to create a valid HomeDrive for '$UserName' due to a permissions error."
                        Write-Log "WARN - Deleting HomeDrive."
                        Write-Host "WARN - Unable to create a valid HomeDrive for '$UserName' due to a permissions error." -ForegroundColor Yellow
                        Write-Host "WARN - Deleting HomeDrive." -ForegroundColor Yellow
                        Remove-Item -Path $HomedrivePath
                    } else {
                        Write-Log "INFO - HomeDrive created for '$UserName'."
                        Write-Host "INFO - HomeDrive created for '$UserName'." -ForegroundColor Green
                        Set-Acl -Path $HomedrivePath -AclObject $Acl
                        Set-ADUser -Identity $UserName -HomeDrive $HomeDrive -HomeDirectory $HomedrivePath
                    }
                } else {
                    Write-Log "WARN - No HomeDrive specified for '$UserName'."
                    Write-Host "WARN - No HomeDrive specified for '$UserName'." -ForegroundColor Yellow
                }

                # Set Expiration Date for Temps/Contractors
                if ($AccountExpires) {
                    Set-ADUser -Identity $UserName -AccountExpirationDate $AccountExpires
                    Write-Log "WARN - Account will expire $AccountExpires."
                    Write-Host "WARN - Account will expire $AccountExpires." -ForegroundColor Yellow
                }

                # Write warning if Type is Temp/Contractor, but no Expiration Date is provided
                if ( ($Type -eq "Temp") -or ($Type -eq "Contractor") -and (!$AccountExpires) ) {
                    Write-Log "WARN - User is a $Type but there is no expiration date!"
                    Write-Host "WARN - User is a $Type but there is no expiration date!" -ForegroundColor Yellow
                }
                
                # If there's a Template account, try to clone all AD groups with CN that starts with 'Name'
                if ($Template) {
                    Write-Log "INFO - Cloning AD groups from $Template..."
                    $CloneADgroups = (Get-ADPrincipalGroupMembership -Identity $Template | Where-Object {$_.DistinguishedName -like 'CN=Name*'}).Name
                    Add-ADPrincipalGroupMembership -Identity $UserName -MemberOf $CloneADgroups
                    if ($? -ne $true) {
                        Write-Log "WARN - AD group cloning failed. '$UserName' has no AD groups!"
                        Write-Host "WARN - AD group cloning failed. '$UserName' has no AD groups!" -ForegroundColor Yellow
                        Write-Host "-----------------------------------------------------------------" -ForegroundColor Cyan
                        Write-Host ""
                    } else {
                        Write-Log "INFO - AD group cloning succeeded."
                        Write-Host "INFO - AD group cloning succeeded." -ForegroundColor Green
                        Write-Host "-----------------------------------------------------------------" -ForegroundColor Cyan
                        Write-Host ""
                    }
                } else {
                    # If there's no Template, add Common, Section, and Local AD groups we got earlier to give us a head start
                    # Other groups will have to be added manually later
                    Write-Log "WARN - No TemplateAccount found to clone AD groups. Adding defaults per Section and Location."
                    Write-Host "WARN - No TemplateAccount found to clone AD groups. Adding defaults per Section and Location." -ForegroundColor Yellow
                    Write-Host "-----------------------------------------------------------------" -ForegroundColor Cyan
                    Write-Host ""
                    if ($Type -eq "Full Time") {
                        $CommonADgroups = @("CommonGroup","FTGroup")
                    } else {
                        $CommonADgroups = @("CommonGroup","PTGroup")
                    }
                    Add-ADPrincipalGroupMembership -Identity $UserName -MemberOf $CommonADgroups
                    if ($SectionADgroups) {
                        Add-ADPrincipalGroupMembership -Identity $UserName -MemberOf $SectionADgroups
                    }
                    if ($LocalADgroup) {
                        Add-ADPrincipalGroupMembership -Identity $UserName -MemberOf $LocalADgroup
                    }
                }

            # If New-ADUser cmdlet fails, write error and move the CSV and LogFile to Failures folder for review
            } else {
                Write-Log "ERR! - Something went wrong and '$UserName' was not created."
                Write-Host "ERR! - Something went wrong and '$UserName' was not created." -BackgroundColor Black -ForegroundColor Red
                Write-Host "ERR! - Moving LogFile to '$FailedDir'" -BackgroundColor Black -ForegroundColor Red
                Write-Host "-----------------------------------------------------------------" -ForegroundColor Cyan
                Write-Host ""
                Move-Item -Path "$PendingDir\$File" -Destination $FailedDir
                Move-Item -Path $LogFile -Destination $FailedDir
            }
        }

        # If any checks failed (unavailable Name, invalid Section), write error message and move the CSV and LogFile to Failures folder for review
        if ($FailToken -eq $true) {
            Write-Log "ERR! - '$UserName' cannot be created due to invalid attribute(s)."
            Write-Host "ERR! - '$UserName' cannot be created due to invalid attribute(s)." -BackgroundColor Black -ForegroundColor Red
            Write-Host "ERR! - Moving LogFile to '$FailedDir'" -BackgroundColor Black -ForegroundColor Red
            Write-Host "-----------------------------------------------------------------" -ForegroundColor Cyan
            Write-Host ""
            Move-Item -Path "$PendingDir\$File" -Destination $FailedDir
            Move-Item -Path $LogFile -Destination $FailedDir
        }
    }
} 

Read-Host -Prompt "Press Enter to exit"
