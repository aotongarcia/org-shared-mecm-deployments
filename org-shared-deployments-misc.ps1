# Script and script documentation home: https://github.com/engrit-illinois/org-shared-mecm-deployments
# Org shared deployment model documentation home: https://wiki.illinois.edu/wiki/display/engritprivate/SCCM+-+Org+shared+collections+and+deployments
# By mseng3

# Note these snippets are not a holistic script.
# Read and understand before using.

# -----------------------------------------------------------------------------

# To prevent anyone from running this as a script blindly:
Exit

# -----------------------------------------------------------------------------

# Prepare a connection to SCCM so you can directly use ConfigurationManager Powershell cmdlets without opening the admin console app
# This is posted as a module in its own repo here: https://github.com/engrit-illinois/Prep-MECM
function Prep-MECM {
	$SiteCode = "MP0" # Site code 
	$ProviderMachineName = "sccmcas.ad.uillinois.edu" # SMS Provider machine name

	# Customizations
	$initParams = @{}
	#$initParams.Add("Verbose", $true) # Uncomment this line to enable verbose logging
	#$initParams.Add("ErrorAction", "Stop") # Uncomment this line to stop the script on any errors

	# Import the ConfigurationManager.psd1 module 
	if((Get-Module ConfigurationManager) -eq $null) {
		Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1" @initParams 
	}

	# Connect to the site's drive if it is not already present
	if((Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue) -eq $null) {
		New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams
	}

	# Set the current location to be the site code.
	Set-Location "$($SiteCode):\" @initParams
}

# -----------------------------------------------------------------------------

# Use the above Prep-MECM function (which must change your working directory to MP0:\), perform some commands, and return to your previous working directory

$myPWD = $pwd.path
Prep-MECM

# Some commands, e.g.:
Get-CMDeviceCollection -Name "UIUC-ENGR-All Systems"

Set-Location $myPWD

# -----------------------------------------------------------------------------

# Find which MECM collections contain a given machine:
# Note: this will probably take a long time (15+ minutes) to run
Get-CMCollection | Where { (Get-CMCollectionMember -InputObject $_).Name -contains "machine-name" } | Select Name

# -----------------------------------------------------------------------------

# Force the MECM client to re-evaluate its assignments
# Useful if deployments just won't show up in Software Center
# https://github.com/engrit-illinois/force-software-center-assignment-evaluation
$Assignments = (Get-WmiObject -Namespace root\ccm\Policy\Machine -Query "Select * FROM CCM_ApplicationCIAssignment").AssignmentID
ForEach ($Assignment in $Assignments) {
    $Trigger = [wmiclass] "\root\ccm:SMS_Client"
    $Trigger.TriggerSchedule("$Assignment")
    Start-Sleep 1
}

# -----------------------------------------------------------------------------

# Find the difference between two MECM collections:
$one = (Get-CMCollectionMember -CollectionName "UIUC-ENGR-Collection 1" | Select Name).Name
$two = (Get-CMCollectionMember -CollectionName "UIUC-ENGR-Collection 2" | Select Name).Name
$diff = Compare-Object -ReferenceObject $one -DifferenceObject $two
$diff
@($diff).count

# -----------------------------------------------------------------------------

# Get the current/authoritative list of valid ENGR computer name prefixes directly from MECM:
$rule = (Get-CMDeviceCollectionQueryMembershipRule -Name "UIUC-ENGR-All Systems" -RuleName "UIUC-ENGR-Imported Computers").QueryExpression
$regex = [regex]'"([a-zA-Z]*)-%"'
$prefixesFound = $regex.Matches($rule)
# Make array of prefixes, removing extraneous characters from matches
$prefixesFinal = @()
foreach($prefix in $prefixesFound) {
	# e.g pull "CEE" out of "`"CEE-%`""
	$prefixClean = $prefix -replace '"',''
	$prefixClean = $prefixClean -replace '-%',''
	$prefixesFinal += @($prefixClean)
}
$prefixesFinal | Sort-Object

# -----------------------------------------------------------------------------

# Rename a collection
Get-CMDeviceCollection -Name $coll | Set-CMDeviceCollection -NewName $newname

# -----------------------------------------------------------------------------

