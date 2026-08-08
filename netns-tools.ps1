# =====================================================================
# netns-tools.ps1
# Boite a outils pour l'etude FW-Chaos-Network sur cluster kind
# Automatise : pod -> noeud K8s -> containerID -> PID -> nsenter
# Usage : dot-sourcer le fichier avant utilisation
#   . .\netns-tools.ps1
# =====================================================================

function Get-PodNetnsInfo {
    <#
    .SYNOPSIS
    Resout un pod (namespace + nom) vers son noeud kind, son containerID
    et son PID hote, necessaires pour nsenter.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$PodName
    )

    $nodeName = kubectl get pod $PodName -n $Namespace -o jsonpath='{.spec.nodeName}'
    if (-not $nodeName) {
        throw "Impossible de resoudre le noeud pour pod=$PodName ns=$Namespace"
    }

    $rawContainerId = kubectl get pod $PodName -n $Namespace -o jsonpath='{.status.containerStatuses[0].containerID}'
    $containerId = $rawContainerId -replace '^containerd://', ''
    if (-not $containerId) {
        throw "Impossible de resoudre le containerID pour pod=$PodName ns=$Namespace"
    }

    $inspectOutput = docker exec $nodeName crictl inspect $containerId
    # crictl inspect renvoie plusieurs occurrences de "pid" (process du conteneur,
    # puis souvent process 1 du sandbox). On prend systematiquement la premiere.
    $pidLine = ($inspectOutput | Select-String '"pid"\s*:\s*(\d+)' | Select-Object -First 1)
    if (-not $pidLine) {
        throw "Impossible d'extraire le PID pour containerID=$containerId sur noeud=$nodeName"
    }
    $podPid = [int]($pidLine.Matches[0].Groups[1].Value)

    $podIp = kubectl get pod $PodName -n $Namespace -o jsonpath='{.status.podIP}'

    return [PSCustomObject]@{
        Namespace   = $Namespace
        PodName     = $PodName
        Node        = $nodeName
        ContainerId = $containerId
        Pid         = $podPid
        PodIp       = $podIp
    }
}

function Invoke-InPodNetns {
    <#
    .SYNOPSIS
    Execute une commande arbitraire dans le network namespace d'un pod,
    via nsenter depuis le conteneur du noeud kind qui l'heberge.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$PodName,
        [Parameter(Mandatory=$true)][string]$Command
    )

    $info = Get-PodNetnsInfo -Namespace $Namespace -PodName $PodName
    $fullCmd = "nsenter -t $($info.Pid) -n $Command"
    docker exec $($info.Node) sh -c $fullCmd
}

function Test-PodLatency {
    <#
    .SYNOPSIS
    Mesure la latence RTT entre deux pods (baseline ou verification post-injection).
    Exclut automatiquement le premier paquet (artefact ARP / cache froid).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$SourceNamespace,
        [Parameter(Mandatory=$true)][string]$SourcePod,
        [Parameter(Mandatory=$true)][string]$TargetIp,
        [int]$Count = 30
    )

    $countWithWarmup = $Count + 1
    $output = Invoke-InPodNetns -Namespace $SourceNamespace -PodName $SourcePod `
        -Command "ping -c $countWithWarmup -i 0.2 $TargetIp"

    Write-Host $output

    # Parsing basique des temps individuels (hors 1er paquet)
    $times = [regex]::Matches($output, 'time=([\d\.]+)\s*ms') |
        ForEach-Object { [double]$_.Groups[1].Value } |
        Select-Object -Skip 1

    if ($times.Count -eq 0) {
        Write-Warning "Aucune mesure de latence exploitable (paquets perdus ?)"
        return $null
    }

    $stats = $times | Measure-Object -Average -Minimum -Maximum
    return [PSCustomObject]@{
        SourcePod = $SourcePod
        TargetIp  = $TargetIp
        N         = $times.Count
        AvgMs     = [math]::Round($stats.Average, 3)
        MinMs     = [math]::Round($stats.Minimum, 3)
        MaxMs     = [math]::Round($stats.Maximum, 3)
        Samples   = $times
    }
}

function Add-PartitionRule {
    <#
    .SYNOPSIS
    Scenario 1 (partition complete) ou 2 (asymetrique) : bloque tout
    le trafic entre un pod et une IP cible via iptables DROP (INPUT + OUTPUT).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$PodName,
        [Parameter(Mandatory=$true)][string]$TargetIp
    )

    Invoke-InPodNetns -Namespace $Namespace -PodName $PodName `
        -Command "iptables -A OUTPUT -d $TargetIp -j DROP"
    Invoke-InPodNetns -Namespace $Namespace -PodName $PodName `
        -Command "iptables -A INPUT -s $TargetIp -j DROP"

    Write-Host "Partition appliquee : $PodName ($Namespace) <-x-> $TargetIp"
}

function Remove-PartitionRule {
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$PodName,
        [Parameter(Mandatory=$true)][string]$TargetIp
    )

    Invoke-InPodNetns -Namespace $Namespace -PodName $PodName `
        -Command "iptables -D OUTPUT -d $TargetIp -j DROP"
    Invoke-InPodNetns -Namespace $Namespace -PodName $PodName `
        -Command "iptables -D INPUT -s $TargetIp -j DROP"

    Write-Host "Partition retiree : $PodName ($Namespace) <-> $TargetIp"
}

function Add-NetemLatency {
    <#
    .SYNOPSIS
    Scenario 3 (latence/gigue) : applique tc netem sur eth0 du pod.
    Exemple : Add-NetemLatency -Namespace mongodb-pi -PodName mongodb-1 -DelayMs 50 -JitterMs 20
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$PodName,
        [Parameter(Mandatory=$true)][int]$DelayMs,
        [int]$JitterMs = 0,
        [double]$LossPercent = 0
    )

    $netemArgs = "delay ${DelayMs}ms"
    if ($JitterMs -gt 0) { $netemArgs += " ${JitterMs}ms distribution normal" }
    if ($LossPercent -gt 0) { $netemArgs += " loss ${LossPercent}%" }

    Invoke-InPodNetns -Namespace $Namespace -PodName $PodName `
        -Command "tc qdisc add dev eth0 root netem $netemArgs"

    Write-Host "Netem applique sur $PodName : $netemArgs"
}

function Clear-Netem {
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$PodName
    )

    Invoke-InPodNetns -Namespace $Namespace -PodName $PodName `
        -Command "tc qdisc del dev eth0 root netem"

    Write-Host "Netem retire de $PodName"
}

function Measure-FailoverRTO {
    <#
    .SYNOPSIS
    Interroge en boucle un pod MongoDB temoin (hors partition) jusqu'a
    detecter l'apparition d'un nouveau PRIMARY, et chronometre le RTO.
    A lancer APRES avoir applique la partition (Add-PartitionRule).

    .EXAMPLE
    Measure-FailoverRTO -Namespace mongodb-pi -ClientPod mongo-client `
        -MonitorFqdn mongodb-1.mongodb.mongodb-pi.svc.cluster.local `
        -IsolatedFqdn mongodb-0.mongodb.mongodb-pi.svc.cluster.local `
        -LogPath .\rto_mongo0_partition.csv
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$ClientPod,
        [Parameter(Mandatory=$true)][string]$MonitorFqdn,
        [Parameter(Mandatory=$true)][string]$IsolatedFqdn,
        [int]$TimeoutSeconds = 60,
        [int]$PollMs = 500,
        [string]$LogPath = ".\rto_measurement.csv"
    )

    "timestamp,elapsed_s,raw_status" | Out-File $LogPath -Encoding utf8

    $startTime = Get-Date
    $newPrimaryFound = $false
    $result = $null

    Write-Host "Debut du monitoring RTO ($startTime)..." -ForegroundColor Yellow

    while (-not $newPrimaryFound -and ((Get-Date) - $startTime).TotalSeconds -lt $TimeoutSeconds) {
        $now = Get-Date
        $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)

        $result = kubectl exec $ClientPod -n $Namespace -- mongosh --host $MonitorFqdn --quiet --eval `
            "rs.status().members.map(m => m.name + '=' + m.stateStr).join(';')" 2>$null

        "$now,$elapsed,""$result""" | Out-File $LogPath -Append -Encoding utf8
        Write-Host "[$elapsed s] $result"

        # Un nouveau PRIMARY est detecte si l'ancien noeud isole n'est plus PRIMARY
        # et qu'un AUTRE membre l'est devenu.
        if ($result -match 'PRIMARY' -and $result -notmatch "$IsolatedFqdn.*=PRIMARY") {
            $newPrimaryFound = $true
            Write-Host "`n>>> Nouveau PRIMARY detecte apres $elapsed s <<<" -ForegroundColor Green
        }

        Start-Sleep -Milliseconds $PollMs
    }

    if (-not $newPrimaryFound) {
        Write-Warning "Timeout atteint ($TimeoutSeconds s) sans nouvelle election detectee."
    }

    return [PSCustomObject]@{
        RtoSeconds   = if ($newPrimaryFound) { $elapsed } else { $null }
        TimedOut     = -not $newPrimaryFound
        FinalStatus  = $result
        LogPath      = $LogPath
    }
}

