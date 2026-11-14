# run-phase1b.ps1 - exécute le calendrier schedule_phase1b.csv (Phase 1b, PXC)
# À lancer depuis le dossier du dépôt (celui qui contient netns-tools-v2.ps1).
#   .\run-phase1b.ps1 -Block A -SecretName <secret> -Smoke     # un seul essai pour tester
#   .\run-phase1b.ps1 -Block A -SecretName <secret>            # bloc A complet (reprise automatique)
#   .\run-phase1b.ps1 -Block B -SecretName <secret>            # bloc B (après le patch failureThreshold=6)
param(
    [Parameter(Mandatory=$true)][ValidateSet("A","B")][string]$Block,
    [Parameter(Mandatory=$true)][string]$SecretName,
    [string]$Namespace = "rpo-ycsb",
    [string]$Cr = "pxc-cluster-pxc-db",
    [string]$Schedule = "schedule_phase1b.csv",
    [int]$SettleSeconds = 30,
    [switch]$Smoke
)

$ErrorActionPreference = "Stop"
. .\netns-tools-v2.ps1

$all      = @(0..2 | ForEach-Object { "$Cr-pxc-$_" })
$isolated = $all[0]
$witness  = $all[1]
$expectedFt = if ($Block -eq "A") { 3 } else { 6 }

# 1) mot de passe xtrabackup lu dans le secret (jamais écrit dans un fichier)
$b64  = (kubectl get secret $SecretName -n $Namespace -o jsonpath='{.data.xtrabackup}') -join ""
if (-not $b64) { throw "clé 'xtrabackup' introuvable dans le secret $SecretName (namespace $Namespace)" }
$pass = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))

# 2) garde-fou : le failureThreshold réel de la probe doit correspondre au bloc
$ft = (kubectl get pod $isolated -n $Namespace -o "jsonpath={.spec.containers[?(@.name=='pxc')].livenessProbe.failureThreshold}") -join ""
Write-Host "failureThreshold actuel de la probe liveness du conteneur pxc : $ft (attendu pour le bloc $Block : $expectedFt)"
if ([int]$ft -ne $expectedFt) { throw "failureThreshold = $ft, attendu $expectedFt pour le bloc $Block : ne rien lancer." }

# 3) calendrier du bloc
$rows = @(Import-Csv $Schedule | Where-Object { $_.block -eq $Block })
if ($rows.Count -eq 0) { throw "aucune ligne pour le bloc $Block dans $Schedule" }
if ($Smoke) { $rows = @($rows[0]) ; Write-Host "MODE SMOKE : un seul essai (à ne pas compter dans l'analyse)" -ForegroundColor Yellow }

foreach ($row in $rows) {
    $camp = "pxc1b_hold{0}_ft{1}" -f $row.hold_s, $row.failureThreshold
    if ($Smoke) { $camp = "smoke1b_" + $camp }
    if (Test-TrialDone -Campaign $camp -Trial ([int]$row.trial) -System "pxc") {
        Write-Host ("Essai {0} : déjà fait, ignoré" -f $row.trial); continue
    }
    Write-Host ("=== Essai {0} (bloc {1}, isolation {2} s, failureThreshold {3}) {4}" -f $row.trial, $Block, $row.hold_s, $row.failureThreshold, (Get-Date -Format s)) -ForegroundColor Cyan
    try {
        Invoke-PxcTrialV2 -Namespace $Namespace -IsolatedPod $isolated -WitnessPod $witness -AllPods $all `
            -XtrabackupPass $pass -Trial ([int]$row.trial) -Campaign $camp -HoldSeconds ([int]$row.hold_s)
    } catch {
        Write-Warning "Essai $($row.trial) en échec : $($_.Exception.Message)"
        "failed: $($_.Exception.Message)" | Set-Content (Join-Path (New-TrialDir -Campaign $camp -Trial ([int]$row.trial)) "FAILED.txt")
    }
    foreach ($pod in $all) { Clear-AllPartitionRules -Namespace $Namespace -PodName $pod -ErrorAction SilentlyContinue | Out-Null }
    Start-Sleep -Seconds $SettleSeconds
}
Write-Host "Terminé." -ForegroundColor Green