# Get all relevant collections so they can be used in a foreach loop with the below commands
# Be very careful to check that you're actually getting ONLY the collections you want with this, before relying on the list of returned collections to make changes. It would have made it easier to rely on this if I had designed these collections to have a standard prefix, but I wanted to keep the UIUC-ENGR-App Name format to make it crystal clear that these are to be used as the primary org collections/deployments for these apps. Unfortunately the ConfigurationManager powershell module doesn't have any support for working with folders (known as container nodes).
$collsAvailable = (Get-CMCollection -Name "Deploy * - Latest (Available)" | Select Name).Name
$collsRequired = (Get-CMCollection -Name "Deploy * - Latest (Required)" | Select Name).Name

# To do actions on all at once
$colls = $collsAvailable + $collsRequired

# -----------------------------------------------------------------------------

# Define a refresh schedule of daily at 1am
# https://docs.microsoft.com/en-us/powershell/module/configurationmanager/set-cmcollection
# https://docs.microsoft.com/en-us/powershell/module/configurationmanager/new-cmschedule
# https://www.danielengberg.com/sccm-powershell-script-update-collection-schedule/
# https://gallery.technet.microsoft.com/Powershell-script-to-set-5d1c52f1
# https://stackoverflow.com/questions/10487011/creating-a-datetime-object-with-a-specific-utc-datetime-in-powershell/44196630
# https://hinchley.net/articles/create-a-collection-in-sccm-with-a-weekly-refresh-cycle/
$sched = New-CMSchedule -Start "2020-07-27 01:00" -RecurInterval "Days" -RecurCount 1

foreach($coll in $colls) {
	# Set the refresh schedule
	Set-CMCollection -Name $coll -RefreshType "Periodic" -RefreshSchedule $sched
}

# -----------------------------------------------------------------------------

# Adding and removing membership rules

# https://docs.microsoft.com/en-us/powershell/module/configurationmanager/add-cmdevicecollectionincludemembershiprule
Get-CMCollection -Name "UIUC-ENGR-Deploy <app> (<purpose>)" | Add-CMDeviceCollectionIncludeMembershipRule -IncludeCollectionName "UIUC-ENGR-Collection to include"

# https://docs.microsoft.com/en-us/powershell/module/configurationmanager/remove-cmdevicecollectionincludemembershiprule
Get-CMCollection -Name "UIUC-ENGR-Deploy <app> (<purpose>)" | Remove-CMDeviceCollectionIncludeMembershipRule -IncludeCollectionName "UIUC-ENGR-Collection to remove" -Force

# -----------------------------------------------------------------------------

# Get a list of all membership rules for a given collection

function Get-CMDeviceCollectionMembershipRuleCounts($coll) {
    $object = [PSCustomObject]@{
        includes = (Get-CMDeviceCollectionIncludeMembershipRule -CollectionName $coll)
        excludes = (Get-CMDeviceCollectionExcludeMembershipRule -CollectionName $coll)
        directs = (Get-CMDeviceCollectionDirectMembershipRule -CollectionName $coll)
        queries = (Get-CMDeviceCollectionQueryMembershipRule -CollectionName $coll)
    }
    Write-Host "`nInclude rules: $(@($object.includes).count)"
    Write-Host "`"$($object.includes.RuleName -join '", "')`""
    Write-Host "`nExclude rules: $(@($object.excludes).count)"
    Write-Host "`"$($object.excludes.RuleName -join '", "')`""
    Write-Host "`nDirect rules: $(@($object.directs).count)"
    Write-Host "`"$($object.directs.RuleName -join '", "')`""
    Write-Host "`nQuery rules: $(@($object.queries).count)"
    Write-Host "`"$($object.queries.RuleName -join '", "')`""
    Write-Host "`n"
    $object
}

$rules = Get-CMDeviceCollectionMembershipRuleCounts "UIUC-ENGR-Deploy 7-Zip x64 - Latest (Available)"

# -----------------------------------------------------------------------------

# Adding a new properly-configured collection for each of "available" and "required"
$app = "App x64 - Latest"
$purposes = @("Available","Required")
foreach($purpose in $purposes) {
    # Make new collection
    $coll = "UIUC-ENGR-Deploy $app ($purpose)"
    $sched = New-CMSchedule -Start "2020-07-27 01:00" -RecurInterval "Days" -RecurCount 1
    New-CMDeviceCollection -Name $coll -LimitingCollectionName "UIUC-ENGR-All Systems" -RefreshType "Periodic" -RefreshSchedule $sched
    
    # Comment this out if this isn't going to be a "common" app
    #Get-CMCollection -Name $coll | Add-CMDeviceCollectionIncludeMembershipRule -IncludeCollectionName "UIUC-ENGR-Deploy ^ All Common Apps - Latest ($purpose)"

    # Deploying the app
    # https://docs.microsoft.com/en-us/powershell/module/configurationmanager/new-cmapplicationdeployment
    # https://www.reddit.com/r/SCCM/comments/9bknh0/newcmapplicationdeployment_help/
    Start-Sleep -Seconds 10 # If performing immediate after creating the collection
    New-CMApplicationDeployment -Name $app -CollectionName $coll -DeployAction "Install" -DeployPurpose $purpose -UpdateSupersedence $true
}