function Get-MongoReplicaSetStatus {
    <#
    .SYNOPSIS
    Interroge l'etat actuel du replica set via mongo-client. A appeler
    systematiquement avant toute injection pour connaitre le role reel
    des pods (pas de failback automatique chez MongoDB).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$ClientPod,
        [Parameter(Mandatory=$true)][string]$AnyMemberFqdn
    )

    $raw = kubectl exec $ClientPod -n $Namespace -- mongosh --host $AnyMemberFqdn --quiet --eval `
        "rs.status().members.map(m => m.name + '=' + m.stateStr).join(';')"
    Write-Host $raw
    return $raw
}

function Invoke-PartitionExperiment {
    <#
    .SYNOPSIS
    Scenario 1 (partition complete) : isole un pod (typiquement le primary)
    de N cibles, attend un delai fixe couvrant l'election + stabilisation,
    retire la partition, puis extrait les timestamps precis (ms) depuis les
    logs pour calculer le RTO reel — plus fiable qu'un sondage live.
    Verifie automatiquement le role du pod cible avant d'injecter.

    .EXAMPLE
    Invoke-PartitionExperiment -Namespace mongodb-pi -IsolatedPod mongodb-0 `
        -TargetIps @("10.244.2.3","10.244.1.2") -HoldSeconds 30 `
        -LogWindowMinutes 5 -ClientPod mongo-client `
        -AnyMemberFqdn mongodb-1.mongodb.mongodb-pi.svc.cluster.local
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$IsolatedPod,
        [Parameter(Mandatory=$true)][string[]]$TargetIps,
        [int]$HoldSeconds = 30,
        [int]$LogWindowMinutes = 5,
        [string]$ClientPod,
        [string]$AnyMemberFqdn
    )

    Write-Host "=== Experience partition : isolation de $IsolatedPod ===" -ForegroundColor Cyan

    if ($ClientPod -and $AnyMemberFqdn) {
        Write-Host "Verification du role actuel avant injection..." -ForegroundColor Magenta
        $preStatus = Get-MongoReplicaSetStatus -Namespace $Namespace -ClientPod $ClientPod -AnyMemberFqdn $AnyMemberFqdn
        if ($preStatus -notmatch "$IsolatedPod.*=PRIMARY") {
            Write-Warning "$IsolatedPod n'est PAS le primary actuel ! Experience annulee -- verifiez rs.status() et relancez avec le bon pod."
            return $null
        }
    } else {
        Write-Warning "Aucune verification de role effectuee (ClientPod/AnyMemberFqdn non fournis). Assurez-vous manuellement que $IsolatedPod est bien le primary actuel."
    }

    $t0 = Get-Date
    foreach ($ip in $TargetIps) {
        Add-PartitionRule -Namespace $Namespace -PodName $IsolatedPod -TargetIp $ip
    }
    $t0Applied = Get-Date
    Write-Host "Partition appliquee. T0 = $t0Applied" -ForegroundColor Yellow

    Write-Host "Attente de $HoldSeconds s (couvre election + stabilisation)..."
    Start-Sleep -Seconds $HoldSeconds

    $tHealStart = Get-Date
    foreach ($ip in $TargetIps) {
        Remove-PartitionRule -Namespace $Namespace -PodName $IsolatedPod -TargetIp $ip
    }
    Write-Host "Partition retiree. Debut healing = $tHealStart" -ForegroundColor Yellow

    # Laisser le temps au healing/rollback de se terminer avant de lire les logs
    Start-Sleep -Seconds 10

    Write-Host "`n--- Logs de $IsolatedPod (stepDown, election refusee, rollback) ---" -ForegroundColor Cyan
    $isolatedLogs = kubectl logs $IsolatedPod -n $Namespace --since="${LogWindowMinutes}m" |
        Select-String -Pattern "stepDown|state transition|Not starting an election|ROLLBACK|Transition to"
    $isolatedLogs | ForEach-Object { Write-Host $_ }

    return [PSCustomObject]@{
        T0_PartitionApplied = $t0Applied
        T_HealStart         = $tHealStart
        IsolatedPodLogs     = $isolatedLogs
        Note                = "Comparer les timestamps ci-dessus a T0 pour calculer le RTO exact (stepDown - T0) et le temps de reconciliation (rejoin SECONDARY - T_HealStart)."
    }
}

function Get-LogTimestamp {
    <#
    .SYNOPSIS
    Extrait le premier timestamp "$date" (UTC, precision ms) d'une ligne
    de log JSON MongoDB, sous forme de DateTime .NET comparable a T0.
    #>
    param([Parameter(Mandatory=$true)][string]$LogLine)

    if ($LogLine -match '"\$date":"([\d\-T:\.]+)(?:Z|\+00:00)?"') {
        return [datetime]::Parse($Matches[1], $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
    }
    return $null
}

function Invoke-PartitionCampaign {
    <#
    .SYNOPSIS
    Automatise n essais de partition complete sur un replica set MongoDB,
    en isolant a chaque fois le primary actuel (quel qu'il soit), et calcule
    le RTO precis (election succeeded - T0, tous deux en UTC ms) ainsi que
    l'impact RPO (nb d'entrees rollback) directement depuis les logs.

    .EXAMPLE
    Invoke-PartitionCampaign -Namespace mongodb-pi -ClientPod mongo-client `
        -AllPods @("mongodb-0","mongodb-1","mongodb-2") `
        -ServiceFqdnSuffix "mongodb.mongodb-pi.svc.cluster.local" `
        -Trials 30 -OutputCsv .\campaign_partition_complete_mongo.csv
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$ClientPod,
        [Parameter(Mandatory=$true)][string[]]$AllPods,
        [Parameter(Mandatory=$true)][string]$ServiceFqdnSuffix,
        [int]$Trials = 30,
        [int]$HoldSeconds = 25,
        [int]$HealWaitSeconds = 15,
        [int]$InterTrialPauseSeconds = 8,
        [string]$OutputCsv = ".\campaign_partition_complete.csv"
    )

    $results = @()
    "trial,t0_utc,isolated_pod,new_primary_pod,rto_seconds,rollback_entries" | Out-File $OutputCsv -Encoding utf8

    # Verification/recreation du pod client avant de demarrer (evite un TTL expire en cours de campagne)
    $clientStatus = kubectl get pod $ClientPod -n $Namespace -o jsonpath='{.status.phase}' 2>$null
    if ($clientStatus -ne "Running") {
        Write-Host "Pod client '$ClientPod' absent ou non-Running (phase: $clientStatus) -- recreation..." -ForegroundColor Yellow
        kubectl delete pod $ClientPod -n $Namespace --force --grace-period=0 2>$null | Out-Null
        kubectl run $ClientPod --restart=Never -n $Namespace --image=mongo:7 -- sleep infinity | Out-Null
        do { Start-Sleep -Seconds 2; $clientStatus = kubectl get pod $ClientPod -n $Namespace -o jsonpath='{.status.phase}' 2>$null } while ($clientStatus -ne "Running")
        Write-Host "Pod client pret." -ForegroundColor Green
    }

    for ($i = 1; $i -le $Trials; $i++) {
        Write-Host "`n========== Essai $i / $Trials ==========" -ForegroundColor Cyan

        # Re-verification rapide a chaque essai (defense en profondeur pour campagnes longues)
        $clientStatus = kubectl get pod $ClientPod -n $Namespace -o jsonpath='{.status.phase}' 2>$null
        if ($clientStatus -ne "Running") {
            Write-Warning "Essai $i : pod client non disponible (phase: $clientStatus), recreation en cours..."
            kubectl delete pod $ClientPod -n $Namespace --force --grace-period=0 2>$null | Out-Null
            kubectl run $ClientPod --restart=Never -n $Namespace --image=mongo:7 -- sleep infinity | Out-Null
            do { Start-Sleep -Seconds 2; $clientStatus = kubectl get pod $ClientPod -n $Namespace -o jsonpath='{.status.phase}' 2>$null } while ($clientStatus -ne "Running")
        }

        # 1. IPs a jour + role actuel
        $ipMap = @{}
        foreach ($pod in $AllPods) {
            $info = Get-PodNetnsInfo -Namespace $Namespace -PodName $pod
            $ipMap[$pod] = $info.PodIp
        }
        $anyFqdn = "$($AllPods[0]).$ServiceFqdnSuffix"
        $statusBefore = Get-MongoReplicaSetStatus -Namespace $Namespace -ClientPod $ClientPod -AnyMemberFqdn $anyFqdn

        $primaryPod = $null
        foreach ($pod in $AllPods) {
            if ($statusBefore -match "$pod\.$([regex]::Escape($ServiceFqdnSuffix))[^;]*?=PRIMARY") { $primaryPod = $pod }
        }
        if (-not $primaryPod) {
            Write-Warning "Essai $i : aucun PRIMARY trouve, on saute (verifier l'etat du cluster)."
            continue
        }
        $targetIps = $AllPods | Where-Object { $_ -ne $primaryPod } | ForEach-Object { $ipMap[$_] }
        Write-Host "Primary actuel : $primaryPod -- isolation de : $($targetIps -join ', ')"

        # 2. T0 precis (UTC, ms) puis injection
        $t0 = (Get-Date).ToUniversalTime()
        foreach ($ip in $targetIps) { Add-PartitionRule -Namespace $Namespace -PodName $primaryPod -TargetIp $ip | Out-Null }

        Start-Sleep -Seconds $HoldSeconds

        foreach ($ip in $targetIps) { Remove-PartitionRule -Namespace $Namespace -PodName $primaryPod -TargetIp $ip | Out-Null }
        Start-Sleep -Seconds $HealWaitSeconds

        # 3. Nouveau primary + timestamp d'election exact
        $statusAfter = Get-MongoReplicaSetStatus -Namespace $Namespace -ClientPod $ClientPod -AnyMemberFqdn $anyFqdn
        $newPrimaryPod = $null
        foreach ($pod in $AllPods) {
            if ($pod -ne $primaryPod -and $statusAfter -match "$pod\.$([regex]::Escape($ServiceFqdnSuffix))[^;]*?=PRIMARY") { $newPrimaryPod = $pod }
        }

        $rtoSeconds = $null
        if ($newPrimaryPod) {
            $electionLog = kubectl logs $newPrimaryPod -n $Namespace --since="2m" | Select-String -Pattern "Election succeeded" | Select-Object -Last 1
            if ($electionLog) {
                $tElection = Get-LogTimestamp -LogLine $electionLog.Line
                if ($tElection) { $rtoSeconds = [math]::Round(($tElection - $t0).TotalSeconds, 3) }
            }
        } else {
            Write-Warning "Essai $i : pas de nouveau primary detecte apres $HoldSeconds+$HealWaitSeconds s."
        }

        # 4. Impact RPO : entrees rollback sur l'ancien primary isole
        $rollbackLog = kubectl logs $primaryPod -n $Namespace --since="2m" | Select-String -Pattern "totalEntriesRolledBackIncludingNoops" | Select-Object -Last 1
        $rollbackEntries = 0
        if ($rollbackLog -and $rollbackLog.Line -match '"totalEntriesRolledBackIncludingNoops":(\d+)') {
            $rollbackEntries = [int]$Matches[1]
        }

        $row = [PSCustomObject]@{
            Trial           = $i
            T0_Utc          = $t0.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            IsolatedPod     = $primaryPod
            NewPrimaryPod   = $newPrimaryPod
            RtoSeconds      = $rtoSeconds
            RollbackEntries = $rollbackEntries
        }
        $results += $row
        "$i,$($row.T0_Utc),$primaryPod,$newPrimaryPod,$rtoSeconds,$rollbackEntries" | Out-File $OutputCsv -Append -Encoding utf8

        Write-Host "RTO essai ${i} : $rtoSeconds s -- rollback : $rollbackEntries entree(s)" -ForegroundColor Green

        if ($i -lt $Trials) { Start-Sleep -Seconds $InterTrialPauseSeconds }
    }

    Write-Host "`nCampagne terminee. Resultats dans $OutputCsv" -ForegroundColor Green
    return $results
}

