param (
    [Parameter(Mandatory = $True)]
    [string]$Subscription = $null,
    [Parameter(Mandatory = $False)]
    [string]$ScheduleJsonFilePath = $null,
    [Parameter(Mandatory = $False)]
    [string]$ScheduleJsonFileUrl = $null,
    [Parameter(Mandatory = $False)]
    [string]$AutomationAccountName = "BNCLabAutomation",
    [Parameter(Mandatory = $False)]
    [string]$AutomationAccountResourceGroupName = "BNCLabAutomation"
)
#***************
# Sets all VMs matching tags.environment "lab" and configures start schedule as per lab schedule file
#***************
$schedules = $null
Write-Host "Starting"
Write-Verbose $ScheduleJsonFilePath
Write-Verbose $ScheduleJsonFileUrl
if ($ScheduleJsonFilePath -ne $null -and $ScheduleJsonFilePath -ne "") {
    Write-Host "Loading file"
    $schedules = Get-Content $ScheduleJsonFilePath | Out-String | ConvertFrom-Json
}
elseif ($ScheduleJsonFileUrl -ne $null -and $ScheduleJsonFileUrl -ne "") {
    Write-Host "Loading URL"
    $getObject = Invoke-RestMethod -Uri $ScheduleJsonFileUrl -Method Get
    $stringObject = $getObject | ConvertTo-Json
    Write-Verbose $stringObject
    $schedules = $getObject
}
if ($null -eq $schedules) {
    Write-Host "No Schedule :("
    throw "Schedule not loaded"
}
$labNames = Get-AzResourceGroup | Where-Object { $_.tags.environment -eq "lab" } | Select-Object $_
foreach ($labName in $labNames) {
    Write-Host "Running labs"
    Write-Host "Finding VMs for lab named" $labName.Tags.lab
    Write-Host "From resource group" $labName.ResourceGroupName
    $labVms = Get-AzVM | Where-Object { $_.tags.environment -eq "lab" -and $_.tags.lab -eq $labName.Tags.lab }
    $labSchedule = $schedules.labs | Where-Object { $_.name -eq $labName.Tags.lab } | Select-Object -First 1
    foreach ($labVm in $labVms) {
        Write-Host "Setting up automatic shutown schedule for" $labVm.Name
        New-AzResourceGroupDeployment -ResourceGroupName $labName.ResourceGroupName -Mode Incremental -Force -TemplateFile devtest-lab-shutdown-arm.json -TemplateParameterObject @{ vm_name = $labVm.Name }
    }
    foreach ($onDate in $labSchedule.onDates | Where-Object { [datetime]::ParseExact($_, 'yyyy-MM-dd', $null) -gt [datetime]::Now } ) {
        Write-Host "for date $onDate"
        $date = [datetime]::ParseExact($onDate, 'yyyy-MM-dd', $null)
        $timeZone = [TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time")
        $startTime = [TimeZoneInfo]::ConvertTimeFromUtc($date.ToUniversalTime(), $timeZone).AddHours(8)
        $endTime = [TimeZoneInfo]::ConvertTimeFromUtc($date.ToUniversalTime(), $timeZone).AddDays(1).AddHours(3)
        $scheduleName = $labVm.Name + "$onDate" 
        $runbookName = "start_vms_runbook_" + $labName.ResourceGroupName
        $schedule = New-AzAutomationSchedule -Name $scheduleName -DayInterval 1 -TimeZone $timeZone.Id -StartTime $startTime -ExpiryTime $endTime -ResourceGroupName $AutomationAccountResourceGroupName -AutomationAccountName $AutomationAccountName
        try {
            Unregister-AzAutomationScheduledRunbook -Force -ResourceGroupName $AutomationAccountResourceGroupName -ScheduleName $schedule.Name -AutomationAccountName $AutomationAccountName -RunbookName $runbookName
        }
        catch {
            Write-Host "Issue unregistering runbook with schedule" $error
        }
        Register-AzAutomationScheduledRunbook -ResourceGroupName $AutomationAccountResourceGroupName -ScheduleName $schedule.Name -AutomationAccountName $AutomationAccountName -RunbookName $runbookName -Parameters @{ "AzureSubscriptionIdAssetName" = $Subscription; "ResourceGroupName" = $labName.ResourceGroupName }
    }
}