# Note: new collections created via Powershell will end up in the root of "Device Collections" and will need to be manually moved to the appropriate folder
# Currently there is no support for management of the folder hierarchy in the ConfigurationManager Powershell module.

# -----------------------------------------------------------------------------

# Adding a collection as a member of a roll up collection
Get-CMCollection -Name "UIUC-ENGR-Deploy ^ All Common Apps - Latest (<purpose>)" | Add-CMDeviceCollectionIncludeMembershipRule -IncludeCollectionName "UIUC-ENGR-Collection to add"

# -----------------------------------------------------------------------------

# Find all collections which have an "include" membership rule that includes a target collection:
# https://configurationmanager.uservoice.com/forums/300492-ideas/suggestions/15827071-collection-deployment

$targetColl = "UIUC-ENGR-Target Collection"
$targetCollId = (Get-CMCollection -Name $targetColl).CollectionId

$collsWhichIncludeTargetColl = @()
Get-CMCollection -CollectionType Device | Foreach-Object {
    $thisColl = $_
    Get-CMCollectionIncludeMembershipRule -InputObject $thisColl | Where-Object { $_.IncludeCollectionId -eq $targetCollId } | Foreach-Object { $collsWhichIncludeTargetColl += $thisColl.Name }
}
$collsWhichIncludeTargetColl | Sort-Object | Format-Table -Autosize -Wrap

# -----------------------------------------------------------------------------

# Find all deployments to a target collection (including deployments that are "inherited" by virtue of the target collection being included in other collections):
# https://configurationmanager.uservoice.com/forums/300492-ideas/suggestions/15827071-collection-deployment

$targetColl = "UIUC-ENGR-Target Collection"
$targetCollId = (Get-CMCollection -Name $targetColl).CollectionId

$collsWhichIncludeTargetColl = @()
Get-CMCollection -CollectionType Device | Foreach-Object {
    $thisColl = $_
    Get-CMCollectionIncludeMembershipRule -InputObject $thisColl | Where-Object { $_.IncludeCollectionId -eq $targetCollId } | Foreach-Object { $collsWhichIncludeTargetColl += $thisColl.Name }
}

$depsToCollsWhichIncludeTargetColl = @()
#TODO

$depsToCollsWhichIncludeTargetColl | Sort-Object | Format-Table -Autosize -Wrap

# -----------------------------------------------------------------------------

# Find out whether deployments to a collection have supersedence enabled
$apps = Get-CMApplicationDeployment -CollectionName "UIUC-ENGR-Deploy All Adobe CC 2020 Apps - SDL (Available)"
$apps | Select ApplicationName,UpdateSupersedence

# -----------------------------------------------------------------------------

# More handy, consolidated function for creating standarized org-shared-model deployment collections
# This has been turned into a proper Powershell module. Please see the "New-CMOrgModelDeploymentCollection" section in the README here: 

# https://gitlab.engr.illinois.edu/engrit-epm/org-shared-deployments/-/tree/master

# -----------------------------------------------------------------------------

# Get the revision number of a local MECM assignment named like "*Siemens NX*":
# Compare the return value with the revision number of the app (as seen in the admin console).
# If it's not the latest revision , use the "Update machine policy" action in the Configuration Manager control panel applet, and then run this code again.
function Get-RevisionOfAssignment($name) {
    $assignments = Get-WmiObject -Namespace root\ccm\Policy\Machine -Query "Select * FROM CCM_ApplicationCIAssignment" | where { $_.assignmentname -like $name }
	foreach($assignment in $assignments) {
		$xmlString = @($assignment.AssignedCIs)[0]
		$xmlObject = New-Object -TypeName System.Xml.XmlDocument
		$xmlObject.LoadXml($xmlString)
		$rev = $xmlObject.CI.ID.Split("/")[2]
		$assignment | Add-Member -NotePropertyName "Revision" -NotePropertyValue $rev
	}
	$assignments | Select Revision,AssignmentName
}

Get-RevisionOfAssignment "*autocad*"


# -----------------------------------------------------------------------------