function Invoke-PartitionCampaignWithRPO {
    <#
    .SYNOPSIS
    Campagne complete : isole le primary actuel a chaque essai, avec un
    writer continu en arriere-plan (w:1). Calcule le RTO (logs) et le RPO
    applicatif reel (bsondump automatique du fichier rollback le plus recent).
    Suppose qu'un writer (mongosh --nodb /tmp/writer.js) tourne deja en Job
    PowerShell et continue d'ecrire pendant toute la campagne.

    .EXAMPLE
    Invoke-PartitionCampaignWithRPO -Namespace mongodb-pi -ClientPod mongo-client `
        -AllPods @("mongodb-0","mongodb-1","mongodb-2") `
        -ServiceFqdnSuffix "mongodb.mongodb-pi.svc.cluster.local" `
        -Trials 30 -OutputCsv .\campaign_rpo_mongodb_n30.csv
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$ClientPod,
        [Parameter(Mandatory=$true)][string[]]$AllPods,
        [Parameter(Mandatory=$true)][string]$ServiceFqdnSuffix,
        [int]$Trials = 30,
        [int]$HoldSeconds = 25,
        [int]$HealWaitSeconds = 15,
        [int]$InterTrialPauseSeconds = 10,
        [string]$OutputCsv = ".\campaign_rpo.csv"
    )

    "trial,t0_utc,isolated_pod,new_primary_pod,rto_seconds,rpo_count,rpo_seq_list" | Out-File $OutputCsv -Encoding utf8
    $results = @()

    for ($i = 1; $i -le $Trials; $i++) {
        Write-Host "`n========== Essai RPO $i / $Trials ==========" -ForegroundColor Cyan

        $ipMap = @{}
        foreach ($pod in $AllPods) {
            $info = Get-PodNetnsInfo -Namespace $Namespace -PodName $pod
            $ipMap[$pod] = $info.PodIp
        }
        $anyFqdn = "$($AllPods[0]).$ServiceFqdnSuffix"
        $statusBefore = Get-MongoReplicaSetStatus -Namespace $Namespace -ClientPod $ClientPod -AnyMemberFqdn $anyFqdn

        $primaryPod = $null
        foreach ($pod in $AllPods) {
            if ($statusBefore -match "$pod\.$([regex]::Escape($ServiceFqdnSuffix))[^;]*?=PRIMARY") { $primaryPod = $pod }
        }
        if (-not $primaryPod) {
            Write-Warning "Essai $i : aucun PRIMARY trouve, on saute."
            continue
        }
        $targetIps = $AllPods | Where-Object { $_ -ne $primaryPod } | ForEach-Object { $ipMap[$_] }

        $t0 = (Get-Date).ToUniversalTime()
        foreach ($ip in $targetIps) { Add-PartitionRule -Namespace $Namespace -PodName $primaryPod -TargetIp $ip | Out-Null }
        Start-Sleep -Seconds $HoldSeconds
        foreach ($ip in $targetIps) { Remove-PartitionRule -Namespace $Namespace -PodName $primaryPod -TargetIp $ip | Out-Null }
        Write-Host "Attente de stabilisation du replica set..." -ForegroundColor Yellow
        Wait-ForStableReplicaSet -Namespace $Namespace -ClientPod $ClientPod -AnyMemberFqdn $anyFqdn -MaxWaitSeconds 60 -PollSeconds 3 | Out-Null
        Start-Sleep -Seconds $HealWaitSeconds

        $statusAfter = Get-MongoReplicaSetStatus -Namespace $Namespace -ClientPod $ClientPod -AnyMemberFqdn $anyFqdn
        $newPrimaryPod = $null
        foreach ($pod in $AllPods) {
            if ($pod -ne $primaryPod -and $statusAfter -match "$pod\.$([regex]::Escape($ServiceFqdnSuffix))[^;]*?=PRIMARY") { $newPrimaryPod = $pod }
        }

        $rtoSeconds = $null
        if ($newPrimaryPod) {
            $electionLog = kubectl logs $newPrimaryPod -n $Namespace --since="2m" | Select-String -Pattern "Election succeeded" | Select-Object -Last 1
            if ($electionLog) {
                $tElection = Get-LogTimestamp -LogLine $electionLog.Line
                if ($tElection) { $rtoSeconds = [math]::Round(($tElection - $t0).TotalSeconds, 3) }
            }
        }

        # RPO : dernier fichier rollback cree sur le pod isole
        $latestRollback = kubectl exec $primaryPod -n $Namespace -- sh -c "ls -t /data/db/rollback/*/removed*.bson 2>/dev/null | head -1"
        $rpoCount = 0
        $seqList = ""
        if ($latestRollback) {
            $bsonOutRaw = kubectl exec $primaryPod -n $Namespace --request-timeout=30s -- bsondump $latestRollback.Trim() 2>$null
            $bsonOut = ($bsonOutRaw -join "`n")
            $seqs = [regex]::Matches($bsonOut, '"seq":\{"\$numberInt":"(\d+)"\}') | ForEach-Object { $_.Groups[1].Value }
            $rpoCount = $seqs.Count
            $seqList = ($seqs -join '|')
        }

        $row = [PSCustomObject]@{
            Trial         = $i
            T0_Utc        = $t0.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            IsolatedPod   = $primaryPod
            NewPrimaryPod = $newPrimaryPod
            RtoSeconds    = $rtoSeconds
            RpoCount      = $rpoCount
            RpoSeqList    = $seqList
        }
        $results += $row
        "$i,$($row.T0_Utc),$primaryPod,$newPrimaryPod,$rtoSeconds,$rpoCount,""$seqList""" | Out-File $OutputCsv -Append -Encoding utf8

        Write-Host "RTO : $rtoSeconds s -- RPO : $rpoCount ecriture(s) perdue(s) [$seqList]" -ForegroundColor Green

        if ($i -lt $Trials) { Start-Sleep -Seconds $InterTrialPauseSeconds }
    }

    Write-Host "`nCampagne RPO terminee. Resultats dans $OutputCsv" -ForegroundColor Green
    return $results
}

