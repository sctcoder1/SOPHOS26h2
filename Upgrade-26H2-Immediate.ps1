#requires -Version 5.1
[CmdletBinding()]
param([switch]$Install,[switch]$CheckOnly,[string]$LauncherSource)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem){
    $a=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
    if($Install){$a+='-Install'}; if($CheckOnly){$a+='-CheckOnly'}; if($LauncherSource){$a+=@('-LauncherSource',$LauncherSource)}
    & "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" @a; exit $LASTEXITCODE
}
$Root=Join-Path $env:ProgramData 'Unified26H2-Immediate'
$Worker=Join-Path $Root 'Upgrade-26H2-Immediate.ps1'
$StatePath=Join-Path $Root 'state.json'
$Launcher=Join-Path $Root 'Win11-26H2-Immediate-Launcher.bat'
$LauncherHash='404DF31D55BAAC469772D26F673E231A1136BC401DEA703CB46D6F8170A17FCD'
$Tasks=@('Unified26H2-Immediate-Startup','Unified26H2-Immediate-Retry')
$Iso=Join-Path $Root 'Win11-26H2.iso'
$IsoHash='BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650'
$FidoUrl='https://raw.githubusercontent.com/sctcoder1/SOPHOS26h2/main/Fido-26H2.ps1'
$FidoHash='B2182411881FE34B84FB44454B4451F9BA7190C587C3D542AEE26682101072E3'
$Fallback='https://mscourts.sharepoint.com/:u:/s/ITDeployment/IQDLA0o0bCpTRaDUiogR_LrLAXbQOnNzgCQKILDzZeQm6OE?e=B768Ux&download=1'
function Assert-Path([string]$Path){
    $p=[IO.Path]::GetFullPath($Path)
    while($p){
        if(Test-Path -LiteralPath $p){if((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Redirected path: $p"}}
        $p=[IO.Path]::GetDirectoryName($p)
    }
}
function Ensure-Root {
    Assert-Path $Root
    New-Item -ItemType Directory -Path $Root -Force|Out-Null
    $acl=Get-Acl -LiteralPath $Root
    $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
    Set-Acl -LiteralPath $Root -AclObject $acl
    foreach($f in Get-ChildItem -LiteralPath $Root -Force){Assert-Path $f.FullName}
}
function Log([string]$Text){
    $line=([datetime]::UtcNow.ToString('o')+' '+$Text)
    Add-Content -LiteralPath (Join-Path $Root 'worker.log') -Value $line -Encoding UTF8
    Write-Host $line
}
function Start-StayAwake {
    # Keep the computer in the working state while the local SYSTEM worker is
    # downloading or running Setup. A dedicated helper process owns the power
    # request so it remains active while this runspace waits for child programs.
    # The display is intentionally allowed to turn off.
    $helperTemplate = @'
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Win10UpgradePowerRequest {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
"@
try {
    $result = [Win10UpgradePowerRequest]::SetThreadExecutionState([uint32]2147483649)
    if ($result -eq 0) { throw 'SetThreadExecutionState failed.' }
    while($true){
        $parent=Get-Process -Id __PARENT_PROCESS_ID__ -ErrorAction SilentlyContinue
        if($parent -and $parent.StartTime.Ticks -ne __PARENT_START_TICKS__){$parent=$null}
        $native=@(Get-Process -Name setup,SetupHost,SetupPrep,dism,wusa,TiWorker -ErrorAction SilentlyContinue)
        if(-not $parent -and -not $native.Count){break}
        if([Win10UpgradePowerRequest]::SetThreadExecutionState([uint32]2147483649) -eq 0){throw 'Power request refresh failed'}
        Start-Sleep -Seconds 20
    }
} finally {
    [void][Win10UpgradePowerRequest]::SetThreadExecutionState([uint32]2147483648)
}
'@
    $helperCode = $helperTemplate.Replace('__PARENT_PROCESS_ID__',[string]$PID).Replace('__PARENT_START_TICKS__',[string][Diagnostics.Process]::GetCurrentProcess().StartTime.Ticks)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($helperCode))
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $process = Start-Process -FilePath $powerShell -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 1
    if ($process.HasExited) { throw "Native stay-awake helper exited unexpectedly with code $($process.ExitCode)." }
    Log "Native stay-awake request enabled (helper PID $($process.Id)); the display may turn off."
    return $process
}

function Stop-StayAwake([Diagnostics.Process]$Process) {
    if (-not $Process) { return }
    try {
        if (-not $Process.HasExited -and (Busy)) {
            Log 'Native servicing is still active; power helper will release its request after worker exit and servicing completion.'
            return
        }
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction Stop
            $Process.WaitForExit(5000) | Out-Null
        }
        Log 'Native stay-awake request released.'
    } catch {
        Log "Stay-awake helper cleanup warning: $($_.Exception.Message)"
    } finally {
        $Process.Dispose()
    }
}
function Test-TransientCode([int]$Code){
    $hex=[BitConverter]::ToUInt32([BitConverter]::GetBytes($Code),0).ToString('X8')
    # Only documented busy/sharing/network failures, not rollback/compatibility corruption.
    return ($hex -in '00000020','000000AA','80070020','800700AA','80072EE2','80072EE7','80072EFD','80072EFE','8024401C','8024402C','80240016')
}
function Queue-TransientRetry([int]$Code,$Before){
    if(-not (Test-TransientCode $Code)){return $false}
    if((Busy) -or (Pending)){return $false}
    $now=Snapshot
    if($now.Boot -ne $Before.Boot -or $now.Build -ne $Before.Build -or $now.Running -ne $Before.Running -or $now.Release -ne $Before.Release){return $false}
    $script:State.PrereqInFlight=$false
    $script:State.InstallBoot=''
    $script:State.NativeRequiresRestart=$false
    Save 'Deferred' ('Recoverable native error '+$Code+'; no pending servicing/build transition. Will retry the normal route on the next task run')
    return $true
}
function Complete-Cleanup {
    # May be retried: validate the OS and every destructive target on every pass.
    $o=Snapshot
    if((Route $o) -ne 'Complete' -or ($script:State.OriginalEdition -and $script:State.OriginalEdition -ne $o.Edition)){throw 'Cleanup refused: target OS/edition not verified'}
    $script:State.CleanupAttempts++
    if($script:State.InstallBoot -and $script:State.InstallBoot -eq $o.Boot){Save 'CleanupPending' 'Waiting for post-install restart before removing media'; return}
    if((Busy) -or (Pending)){Save 'CleanupPending' 'Target reached; waiting for servicing/restart to finish before cleanup'; return}
    Save 'Cleaning' 'Target release, running build, edition and post-install boot verified'
    Assert-Path $Root
    # Validate task ownership before touching any task or media.
    foreach($name in $Tasks){Assert-Task $name}
    if(Test-Path -LiteralPath $Iso){
        Assert-Path $Iso
        $disk=Get-DiskImage -ImagePath $Iso -ErrorAction Stop
        if($disk.Attached){Dismount-DiskImage -ImagePath $Iso -ErrorAction Stop|Out-Null}
    }
    $payloads=@($Iso,($Iso+'.partial'),(Join-Path $Root 'Fido.ps1'),(Join-Path $Root 'Fido.ps1.partial'))
    Import-Module BitsTransfer -ErrorAction Stop
    foreach($job in @(Get-BitsTransfer -ErrorAction SilentlyContinue)){
        if($job.DisplayName -notin 'Unified26H2-Win11-26H2.iso','Unified26H2-Fido.ps1'){continue}
        $files=@($job.FileList)
        if($files.Count -eq 1 -and $files[0].LocalName -in @(($Iso+'.partial'),(Join-Path $Root 'Fido.ps1.partial'))){$job|Remove-BitsTransfer -ErrorAction Stop}
    }
    foreach($path in $payloads){
        $full=[IO.Path]::GetFullPath($path)
        if([IO.Path]::GetDirectoryName($full) -ne [IO.Path]::GetFullPath($Root)){throw 'Cleanup path outside deployment directory'}
        Assert-Path $full
        if(Test-Path -LiteralPath $full){
            if((Get-Item -LiteralPath $full -Force).PSIsContainer){throw 'Payload path is unexpectedly a directory'}
            Remove-Item -LiteralPath $full -Force -ErrorAction Stop
            Log ('Removed payload '+[IO.Path]::GetFileName($full))
        }
    }
    # Retain worker, BAT, state and logs. No Windows.old, rollback data or global caches.
    # Delete retry task last, so a failed earlier cleanup step can be retried automatically.
    foreach($name in $Tasks){
        Assert-Task $name
        if(Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue){Unregister-ScheduledTask -TaskName $name -TaskPath '\' -Confirm:$false -ErrorAction Stop}
    }
    Save 'Complete' '26H2 verified; ISO/partial downloads/Fido removed and owned startup/retry tasks unregistered. Temporary power request ends with this worker; no power-plan settings changed'
}

function Install-LocalTasks([string]$Source){
        $otherTasks=@(Get-ScheduledTask -ErrorAction Stop|Where-Object {$_.TaskName -like 'Unified26H2-*' -and $_.TaskName -notin $Tasks -and $_.State -ne 'Disabled'})
        if($otherTasks.Count){throw 'Another 26H2 reboot policy is scheduled; disable its tasks after reviewing state before switching'}
        foreach($n in $Tasks){Assert-Task $n}
        if(Test-Path -LiteralPath $Worker){
            $deployedHash=(Get-FileHash $Worker).Hash; $newHash=(Get-FileHash $Source).Hash
            if($deployedHash -ne $newHash){
                if(-not (Test-ReviewedWorkerMigration $deployedHash)){throw 'Worker migration refused: hash/state/boot/edition/reboot evidence or active-install check did not pass; existing worker retained'}
                foreach($name in $Tasks){$existing=Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue;if($existing -and $existing.State -eq 'Running'){throw 'Existing task is running; retry migration after it finishes'}}
                Copy-Item -LiteralPath $Source -Destination $Worker -Force
                Log 'Updated reviewed worker; existing completion state, reboot history and servicing retained'
            }
        }else{Copy-Item -LiteralPath $Source -Destination $Worker}
        Stage-Launcher
        $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument (Launcher-Arguments)
        $principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
        $settings=New-ScheduledTaskSettingsSet -WakeToRun -DisallowHardTerminate -AllowStartIfOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([timespan]::Zero) -DontStopIfGoingOnBatteries
        $triggers=@((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 30)))
        for($i=0;$i -lt 2;$i++){Register-ScheduledTask -TaskName $Tasks[$i] -TaskPath '\' -Action $action -Principal $principal -Settings $settings -Trigger $triggers[$i] -Force|Out-Null}
        if($script:State.Phase -eq 'New'){Save 'Installed' 'SYSTEM tasks installed'}
        Write-Output 'Local SYSTEM worker queued; starts in about one minute and retries every 30 minutes. Active servicing will be checked by the worker, not the bootstrap'
    
}

function Handle-PreReboot($o){
    # Only before our installation has started. Uncertain owned operations retain
    # their existing recovery/review behavior; a pending flag does not waive it.
    if($script:State.PrereqInFlight -or $script:State.InstallBoot -or $script:State.Phase -notin 'New','Installed','Deferred','Ready','UpdateSearch','UpdateDownload','PreRebootPending','AwaitingRestart','RestartWarning'){return $false}
    $pendingNow=Pending
    if($script:State.PreRebootBoot -and $script:State.PreRebootBoot -ne $o.Boot){
        if($pendingNow){
            Save 'ManualAttention' 'Pre-upgrade restart completed but Windows still reports a pending reboot; stopped to prevent a pre-reboot loop'
            Disable-OwnedTasks
            return $true
        }
        $script:State.PreRebootBoot='';$script:State.RebootBoot='';$script:State.NativeRequiresRestart=$false
        Save 'Ready' 'Pre-upgrade restart verified; previous Windows reboot requirement cleared'
        return $false
    }
    if(-not $pendingNow){return $false}
    $reason=Get-BusyReason -ForPreReboot
    if($reason){Save 'Deferred' ('Pre-reboot required; waiting for '+$reason);return $true}
    # Persist before shutdown. RebootBoot retains the once-per-boot countdown guard.
    $script:State.PreRebootBoot=$o.Boot
    Save 'PreRebootPending' 'Windows required a restart before our upgrade; requests the selected reboot policy and resumes from startup'
    Restart 'Pre-upgrade restart for an existing Windows reboot requirement' -PreUpgrade
    return $true
}

function Snapshot {
    $cv=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $os=Get-CimInstance Win32_OperatingSystem
    [pscustomobject]@{Build=[int]$cv.CurrentBuildNumber; Running=[int]$os.BuildNumber; UBR=[int]$cv.UBR; Release=[string]$cv.DisplayVersion; Edition=[string]$cv.EditionID; Type=[string]$cv.InstallationType; Boot=$os.LastBootUpTime.ToUniversalTime().ToString('o'); Architecture=$env:PROCESSOR_ARCHITECTURE}
}
function Route($o){
    if($o.Type -ne 'Client' -or $o.Architecture -ne 'AMD64' -or $o.Edition -match '^(EnterpriseS|IoTEnterpriseS)'){return 'Unsupported'}
    if($o.Build -ne $o.Running){return 'Inconsistent'}
    if($o.Build -eq 26300 -and $o.Release -eq '26H2'){return 'Complete'}
    if(($o.Build -eq 19045 -and $o.Release -eq '22H2') -or ($o.Build -eq 22631 -and $o.Release -eq '23H2')){return 'ISO'}
    if(($o.Build -eq 26100 -and $o.Release -eq '24H2') -or ($o.Build -eq 26200 -and $o.Release -eq '25H2')){return 'Enablement'}
    return 'Unsupported'
}
function Save([string]$Phase,[string]$Detail){
    $script:State.Phase=$Phase; $script:State.Detail=$Detail; $script:State.UpdatedUtc=[datetime]::UtcNow.ToString('o')
    $temp=Join-Path $Root 'state.tmp'; Assert-Path $temp; Assert-Path $StatePath
    [IO.File]::WriteAllText($temp,($script:State|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $StatePath -Force
    Log "$Phase : $Detail"
}
function Pending {
    if(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'){return $true}
    if(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'){return $true}
    return [bool](New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired
}
function Test-UpgradeWorkerProcess($Process){
    $line=[string]$Process.CommandLine
    $file=[regex]::Match($line,'(?i)(?:^|\s)-(?:File|f)\s+(?:"([^"]+)"|([^\s"]+))')
    if(-not $file.Success){return $false}
    $inline=[regex]::Match($line,'(?i)(?:^|\s)-(?:Command|EncodedCommand|c|ec)\b')
    if($inline.Success -and $inline.Index -lt $file.Index){return $false}
    $path=if($file.Groups[1].Success){$file.Groups[1].Value}else{$file.Groups[2].Value}
    return ([IO.Path]::GetFileName($path) -match '(?i)^(Upgrade-(Unified25H2|26H2|Win10|23H2|25H2).*|Update-Windows25H2.*)\.ps1$')
}
function Get-BusyReason([switch]$ForPreReboot,[switch]$ForUpgrade) {
    if((New-Object -ComObject Microsoft.Update.Installer).IsBusy){return 'Windows Update reports an active installation'}
    $native=@(Get-Process -Name setup,SetupHost,SetupPrep,dism,wusa,TiWorker -ErrorAction SilentlyContinue)
    if($ForUpgrade){
        $ti=@($native|Where-Object {$_.ProcessName -eq 'TiWorker'})
        if($ti.Count){Log ('TiWorker presence is advisory for upgrade readiness (PID(s) '+(($ti|ForEach-Object {$_.Id}) -join ', ')+'); Windows Update busy status, Setup/DISM/WUSA, setup flags and competing workers remain enforced')}
    }
    if($ForPreReboot -or $ForUpgrade){$native=@($native|Where-Object {$_.ProcessName -ne 'TiWorker'})}
    if($native.Count){return ('Native servicing: '+(($native|ForEach-Object {$_.ProcessName+' PID '+$_.Id}) -join ', '))}
    $setup=Get-ItemProperty 'HKLM:\SYSTEM\Setup'
    foreach($name in @('SystemSetupInProgress','OOBEInProgress')){if($setup.PSObject.Properties[$name] -and [int]$setup.$name -ne 0){return ('Windows Setup flag: '+$name)}}
    $ps=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'")
    # Ignore our process and its directly connected PowerShell ancestors (including
    # a 32-bit bootstrap that relaunched this worker in native 64-bit PowerShell).
    $ignored=@([int]$PID);$cursor=[int]$PID
    for($i=0;$i -lt 16;$i++){
        $current=$ps|Where-Object {[int]$_.ProcessId -eq $cursor}|Select-Object -First 1
        if(-not $current){break}
        $cursor=[int]$current.ParentProcessId
        if($cursor -in $ignored){break};$ignored+=$cursor
    }
    $others=@($ps|Where-Object {[int]$_.ProcessId -notin $ignored -and (Test-UpgradeWorkerProcess $_)})
    if($others.Count){return ('Other upgrade worker PID(s): '+(($others|ForEach-Object {$_.ProcessId}) -join ', '))}
    return ''
}
function Busy([switch]$ForUpgrade) {
    $script:LastBusyReason=Get-BusyReason -ForUpgrade:$ForUpgrade
    return [bool]$script:LastBusyReason
}

function Launcher-Arguments { '/d /s /c ""'+$Launcher+'""' }
function Stage-Launcher {
    $source=$LauncherSource
    if(-not $source){$source=Join-Path (Split-Path -Parent $PSCommandPath) ([IO.Path]::GetFileName($Launcher))}
    Assert-Path $source; Assert-Path $Launcher
    if(-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $LauncherHash){throw 'Downloaded BAT launcher missing or hash mismatch; no task registered'}
    if(Test-Path -LiteralPath $Launcher){
        if((Get-FileHash -LiteralPath $Launcher -Algorithm SHA256).Hash -ne $LauncherHash){throw 'Different deployed BAT launcher exists; review before replacement'}
    }elseif([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($Launcher)){
        Copy-Item -LiteralPath $source -Destination $Launcher
    }
}
function Assert-Task($Name){
    $t=Get-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction SilentlyContinue
    if($t){
        if(@($t.Actions).Count -ne 1 -or $t.Actions[0].Arguments -ne (Launcher-Arguments) -or $t.Actions[0].Execute -ne "$env:SystemRoot\System32\cmd.exe"){throw "Task collision: $Name"}
    }
}
function Disable-OwnedTasks {foreach($n in $Tasks){Assert-Task $n; if(Get-ScheduledTask -TaskName $n -TaskPath '\' -ErrorAction SilentlyContinue){Disable-ScheduledTask -TaskName $n -TaskPath '\'|Out-Null}}}
function Download([string]$Url,[string]$Path,[string]$Hash){
    Assert-Path $Path
    if((Test-Path -LiteralPath $Path) -and (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Hash){return}
    Import-Module BitsTransfer
    $jobName='Unified26H2-'+[IO.Path]::GetFileName($Path)
    # Clean up only this deployment's interrupted download jobs, never servicing.
    Get-BitsTransfer -ErrorAction SilentlyContinue|Where-Object {$_.DisplayName -eq $jobName}|Remove-BitsTransfer
    $part=$Path+'.partial'; Assert-Path $part
    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    Start-BitsTransfer -Source $Url -Destination $part -DisplayName $jobName -Priority Foreground -RetryInterval 60 -RetryTimeout 3600
    $actual=(Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash
    if($actual -ne $Hash){
        $bytes=(Get-Item -LiteralPath $part).Length
        $html='Unknown';$stream=$null
        try{
            $stream=[IO.File]::OpenRead($part);$head=New-Object byte[] 512;$read=$stream.Read($head,0,$head.Length)
            $prefix=[Text.Encoding]::UTF8.GetString($head,0,$read).TrimStart([char]0xFEFF).TrimStart()
            $html=[string]($prefix -match '(?is)^(<!doctype\s+html|<html|<head|<body|<form)')
        }catch{}finally{if($stream){$stream.Dispose()}}
        Remove-Item -LiteralPath $part -Force
        throw ('SHA256 mismatch: file='+[IO.Path]::GetFileName($Path)+'; sourceHost='+([uri]$Url).Host+'; bytes='+$bytes+'; looksLikeHTML='+$html+'; expected='+$Hash+'; actual='+$actual+'; rejected partial removed; no installation started')
    }
    Move-Item -LiteralPath $part -Destination $Path -Force
}
function Signature([string]$Path){
    $sig=Get-AuthenticodeSignature -LiteralPath $Path
    if($sig.Status -ne 'Valid' -or -not $sig.SignerCertificate -or $sig.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)'){throw "Microsoft signature invalid: $Path"}
}
function Native([string]$Exe,[string]$Arguments){
    $p=Start-Process -FilePath $Exe -ArgumentList $Arguments -WindowStyle Hidden -PassThru
    while(-not $p.WaitForExit(30000)){Log "Waiting for native PID $($p.Id); no timeout or termination"}
    $null=$p.WaitForExit(); $code=$p.ExitCode; $p.Dispose(); Log "Native exit: $code"; return $code
}
function Test-SetupRebootEvidence {
    # Correlate our successful real install with Setup's own explicit reboot
    # request. Generic Windows Update/CBS flags are not required for this case.
    $now=Snapshot
    if($script:State.Phase -notin 'OnlineComplete','AwaitingRestart','RestartWarning' -or $script:State.Attempts -ne 1 -or $script:State.PrereqInFlight -or -not $script:State.InstallBoot -or $script:State.InstallBoot -ne $now.Boot -or $script:State.OriginalEdition -ne $now.Edition){return $false}
    $workerLog=Join-Path $Root 'worker.log'
    $setupLog=Join-Path ($env:SystemDrive+'\') '$WINDOWS.~BT\Sources\Panther\setupact.log'
    Assert-Path $workerLog; Assert-Path $setupLog
    if(-not (Test-Path -LiteralPath $workerLog -PathType Leaf) -or -not (Test-Path -LiteralPath $setupLog -PathType Leaf)){return $false}
    $lines=@(Get-Content -LiteralPath $workerLog -Tail 5000 -ErrorAction Stop)
    $complete=$null
    for($i=$lines.Count-1;$i -ge 1;$i--){
        if($lines[$i] -match '^(\S+) OnlineComplete : Setup exited successfully with /noreboot$'){
            $complete=[datetimeoffset]::Parse($Matches[1]).UtcDateTime
            if($lines[$i-1] -notmatch '^(\S+) Native exit: (0|3010)$'){return $false}
            $nativeTime=[datetimeoffset]::Parse($Matches[1]).UtcDateTime
            if($nativeTime -gt $complete -or ($complete-$nativeTime).TotalSeconds -gt 60){return $false}
            break
        }
    }
    if(-not $complete -or $complete -lt ([datetimeoffset]::Parse($now.Boot).UtcDateTime) -or $complete -gt [datetime]::UtcNow.AddMinutes(2)){return $false}
    $tail=@(Get-Content -LiteralPath $setupLog -Tail 200 -ErrorAction Stop)
    $pendingTime=$null;$overrideTime=$null;$finalize=$false
    foreach($line in $tail){
        if($line -notmatch '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),'){continue}
        $time=[datetime]::ParseExact($Matches[1],'yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeLocal).ToUniversalTime()
        if([math]::Abs(($time-$complete).TotalSeconds) -gt 120){continue}
        if($line.Contains('Setup phase change: [SetupPhaseInstall] -> [SetupPhasePostFinalize]')){$finalize=$true}
        if($line.Contains('SetupHost: Reporting pending reboot event')){$pendingTime=$time}
        if($line.Contains('SetupManager: Rebooting system... prevented by command line override.')){$overrideTime=$time}
    }
    $lastWrite=(Get-Item -LiteralPath $setupLog -ErrorAction Stop).LastWriteTimeUtc
    return ($finalize -and $null -ne $pendingTime -and $null -ne $overrideTime -and $overrideTime -ge $pendingTime -and [math]::Abs(($lastWrite-$complete).TotalSeconds) -le 120)
}


function Resume-CompletedRestart([string]$Reason){
    if(-not $script:awake){$script:awake=Start-StayAwake}
    while($true){
        $now=Snapshot
        if($script:State.Phase -notin 'OnlineComplete','AwaitingRestart','RestartWarning' -or -not $script:State.InstallBoot -or $script:State.InstallBoot -ne $now.Boot -or $script:State.PrereqInFlight){throw 'Completed-upgrade restart recovery requires confirmed completion on this boot'}
        if(-not $script:State.NativeRequiresRestart -and (Test-SetupRebootEvidence)){
            $script:State.NativeRequiresRestart=$true
            Save $script:State.Phase 'Setup log and owned successful installation confirm the suppressed first reboot; automatic restart recovery retained'
        }
        if(-not (Pending) -and -not $script:State.NativeRequiresRestart){throw 'Completed phase has no confirmed reboot requirement; Setup evidence missing or mismatched'}
        # Presence of TiWorker alone is not an active-install indication. WUA,
        # Setup/DISM/WUSA, setup flags and other deployment workers still block.
        $block=Get-BusyReason -ForPreReboot
        if($block){
            Save 'OnlineComplete' ('Automatic restart recovery waiting: '+$block)
        }else{
            Restart $Reason -CompletedUpgrade
            if($script:State.RebootBoot -eq $now.Boot){return}
        }
        Start-Sleep -Seconds 30
    }
}
function Restart([string]$Reason,[switch]$PreUpgrade,[switch]$CompletedUpgrade){
    $restartBlock=Get-BusyReason -ForPreReboot:($PreUpgrade -or $CompletedUpgrade)
    if($restartBlock){throw ('Deferred: no restart while '+$restartBlock)}
    if(-not $script:awake){$script:awake=Start-StayAwake}
    $boot=(Snapshot).Boot
    if($script:State.RebootBoot -eq $boot){Save 'AwaitingRestart' 'Restart already requested this boot; operator review if cancelled'; return}
    if(-not (Pending) -and -not $script:State.NativeRequiresRestart){throw 'No confirmed reboot requirement'}
    Save 'RestartWarning' $Reason
    $message='Windows 11 upgrade requires a restart in 30 seconds. Save your work now; applications will be forcibly closed.'
    try{& "$env:SystemRoot\System32\msg.exe" '*' /TIME:30 $message 2>&1|Out-Null}catch{Log 'msg notification unavailable; shutdown notification will be used'}
    # Native shutdown shows the countdown. Continuously cancel it if servicing starts.
    $script:State.RebootBoot=$boot; $script:State.Reboots++; Save 'AwaitingRestart' $Reason
    & "$env:SystemRoot\System32\shutdown.exe" /r /f /t 30 /d p:2:3 /c $message
    if($LASTEXITCODE -ne 0){Save 'ManualAttention' 'Could not schedule restart; existing external shutdown left alone'; Disable-OwnedTasks; throw 'Restart request failed'}

    try{
        for($i=0;$i -lt 6;$i++){
            Start-Sleep -Seconds 5
            if(Get-BusyReason -ForPreReboot:($PreUpgrade -or $CompletedUpgrade)){
                & "$env:SystemRoot\System32\shutdown.exe" /a|Out-Null
                if($LASTEXITCODE -ne 0){throw 'Restart cancellation failed; immediate operator attention required'}
                $script:State.RebootBoot=''; Save 'AwaitingRestart' 'Servicing started during countdown; cancelled our restart'; return
            }
        }
    }catch{
        & "$env:SystemRoot\System32\shutdown.exe" /a|Out-Null
        $script:State.RebootBoot=''; Save 'ManualAttention' ('Countdown guard failed: '+$_.Exception.Message); Disable-OwnedTasks
        throw
    }
}
function Assert-MicrosoftIsoUri([string]$Value){
    $uri=$null
    if(-not [uri]::TryCreate($Value,[UriKind]::Absolute,[ref]$uri)){throw 'Fido returned an invalid absolute URL'}
    # The exact ISO SHA256 and mounted-image verification establish media identity;
    # a filename spelling is not a trust boundary. Keep the explicit host boundary.
    if($uri.Scheme -ne 'https' -or $uri.Host -notin @('software.download.prss.microsoft.com','software-static.download.prss.microsoft.com','software-download.microsoft.com') -or -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Fragment){
        throw ('Rejected ISO URL: scheme='+$uri.Scheme+'; host='+$uri.Host+'; path='+$uri.AbsolutePath+'; expected an allowed HTTPS Microsoft host without credentials, custom port or fragment')
    }
    return $uri
}
function Get-FidoDownloadUrl([string]$Path){
    $out=& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path -Win 11 -Rel '26H2' -Ed Pro -Lang English -Arch x64 -GetUrl 2>&1
    if($LASTEXITCODE -ne 0){throw ('Fido URL query failed; exit='+$LASTEXITCODE)}
    $urls=@($out|ForEach-Object {([string]$_).Trim()}|Where-Object {$_ -match '^https://'})
    if($urls.Count -ne 1){throw ('Expected exactly one Fido HTTPS URL; received '+$urls.Count)}
    return $urls[0]
}
function Acquire-Iso {
    if((Test-Path -LiteralPath $Iso) -and (Get-FileHash -LiteralPath $Iso -Algorithm SHA256).Hash -eq $IsoHash){return}
    try{
        $f=Join-Path $Root 'Fido.ps1'; Download $FidoUrl $f $FidoHash
        $candidate=Get-FidoDownloadUrl $f
        $uri=Assert-MicrosoftIsoUri $candidate
        Log ('Primary ISO URL accepted: host='+$uri.Host+'; path='+$uri.AbsolutePath+'; URL query omitted; exact ISO hash still required')
        Download $uri.AbsoluteUri $Iso $IsoHash
    }catch{
        Log ('Primary ISO failed: '+$_.Exception.Message)
        Log 'Trying supplied SharePoint fallback; exact ISO hash remains required'
        Download $Fallback $Iso $IsoHash
    }
}

function Iso-Upgrade($o){
    # v9 unsupported-hardware attempt: honor existing configuration, without
    # changing registry values, deleting appraiser data or modifying media.
    $bypass=Get-ItemProperty 'HKLM:\SYSTEM\Setup\MoSetup' -ErrorAction SilentlyContinue
    if($bypass -and $bypass.PSObject.Properties['AllowUpgradesWithUnsupportedTPMOrCPU'] -and $bypass.AllowUpgradesWithUnsupportedTPMOrCPU -ne 0){
        Log ('Unsupported-hardware attempt: honoring existing AllowUpgradesWithUnsupportedTPMOrCPU='+$bypass.AllowUpgradesWithUnsupportedTPMOrCPU+'; installer hard limits can still apply')
    }
    if(Test-Path 'HKLM:\SYSTEM\Setup\LabConfig'){Log 'Existing LabConfig retained; its presence does not establish that an in-place upgrade can bypass hardware requirements'}
    if($o.Edition -notin @('Professional','Core','Education')){throw 'Consumer ISO edition unsupported'}
    # Installed UI language, not keyboard/system locale, must match media.
    $lang=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language').InstallLanguage
    if($lang -ne '0409'){throw 'ISO requires en-US installed UI language'}
    if((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").FreeSpace -lt 35GB){throw '35 GB free space required'}
    if(-not (Test-IsoReady $o)){return}
    Log 'Route=ISO: acquiring pinned Windows 11 26H2 English x64 media'
    Acquire-Iso
    if(-not (Test-IsoReady $o)){return}
    $disk=Mount-DiskImage -ImagePath $Iso -PassThru
    try{
        $vol=$disk|Get-Volume|Where-Object DriveLetter|Select-Object -First 1
        if(-not $vol){throw 'ISO has no drive letter'}
        $drive=$vol.DriveLetter+':'; $setup=Join-Path $drive 'setup.exe'
        Signature $setup; Signature (Join-Path $drive 'sources\setupprep.exe')
        $image=Join-Path $drive 'sources\install.wim'; if(-not(Test-Path $image)){$image=Join-Path $drive 'sources\install.esd'}
        $valid=@(Get-WindowsImage -ImagePath $image|ForEach-Object {Get-WindowsImage -ImagePath $image -Index $_.ImageIndex}|Where-Object {$_.EditionId -eq $o.Edition -and ([version]$_.Version).Build -eq 26300 -and [string]$_.Architecture -in @('9','x64','amd64') -and @($_.Languages) -contains 'en-US'})
        if($valid.Count -ne 1){throw 'Expected exactly one matching x64/en-US edition at build 26300'}
        if(-not (Test-IsoReady $o)){return}
        Save 'Scanning' 'Windows Setup compatibility scan'
        $base='/auto upgrade /quiet /eula accept /compat ignorewarning /dynamicupdate enable /noreboot /imageindex '+$valid[0].ImageIndex
        $code=Native $setup ($base+' /compat scanonly /copylogs "'+(Join-Path $Root 'CompatLogs.zip')+'"')
        $hex=[BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$code),0).ToString('X8')
        if($hex -ne 'C1900210'){
            if($hex -in 'C1900200','C1900204','C1900208','C190020E'){Save 'Deferred' "Compatibility block 0x$hex; next task run will recheck after remediation"}
            throw "Compatibility not approved: 0x$hex"
        }
        Save 'Ready' 'ISO compatibility scan passed; rechecking source OS, servicing and reboot requirements'
        if(-not (Test-IsoReady $o)){return}
        $script:State.Attempts++; $script:State.InstallBoot=$o.Boot; Save 'InstallingISO' 'Online Setup started; interrupted execution requires review'
        $code=Native $setup ($base+' /showoobe none /copylogs "'+(Join-Path $Root 'SetupLogs.zip')+'"')
        if($code -notin 0,3010){
            if(Queue-TransientRetry $code $o){return}
            throw "Setup failed/unexpected exit $code; do not infer restart readiness"
        }
        $script:State.NativeRequiresRestart=($code -eq 3010)
        Save 'OnlineComplete' 'Setup exited successfully with /noreboot'

        if((Pending) -or $script:State.NativeRequiresRestart -or (Test-SetupRebootEvidence)){Resume-CompletedRestart 'Windows Setup online phase finished'}else{Save 'ManualAttention' 'Setup returned 0 but no confirmed reboot marker; inspect Panther before restarting'; Disable-OwnedTasks}
    }finally{
        if(-not (Busy)){Dismount-DiskImage -ImagePath $Iso -ErrorAction SilentlyContinue}
    }
}
function Test-PrerequisiteCandidate($Update){
    if($Update.BrowseOnly -or $Update.InstallationBehavior.CanRequestUserInput){return $false}
    if($Update.Title -notmatch '(?i)Cumulative Update.*Windows 11.*(24H2|25H2).*x64'){return $false}
    return ($Update.Title -notmatch '(?i)Preview|Insider|Dynamic|Safe OS|\.NET|Hotpatch' -and [datetime]$Update.LastDeploymentChangeTime -ge [datetime]'2026-10-13')
}
function Invoke-PrerequisiteOperation($Owner,[string]$Kind,[string]$Criteria=''){
    if(-not ('Unified26H2.UpdateCallback' -as [type])){
        Add-Type 'using System.Runtime.InteropServices; namespace Unified26H2 { [ComVisible(true),ClassInterface(ClassInterfaceType.AutoDispatch)] public class UpdateCallback { [DispId(0)] public void Invoke(object job,object args){} } }'
    }
    $callback=New-Object Unified26H2.UpdateCallback
    switch($Kind){
        'Search' {$job=$Owner.BeginSearch($Criteria,$callback,$null)}
        'Download' {$job=$Owner.BeginDownload($callback,$callback,$null)}
        'Install' {$job=$Owner.BeginInstall($callback,$callback,$null)}
        default {throw 'Unknown Windows Update operation'}
    }
    # Never abort or kill a servicing operation because of an arbitrary timeout.
    $watch=[Diagnostics.Stopwatch]::StartNew(); $nextLog=0
    while(-not $job.IsCompleted){
        if($watch.Elapsed.TotalSeconds -ge $nextLog){Log "Prerequisite $Kind active ($([int]$watch.Elapsed.TotalSeconds) seconds)"; $nextLog=$watch.Elapsed.TotalSeconds+30}
        Start-Sleep -Seconds 5
    }
    switch($Kind){
        'Search' {$result=$Owner.EndSearch($job)}
        'Download' {$result=$Owner.EndDownload($job)}
        'Install' {$result=$Owner.EndInstall($job)}
    }
    $watch.Stop(); return $result
}
function Install-OfferedUpdate($session,$chosen,[bool]$Feature,$o){
    if(Busy -ForUpgrade){throw 'Servicing busy; deferred before download'}
    if((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").FreeSpace -lt 15GB){throw '15 GB free required for update servicing'}
    Log ('Selected update: '+$chosen.Title+'; ID='+$chosen.Identity.UpdateID+'; revision='+$chosen.Identity.RevisionNumber)
    if(-not $chosen.EulaAccepted){$chosen.AcceptEula()}
    $collection=New-Object -ComObject Microsoft.Update.UpdateColl; $null=$collection.Add($chosen)
    $downloader=$session.CreateUpdateDownloader(); $downloader.Updates=$collection
    Save 'UpdateDownload' $chosen.Title
    $download=Invoke-PrerequisiteOperation $downloader Download
    if($download.ResultCode -ne 2 -or $download.GetUpdateResult(0).ResultCode -ne 2 -or -not $chosen.IsDownloaded){throw 'Update download failed; no installation attempted'}
    if(Busy -ForUpgrade){throw 'Servicing busy; deferred before installation'}
    $installer=$session.CreateUpdateInstaller(); $installer.Updates=$collection; $installer.ForceQuiet=$true; $installer.AllowSourcePrompts=$false
    if($installer.RebootRequiredBeforeInstallation){Restart 'Windows Update requires restart before installation'; return}
    if($Feature){$script:State.Attempts++; $script:State.InstallBoot=$o.Boot}else{$script:State.PrereqAttempts++}
    $script:State.PrereqInFlight=$true
    Save 'InstallingUpdate' $chosen.Title
    $installed=Invoke-PrerequisiteOperation $installer Install
    $item=$installed.GetUpdateResult(0)
    if($installed.ResultCode -ne 2 -or $item.ResultCode -ne 2){
        if($installed.ResultCode -eq 4 -and $item.ResultCode -eq 4 -and -not $installed.RebootRequired -and -not $item.RebootRequired -and -not $chosen.IsInstalled -and (Queue-TransientRetry $item.HResult $o)){return}
        throw "Partial/failed update result: $($item.HResult); review CBS and Windows Update logs"
    }
    $script:State.PrereqInFlight=$false
    $script:State.NativeRequiresRestart=[bool]($installed.RebootRequired -or $item.RebootRequired)
    if($Feature){Save 'OnlineComplete' '26H2 offered update installed successfully'}else{Save 'PrerequisiteComplete' 'Cumulative prerequisite installed successfully'}
    if($script:State.NativeRequiresRestart -or (Pending)){Restart 'Windows update installed; upgrade continues after restart'; return}
    if($Feature){Save 'ManualAttention' 'Feature update returned success without restart requirement; inspect logs'; Disable-OwnedTasks}
    elseif((Snapshot).UBR -lt 9711){Save 'ManualAttention' 'Prerequisite did not reach expected October baseline'; Disable-OwnedTasks}
}
function Test-ReviewedWorkerMigration([string]$Hash){
    if($Hash -in '6B70AFB06406F851BB1FA537F3AEFCEE7AF25D8E1A2A5D62695CC1E4B4A7BD26','31CB190E55E573CCB57803B94F796A1E6BF909D97645AB621BC7EEF3F7800C80'){
        if($script:State.PrereqInFlight){return $false}
        if($script:State.Attempts -eq 0 -and $script:State.PrereqAttempts -eq 0 -and -not $script:State.InstallBoot){return ($script:State.Phase -in 'New','Installed','Deferred','Ready','UpdateSearch','UpdateDownload','PreRebootPending','AwaitingRestart','RestartWarning')}
        $now=Snapshot
        return ($script:State.Phase -eq 'OnlineComplete' -and $script:State.Attempts -eq 1 -and $script:State.InstallBoot -eq $now.Boot -and $script:State.OriginalEdition -eq $now.Edition -and ((Pending) -or $script:State.NativeRequiresRestart -or (Test-SetupRebootEvidence)) -and -not (Get-BusyReason -ForPreReboot))
    }
    # Never reset state or replace an installation that may have started.
    if($script:State.Attempts -ne 0 -or $script:State.PrereqAttempts -ne 0 -or $script:State.InstallBoot -or $script:State.PrereqInFlight){return $false}
    if($Hash -in '9BF31597C2D2CD959BDA781325198718C3A15958D93B43F10141066BD558E675','CD6D8F63B5E7437B57FFD9F0EA4B95533F850F5DFE9BD4854D83C8886FAB9BE6','2C46792579FAC24EDA6C4D3A4C16E05DB863BF75AFB5227D68C2C2CB3F922D20','2BCA66C534FDE64FD7CF84D8A2330CC5047D805548B24488EB8C0187A4D22750','D6459382CE731180BCB48548FF8337991CE41F253D73D9A3EBD5CD56635336F0','B74CD326D65CA5D54F8E0D9E9D995018E5C7895EEA882443AEAF4E6F1FE659A1'){
        # A completed pre-upgrade reboot is allowed; preserve its history.
        return ($script:State.Phase -in 'New','Installed','Deferred','Ready','UpdateSearch','UpdateDownload','PreRebootPending','AwaitingRestart','RestartWarning')
    }
    return ($Hash -eq 'C1225B47C98780C2EB3C4CEB919AC4A9BACDDB821372705C37B7EACB5114D8FC' -and $script:State.Reboots -eq 0 -and $script:State.Phase -in 'New','Installed','Deferred','Ready')
}
function Assert-NoReportedSafeguard {
    # Microsoft documents this local indication. Absence is not proof that no
    # service-side hold exists; media upgrades still need pilot validation.
    $g=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Appraiser\GWX' -ErrorAction SilentlyContinue
    if($g -and $g.PSObject.Properties['GStatus'] -and [string]$g.GStatus -eq '0'){
        throw 'Deferred: Windows reports an active safeguard hold (GStatus=0); resolve the reported hold before ISO installation'
    }
}
function Test-IsoReady($Before){
    $now=Snapshot
    foreach($key in @('Build','Running','Release','Edition','Boot','Architecture','Type')){
        if($now.$key -ne $Before.$key){throw ('Source OS changed before ISO installation: '+$key+'; retry with a fresh snapshot')}
    }
    if(Busy -ForUpgrade){throw 'Deferred: native servicing active before ISO operation'}
    Assert-NoReportedSafeguard
    if(Pending){
        Save 'Ready' 'Windows now requires a restart before ISO work; using the selected pre-reboot policy'
        [void](Handle-PreReboot $now)
        return $false
    }
    return $true
}
function Msu-Upgrade($o){
    $session=New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID='Unified26H2'; $session.UserLocale=1033
    $searcher=$session.CreateUpdateSearcher(); $searcher.ServerSelection=0; $searcher.Online=$true
    Save 'UpdateSearch' 'Searching configured Windows Update/WSUS for 26H2 enablement before choosing ISO'
    $scan=Invoke-PrerequisiteOperation $searcher Search "IsInstalled=0 and IsHidden=0 and Type='Software'"
    # A failed/incomplete search is not evidence of an absent offer.
    if($scan.ResultCode -ne 2){throw 'Update search incomplete; retry search before selecting a method'}
    $candidates=@(for($i=0;$i -lt $scan.Updates.Count;$i++){
        $u=$scan.Updates.Item($i)
        if(@($u.KBArticleIDs) -contains '5121794' -and $u.Title -match '(?i)26H2' -and $u.Title -notmatch '(?i)Preview|Insider' -and -not $u.InstallationBehavior.CanRequestUserInput){$u}
    })
    if($candidates.Count -gt 1){throw 'Multiple applicable KB5121794 26H2 offers; review update identities before selecting an update'}
    if($candidates.Count -eq 0){
        Save 'Ready' 'Route=ISO: successful update search returned no supported 26H2 enablement offer; selecting validated 26H2 media'
        Iso-Upgrade $o
        return
    }
    if($o.UBR -lt 9711){
        $prerequisites=@(for($i=0;$i -lt $scan.Updates.Count;$i++){
            $u=$scan.Updates.Item($i); if(Test-PrerequisiteCandidate $u){$u}
        })
        if(-not $prerequisites.Count){
            Save 'Ready' 'Route=ISO: enablement prerequisite is below the package baseline and no suitable cumulative update is offered'
            Iso-Upgrade $o
            return
        }
        $chosen=$prerequisites|Sort-Object LastDeploymentChangeTime -Descending|Select-Object -First 1
        Install-OfferedUpdate $session $chosen $false $o
        return
    }
    Log 'Route=Enablement: exactly one supported 26H2 offer found and cumulative baseline satisfied'
    Install-OfferedUpdate $session $candidates[0] $true $o
}

if($CheckOnly){Snapshot|Format-List; if(Test-Path -LiteralPath $StatePath){Get-Content -LiteralPath $StatePath}; exit 0}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Elevation required'}
if(-not $Install -and $identity.User.Value -ne 'S-1-5-18'){throw 'Worker must run as SYSTEM; use -Install'}
$mutex=[Threading.Mutex]::new($false,'Global\WindowsFeatureUpgrade-26H2-v1')
$locked=$false
$script:State=$null
$stateValid=$false
$awake=$null
try{
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){Write-Output 'Worker already active; deployment unchanged'; exit 0}
    Ensure-Root
    $script:State=@{Schema=1;Phase='New';Detail='';UpdatedUtc='';Attempts=0;Runs=0;Reboots=0;RebootBoot='';InstallBoot='';OriginalEdition='';NativeRequiresRestart=$false;CreatedUtc=[datetime]::UtcNow.ToString('o');PrereqAttempts=0;PrereqBoot='';PrereqTitle='';PrereqInFlight=$false;CleanupAttempts=0;PreRebootBoot=''}
    if(Test-Path -LiteralPath $StatePath){
        $loaded=Get-Content -LiteralPath $StatePath -Raw|ConvertFrom-Json
        if($loaded.Schema -ne 1){throw 'State schema invalid; no automatic reset'}
        foreach($key in @($script:State.Keys)){
            if(-not $loaded.PSObject.Properties[$key]){if($key -in 'PrereqAttempts','PrereqBoot','PrereqTitle','PrereqInFlight','CleanupAttempts','PreRebootBoot'){continue}; throw "State field missing: $key"}
            $script:State[$key]=$loaded.$key
        }
    }
    foreach($key in @('Attempts','Runs','Reboots','PrereqAttempts','CleanupAttempts')){if($script:State[$key] -isnot [int] -and $script:State[$key] -isnot [long]){throw "Invalid state counter: $key"}; if($script:State[$key] -lt 0){throw "Negative state counter: $key"}}
    if($script:State.PrereqInFlight -isnot [bool]){throw 'Invalid prerequisite recovery flag'}
    $null=[datetime]::Parse($script:State.CreatedUtc)
    $stateValid=$true
    if($Install -and $script:State.Phase -eq 'OnlineComplete' -and (Test-Path -LiteralPath $Worker) -and (Test-ReviewedWorkerMigration (Get-FileHash -LiteralPath $Worker).Hash)){
        Install-LocalTasks -Source $PSCommandPath; exit 0
    }
    $o=Snapshot; $route=Route $o
    if($route -eq 'Complete'){
        if($script:State.PrereqInFlight){Save 'ManualAttention' 'Interrupted update operation; inspect servicing before completion'; Disable-OwnedTasks; exit 1}
        if($script:State.OriginalEdition -and $script:State.OriginalEdition -ne $o.Edition){Save 'ManualAttention' 'Target build reached but edition changed'; Disable-OwnedTasks; exit 1}
        Complete-Cleanup; exit 0
    }
    if($route -eq 'Inconsistent' -and -not $Install -and $script:State.InstallBoot -eq $o.Boot -and $script:State.Phase -in 'OnlineComplete','AwaitingRestart','RestartWarning'){
        Resume-CompletedRestart 'Owned completed online phase has staged a kernel transition'; exit 0
    }
    if($route -in 'Unsupported','Inconsistent'){throw "Unsupported/inconsistent OS: $($o|ConvertTo-Json -Compress)"}
    if(-not $script:State.OriginalEdition){$script:State.OriginalEdition=$o.Edition}
    if($Install){Install-LocalTasks -Source $PSCommandPath; exit 0}
    if($script:State.Phase -in 'Complete','ManualAttention'){exit 0}
    $script:State.Runs++; Save $script:State.Phase 'Worker entered'
    if($script:State.Phase -in 'OnlineComplete','AwaitingRestart','RestartWarning' -and $script:State.InstallBoot -eq $o.Boot){Resume-CompletedRestart 'Previously completed online phase'; exit 0}
    if(Handle-PreReboot $o){exit 0}
    if(Busy -ForUpgrade){Save $script:State.Phase ('Waiting; retained recovery phase. '+$script:LastBusyReason); exit 0}
    if($script:State.PrereqInFlight){Save 'ManualAttention' 'Interrupted/partial cumulative-update install; review Windows Update/CBS before resuming'; Disable-OwnedTasks; exit 1}
    # Do not re-run a possibly completed Setup after crash, external reboot, or rollback.
    if($script:State.InstallBoot -and $script:State.InstallBoot -ne $o.Boot){Save 'ManualAttention' 'Upgrade attempt crossed reboot without target verification; possible rollback'; Disable-OwnedTasks; exit 1}
    if(-not $script:State.InstallBoot -and $script:State.RebootBoot -and $script:State.RebootBoot -ne $o.Boot){
        $script:State.NativeRequiresRestart=$false
        Save 'Ready' 'Prerequisite restart completed; rechecking upgrade applicability'
    }
    if($script:State.Phase -in 'InstallingISO','InstallingUpdate','Scanning'){Save 'ManualAttention' 'Interrupted native operation; review logs before resuming'; Disable-OwnedTasks; exit 1}
    if($script:State.Phase -eq 'PrerequisiteComplete'){
        if($script:State.NativeRequiresRestart -or (Pending)){Restart 'Completed cumulative update requires restart'; exit 0}
        Save 'Ready' 'Cumulative update complete; rechecking running build threshold'
    }
    if($script:State.Phase -in 'OnlineComplete','AwaitingRestart','RestartWarning'){
        Resume-CompletedRestart 'Previously completed online phase'; exit 0
    }
    if(Pending){Restart 'Existing Windows servicing requires restart before upgrade'; exit 0}
    if(-not $awake){$awake=Start-StayAwake}
    if($route -eq 'ISO'){Iso-Upgrade $o}else{Msu-Upgrade $o}
}catch{
    $failure=$_.Exception.Message
    if($locked -and $stateValid){
        # Failure after native install may have left servicing staged. Never retry/reboot on speculation.
        try{if($script:State.Phase -in 'Cleaning','CleanupPending'){Save 'CleanupPending' $failure}elseif($script:State.PrereqInFlight -or $script:State.Phase -in 'InstallingISO','InstallingUpdate','Scanning'){Save 'ManualAttention' $failure; Disable-OwnedTasks}elseif($script:State.Phase -in 'OnlineComplete','AwaitingRestart','RestartWarning','PrerequisiteComplete','ManualAttention'){Save $script:State.Phase $failure}else{Save 'Deferred' $failure}}catch{}
    }
    Write-Error $failure -ErrorAction Continue; exit 1
}finally{if($awake){Stop-StayAwake $awake}; if($locked){$mutex.ReleaseMutex()}; $mutex.Dispose()}