# Get the refresh schedules of all MECM device collections,
# limit them to those that refresh daily,
# sort by refresh time and then by collection name,
# and print them in a table.
# This will take a while to run.
# Useful for finding out if we are contributing to poor MECM performance by having a bunch of collections refreshing at the same time, and when those collections refresh.

$colls = Get-CMDeviceCollection
$collsPruned = $colls | Select `
	Name,
	@{Name="RecurStartDate";Expression={$_.RefreshSchedule.StartTime.ToString("yyyy-MM-dd")}},
	@{Name="RecurTime";Expression={$_.RefreshSchedule.StartTime.ToString("HH:mm:ss")}},
	@{Name="RecurIntervalDays";Expression={$_.RefreshSchedule.DaySpan}},
	@{Name="RecurIntervalHours";Expression={$_.RefreshSchedule.HourSpan}},
	@{Name="RecurIntervalMins";Expression={$_.RefreshSchedule.MinuteSpan}}
$collsWithDailySchedules = $collsPruned | Where { $_.RecurIntervalDays -eq 1 } | Sort RecurTime,Name
$collsWithDailySchedules | Format-Table

# -----------------------------------------------------------------------------

# Find collections which have "incremental updates" enabled
# https://www.danielengberg.com/sccm-powershell-script-update-collection-schedule/
$refreshTypes = @{
    1 = "Manual Update Only"
    2 = "Scheduled Updates Only"
    4 = "Incremental Updates Only"
    6 = "Incremental and Scheduled Updates"
}
$colls = Get-CMCollection | Where { ($_.RefreshType -eq 4) -or ($_.RefreshType -eq 6) }
$collsCustom = $colls | Select Name,RefreshType,@{
    Name = "RefreshTypeFriendly"
    Expression = {
        [int]$type = $_.RefreshType
        $refreshTypes.$type
    }
}
$collsCustom | Format-Table

# -----------------------------------------------------------------------------

# Get all MECM device collections named like "UIUC-ENGR-CollectionName*" and set their refresh schedule to daily at 3am, starting 2020-08-28
$sched = New-CMSchedule -Start "2020-08-28 03:00" -RecurInterval "Days" -RecurCount 1
Get-CMDeviceCollection | Where { $_.Name -like "UIUC-ENGR-CollectionName*" } | Set-CMCollection -RefreshSchedule $sched

# -----------------------------------------------------------------------------

# Get all MECM Collections and apps named like "UIUC-ENGR *" and rename them to "UIUC-ENGR-*"

$colls = Get-CMCollection | Where { $_.Name -like "UIUC-ENGR *" }
$colls | ForEach {
	$name = $_.Name
	$newname = $name -replace "UIUC-ENGR ","UIUC-ENGR-"
	Write-Host "Renaming collection `"$name`" to `"$newname`"..."
	Set-CMCollection -Name $name -NewName $newname
}

$apps = Get-CMApplication -Fast | Where { $_.LocalizedDisplayName -like "UIUC-ENGR *" }
$apps | ForEach {
	$name = $_.LocalizedDisplayName
	$newname = $name -replace "UIUC-ENGR ","UIUC-ENGR-"
	Write-Host "Renaming app `"$name`" to `"$newname`"..."
	Set-CMApplication -Name $name -NewName $newname
}

# -----------------------------------------------------------------------------

# Force Software Center to reset its policy
# Useful for when an application is stuck downloading/installing on a client, and you want to redeploy it
# https://docs.microsoft.com/en-us/answers/questions/123991/sccm-software-center-how-to-reset-or-cancel-an-app.html
# Should be followed up by running the download computer policy/app deployment eval cycles
WMIC /Namespace:\\root\ccm path SMS_Client CALL ResetPolicy 1 /NOINTERACTIVE

# -----------------------------------------------------------------------------

# Find the app/deployment type associated with the CI_UniqueId of an unknown deployment type:
$ciuid = "DeploymentType_fb0b749d-dba0-45c4-b30e-98497831b2d7"
$ciuid = $ciuid.Replace("DeploymentType_","")
$dt = Get-WmiObject -Namespace "root\sms\site_MP0" -ComputerName "sccmcas.ad.uillinois.edu" -Class "SMS_Deploymenttype" -Filter "CI_UniqueId like '%$ciuid%'"
Write-Host "Deployment type: `"$($dt.LocalizedDisplayName)`""
$app = Get-CMApplication -ModelName $dt.AppModelName
Write-Host "App: `"$($app.LocalizedDisplayName)`""

# -----------------------------------------------------------------------------