function Invoke-AsymmetricPartitionExperiment {
    <#
    .SYNOPSIS
    Scenario 2 (degradation asymetrique) : isole un pod cible d'UN SEUL
    autre pod (typiquement secondary isole du primary uniquement, en
    gardant sa vue sur les autres secondaries). Contrairement au scenario 1,
    aucune election n'est attendue si le pod isole n'est pas le primary --
    on observe plutot le comportement de replication/heartbeat du pod isole.

    .EXAMPLE
    Invoke-AsymmetricPartitionExperiment -Namespace mongodb-pi `
        -IsolatedPod mongodb-1 -IsolatedFromIp 10.244.1.9 `
        -HoldSeconds 25 -ClientPod mongo-client `
        -AnyMemberFqdn mongodb-0.mongodb.mongodb-pi.svc.cluster.local
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$IsolatedPod,
        [Parameter(Mandatory=$true)][string]$IsolatedFromIp,
        [int]$HoldSeconds = 25,
        [int]$LogWindowMinutes = 5,
        [string]$ClientPod,
        [string]$AnyMemberFqdn
    )

    Write-Host "=== Experience asymetrique : $IsolatedPod isole de $IsolatedFromIp uniquement ===" -ForegroundColor Cyan

    if ($ClientPod -and $AnyMemberFqdn) {
        Write-Host "Etat avant injection :" -ForegroundColor Magenta
        Get-MongoReplicaSetStatus -Namespace $Namespace -ClientPod $ClientPod -AnyMemberFqdn $AnyMemberFqdn | Out-Null
    }

    $t0 = (Get-Date).ToUniversalTime()
    Add-PartitionRule -Namespace $Namespace -PodName $IsolatedPod -TargetIp $IsolatedFromIp
    Write-Host "Lien coupe. T0 = $t0 (UTC)" -ForegroundColor Yellow

    Start-Sleep -Seconds $HoldSeconds

    Write-Host "`n--- Logs de $IsolatedPod pendant l'isolation (heartbeat, sync, election) ---" -ForegroundColor Cyan
    $duringLogs = kubectl logs $IsolatedPod -n $Namespace --since="${LogWindowMinutes}m" |
        Select-String -Pattern "heartbeat|DOWN|SyncSource|Not starting an election|state transition|Standing for election"
    $duringLogs | ForEach-Object { Write-Host $_ }

    Remove-PartitionRule -Namespace $Namespace -PodName $IsolatedPod -TargetIp $IsolatedFromIp
    Write-Host "`nLien retabli." -ForegroundColor Yellow
    Start-Sleep -Seconds 10

    if ($ClientPod -and $AnyMemberFqdn) {
        Write-Host "Etat apres retablissement :" -ForegroundColor Magenta
        Get-MongoReplicaSetStatus -Namespace $Namespace -ClientPod $ClientPod -AnyMemberFqdn $AnyMemberFqdn | Out-Null
    }

    return [PSCustomObject]@{
        T0             = $t0
        IsolatedPod    = $IsolatedPod
        IsolatedFromIp = $IsolatedFromIp
        DuringLogs     = $duringLogs
    }
}

function Get-ConfirmedPrimary {
    <#
    .SYNOPSIS
    Determine le primary actuel de facon robuste, en interrogeant DEUX pods
    differents et en ne faisant confiance au resultat que s'ils sont d'accord.
    Evite le biais d'interroger un pod fixe qui pourrait avoir une vue locale
    perimee (ex: recemment isole dans un essai precedent).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$ClientPod,
        [Parameter(Mandatory=$true)][string[]]$AllPods,
        [Parameter(Mandatory=$true)][string]$ServiceFqdnSuffix
    )

    $votes = @{}
    foreach ($askVia in $AllPods) {
        $statusRaw = kubectl exec $ClientPod -n $Namespace -- mongosh --host "$askVia.$ServiceFqdnSuffix" --quiet --eval `
            "rs.status().members.map(m => m.name + '=' + m.stateStr).join(';')" 2>$null
        $status = ($statusRaw -join "`n")
        foreach ($pod in $AllPods) {
            if ($status -match "$pod\.$([regex]::Escape($ServiceFqdnSuffix))[^;]*?=PRIMARY") {
                $votes[$pod] = ($votes[$pod] + 1)
            }
        }
    }
    $agreed = $votes.GetEnumerator() | Where-Object { $_.Value -ge 2 } | Select-Object -First 1
    if ($agreed) { return $agreed.Key }

    Write-Warning "Get-ConfirmedPrimary : pas d'accord entre les temoins interroges (votes: $($votes | Out-String))"
    return $null
}

function Invoke-AsymmetricCampaign {
    <#
    .SYNOPSIS
    Mini-campagne scenario 2 : alterne entre les deux configurations
    (A: primary isole d'1 secondary : garde la majorite ; B: secondary
    isole du primary : garde l'autre secondary), et verifie a chaque essai
    que le primary ne change pas (stabilite) + capture le replLag pendant
    l'isolement (chainage actif ou non).

    .EXAMPLE
    Invoke-AsymmetricCampaign -Namespace mongodb-pi -ClientPod mongo-client `
        -AllPods @("mongodb-0","mongodb-1","mongodb-2") `
        -ServiceFqdnSuffix "mongodb.mongodb-pi.svc.cluster.local" `
        -Trials 12 -OutputCsv .\campaign_scenario2_mongodb_n12.csv
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$ClientPod,
        [Parameter(Mandatory=$true)][string[]]$AllPods,
        [Parameter(Mandatory=$true)][string]$ServiceFqdnSuffix,
        [int]$Trials = 12,
        [int]$HoldSeconds = 25,
        [int]$InterTrialPauseSeconds = 8,
        [string]$OutputCsv = ".\campaign_scenario2.csv"
    )

    "trial,config,isolated_pod,target_pod,witness_pod,primary_before,primary_during,primary_stable,replLag_during,anomaly" | Out-File $OutputCsv -Encoding utf8
    $results = @()

    for ($i = 1; $i -le $Trials; $i++) {
        Write-Host "`n========== Essai scenario 2 -- $i / $Trials ==========" -ForegroundColor Cyan

        $ipMap = @{}
        foreach ($pod in $AllPods) {
            $info = Get-PodNetnsInfo -Namespace $Namespace -PodName $pod
            $ipMap[$pod] = $info.PodIp
        }

        $primaryPod = Get-ConfirmedPrimary -Namespace $Namespace -ClientPod $ClientPod -AllPods $AllPods -ServiceFqdnSuffix $ServiceFqdnSuffix
        if (-not $primaryPod) { Write-Warning "Essai $i : primary non confirme, on saute."; continue }
        $secondaries = $AllPods | Where-Object { $_ -ne $primaryPod }

        # Alterne config A (isoler primary d'1 secondary) / config B (isoler 1 secondary du primary)
        $configType = if ($i % 2 -eq 1) { "A_primary_from_one_secondary" } else { "B_secondary_from_primary" }

        if ($configType -eq "A_primary_from_one_secondary") {
            $isolatedPod = $primaryPod
            $targetPod = $secondaries | Get-Random
        } else {
            $isolatedPod = $secondaries | Get-Random
            $targetPod = $primaryPod
        }
        $targetIp = $ipMap[$targetPod]
        $witnessPod = $AllPods | Where-Object { $_ -ne $isolatedPod -and $_ -ne $targetPod } | Select-Object -First 1
        $witnessFqdn = "$witnessPod.$ServiceFqdnSuffix"

        Write-Host "Config $configType : isolation de $isolatedPod <-x-> $targetPod (temoin : $witnessPod)"

        Add-PartitionRule -Namespace $Namespace -PodName $isolatedPod -TargetIp $targetIp | Out-Null
        $t0 = (Get-Date).ToUniversalTime()

        Start-Sleep -Seconds ([math]::Round($HoldSeconds / 2))
        $lagRaw = kubectl exec $ClientPod -n $Namespace -- mongosh --host "$isolatedPod.$ServiceFqdnSuffix" --quiet --eval `
            "rs.printSecondaryReplicationInfo()" 2>$null
        $lagJoined = ($lagRaw -join "`n")
        $replLag = "N/A"
        if ($lagJoined -match "replLag:\s*'([^']+)'") { $replLag = $Matches[1] }
        Start-Sleep -Seconds ([math]::Ceiling($HoldSeconds / 2))

        Remove-PartitionRule -Namespace $Namespace -PodName $isolatedPod -TargetIp $targetIp | Out-Null
        Wait-ForStableReplicaSet -Namespace $Namespace -ClientPod $ClientPod -AnyMemberFqdn $witnessFqdn -MaxWaitSeconds 30 -PollSeconds 3 | Out-Null

        # Verification a posteriori via les logs (robuste, pas de sondage live) :
        # une vraie transition laisse TOUJOURS une trace "Election succeeded" quelque part.
        $anyElection = $null
        foreach ($pod in $AllPods) {
            $log = kubectl logs $pod -n $Namespace --since="2m" | Select-String -Pattern "Election succeeded" | Select-Object -Last 1
            if ($log) {
                $tElection = Get-LogTimestamp -LogLine $log.Line
                if ($tElection -and $tElection -gt $t0) { $anyElection = $pod; break }
            }
        }
        $primaryDuring = if ($anyElection) { $anyElection } else { $primaryPod }
        $stable = -not $anyElection
        $anomaly = [bool]$anyElection

        $row = [PSCustomObject]@{
            Trial          = $i
            Config         = $configType
            IsolatedPod    = $isolatedPod
            TargetPod      = $targetPod
            WitnessPod     = $witnessPod
            PrimaryBefore  = $primaryPod
            PrimaryDuring  = $primaryDuring
            PrimaryStable  = $stable
            ReplLagDuring  = $replLag
            Anomaly        = $anomaly
        }
        $results += $row
        "$i,$configType,$isolatedPod,$targetPod,$witnessPod,$primaryPod,$primaryDuring,$stable,""$replLag"",$anomaly" | Out-File $OutputCsv -Append -Encoding utf8

        $color = if ($anomaly) { "Red" } else { "Green" }
        Write-Host "Stable : $stable -- replLag : $replLag $(if($anomaly){'-- ANOMALIE : changement de primary !'})" -ForegroundColor $color

        if ($i -lt $Trials) { Start-Sleep -Seconds $InterTrialPauseSeconds }
    }

    Write-Host "`nCampagne scenario 2 terminee. Resultats dans $OutputCsv" -ForegroundColor Green
    return $results
}

