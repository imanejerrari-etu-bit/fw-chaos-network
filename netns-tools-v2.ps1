# =====================================================================
# netns-tools-v2.ps1  (v2.1)  --  collection of raw artefacts for the Phase 1 experiments
# Usage:  . .\netns-tools.ps1 ; . .\netns-tools-v2.ps1
# Requires from netns-tools.ps1: Get-PodNetnsInfo, Add-PartitionRule, Remove-PartitionRule,
#                                Clear-AllPartitionRules, Wait-ForStableReplicaSet
# This script only SAVES raw material (writer logs, engine logs, final state, metadata).
# All metrics are computed offline by parse_trials.py.
# Changes after the smoke test: single-call rule application (near-atomic isolation), four timestamps
# (partition start, isolated, heal start, heal end), health pre-check, writer pre-check, restart counters,
# PXC engine log read from mysqld-error.log, PXC default hold 20 s (see PLAN_EXPERIMENTS_V2.md).
# =====================================================================

$script:V2Root = "runs_v2"

function Get-NowMs { return [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) }

function New-TrialDir {
    param([Parameter(Mandatory=$true)][string]$Campaign, [Parameter(Mandatory=$true)][int]$Trial)
    $d = Join-Path $script:V2Root ("{0}\t{1:D3}" -f $Campaign, $Trial)
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return (Resolve-Path $d).Path
}

function Save-Meta {
    param([Parameter(Mandatory=$true)][string]$Dir, [Parameter(Mandatory=$true)]$Meta)
    ($Meta | ConvertTo-Json -Depth 5) | Set-Content -Encoding utf8 (Join-Path $Dir "meta.json")
}

function Write-LinesFile {
    # Always creates the file, even when the command returned nothing (Set-Content would not).
    param([string]$Path, $Lines)
    if ($null -eq $Lines) { $Lines = @() }
    [System.IO.File]::WriteAllLines($Path, [string[]]@($Lines), (New-Object System.Text.UTF8Encoding($false)))
}

function ConvertTo-Base64 { param([string]$Text) return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) }

function Get-PodIp { param([string]$Namespace, [string]$Pod) return ((kubectl get pod $Pod -n $Namespace -o jsonpath='{.status.podIP}' 2>$null) -join "").Trim() }

function Test-TrialDone {
    param([string]$Campaign, [string]$Trial, [string]$System)
    $d = Join-Path $script:V2Root ("{0}\t{1:D3}" -f $Campaign, [int]$Trial)
    if (-not (Test-Path (Join-Path $d "meta.json"))) { return $false }
    if ($System -eq "mongo" -and -not (Test-Path (Join-Path $d "present.txt"))) { return $false }
    return $true
}

function Ensure-MongoClient {
    # The client pod has no controller: after a Docker/WSL restart it stays in phase Failed (status Unknown). Recreate it.
    param([string]$Namespace, [string]$ClientPod, [string]$Manifest = "cluster\mongo-client.yaml")
    $ph = ((kubectl get pod $ClientPod -n $Namespace -o jsonpath='{.status.phase}' 2>$null) -join "")
    $rd = ((kubectl get pod $ClientPod -n $Namespace -o jsonpath='{.status.containerStatuses[0].ready}' 2>$null) -join "")
    if ($ph -eq "Running" -and $rd -eq "true") { return }
    Write-Warning "$ClientPod is not ready (phase=$ph); recreating it from $Manifest"
    kubectl delete pod $ClientPod -n $Namespace --force --grace-period=0 2>$null | Out-Null
    kubectl apply -f $Manifest | Out-Null
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 3
        $rd = ((kubectl get pod $ClientPod -n $Namespace -o jsonpath='{.status.containerStatuses[0].ready}' 2>$null) -join "")
        if ($rd -eq "true") { return }
    }
    throw "$ClientPod could not be recreated"
}

function Get-ClockOffsetMs {
    # Offset (container clock minus host clock) in ms. After a host sleep, the WSL/Docker VM clock can drift; engine log
    # timestamps then no longer match the host timestamps used for t_partition, t_heal...
    param([string]$Namespace, [string]$Pod, [string]$Container = "")
    $kargs = @("exec", $Pod, "-n", $Namespace)
    if ($Container) { $kargs += @("-c", $Container) }
    $kargs += @("--", "date", "+%s%3N")
    $a = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    $r = (& kubectl @kargs 2>$null) -join ""
    $b = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    if ($r -notmatch "^\d{13}$") { throw "cannot read the container clock" }
    return [int64]$r - [int64](($a + $b) / 2)
}

