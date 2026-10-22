#requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Both','Warning','Immediate')][string]$Mode='Both',[switch]$Preview)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem){
    $nativeArgs=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Mode',$Mode)
    if($Preview){$nativeArgs+='-Preview'}
    & "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" @nativeArgs
    exit $LASTEXITCODE
}
function Assert-CleanupPath([string]$Path){
    $full=[IO.Path]::GetFullPath($Path)
    $cursor=$full
    while($cursor){
        if(Test-Path -LiteralPath $cursor){
            if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Redirected cleanup path refused: '+$cursor)}
        }
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
    return $full
}
function Get-OwnedTask([string]$Name,[string]$Root,[string]$Variant){
    try{$task=Get-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction Stop}
    catch{if($_.CategoryInfo.Category -eq 'ObjectNotFound'){return $null};throw}
    $expected='/d /s /c ""'+(Join-Path $Root ('Win11-26H2-'+$Variant+'-Launcher.bat'))+'""'
    if(@($task.Actions).Count -ne 1 -or $task.Actions[0].Execute -ine "$env:SystemRoot\System32\cmd.exe" -or $task.Actions[0].Arguments -cne $expected -or $task.Principal.UserId -notin 'SYSTEM','S-1-5-18','NT AUTHORITY\SYSTEM'){
        throw ('Task ownership/action mismatch; left unchanged: '+$Name)
    }
    if([string]$task.State -eq 'Running'){throw ('Owned task is running; let it finish and rerun cleanup: '+$Name)}
    return $task
}
function Assert-CleanupIdle {
    if((New-Object -ComObject Microsoft.Update.Installer).IsBusy){throw 'Windows Update is installing; cleanup deferred'}
    $native=@(Get-Process -Name setup,SetupHost,SetupPrep,dism,wusa,TiWorker -ErrorAction SilentlyContinue)
    if($native.Count){throw ('Servicing processes are present; cleanup deferred: '+(($native|ForEach-Object {$_.ProcessName+' PID '+$_.Id}) -join ', '))}
    $setup=Get-ItemProperty 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
    foreach($name in @('SystemSetupInProgress','OOBEInProgress')){
        if($setup.PSObject.Properties[$name] -and [int]$setup.$name -ne 0){throw ('Windows Setup flag is active: '+$name)}
    }
    foreach($process in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop)){
        $line=[string]$process.CommandLine
        $file=[regex]::Match($line,'(?i)(?:^|\s)-(?:File|f)\s+(?:"([^"]+)"|([^\s"]+))')
        $inline=[regex]::Match($line,'(?i)(?:^|\s)-(?:Command|EncodedCommand|c|ec)\b')
        if(-not $file.Success -or ($inline.Success -and $inline.Index -lt $file.Index)){continue}
        $path=if($file.Groups[1].Success){$file.Groups[1].Value}else{$file.Groups[2].Value}
        if([IO.Path]::GetFileName($path) -match '(?i)^(Upgrade-(Unified25H2|26H2|Win10|23H2|25H2).*|Update-Windows25H2.*)\.ps1$'){
            throw ('Another upgrade script is present; cleanup deferred: PID '+$process.ProcessId)
        }
    }
    foreach($path in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')){
        if(Test-Path -LiteralPath $path){throw 'Windows reports a pending reboot; cleanup deferred without requesting a restart'}
    }
    if((New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired){throw 'Windows Update reports a pending reboot; cleanup deferred without requesting a restart'}
}
function Get-CleanupOs {
    $cv=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    [pscustomobject]@{Build=[int]$cv.CurrentBuildNumber;Running=[int]$os.BuildNumber;Release=[string]$cv.DisplayVersion;Edition=[string]$cv.EditionID;Type=[string]$cv.InstallationType;Boot=$os.LastBootUpTime.ToUniversalTime().ToString('o')}
}
function Assert-CleanupState([string]$Root,$Os){
    if($Os.Build -ne $Os.Running){throw 'Installed/running Windows builds differ; retain deployment recovery files'}
    $path=Assert-CleanupPath (Join-Path $Root 'state.json')
    if(-not (Test-Path -LiteralPath $path)){return}
    $state=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    foreach($name in @('Schema','Phase','Attempts','InstallBoot','PrereqInFlight','NativeRequiresRestart','OriginalEdition')){
        if(-not $state.PSObject.Properties[$name]){throw ('Cleanup refused: saved state field missing: '+$name+' in '+$Root)}
    }
    if($state.Schema -ne 1 -or ($state.Attempts -isnot [int] -and $state.Attempts -isnot [long]) -or $state.Attempts -lt 0 -or $state.PrereqInFlight -isnot [bool] -or $state.NativeRequiresRestart -isnot [bool]){throw ('Cleanup refused: invalid saved state in '+$Root)}
    if($state.PrereqInFlight){throw ('Unfinished update state; retain recovery files: '+$Root)}
    $target=($Os.Type -eq 'Client' -and $Os.Build -eq 26300 -and $Os.Running -eq 26300 -and $Os.Release -eq '26H2' -and (!$state.OriginalEdition -or $state.OriginalEdition -eq $Os.Edition))
    if($target -and (!$state.InstallBoot -or $state.InstallBoot -ne $Os.Boot)){return}
    if($state.NativeRequiresRestart){throw ('Unfinished restart state; retain recovery files: '+$Root)}
    if($state.Attempts -gt 0 -or $state.InstallBoot){throw ('Owned upgrade was attempted but post-boot target is not verified; retain recovery media/state: '+$Root)}
    if($state.Phase -notin 'New','Installed','Ready','Deferred','UpdateSearch','UpdateDownload','PrerequisiteComplete','PreRebootPending','AwaitingRestart','RestartWarning','ManualAttention'){
        throw ('Uncertain saved phase; retain recovery files: '+[string]$state.Phase+' in '+$Root)
    }
}
function Get-CleanupPlan([string]$Variant,$Os,$BitsJobs){
    $root=Assert-CleanupPath (Join-Path $env:ProgramData ('Unified26H2-'+$Variant))
    if([IO.Path]::GetDirectoryName($root) -ine [IO.Path]::GetFullPath($env:ProgramData)){throw 'Cleanup root is outside ProgramData'}
    if((Test-Path -LiteralPath $root) -and -not (Get-Item -LiteralPath $root -Force).PSIsContainer){throw ('Deployment root is not a directory: '+$root)}
    $names=@(('Unified26H2-'+$Variant+'-Startup'),('Unified26H2-'+$Variant+'-Retry'))
    $tasks=@(foreach($name in $names){$task=Get-OwnedTask $name $root $Variant;if($task){$name}})
    Assert-CleanupState $root $Os
    $log=Assert-CleanupPath (Join-Path $root 'ManualCleanup.log')
    if((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log -Force).PSIsContainer){throw 'Cleanup log path is a directory'}
    $paths=@(foreach($leaf in @('Win11-26H2.iso','Win11-26H2.iso.partial','Fido.ps1','Fido.ps1.partial')){
        $path=Assert-CleanupPath (Join-Path $root $leaf)
        if([IO.Path]::GetDirectoryName($path) -ine $root){throw 'Cleanup payload escapes deployment root'}
        if((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path -Force).PSIsContainer){throw ('Payload path is a directory: '+$path)}
        $path
    })
    $jobs=@(foreach($job in $BitsJobs){
        $files=@($job.FileList)
        $destinations=@($files|ForEach-Object {[string]$_.LocalName})
        if(-not @($destinations|Where-Object {$_ -in $paths}).Count){continue}
        if($files.Count -ne 1 -or $destinations[0] -notin @((Join-Path $root 'Win11-26H2.iso.partial'),(Join-Path $root 'Fido.ps1.partial')) -or $job.DisplayName -cne ('Unified26H2-'+[IO.Path]::GetFileName($destinations[0]).Replace('.partial',''))){throw ('Unrecognized BITS job targets deployment files; left unchanged: '+$job.DisplayName)}
        $job
    })
    [pscustomobject]@{Variant=$Variant;Root=$root;Tasks=$tasks;Paths=$paths;Jobs=$jobs}
}
function Invoke-OwnedCleanup($Plan){
    Assert-CleanupIdle
    # Disable before deleting media so no new scheduled attempt starts afterward.
    foreach($name in $Plan.Tasks){
        if(Get-OwnedTask $name $Plan.Root $Plan.Variant){Disable-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction Stop|Out-Null}
    }
    Assert-CleanupIdle
    foreach($job in $Plan.Jobs){$job|Remove-BitsTransfer -ErrorAction Stop}
    $iso=Join-Path $Plan.Root 'Win11-26H2.iso'
    if(Test-Path -LiteralPath $iso){
        $null=Assert-CleanupPath $iso
        $disk=Get-DiskImage -ImagePath $iso -ErrorAction Stop
        if($disk.Attached){Dismount-DiskImage -ImagePath $iso -ErrorAction Stop|Out-Null}
    }
    Assert-CleanupIdle
    foreach($path in $Plan.Paths){
        $null=Assert-CleanupPath $path
        if(Test-Path -LiteralPath $path){
            if((Get-Item -LiteralPath $path -Force).PSIsContainer){throw 'Payload changed into a directory; cleanup stopped'}
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            Write-Output ('Removed: '+$path)
        }
    }
    foreach($name in $Plan.Tasks){
        if(Get-OwnedTask $name $Plan.Root $Plan.Variant){Unregister-ScheduledTask -TaskName $name -TaskPath '\' -Confirm:$false -ErrorAction Stop}
    }
    if(Test-Path -LiteralPath $Plan.Root){
        $log=Join-Path $Plan.Root 'ManualCleanup.log';$null=Assert-CleanupPath $log
        Add-Content -LiteralPath $log -Encoding UTF8 -Value ([datetime]::UtcNow.ToString('o')+' Manual cleanup: owned tasks/media/download jobs removed. Worker/BAT/state/logs retained; no reboot, servicing termination or power-plan changes.')
    }
    Write-Output ($Plan.Variant+': manual cleanup complete; retained worker/BAT, state and logs. No future owned task remains.')
}

$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run through elevated Sophos Live Response'}
$mutex=[Threading.Mutex]::new($false,'Global\WindowsFeatureUpgrade-26H2-v1')
$locked=$false;$changesStarted=$false
try{
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw '26H2 deployment is active; no cleanup attempted. Let it finish and rerun cleanup'}
    Assert-CleanupIdle
    Import-Module BitsTransfer -ErrorAction Stop
    $jobs=@(Get-BitsTransfer -AllUsers -ErrorAction Stop)
    $os=Get-CleanupOs
    $variants=if($Mode -eq 'Both'){@('Warning','Immediate')}else{@($Mode)}
    # Complete both-mode preflight before altering either deployment.
    $plans=@(foreach($variant in $variants){Get-CleanupPlan $variant $os $jobs})
    foreach($plan in $plans){Write-Output ($plan.Variant+': tasks='+$plan.Tasks.Count+'; owned BITS jobs='+$plan.Jobs.Count+'; payload paths='+$plan.Paths.Count)}
    if($Preview){Write-Output 'Preview only: nothing disabled, removed or changed';exit 0}
    $changesStarted=$true
    foreach($plan in $plans){Invoke-OwnedCleanup $plan}
    Write-Output 'Manual cleanup finished. No reboot requested; Windows.old, recovery files and unrelated jobs/power settings were retained.'
    exit 0
}catch{
    Write-Error $_.Exception.Message -ErrorAction Continue
    if($changesStarted){Write-Output 'Cleanup stopped after changes began. Some owned tasks may now be disabled; retain the logs and rerun cleanup once the reported issue clears.'}
    else{Write-Output 'Preflight failed: no deployment tasks or payloads were changed.'}
    exit 1
}finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