function Wait-ForStableReplicaSet {
    <#
    .SYNOPSIS
    Attend que tous les membres du replica set soient dans un etat stable
    (PRIMARY ou SECONDARY, ni ROLLBACK ni RECOVERING ni STARTUP2), pour
    garantir l'independance entre essais successifs d'une campagne.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$ClientPod,
        [Parameter(Mandatory=$true)][string]$AnyMemberFqdn,
        [int]$MaxWaitSeconds = 60,
        [int]$PollSeconds = 3
    )

    $elapsed = 0
    while ($elapsed -lt $MaxWaitSeconds) {
        $status = kubectl exec $ClientPod -n $Namespace -- mongosh --host $AnyMemberFqdn --quiet --eval `
            "rs.status().members.map(m => m.stateStr).join(';')" 2>$null
        if ($status -match '^(PRIMARY|SECONDARY)(;(PRIMARY|SECONDARY))*$') {
            return $true
        }
        Start-Sleep -Seconds $PollSeconds
        $elapsed += $PollSeconds
    }
    Write-Warning "Wait-ForStableReplicaSet : timeout ($MaxWaitSeconds s) sans etat stable confirme (dernier etat : $status)"
    return $false
}

function Stop-WriterProcess {
    <#
    .SYNOPSIS
    Tue le(s) processus mongosh distant(s) tournant dans le pod client
    (le writer de charge), en plus d'arreter le Job PowerShell local.
    A utiliser systematiquement a la place de Stop-Job seul : Stop-Job
    n'arrete que le wrapper PowerShell, pas le process kubectl exec/mongosh
    distant, ce qui laisse des writers zombies actifs.

    .EXAMPLE
    Stop-WriterProcess -Namespace mongodb-pi -ClientPod mongo-client -WriterJob $writerJob
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$ClientPod,
        [Parameter()]$WriterJob
    )

    if ($WriterJob) { Stop-Job -Job $WriterJob -ErrorAction SilentlyContinue }

    $procs = kubectl exec $ClientPod -n $Namespace -- ps aux | Select-String "mongosh"
    if ($procs) {
        $pids = $procs | ForEach-Object { ($_ -split '\s+')[1] }
        Write-Host "Processus mongosh trouves : $($pids -join ', ') -- extinction..." -ForegroundColor Yellow
        kubectl exec $ClientPod -n $Namespace -- kill -9 $pids
        Write-Host "Writers arretes." -ForegroundColor Green
    } else {
        Write-Host "Aucun processus mongosh residuel trouve." -ForegroundColor Green
    }
}

function Invoke-JitterExperiment {
    <#
    .SYNOPSIS
    Scenario 3 (latence/gigue) : applique un delai + une gigue sur TOUTE
    l'interface eth0 du pod cible (limite technique de tc netem -- pas de
    ciblage par pair comme iptables), maintient, retire, puis verifie via
    les logs si une election a ete declenchee (methode robuste, pas de
    sondage live).

    .EXAMPLE
    Invoke-JitterExperiment -Namespace mongodb-pi -TargetPod mongodb-0 `
        -DelayMs 15000 -JitterMs 5000 -HoldSeconds 25 `
        -AllPods @("mongodb-0","mongodb-1","mongodb-2")
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$TargetPod,
        [Parameter(Mandatory=$true)][int]$DelayMs,
        [int]$JitterMs = 0,
        [int]$HoldSeconds = 25,
        [Parameter(Mandatory=$true)][string[]]$AllPods,
        [int]$LogWindowMinutes = 3
    )

    $t0 = (Get-Date).ToUniversalTime()
    Add-NetemLatency -Namespace $Namespace -PodName $TargetPod -DelayMs $DelayMs -JitterMs $JitterMs
    Start-Sleep -Seconds $HoldSeconds
    Clear-Netem -Namespace $Namespace -PodName $TargetPod
    Start-Sleep -Seconds 5

    $electionPod = $null
    $tElection = $null
    foreach ($pod in $AllPods) {
        $log = kubectl logs $pod -n $Namespace --since="${LogWindowMinutes}m" | Select-String -Pattern "Election succeeded" | Select-Object -Last 1
        if ($log) {
            $t = Get-LogTimestamp -LogLine $log.Line
            if ($t -and $t -gt $t0) {
                if (-not $tElection -or $t -lt $tElection) { $tElection = $t; $electionPod = $pod }
            }
        }
    }

    $rtoSeconds = if ($tElection) { [math]::Round(($tElection - $t0).TotalSeconds, 3) } else { $null }

    return [PSCustomObject]@{
        T0             = $t0
        TargetPod      = $TargetPod
        DelayMs        = $DelayMs
        JitterMs       = $JitterMs
        ElectionTriggered = [bool]$tElection
        NewPrimaryPod  = $electionPod
        RtoSeconds     = $rtoSeconds
    }
}

function Invoke-JitterCampaign {
    <#
    .SYNOPSIS
    Balaye plusieurs niveaux de delai (autour du seuil electionTimeoutMillis)
    pour construire une courbe de seuil : a quel niveau de latence le
    primary declenche-t-il une election, et avec quelle probabilite ?

    .EXAMPLE
    Invoke-JitterCampaign -Namespace mongodb-pi -ClientPod mongo-client `
        -AllPods @("mongodb-0","mongodb-1","mongodb-2") `
        -ServiceFqdnSuffix "mongodb.mongodb-pi.svc.cluster.local" `
        -DelayLevelsMs @(3000,6000,9000,12000,15000,20000) -JitterMs 2000 `
        -TrialsPerLevel 5 -OutputCsv .\campaign_jitter_mongodb.csv
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$ClientPod,
        [Parameter(Mandatory=$true)][string[]]$AllPods,
        [Parameter(Mandatory=$true)][string]$ServiceFqdnSuffix,
        [Parameter(Mandatory=$true)][int[]]$DelayLevelsMs,
        [int]$JitterMs = 2000,
        [int]$TrialsPerLevel = 5,
        [int]$HoldSeconds = 25,
        [int]$InterTrialPauseSeconds = 10,
        [string]$OutputCsv = ".\campaign_jitter.csv"
    )

    "delay_ms,jitter_ms,trial,t0_utc,target_pod,election_triggered,new_primary,rto_seconds" | Out-File $OutputCsv -Encoding utf8
    $results = @()

    foreach ($delay in $DelayLevelsMs) {
        for ($t = 1; $t -le $TrialsPerLevel; $t++) {
            Write-Host "`n=== Delai $delay ms (+/-$JitterMs ms) -- essai $t / $TrialsPerLevel ===" -ForegroundColor Cyan

            $anyFqdn = "$($AllPods[0]).$ServiceFqdnSuffix"
            $primaryPod = Get-ConfirmedPrimary -Namespace $Namespace -ClientPod $ClientPod -AllPods $AllPods -ServiceFqdnSuffix $ServiceFqdnSuffix
            if (-not $primaryPod) { Write-Warning "Primary non confirme, on saute."; continue }

            $exp = Invoke-JitterExperiment -Namespace $Namespace -TargetPod $primaryPod `
                -DelayMs $delay -JitterMs $JitterMs -HoldSeconds $HoldSeconds -AllPods $AllPods

            Wait-ForStableReplicaSet -Namespace $Namespace -ClientPod $ClientPod -AnyMemberFqdn $anyFqdn -MaxWaitSeconds 30 -PollSeconds 3 | Out-Null

            $row = [PSCustomObject]@{
                DelayMs           = $delay
                JitterMs          = $JitterMs
                Trial             = $t
                T0_Utc            = $exp.T0.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                TargetPod         = $primaryPod
                ElectionTriggered = $exp.ElectionTriggered
                NewPrimaryPod     = $exp.NewPrimaryPod
                RtoSeconds        = $exp.RtoSeconds
            }
            $results += $row
            "$delay,$JitterMs,$t,$($row.T0_Utc),$primaryPod,$($exp.ElectionTriggered),$($exp.NewPrimaryPod),$($exp.RtoSeconds)" | Out-File $OutputCsv -Append -Encoding utf8

            $color = if ($exp.ElectionTriggered) { "Yellow" } else { "Green" }
            Write-Host "Election declenchee : $($exp.ElectionTriggered) -- RTO : $($exp.RtoSeconds)" -ForegroundColor $color

            Start-Sleep -Seconds $InterTrialPauseSeconds
        }
    }

    Write-Host "`nCampagne jitter terminee. Resultats dans $OutputCsv" -ForegroundColor Green
    return $results
}