function Get-RestartCounts {
    param([string]$Namespace, [string[]]$Pods)
    $o = [ordered]@{}
    foreach ($p in $Pods) {
        $v = kubectl get pod $p -n $Namespace -o jsonpath='{.status.containerStatuses[*].restartCount}' 2>$null
        $o[$p] = (($v -join " ") -replace "\s+", ",")
    }
    return $o
}

function Save-PodLogs {
    param([string]$Dir, [string]$Namespace, [string[]]$Pods, [int64]$SinceMs, [string]$Container = "")
    $since = [DateTimeOffset]::FromUnixTimeMilliseconds($SinceMs).UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
    foreach ($p in $Pods) {
        $kargs = @("logs", $p, "-n", $Namespace, "--since-time=$since")
        if ($Container) { $kargs += @("-c", $Container) }
        $stdout = & kubectl @kargs 2>$null
        $out = $stdout; $src = "kubectl logs"
        if ($Container -eq "pxc") {
            # PXC: the engine (Galera) log is the file mysqld-error.log inside the pod; container stdout only has entrypoint messages
            $f = kubectl exec $p -n $Namespace -c pxc -- sh -c "tail -n 6000 /var/lib/mysql/mysqld-error.log" 2>$null
            if (@($f).Count -ge 5) { $out = $f; $src = "mysqld-error.log (tail 6000)" }
            Write-LinesFile -Path (Join-Path $Dir "stdout_$p.txt") -Lines $stdout
        }
        Write-LinesFile -Path (Join-Path $Dir "log_$p.txt") -Lines $out
        Write-LinesFile -Path (Join-Path $Dir "log_source_$p.txt") -Lines @($src)
    }
}

# ---------------------------------------------------------------------------------------------
# Partition rules applied in ONE docker exec (the PID is resolved beforehand, outside the timed section)
# ---------------------------------------------------------------------------------------------
function New-RuleCommand {
    param($Info, [string[]]$TargetIps, [ValidateSet("A","D")][string]$Op)
    $parts = @()
    foreach ($ip in $TargetIps) {
        $parts += "nsenter -t $($Info.Pid) -n iptables -$Op OUTPUT -d $ip -j DROP"
        $parts += "nsenter -t $($Info.Pid) -n iptables -$Op INPUT -s $ip -j DROP"
    }
    return ($parts -join " && ")
}
function Invoke-RuleCommand { param($Info, [string]$Cmd) docker exec $Info.Node sh -c $Cmd | Out-Null }

# ---------------------------------------------------------------------------------------------
# PXC
# ---------------------------------------------------------------------------------------------
function Initialize-PxcV2Schema {
    param([Parameter(Mandatory=$true)][string]$Namespace, [Parameter(Mandatory=$true)][string]$Pod, [Parameter(Mandatory=$true)][string]$XtrabackupPass)
    $sql = "CREATE DATABASE IF NOT EXISTS rpo_test_pxc; CREATE TABLE IF NOT EXISTS rpo_test_pxc.writes_v2 (seq BIGINT NOT NULL PRIMARY KEY, trial INT NOT NULL, node VARCHAR(80) NOT NULL, ts TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)) ENGINE=InnoDB;"
    kubectl exec $Pod -n $Namespace -c pxc -- mysql -uxtrabackup -p"$XtrabackupPass" -e $sql
}

