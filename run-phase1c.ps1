# run-phase1c.ps1 - Phase 1c : coût d'un redémarrage. À lancer depuis le dossier du dépôt.
#   .\run-phase1c.ps1 -Block A1 -SecretName pxc-cluster-pxc-db-secrets -Smoke   # un essai test (ft=3)
#   .\run-phase1c.ps1 -Block A1 -SecretName ...    # 10 essais, ft=3 (configuration actuelle)
#   (patch ft=6, attendre les pods)  .\run-phase1c.ps1 -Block B  -SecretName ...   # 15 essais
#   (patch ft=3, attendre les pods)  .\run-phase1c.ps1 -Block A2 -SecretName ...   # 10 essais
param(
    [Parameter(Mandatory=$true)][ValidateSet("A1","B","A2")][string]$Block,
    [Parameter(Mandatory=$true)][string]$SecretName,
    [string]$Namespace = "rpo-ycsb",
    [string]$Cr = "pxc-cluster-pxc-db",
    [string]$Schedule = "schedule_phase1c.csv",
    [int]$SettleSeconds = 30,
    [switch]$Smoke
)
$ErrorActionPreference = "Continue"
. .\netns-tools-v2.ps1

$all = @(0..2 | ForEach-Object { "$Cr-pxc-$_" }); $isolated = $all[0]; $witness = $all[1]
$expectedFt = if ($Block -eq "B") { 6 } else { 3 }

$b64 = (kubectl get secret $SecretName -n $Namespace -o jsonpath='{.data.xtrabackup}') -join ""
if (-not $b64) { throw "clé 'xtrabackup' introuvable dans le secret $SecretName" }
$pass = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))

# garde-fou : failureThreshold des TROIS pods (pas seulement pxc-0)
foreach ($p in $all) {
    $ft = (kubectl get pod $p -n $Namespace -o "jsonpath={.spec.containers[?(@.name=='pxc')].livenessProbe.failureThreshold}") -join ""
    Write-Host "$p : failureThreshold = $ft (attendu pour le bloc $Block : $expectedFt)"
    if ([int]$ft -ne $expectedFt) { throw "failureThreshold incorrect sur $p : ne rien lancer." }
}

$rows = @(Import-Csv $Schedule | Where-Object { $_.block -eq $Block })
if ($rows.Count -eq 0) { throw "aucune ligne pour le bloc $Block" }
if ($Smoke) { $rows = @($rows[0]); Write-Host "MODE SMOKE : un seul essai (non compté)" -ForegroundColor Yellow }

foreach ($row in $rows) {
    $t = [int]$row.trial
    $camp = "pxc1c_ft{0}_hold{1}_{2}" -f $row.failureThreshold, $row.hold_s, $Block
    if ($Smoke) { $camp = "smoke1c_" + $camp }
    if (Test-TrialDone -Campaign $camp -Trial $t -System "pxc") { Write-Host "Essai $t : déjà fait, ignoré"; continue }
    Write-Host ("=== Essai {0} (bloc {1}, isolation {2} s, failureThreshold {3}) {4}" -f $t, $Block, $row.hold_s, $row.failureThreshold, (Get-Date -Format s)) -ForegroundColor Cyan

    $dir  = New-TrialDir -Campaign $camp -Trial $t
    $stop = Join-Path $dir "stop_probe.flag"; Remove-Item $stop -ErrorAction SilentlyContinue
    $file = Join-Path $dir "hostprobe.log"; Remove-Item $file -ErrorAction SilentlyContinue
    $probe = Start-Job -ScriptBlock {
        param($ns, $pod, $pass, $file, $stop, $trialCol, $base)
        $i = 0
        while (-not (Test-Path $stop)) {
            $i++; $seq = $base + $i
            $s = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
            $out = kubectl exec $pod -n $ns -c pxc -- timeout 4 mysql -uxtrabackup -p"$pass" -N -e "INSERT INTO rpo_test_pxc.writes_v2 (seq,trial,node) VALUES ($seq,$trialCol,'hostprobe');" 2>&1
            $rc = $LASTEXITCODE
            $e = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
            $msg = (($out | Out-String) -replace 'mysql: \[Warning\][^\r\n]*', '' -replace '[,\r\n]+', ' ').Trim()
            if ($msg.Length -gt 70) { $msg = $msg.Substring(0, 70) }
            Add-Content -Path $file -Value "$s,$e,$seq,$rc,$msg"
            Start-Sleep -Milliseconds 500
        }
    } -ArgumentList $Namespace, $isolated, $pass, $file, $stop, ($t + 9000), ($t * 1000000 + 500000)
    try {
        Invoke-PxcTrialV2 -Namespace $Namespace -IsolatedPod $isolated -WitnessPod $witness -AllPods $all `
            -XtrabackupPass $pass -Trial $t -Campaign $camp -HoldSeconds ([int]$row.hold_s) -AfterRejoinSeconds 20
    } catch {
        Write-Warning "Essai $t en échec : $($_.Exception.Message)"
        "failed: $($_.Exception.Message)" | Set-Content (Join-Path $dir "FAILED.txt")
    } finally {
        New-Item -ItemType File -Path $stop -Force | Out-Null
        Wait-Job $probe -Timeout 20 | Out-Null; Stop-Job $probe -ErrorAction SilentlyContinue; Remove-Job $probe -Force -ErrorAction SilentlyContinue
        foreach ($pod in $all) { Clear-AllPartitionRules -Namespace $Namespace -PodName $pod -ErrorAction SilentlyContinue | Out-Null }
    }
    Start-Sleep -Seconds $SettleSeconds
}
Write-Host "Terminé." -ForegroundColor Green