function Get-PxcStatus {
    <#
    .SYNOPSIS
    Interroge le statut Galera (wsrep) d'un pod PXC via le compte xtrabackup
    (le compte root a un mot de passe desynchronise sur ce cluster).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$PodName,
        [Parameter(Mandatory=$true)][string]$XtrabackupPass
    )

    $raw = kubectl exec $PodName -n $Namespace -c pxc -- mysql -uxtrabackup -p"$XtrabackupPass" --connect-timeout=5 -e `
        "SHOW STATUS LIKE 'wsrep_local_state_comment'; SHOW STATUS LIKE 'wsrep_cluster_size'; SHOW STATUS LIKE 'wsrep_ready'; SHOW STATUS LIKE 'wsrep_cluster_status';" 2>$null

    $joined = ($raw -join "`n")
    $result = [ordered]@{
        Reachable   = [bool]($raw)
        StateComment = $null
        ClusterSize  = $null
        Ready        = $null
        ClusterStatus = $null
    }
    if ($joined -match "wsrep_local_state_comment\s+(\S+)") { $result.StateComment = $Matches[1] }
    if ($joined -match "wsrep_cluster_size\s+(\d+)") { $result.ClusterSize = [int]$Matches[1] }
    if ($joined -match "wsrep_ready\s+(\S+)") { $result.Ready = $Matches[1] }
    if ($joined -match "wsrep_cluster_status\s+(\S+)") { $result.ClusterStatus = $Matches[1] }

    return [PSCustomObject]$result
}

function Invoke-PxcPartitionExperiment {
    <#
    .SYNOPSIS
    Isole un noeud PXC des deux autres, verifie le rejet immediat des
    ecritures (RPO attendu = 0 par construction Galera), retire la
    partition, puis mesure le temps de reintegration (IST ou SST) jusqu'a
    Synced. Contrairement a MongoDB, le "RTO" cluster est quasi nul (les 2
    autres noeuds restent disponibles) -- la metrique clef est le temps
    de reintegration du noeud isole.

    .EXAMPLE
    Invoke-PxcPartitionExperiment -Namespace rpo-ycsb -IsolatedPod pxc-cluster-pxc-db-pxc-0 `
        -TargetIps @("10.244.2.25","10.244.2.26") -XtrabackupPass $xtrabackupPass `
        -HoldSeconds 25 -MaxRejoinWaitSeconds 300
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$IsolatedPod,
        [Parameter(Mandatory=$true)][string[]]$TargetIps,
        [Parameter(Mandatory=$true)][string]$XtrabackupPass,
        [int]$HoldSeconds = 25,
        [int]$MaxRejoinWaitSeconds = 300,
        [int]$PollSeconds = 10
    )

    $t0 = (Get-Date).ToUniversalTime()

    # Writer continu, cible sur le premier target (non isole) -- demarre AVANT la partition,
    # arrete proprement APRES la reintegration confirmee (autonome, pas de risque de zombie
    # inter-essai puisque tout se passe dans cette meme fonction).
    $writerTargetPod = $null
    $writerJob = $null
    if ($TargetIps.Count -gt 0) {
        # Retrouver le nom du pod correspondant a la premiere IP cible (pour y lancer le writer)
        $writerTargetPod = kubectl get pods -n $Namespace -o jsonpath="{range .items[?(@.status.podIP=='$($TargetIps[0])')]}{.metadata.name}{end}"
        if ($writerTargetPod) {
            $writerJob = Start-Job -ScriptBlock {
                param($ns, $pod, $pass)
                kubectl exec $pod -n $ns -c pxc -- sh -c "while true; do mysql -uxtrabackup -p'$pass' -e 'INSERT INTO rpo_test_pxc.writes (seq) VALUES (FLOOR(RAND()*1000000000));' 2>/dev/null; sleep 0.5; done"
            } -ArgumentList $Namespace, $writerTargetPod, $XtrabackupPass
        }
    }

    foreach ($ip in $TargetIps) { Add-PartitionRule -Namespace $Namespace -PodName $IsolatedPod -TargetIp $ip | Out-Null }

    Start-Sleep -Seconds 2
    $detectionElapsed = 2
    $detectionOk = $false
    while ($detectionElapsed -le 15) {
        $statusDuring = Get-PxcStatus -Namespace $Namespace -PodName $IsolatedPod -XtrabackupPass $XtrabackupPass
        if ($statusDuring.Ready -eq "OFF") { $detectionOk = $true; break }
        Start-Sleep -Seconds 2
        $detectionElapsed += 2
    }

    $writeRejected = $null
    try {
        kubectl exec $IsolatedPod -n $Namespace -c pxc -- mysql -uxtrabackup -p"$XtrabackupPass" --connect-timeout=5 -e `
            "INSERT INTO rpo_test_pxc.writes VALUES (FLOOR(RAND()*1000000));" 2>$null | Out-Null
        $writeRejected = ($LASTEXITCODE -ne 0)
    } catch { $writeRejected = $true }

    Start-Sleep -Seconds ([math]::Max(0, $HoldSeconds - $detectionElapsed))

    foreach ($ip in $TargetIps) { Remove-PartitionRule -Namespace $Namespace -PodName $IsolatedPod -TargetIp $ip | Out-Null }
    $tHealStart = (Get-Date).ToUniversalTime()

    $elapsed = 0
    $rejoined = $false
    while ($elapsed -lt $MaxRejoinWaitSeconds) {
        $s = Get-PxcStatus -Namespace $Namespace -PodName $IsolatedPod -XtrabackupPass $XtrabackupPass
        if ($s.StateComment -eq "Synced" -and $s.ClusterSize -ge 3) { $rejoined = $true; break }
        Start-Sleep -Seconds $PollSeconds
        $elapsed += $PollSeconds
    }
    $tRejoin = (Get-Date).ToUniversalTime()
    $rejoinSeconds = if ($rejoined) { [math]::Round(($tRejoin - $tHealStart).TotalSeconds, 1) } else { $null }

    $sstLogLines = kubectl logs $IsolatedPod -n $Namespace -c pxc --since-time="$($t0.ToString('yyyy-MM-ddTHH:mm:ssZ'))" | Select-String -Pattern "wsrep_sst_method|State Transfer"
    $sstDetected = $sstLogLines | Select-Object -Last 1

    # Arret propre du writer (job + process distant, pour eviter tout zombie inter-essai)
    if ($writerJob) {
        Stop-Job -Job $writerJob -ErrorAction SilentlyContinue
        Remove-Job -Job $writerJob -Force -ErrorAction SilentlyContinue
        if ($writerTargetPod) {
            $procs = kubectl exec $writerTargetPod -n $Namespace -c pxc -- sh -c "ps aux | grep '[m]ysql -uxtrabackup'" 2>$null
            if ($procs) {
                $pidsToKill = $procs | ForEach-Object { ($_ -split '\s+')[1] }
                kubectl exec $writerTargetPod -n $Namespace -c pxc -- kill -9 $pidsToKill 2>$null | Out-Null
            }
            kubectl exec $writerTargetPod -n $Namespace -c pxc -- sh -c "pkill -f 'while true.*mysql -uxtrabackup'" 2>$null | Out-Null
        }
    }

    return [PSCustomObject]@{
        T0                = $t0
        IsolatedPod       = $IsolatedPod
        DetectionImmediate = $detectionOk
        WriteRejected     = $writeRejected
        Rejoined          = $rejoined
        RejoinSeconds     = $rejoinSeconds
        LikelySST         = [bool]$sstDetected
    }
}

function Invoke-PxcCampaign {
    <#
    .SYNOPSIS
    Automatise n essais de partition complete sur PXC, en isolant a tour
    de role chacun des 3 noeuds. Chaque essai peut prendre 2-4 minutes
    (temps de reintegration IST/SST), prevoir n=30 ~1h30-2h.

    .EXAMPLE
    Invoke-PxcCampaign -Namespace rpo-ycsb -AllPods @("pxc-cluster-pxc-db-pxc-0","pxc-cluster-pxc-db-pxc-1","pxc-cluster-pxc-db-pxc-2") `
        -XtrabackupPass $xtrabackupPass -Trials 30 -OutputCsv .\campaign_pxc_partition_n30.csv
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string[]]$AllPods,
        [Parameter(Mandatory=$true)][string]$XtrabackupPass,
        [int]$Trials = 30,
        [int]$HoldSeconds = 25,
        [int]$MaxRejoinWaitSeconds = 300,
        [int]$PollSeconds = 10,
        [int]$InterTrialPauseSeconds = 15,
        [string]$OutputCsv = ".\campaign_pxc_partition.csv"
    )

    "trial,t0_utc,isolated_pod,detection_immediate,write_rejected,rejoined,rejoin_seconds,likely_sst" | Out-File $OutputCsv -Encoding utf8
    $results = @()

    for ($i = 1; $i -le $Trials; $i++) {
        $isolatedPod = $AllPods[($i - 1) % $AllPods.Count]
        $targetPods = $AllPods | Where-Object { $_ -ne $isolatedPod }

        Write-Host "`n========== Essai PXC $i / $Trials -- isolation de $isolatedPod ==========" -ForegroundColor Cyan

        # Verifier stabilite avant de commencer
        $preStatus = Get-PxcStatus -Namespace $Namespace -PodName $isolatedPod -XtrabackupPass $XtrabackupPass
        if ($preStatus.StateComment -ne "Synced") {
            Write-Warning "Essai $i : $isolatedPod pas encore Synced avant l'essai (etat: $($preStatus.StateComment)), on attend..."
            Start-Sleep -Seconds 30
        }

        $targetIps = foreach ($p in $targetPods) {
            (kubectl get pod $p -n $Namespace -o jsonpath='{.status.podIP}')
        }

        $exp = Invoke-PxcPartitionExperiment -Namespace $Namespace -IsolatedPod $isolatedPod `
            -TargetIps $targetIps -XtrabackupPass $XtrabackupPass `
            -HoldSeconds $HoldSeconds -MaxRejoinWaitSeconds $MaxRejoinWaitSeconds -PollSeconds $PollSeconds

        $row = [PSCustomObject]@{
            Trial              = $i
            T0_Utc             = $exp.T0.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            IsolatedPod        = $isolatedPod
            DetectionImmediate = $exp.DetectionImmediate
            WriteRejected      = $exp.WriteRejected
            Rejoined           = $exp.Rejoined
            RejoinSeconds      = $exp.RejoinSeconds
            LikelySST          = $exp.LikelySST
        }
        $results += $row
        "$i,$($row.T0_Utc),$isolatedPod,$($exp.DetectionImmediate),$($exp.WriteRejected),$($exp.Rejoined),$($exp.RejoinSeconds),$($exp.LikelySST)" | Out-File $OutputCsv -Append -Encoding utf8

        $color = if ($exp.Rejoined) { "Green" } else { "Red" }
        Write-Host "Detection immediate : $($exp.DetectionImmediate) -- Ecriture rejetee : $($exp.WriteRejected) -- Reintegre : $($exp.Rejoined) en $($exp.RejoinSeconds)s (SST probable: $($exp.LikelySST))" -ForegroundColor $color

        if ($i -lt $Trials) { Start-Sleep -Seconds $InterTrialPauseSeconds }
    }

    Write-Host "`nCampagne PXC terminee. Resultats dans $OutputCsv" -ForegroundColor Green
    return $results
}

