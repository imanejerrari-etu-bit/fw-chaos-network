# Phase 1b — seuil de redémarrage PXC et vérification du remède (plan avant essais)

Statut : brouillon. À committer et à taguer `prereg-phase1b` AVANT le premier essai de ce plan.
Les essais 1 à 85 de la Phase 1 ne sont pas modifiés.

## Pourquoi
La Phase 1 montre : 0/29 redémarrages à 20 s, 8/9 à 30 s (liveness probe, failureThreshold=3, period=10 s).
Deux lacunes : (1) on ne connaît pas le seuil entre 20 s et 30 s ; (2) la cause "liveness probe" est déduite
des événements Kubernetes, pas démontrée par une intervention.

## Hypothèses (écrites avant les essais)
- H6 (seuil) : la proportion de redémarrages croît avec la durée d'isolation. Elle est nulle à 24 s et 26 s,
  et proche de 1 à 36 s. Le seuil est estimé entre 26 s et 32 s (le signal d'arrêt arrive ~30,3 s après
  le début de la partition en Phase 1). Si ce n'est pas le cas, on le rapporte tel quel.
- H7 (remède) : avec failureThreshold=6, aucun redémarrage à 30 s (0/10).
- H8 (décalage) : avec failureThreshold=6, des redémarrages réapparaissent à 70 s (au moins 1/5),
  avec un signal d'arrêt environ 30 s plus tard que dans le bras failureThreshold=3 pour la même
  condition "hors du primary component".
Si H7 est fausse, la liveness probe seule n'explique pas les redémarrages : on le dit.

## Plan
Bloc A (failureThreshold=3, configuration de la Phase 1)  : durées 24, 26, 28, 32, 36 s, 10 essais chacun = 50.
Bloc B (failureThreshold=6)                                : 30 s x 10 + 70 s x 5 = 15.
Ordre : bloc A puis bloc B, ordre aléatoire à l'intérieur de chaque bloc (graine 2026, `schedule_phase1b.csv`).
Les bras 20 s (n=29) et 30 s (n=9) de la Phase 1 servent de points de référence du bloc A ; ils ont été
exécutés avant, sans interleaving avec Phase 1b : à signaler comme limite (dérive possible du banc).
Total : 65 essais. Un essai avec redémarrage impose d'attendre au moins 310 s avant l'essai suivant
(règle de la Phase 1 : la probe doit être active) : prévoir environ 8 à 12 heures de banc.

## Modification de la probe (bloc B)
Changer uniquement `failureThreshold` du conteneur `pxc` (3 -> 6) via le CR de l'opérateur Percona
(section des liveness probes du pxc ; à vérifier dans la version déployée). Vérifier après redéploiement,
dans le YAML du pod : failureThreshold=6, les autres champs inchangés (initialDelaySeconds 300, period 10, timeout 5).
Ne rien changer d'autre (images, ressources, Galera). Noter la date et l'heure du changement.

## Mesures (inchangées par rapport à la Phase 1)
Même writer, même rythme, mêmes règles de validité, mêmes quatre horodatages, même définition de "restart"
(signal d'arrêt de mysqld OU compteur de restarts corrigé), mêmes exclusions décidées avant les résultats.
Ajout : l'instant du premier échec de probe dans les événements du pod (si disponible) pour relier
"sortie du primary component" -> "arrêt".

## Analyse
Proportions avec intervalles exacts de Clopper-Pearson. Tendance : régression logistique restart ~ durée
(bloc A, plus les bras 20 s et 30 s de la Phase 1), avec intervalle de confiance du seuil à 50 %.
Test H7/H8 : Fisher exact entre bras (30 s, ft=3) de la Phase 1 et (30 s, ft=6), et entre (30 s, ft=6) et (70 s, ft=6).
Avec 0/10, la borne haute exacte à 95 % est 25,9 % : l'écrire tel quel.

## À corriger dans le dépôt AVANT de committer ce plan
1. Rédiger "Amendment 3" (exclusion des essais 1 et 2 : règles dirigées vers l'ancienne IP de pxc-2),
   daté du jour réel de rédaction. Ne pas antidater. Préciser que l'inspection des données précédait la rédaction.
2. Corriger l'amendement 2 : la phrase "before any campaign data" est inexacte, car les essais 1 et 2
   (13h31 et 13h33 UTC le 8 novembre) précèdent l'amendement 2 (18h00 UTC).
   Les règles en un seul appel et les bras 20 s/30 s appartiennent à l'amendement 1.
3. Aligner `parse_trials.py` sur `independent_check.py` pour la définition de "restart" (6/10 contre 8/9).
4. Mettre à jour le README (il décrit encore l'ancienne campagne).

## Limites à garder dans le papier
Une seule machine, un seul débit (5 écritures/s), un seul type de partition, probe dans la configuration de l'opérateur.
Phase 1b ne répond pas à la généralisation à d'autres moteurs : à discuter séparément.