function Wait-PxcHealthy {
    # All pods Synced with cluster size 3, three consecutive readings. If UptimePod is given, its pxc container must also
    # have been running for at least MinUptimeSeconds: the liveness probe has initialDelaySeconds=300, so a trial that
    # starts earlier would run without the probe being active.
    param([string]$Namespace, [string[]]$Pods, [string]$Pass, [int]$MaxWaitSeconds = 900, [string]$UptimePod = "", [int]$MinUptimeSeconds = 0)
    $ok = 0; $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $MaxWaitSeconds) {
        $good = $true
        foreach ($p in $Pods) {
            $raw = kubectl exec $p -n $Namespace -c pxc -- mysql -uxtrabackup -p"$Pass" --connect-timeout=3 -N -e "SHOW STATUS WHERE Variable_name IN ('wsrep_local_state_comment','wsrep_cluster_size');" 2>$null
            $txt = ($raw -join " ")
            if (-not ($txt -match "Synced" -and $txt -match "wsrep_cluster_size\s+3")) { $good = $false; break }
        }
        if ($good -and $UptimePod) {
            $st = (kubectl get pod $UptimePod -n $Namespace -o "jsonpath={.status.containerStatuses[?(@.name=='pxc')].state.running.startedAt}" 2>$null) -join ""
            if (-not $st) { $good = $false }
            else {
                $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($st)).TotalSeconds
                if ($age -lt $MinUptimeSeconds) { $good = $false }
            }
        }
        if ($good) { $ok++ } else { $ok = 0 }
        if ($ok -ge 3) { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Invoke-PxcTrialV2 {
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$IsolatedPod,
        [Parameter(Mandatory=$true)][string]$WitnessPod,
        [Parameter(Mandatory=$true)][string[]]$AllPods,
        [string[]]$TargetIps = @(),
        [Parameter(Mandatory=$true)][string]$XtrabackupPass,
        [Parameter(Mandatory=$true)][int]$Trial,
        [string]$Campaign = "pxc_partition_v2",
        [int]$BaselineSeconds = 10, [int]$HoldSeconds = 20,
        [int]$MaxRejoinWaitSeconds = 300, [int]$AfterRejoinSeconds = 10
    )
    $dir = New-TrialDir -Campaign $Campaign -Trial $Trial
    if (-not (Wait-PxcHealthy -Namespace $Namespace -Pods $AllPods -Pass $XtrabackupPass -UptimePod $IsolatedPod -MinUptimeSeconds 310)) { throw "PXC cluster not healthy at trial start (Synced, size 3, isolated pod running for at least 310 s)" }
    $tStart = Get-NowMs
    # pod IPs can change after a Docker/WSL restart: always resolved at trial start (the parameter is ignored)
    $TargetIps = @($AllPods | Where-Object { $_ -ne $IsolatedPod } | ForEach-Object { Get-PodIp -Namespace $Namespace -Pod $_ })
    if ($TargetIps.Count -ne 2 -or @($TargetIps | Where-Object { -not $_ }).Count -gt 0) { throw "cannot resolve the IPs of the other PXC pods" }
    $clockOffset = Get-ClockOffsetMs -Namespace $Namespace -Pod $IsolatedPod -Container "pxc"
    if ([Math]::Abs($clockOffset) -gt 1000) { throw "clock offset between host and container is $clockOffset ms (after a sleep?): trial not run" }
    $rcBefore = Get-RestartCounts -Namespace $Namespace -Pods $AllPods
    $info = Get-PodNetnsInfo -Namespace $Namespace -PodName $IsolatedPod       # slow step, done before the timed section
    $addCmd = New-RuleCommand -Info $info -TargetIps $TargetIps -Op "A"
    $delCmd = New-RuleCommand -Info $info -TargetIps $TargetIps -Op "D"
    $stopPoll = Join-Path $dir "stop_poll.flag"
    Remove-Item $stopPoll -ErrorAction SilentlyContinue

    $writerSh = @'
rm -f /tmp/stop___TRIAL__ /tmp/writer___TRIAL__.log
i=0
while [ ! -f /tmp/stop___TRIAL__ ] && [ $i -lt 5000 ]; do
  i=$((i+1)); seq=$((__TRIAL__*1000000+i))
  s=$(date +%s%3N)
  out=$(timeout 4 mysql -uxtrabackup -p'__PASS__' -N -e "INSERT INTO rpo_test_pxc.writes_v2 (seq,trial,node) VALUES ($seq,__TRIAL__,'__NODE__');" 2>&1)
  rc=$?
  e=$(date +%s%3N)
  msg=$(echo "$out" | grep -v 'Using a password' | tr -d ',\r\n' | cut -c1-70)
  echo "$s,$e,$seq,$rc,$msg" >> /tmp/writer___TRIAL__.log
  sleep 0.2
done
'@
    $writerSh = $writerSh.Replace("__TRIAL__", "$Trial").Replace("__PASS__", $XtrabackupPass).Replace("__NODE__", $IsolatedPod)
    $writerB64 = ConvertTo-Base64 $writerSh

    $writerJob = $null; $pollJob = $null; $ruleApplied = $false
    $tPartition = 0; $tIsolated = 0; $tHealStart = 0; $tHeal = 0
    try {
        $pollJob = Start-Job -ScriptBlock {
            param($ns, $pods, $pass, $file, $stop)
            while (-not (Test-Path $stop)) {
                foreach ($p in $pods) {
                    $ts = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
                    $raw = kubectl exec $p -n $ns -c pxc -- mysql -uxtrabackup -p"$pass" --connect-timeout=3 -N -e "SHOW STATUS WHERE Variable_name IN ('wsrep_local_state_comment','wsrep_cluster_size','wsrep_ready','wsrep_cluster_status');" 2>$null
                    $txt = (($raw -join " ") -replace "\s+", " ")
                    Add-Content -Path $file -Value "$ts,$p,$txt"
                }
                Start-Sleep -Milliseconds 300
            }
        } -ArgumentList $Namespace, @($IsolatedPod, $WitnessPod), $XtrabackupPass, (Join-Path $dir "status_poll.csv"), $stopPoll

        $writerJob = Start-Job -ScriptBlock {
            param($ns, $pod, $b64)
            kubectl exec $pod -n $ns -c pxc -- sh -c "echo $b64 | base64 -d | sh"
        } -ArgumentList $Namespace, $IsolatedPod, $writerB64

        # writer pre-check: at least one acknowledged write before the partition
        $t0 = Get-Date; $writerOk = $false
        while (((Get-Date) - $t0).TotalSeconds -lt 20 -and -not $writerOk) {
            Start-Sleep -Seconds 2
            $n = kubectl exec $IsolatedPod -n $Namespace -c pxc -- sh -c "grep -c '^[0-9]*,[0-9]*,[0-9]*,0,' /tmp/writer_$Trial.log 2>/dev/null" 2>$null
            if ([int](($n -join "").Trim() -replace "[^0-9]", "0") -gt 0) { $writerOk = $true }
        }
        if (-not $writerOk) { throw "PXC writer is not producing acknowledged writes" }
        $left = $BaselineSeconds - [int]((Get-Date) - $t0).TotalSeconds
        if ($left -gt 0) { Start-Sleep -Seconds $left }

        $tPartition = Get-NowMs
        $ruleApplied = $true
        Invoke-RuleCommand -Info $info -Cmd $addCmd
        $tIsolated = Get-NowMs
        Start-Sleep -Seconds $HoldSeconds
        $tHealStart = Get-NowMs
        Invoke-RuleCommand -Info $info -Cmd $delCmd
        $ruleApplied = $false
        $tHeal = Get-NowMs

        $elapsed = 0
        while ($elapsed -lt $MaxRejoinWaitSeconds) {
            $raw = kubectl exec $IsolatedPod -n $Namespace -c pxc -- mysql -uxtrabackup -p"$XtrabackupPass" --connect-timeout=3 -N -e "SHOW STATUS WHERE Variable_name IN ('wsrep_local_state_comment','wsrep_cluster_size');" 2>$null
            $txt = ($raw -join " ")
            if ($txt -match "Synced" -and $txt -match "wsrep_cluster_size\s+3") { break }
            Start-Sleep -Seconds 2; $elapsed += 2
        }
        Start-Sleep -Seconds $AfterRejoinSeconds
    }
    finally {
        if ($ruleApplied) { try { Invoke-RuleCommand -Info $info -Cmd $delCmd } catch { Write-Warning "rule removal failed: $($_.Exception.Message)" } }
        kubectl exec $IsolatedPod -n $Namespace -c pxc -- touch "/tmp/stop_$Trial" 2>$null | Out-Null
        Start-Sleep -Seconds 2
        New-Item -ItemType File -Path $stopPoll -Force | Out-Null
        if ($writerJob) { Wait-Job $writerJob -Timeout 20 | Out-Null; Stop-Job $writerJob -ErrorAction SilentlyContinue; Remove-Job $writerJob -Force -ErrorAction SilentlyContinue }
        if ($pollJob)   { Wait-Job $pollJob -Timeout 15 | Out-Null;   Stop-Job $pollJob -ErrorAction SilentlyContinue;   Remove-Job $pollJob -Force -ErrorAction SilentlyContinue }
    }

    Write-LinesFile -Path (Join-Path $dir "writer.log") -Lines (kubectl exec $IsolatedPod -n $Namespace -c pxc -- cat "/tmp/writer_$Trial.log" 2>$null)
    Write-LinesFile -Path (Join-Path $dir "present.txt") -Lines (kubectl exec $WitnessPod -n $Namespace -c pxc -- mysql -uxtrabackup -p"$XtrabackupPass" -N -e "SELECT seq FROM rpo_test_pxc.writes_v2 WHERE trial=$Trial ORDER BY seq;" 2>$null)
    Save-PodLogs -Dir $dir -Namespace $Namespace -Pods $AllPods -SinceMs ($tStart - 30000) -Container "pxc"
    $rcAfter = Get-RestartCounts -Namespace $Namespace -Pods $AllPods
    Save-Meta -Dir $dir -Meta ([ordered]@{
        system = "pxc"; campaign = $Campaign; trial = $Trial; t_start_ms = $tStart
        t_partition_ms = $tPartition; t_isolated_ms = $tIsolated; t_heal_start_ms = $tHealStart; t_heal_ms = $tHeal
        hold_s = $HoldSeconds; isolated_pod = $IsolatedPod; witness_pod = $WitnessPod; pods = $AllPods; target_ips = $TargetIps
        restarts_before = $rcBefore; restarts_after = $rcAfter; clock_offset_ms = $clockOffset
    })
    Write-Host ("PXC trial {0} (hold {1} s) saved in {2}" -f $Trial, $HoldSeconds, $dir) -ForegroundColor Green
}