function Invoke-PxcAsymmetricExperiment {
    <#
    .SYNOPSIS
    Scenario 2 pour PXC : coupe uniquement le lien entre PodA et PodB, en
    laissant PodC (temoin) connecte aux deux. Teste si Galera tolere cette
    asymetrie (quorum maintenu via PodC) ou si son modele de communication
    de groupe (mesh complet requis) casse le cluster malgre la connectivite
    indirecte.

    .EXAMPLE
    Invoke-PxcAsymmetricExperiment -Namespace rpo-ycsb -PodA pxc-cluster-pxc-db-pxc-0 `
        -PodB pxc-cluster-pxc-db-pxc-1 -PodC pxc-cluster-pxc-db-pxc-2 `
        -XtrabackupPass $xtrabackupPass -HoldSeconds 25
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$PodA,
        [Parameter(Mandatory=$true)][string]$PodB,
        [Parameter(Mandatory=$true)][string]$PodC,
        [Parameter(Mandatory=$true)][string]$XtrabackupPass,
        [int]$HoldSeconds = 25
    )

    $ipB = kubectl get pod $PodB -n $Namespace -o jsonpath='{.status.podIP}'

    Write-Host "Etat avant (A/B/C) :" -ForegroundColor Magenta
    foreach ($pod in @($PodA, $PodB, $PodC)) {
        $s = Get-PxcStatus -Namespace $Namespace -PodName $pod -XtrabackupPass $XtrabackupPass
        Write-Host "  $pod : $($s.StateComment), size=$($s.ClusterSize), ready=$($s.Ready)"
    }

    $t0 = (Get-Date).ToUniversalTime()
    Add-PartitionRule -Namespace $Namespace -PodName $PodA -TargetIp $ipB
    Write-Host "`nLien coupe : $PodA <-x-> $PodB (uniquement, $PodC reste connecte aux deux)" -ForegroundColor Yellow

    Start-Sleep -Seconds $HoldSeconds

    Write-Host "`nEtat pendant l'isolement (A/B/C) :" -ForegroundColor Magenta
    $statuses = @{}
    foreach ($pod in @($PodA, $PodB, $PodC)) {
        $s = Get-PxcStatus -Namespace $Namespace -PodName $pod -XtrabackupPass $XtrabackupPass
        $statuses[$pod] = $s
        Write-Host "  $pod : $($s.StateComment), size=$($s.ClusterSize), ready=$($s.Ready)"
    }

    Write-Host "`nTest d'ecriture sur $PodA :" -ForegroundColor Magenta
    kubectl exec $PodA -n $Namespace -c pxc -- mysql -uxtrabackup -p"$XtrabackupPass" --connect-timeout=5 -e "INSERT INTO rpo_test_pxc.writes (seq) VALUES (999999);" 2>$null
    Write-Host "Code de sortie : $LASTEXITCODE (0 = succes, autre = echec)"

    Write-Host "`nTest d'ecriture sur $PodB :" -ForegroundColor Magenta
    kubectl exec $PodB -n $Namespace -c pxc -- mysql -uxtrabackup -p"$XtrabackupPass" --connect-timeout=5 -e "INSERT INTO rpo_test_pxc.writes (seq) VALUES (999998);" 2>$null
    Write-Host "Code de sortie : $LASTEXITCODE (0 = succes, autre = echec)"

    Remove-PartitionRule -Namespace $Namespace -PodName $PodA -TargetIp $ipB
    Write-Host "`nLien retabli." -ForegroundColor Green
    Start-Sleep -Seconds 10

    Write-Host "`nEtat apres retablissement (A/B/C) :" -ForegroundColor Magenta
    foreach ($pod in @($PodA, $PodB, $PodC)) {
        $s = Get-PxcStatus -Namespace $Namespace -PodName $pod -XtrabackupPass $XtrabackupPass
        Write-Host "  $pod : $($s.StateComment), size=$($s.ClusterSize), ready=$($s.Ready)"
    }

    return $statuses
}

function Invoke-PxcAsymmetricCampaign {
    <#
    .SYNOPSIS
    Automatise le scenario 2 sur PXC : teste les 3 paires possibles de
    noeuds (avec le 3e comme temoin a chaque fois), plusieurs essais par
    paire, verifie que le cluster reste sain et que les ecritures passent
    des deux cotes du lien coupe.

    .EXAMPLE
    Invoke-PxcAsymmetricCampaign -Namespace rpo-ycsb `
        -AllPods @("pxc-cluster-pxc-db-pxc-0","pxc-cluster-pxc-db-pxc-1","pxc-cluster-pxc-db-pxc-2") `
        -XtrabackupPass $xtrabackupPass -TrialsPerPair 3 -OutputCsv .\campaign_pxc_scenario2.csv
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string[]]$AllPods,
        [Parameter(Mandatory=$true)][string]$XtrabackupPass,
        [int]$TrialsPerPair = 3,
        [int]$HoldSeconds = 20,
        [int]$InterTrialPauseSeconds = 5,
        [string]$OutputCsv = ".\campaign_pxc_scenario2.csv"
    )

    $pairs = @(
        @($AllPods[0], $AllPods[1], $AllPods[2]),
        @($AllPods[0], $AllPods[2], $AllPods[1]),
        @($AllPods[1], $AllPods[2], $AllPods[0])
    )

    "trial,pair,pod_a,pod_b,witness,cluster_stayed_healthy,write_a_ok,write_b_ok" | Out-File $OutputCsv -Encoding utf8
    $results = @()
    $trialNum = 0

    foreach ($pair in $pairs) {
        $podA, $podB, $podC = $pair
        for ($t = 1; $t -le $TrialsPerPair; $t++) {
            $trialNum++
            Write-Host "`n=== Essai $trialNum -- paire $podA / $podB (temoin: $podC) ===" -ForegroundColor Cyan

            $ipB = kubectl get pod $podB -n $Namespace -o jsonpath='{.status.podIP}'
            Add-PartitionRule -Namespace $Namespace -PodName $podA -TargetIp $ipB | Out-Null
            Start-Sleep -Seconds $HoldSeconds

            $sA = Get-PxcStatus -Namespace $Namespace -PodName $podA -XtrabackupPass $XtrabackupPass
            $sB = Get-PxcStatus -Namespace $Namespace -PodName $podB -XtrabackupPass $XtrabackupPass
            $sC = Get-PxcStatus -Namespace $Namespace -PodName $podC -XtrabackupPass $XtrabackupPass
            $healthy = ($sA.StateComment -eq "Synced" -and $sB.StateComment -eq "Synced" -and $sC.StateComment -eq "Synced" -and
                        $sA.ClusterSize -eq 3 -and $sB.ClusterSize -eq 3 -and $sC.ClusterSize -eq 3)

            kubectl exec $podA -n $Namespace -c pxc -- mysql -uxtrabackup -p"$XtrabackupPass" --connect-timeout=5 -e "INSERT INTO rpo_test_pxc.writes (seq) VALUES (1);" 2>$null
            $writeAOk = ($LASTEXITCODE -eq 0)
            kubectl exec $podB -n $Namespace -c pxc -- mysql -uxtrabackup -p"$XtrabackupPass" --connect-timeout=5 -e "INSERT INTO rpo_test_pxc.writes (seq) VALUES (1);" 2>$null
            $writeBOk = ($LASTEXITCODE -eq 0)

            Remove-PartitionRule -Namespace $Namespace -PodName $podA -TargetIp $ipB | Out-Null
            Start-Sleep -Seconds 5

            $row = [PSCustomObject]@{
                Trial       = $trialNum
                Pair        = "$podA/$podB"
                Witness     = $podC
                ClusterHealthy = $healthy
                WriteAOk    = $writeAOk
                WriteBOk    = $writeBOk
            }
            $results += $row
            "$trialNum,$($podA)-$($podB),$podA,$podB,$podC,$healthy,$writeAOk,$writeBOk" | Out-File $OutputCsv -Append -Encoding utf8

            $color = if ($healthy -and $writeAOk -and $writeBOk) { "Green" } else { "Red" }
            Write-Host "Cluster sain : $healthy -- Ecriture A : $writeAOk -- Ecriture B : $writeBOk" -ForegroundColor $color

            Start-Sleep -Seconds $InterTrialPauseSeconds
        }
    }

    Write-Host "`nCampagne scenario 2 PXC terminee. Resultats dans $OutputCsv" -ForegroundColor Green
    return $results
}

function Invoke-PxcJitterExperiment {
    <#
    .SYNOPSIS
    Scenario 3 pour PXC : applique un delai sur eth0 du noeud cible,
    verifie via un temoin si Galera l'a exclu du quorum (wsrep_cluster_size
    < 3), puis retire le delai et verifie le retour a la normale.

    .EXAMPLE
    Invoke-PxcJitterExperiment -Namespace rpo-ycsb -TargetPod pxc-cluster-pxc-db-pxc-0 `
        -WitnessPod pxc-cluster-pxc-db-pxc-1 -DelayMs 8000 -JitterMs 1000 `
        -HoldSeconds 20 -XtrabackupPass $xtrabackupPass
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$TargetPod,
        [Parameter(Mandatory=$true)][string]$WitnessPod,
        [Parameter(Mandatory=$true)][int]$DelayMs,
        [int]$JitterMs = 500,
        [int]$HoldSeconds = 20,
        [Parameter(Mandatory=$true)][string]$XtrabackupPass
    )

    $t0 = (Get-Date).ToUniversalTime()
    Add-NetemLatency -Namespace $Namespace -PodName $TargetPod -DelayMs $DelayMs -JitterMs $JitterMs
    Start-Sleep -Seconds $HoldSeconds

    $witnessStatus = Get-PxcStatus -Namespace $Namespace -PodName $WitnessPod -XtrabackupPass $XtrabackupPass
    $excluded = ($witnessStatus.ClusterSize -lt 3)

    Clear-Netem -Namespace $Namespace -PodName $TargetPod
    Start-Sleep -Seconds 10
    $witnessAfter = Get-PxcStatus -Namespace $Namespace -PodName $WitnessPod -XtrabackupPass $XtrabackupPass
    $recovered = ($witnessAfter.ClusterSize -eq 3 -and $witnessAfter.StateComment -eq "Synced")

    return [PSCustomObject]@{
        T0                  = $t0
        TargetPod           = $TargetPod
        DelayMs             = $DelayMs
        JitterMs            = $JitterMs
        ClusterSizeDuring   = $witnessStatus.ClusterSize
        Excluded            = $excluded
        RecoveredAfter      = $recovered
    }
}

function Invoke-PxcJitterCampaign {
    <#
    .SYNOPSIS
    Balaye plusieurs niveaux de delai autour des seuils Galera reels
    (gmcast.peer_timeout=3s, evs.suspect_timeout=5s, evs.inactive_timeout=15s)
    pour construire la courbe de seuil d'exclusion du quorum.

    .EXAMPLE
    Invoke-PxcJitterCampaign -Namespace rpo-ycsb -AllPods @("pxc-cluster-pxc-db-pxc-0","pxc-cluster-pxc-db-pxc-1","pxc-cluster-pxc-db-pxc-2") `
        -XtrabackupPass $xtrabackupPass -DelayLevelsMs @(1000,3000,5000,8000,15000,20000) `
        -TrialsPerLevel 5 -OutputCsv .\campaign_pxc_jitter.csv
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string[]]$AllPods,
        [Parameter(Mandatory=$true)][string]$XtrabackupPass,
        [Parameter(Mandatory=$true)][int[]]$DelayLevelsMs,
        [int]$JitterMs = 500,
        [int]$TrialsPerLevel = 5,
        [int]$HoldSeconds = 20,
        [int]$InterTrialPauseSeconds = 10,
        [string]$OutputCsv = ".\campaign_pxc_jitter.csv"
    )

    "delay_ms,jitter_ms,trial,t0_utc,target_pod,cluster_size_during,excluded,recovered_after" | Out-File $OutputCsv -Encoding utf8
    $results = @()

    foreach ($delay in $DelayLevelsMs) {
        for ($t = 1; $t -le $TrialsPerLevel; $t++) {
            $targetPod = $AllPods[($t - 1) % $AllPods.Count]
            $witnessPod = ($AllPods | Where-Object { $_ -ne $targetPod })[0]

            Write-Host "`n=== Delai $delay ms -- essai $t / $TrialsPerLevel (cible: $targetPod) ===" -ForegroundColor Cyan

            $exp = Invoke-PxcJitterExperiment -Namespace $Namespace -TargetPod $targetPod -WitnessPod $witnessPod `
                -DelayMs $delay -JitterMs $JitterMs -HoldSeconds $HoldSeconds -XtrabackupPass $XtrabackupPass

            $row = [PSCustomObject]@{
                DelayMs           = $delay
                JitterMs          = $JitterMs
                Trial             = $t
                T0_Utc            = $exp.T0.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                TargetPod         = $targetPod
                ClusterSizeDuring = $exp.ClusterSizeDuring
                Excluded          = $exp.Excluded
                RecoveredAfter    = $exp.RecoveredAfter
            }
            $results += $row
            "$delay,$JitterMs,$t,$($row.T0_Utc),$targetPod,$($exp.ClusterSizeDuring),$($exp.Excluded),$($exp.RecoveredAfter)" | Out-File $OutputCsv -Append -Encoding utf8

            $color = if ($exp.Excluded) { "Yellow" } else { "Green" }
            Write-Host "Taille cluster pendant : $($exp.ClusterSizeDuring) -- Exclu : $($exp.Excluded) -- Recupere : $($exp.RecoveredAfter)" -ForegroundColor $color

            Start-Sleep -Seconds $InterTrialPauseSeconds
        }
    }

    Write-Host "`nCampagne jitter PXC terminee. Resultats dans $OutputCsv" -ForegroundColor Green
    return $results
}

function Clear-AllPartitionRules {
    <#
    .SYNOPSIS
    Filet de securite : vide toutes les regles iptables custom d'un pod
    (utile en fin de campagne pour repartir propre).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$PodName
    )

    Invoke-InPodNetns -Namespace $Namespace -PodName $PodName -Command "iptables -F INPUT"
    Invoke-InPodNetns -Namespace $Namespace -PodName $PodName -Command "iptables -F OUTPUT"
    Write-Host "Toutes les regles iptables INPUT/OUTPUT videes pour $PodName"
}