function Invoke-PxcInterleavedV2 {
    <# Randomised, interleaved schedule written to schedule_pxc_v2.csv BEFORE the first run.
       Example: Invoke-PxcInterleavedV2 -N20 30 -N30 10 -Seed 2026 -StartTrial 1 -Namespace rpo-ycsb ... #>
    param(
        [int]$N20 = 30, [int]$N30 = 10, [int]$Seed = 2026, [int]$StartTrial = 1,
        [Parameter(Mandatory=$true)][string]$Namespace, [Parameter(Mandatory=$true)][string]$IsolatedPod,
        [Parameter(Mandatory=$true)][string]$WitnessPod, [Parameter(Mandatory=$true)][string[]]$AllPods,
        [string[]]$TargetIps = @(), [Parameter(Mandatory=$true)][string]$XtrabackupPass,
        [int]$SettleSeconds = 30, [switch]$ScheduleOnly
    )
    $list = @(); 1..$N20 | ForEach-Object { $list += 20 }; 1..$N30 | ForEach-Object { $list += 30 }
    $rng = New-Object System.Random($Seed)
    $order = $list | Sort-Object { $rng.Next() }
    $sched = for ($i = 0; $i -lt $order.Count; $i++) { [PSCustomObject]@{ trial = $StartTrial + $i; hold_s = $order[$i] } }
    $schedFile = "schedule_pxc_v2.csv"
    if (-not (Test-Path $schedFile)) { $sched | Export-Csv -NoTypeInformation -Encoding utf8 $schedFile }
    if ($ScheduleOnly) { Write-Host "Schedule written to $schedFile (no trial run). Commit it, then run again without -ScheduleOnly." -ForegroundColor Yellow; return }
    foreach ($row in (Import-Csv $schedFile)) {
        $camp = "pxc_hold{0}_v2" -f $row.hold_s
        if (Test-TrialDone -Campaign $camp -Trial $row.trial -System "pxc") { Write-Host ("Trial {0}: already done, skipped" -f $row.trial); continue }
        try {
            Invoke-PxcTrialV2 -Namespace $Namespace -IsolatedPod $IsolatedPod -WitnessPod $WitnessPod -AllPods $AllPods `
                -TargetIps $TargetIps -XtrabackupPass $XtrabackupPass -Trial ([int]$row.trial) -Campaign $camp -HoldSeconds ([int]$row.hold_s)
        } catch {
            Write-Warning "Trial $($row.trial) failed: $($_.Exception.Message)"
            "failed: $($_.Exception.Message)" | Set-Content (Join-Path (New-TrialDir -Campaign $camp -Trial ([int]$row.trial)) "FAILED.txt")
        }
        foreach ($pod in $AllPods) { Clear-AllPartitionRules -Namespace $Namespace -PodName $pod -ErrorAction SilentlyContinue | Out-Null }
        Start-Sleep -Seconds $SettleSeconds
    }
}

# ---------------------------------------------------------------------------------------------
# MongoDB
# ---------------------------------------------------------------------------------------------
function Get-MongoPrimaryHost {
    param([string]$Namespace, [string]$ClientPod, [string[]]$MemberHosts, [int]$Retries = 20, [int]$SleepSeconds = 3)
    for ($k = 0; $k -lt $Retries; $k++) {
        foreach ($h in $MemberHosts) {
            $r = kubectl exec $ClientPod -n $Namespace -- mongosh --host $h --quiet --eval "(rs.status().members.find(m => m.stateStr === 'PRIMARY') || {name: ''}).name" 2>$null
            $name = (($r -join "").Trim()).Trim([char]39).Trim([char]34).Trim()
            if ($name -and ($MemberHosts -contains $name)) { return $name }
        }
        Start-Sleep -Seconds $SleepSeconds
    }
    return $null
}

function Invoke-MongoTrialV2 {
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$ClientPod,
        [Parameter(Mandatory=$true)][string[]]$MemberHosts,
        [Parameter(Mandatory=$true)][string[]]$MemberPods,
        [string[]]$MemberIps = @(),
        [Parameter(Mandatory=$true)][ValidateSet("w1","wmajority")][string]$WriteConcern,
        [Parameter(Mandatory=$true)][int]$Trial,
        [string]$Campaign = "",
        [int]$BaselineSeconds = 10, [int]$HoldSeconds = 25, [int]$PostHealSeconds = 45
    )
    if (-not $Campaign) { $Campaign = "mongo_{0}_v2" -f $WriteConcern }
    $dir = New-TrialDir -Campaign $Campaign -Trial $Trial
    Ensure-MongoClient -Namespace $Namespace -ClientPod $ClientPod
    Wait-ForStableReplicaSet -Namespace $Namespace -ClientPod $ClientPod -AnyMemberFqdn $MemberHosts[0] | Out-Null
    $tStart = Get-NowMs
    $MemberIps = @($MemberPods | ForEach-Object { Get-PodIp -Namespace $Namespace -Pod $_ })      # IPs can change: resolved per trial
    if (@($MemberIps | Where-Object { -not $_ }).Count -gt 0) { throw "cannot resolve the IPs of the MongoDB pods" }
    $clockOffset = Get-ClockOffsetMs -Namespace $Namespace -Pod $ClientPod
    if ([Math]::Abs($clockOffset) -gt 1000) { throw "clock offset between host and container is $clockOffset ms (after a sleep?): trial not run" }
    $rcBefore = Get-RestartCounts -Namespace $Namespace -Pods $MemberPods

    $pHost = Get-MongoPrimaryHost -Namespace $Namespace -ClientPod $ClientPod -MemberHosts $MemberHosts
    if (-not $pHost) { throw "no primary found" }
    $pIdx = [array]::IndexOf($MemberHosts, $pHost)
    $isolatedPod = $MemberPods[$pIdx]
    $targetIps = @(); for ($i = 0; $i -lt $MemberIps.Count; $i++) { if ($i -ne $pIdx) { $targetIps += $MemberIps[$i] } }
    $info = Get-PodNetnsInfo -Namespace $Namespace -PodName $isolatedPod
    $addCmd = New-RuleCommand -Info $info -TargetIps $targetIps -Op "A"
    $delCmd = New-RuleCommand -Info $info -TargetIps $targetIps -Op "D"

    $wc = if ($WriteConcern -eq "w1") { "{w: 1}" } else { "{w: 'majority', wtimeout: 2000}" }
    $durationMs = ($BaselineSeconds + $HoldSeconds + $PostHealSeconds + 10) * 1000
    $js = @'
const uri = "mongodb://__HOST__/?directConnection=true&retryWrites=false&serverSelectionTimeoutMS=3000&socketTimeoutMS=6000&connectTimeoutMS=3000";
const trial = __TRIAL__;
const wc = __WC__;
const endAt = Date.now() + __DURATION__;
let col = null, i = 0, lastConnErr = "";
function connect() {
  try { col = new Mongo(uri).getDB("rpo_test").getCollection("writes_v2"); lastConnErr = ""; }
  catch (e) { col = null; lastConnErr = "CONNECT:" + String(e.name || "") + ":" + String(e.message || "").replace(/[,\r\n]/g, " ").slice(0, 60); }
}
connect();
while (Date.now() < endAt) {
  i++; const seq = trial * 1000000 + i; const s = Date.now(); let st = "OK";
  try {
    if (!col) connect();
    if (!col) { st = "ERR:" + lastConnErr; }
    else { col.insertOne({_id: seq, trial: trial, t: s}, {writeConcern: wc}); }
  } catch (e) {
    st = "ERR:" + String(e.codeName || e.name || "unknown") + ":" + String(e.code || "") + ":" + String(e.message || "").replace(/[,\r\n]/g, " ").slice(0, 40);
    if (!(e.codeName === "WriteConcernFailed")) { col = null; }
  }
  print(s + "," + Date.now() + "," + seq + "," + st);
  sleep(200);
}
'@
    $js = $js.Replace("__HOST__", $pHost).Replace("__TRIAL__", "$Trial").Replace("__WC__", $wc).Replace("__DURATION__", "$durationMs")
    $jsB64 = ConvertTo-Base64 $js

    $writerJob = $null; $ruleApplied = $false
    $tPartition = 0; $tIsolated = 0; $tHealStart = 0; $tHeal = 0
    try {
        $writerJob = Start-Job -ScriptBlock {
            param($ns, $pod, $b64, $trial)
            kubectl exec $pod -n $ns -- sh -c "echo $b64 | base64 -d > /tmp/w_$trial.js && mongosh --nodb --quiet /tmp/w_$trial.js"
        } -ArgumentList $Namespace, $ClientPod, $jsB64, $Trial

        # writer pre-check: at least one acknowledged write before the partition
        $t0 = Get-Date; $writerOk = $false; $o = @()
        while (((Get-Date) - $t0).TotalSeconds -lt 20 -and -not $writerOk) {
            Start-Sleep -Seconds 1
            $o = @(Receive-Job $writerJob -Keep -ErrorAction SilentlyContinue)
            if (@($o | Where-Object { $_ -match ",OK\s*$" }).Count -gt 0) { $writerOk = $true }
        }
        if (-not $writerOk) { throw ("MongoDB writer is not producing acknowledged writes: " + (($o | Select-Object -Last 2) -join " | ")) }
        $left = $BaselineSeconds - [int]((Get-Date) - $t0).TotalSeconds
        if ($left -gt 0) { Start-Sleep -Seconds $left }

        $tPartition = Get-NowMs
        $ruleApplied = $true
        Invoke-RuleCommand -Info $info -Cmd $addCmd
        $tIsolated = Get-NowMs
        Start-Sleep -Seconds $HoldSeconds
        $tHealStart = Get-NowMs
        Invoke-RuleCommand -Info $info -Cmd $delCmd
        $ruleApplied = $false
        $tHeal = Get-NowMs
        Wait-Job $writerJob -Timeout ($PostHealSeconds + 40) | Out-Null
    }
    finally {
        if ($ruleApplied) { try { Invoke-RuleCommand -Info $info -Cmd $delCmd } catch { Write-Warning "rule removal failed: $($_.Exception.Message)" } }
        if ($writerJob) {
            Write-LinesFile -Path (Join-Path $dir "writer.log") -Lines @(Receive-Job $writerJob -Keep -ErrorAction SilentlyContinue)
            Stop-Job $writerJob -ErrorAction SilentlyContinue; Remove-Job $writerJob -Force -ErrorAction SilentlyContinue
        }
    }

    Save-PodLogs -Dir $dir -Namespace $Namespace -Pods $MemberPods -SinceMs ($tStart - 30000)
    $metaObj = [ordered]@{
        system = "mongo"; campaign = $Campaign; trial = $Trial; write_concern = $WriteConcern; t_start_ms = $tStart
        t_partition_ms = $tPartition; t_isolated_ms = $tIsolated; t_heal_start_ms = $tHealStart; t_heal_ms = $tHeal
        hold_s = $HoldSeconds; isolated_pod = $isolatedPod; primary_host = $pHost; pods = $MemberPods; target_ips = $targetIps
        restarts_before = $rcBefore; restarts_after = (Get-RestartCounts -Namespace $Namespace -Pods $MemberPods); clock_offset_ms = $clockOffset
    }
    Save-Meta -Dir $dir -Meta $metaObj

    Wait-ForStableReplicaSet -Namespace $Namespace -ClientPod $ClientPod -AnyMemberFqdn $MemberHosts[0] -MaxWaitSeconds 90 | Out-Null
    $finalHost = Get-MongoPrimaryHost -Namespace $Namespace -ClientPod $ClientPod -MemberHosts $MemberHosts
    if (-not $finalHost) {
        "no primary found after the trial" | Set-Content (Join-Path $dir "VERIFY_FAILED.txt")
        throw "no primary found after the trial (artefacts saved in $dir)"
    }
    Write-LinesFile -Path (Join-Path $dir "present.txt") -Lines (kubectl exec $ClientPod -n $Namespace -- mongosh --host $finalHost --quiet --eval "db.getSiblingDB('rpo_test').writes_v2.find({trial:$Trial},{_id:1}).sort({_id:1}).forEach(d => print(d._id))" 2>$null)
    Write-LinesFile -Path (Join-Path $dir "rs_status_end.json") -Lines (kubectl exec $ClientPod -n $Namespace -- mongosh --host $finalHost --quiet --eval "print(JSON.stringify(rs.status().members.map(m=>({n:m.name,s:m.stateStr}))))" 2>$null)
    $metaObj["final_primary_host"] = $finalHost
    Save-Meta -Dir $dir -Meta $metaObj
    Write-Host ("Mongo trial {0} ({1}) saved in {2}" -f $Trial, $WriteConcern, $dir) -ForegroundColor Green
}

function Invoke-MongoInterleavedV2 {
    param(
        [int]$NMajority = 30, [int]$NW1 = 15, [int]$Seed = 2026, [int]$StartTrial = 1,
        [Parameter(Mandatory=$true)][string]$Namespace, [Parameter(Mandatory=$true)][string]$ClientPod,
        [Parameter(Mandatory=$true)][string[]]$MemberHosts, [Parameter(Mandatory=$true)][string[]]$MemberPods,
        [string[]]$MemberIps = @(), [int]$SettleSeconds = 20, [switch]$ScheduleOnly
    )
    $list = @(); 1..$NMajority | ForEach-Object { $list += "wmajority" }; 1..$NW1 | ForEach-Object { $list += "w1" }
    $rng = New-Object System.Random($Seed)
    $order = $list | Sort-Object { $rng.Next() }
    $sched = for ($i = 0; $i -lt $order.Count; $i++) { [PSCustomObject]@{ trial = $StartTrial + $i; write_concern = $order[$i] } }
    $schedFile = "schedule_mongo_v2.csv"
    if (-not (Test-Path $schedFile)) { $sched | Export-Csv -NoTypeInformation -Encoding utf8 $schedFile }
    if ($ScheduleOnly) { Write-Host "Schedule written to $schedFile (no trial run). Commit it, then run again without -ScheduleOnly." -ForegroundColor Yellow; return }
    foreach ($row in (Import-Csv $schedFile)) {
        if (Test-TrialDone -Campaign ("mongo_{0}_v2" -f $row.write_concern) -Trial $row.trial -System "mongo") { Write-Host ("Trial {0}: already done, skipped" -f $row.trial); continue }
        try {
            Invoke-MongoTrialV2 -Namespace $Namespace -ClientPod $ClientPod -MemberHosts $MemberHosts -MemberPods $MemberPods `
                -MemberIps $MemberIps -WriteConcern $row.write_concern -Trial ([int]$row.trial)
        } catch {
            Write-Warning "Trial $($row.trial) failed: $($_.Exception.Message)"
            "failed: $($_.Exception.Message)" | Set-Content (Join-Path (New-TrialDir -Campaign ("mongo_{0}_v2" -f $row.write_concern) -Trial ([int]$row.trial)) "FAILED.txt")
        }
        foreach ($pod in $MemberPods) { Clear-AllPartitionRules -Namespace $Namespace -PodName $pod -ErrorAction SilentlyContinue | Out-Null }
        Start-Sleep -Seconds $SettleSeconds
    }
}
