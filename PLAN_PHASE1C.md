# Phase 1c - coût d'un redémarrage provoqué par la sonde (plan avant essais)

Statut : brouillon. À committer et à taguer `prereg-phase1c` AVANT le premier essai.
Les Phases 1 et 1b ne sont pas modifiées.

## Pourquoi
La Phase 1b montre qu'une sonde tolérante (failureThreshold 6) supprime les redémarrages à 30 s, mais nous
ne savons pas ce que coûte un redémarrage : combien de temps le noeud isolé reste indisponible après la fin de la
partition. Sans cette mesure, la recommandation "relever le seuil" reste incomplète (le coût inverse - retarder le
retrait d'un noeud réellement en panne - est déjà mesuré : l'arrêt arrive ~30 s plus tard, 56,9-63,3 s contre 26,6-35,9 s).

Observation exploratoire qui motive le plan (NON pré-spécifiée, issue de sondes de statut qui n'étaient pas conçues
pour cela et dont le suivi s'arrête avant la fin de la récupération : durées censurées) : dans les données de la
Phase 1b, la dernière observation "non Synced" après le début du heal vaut une médiane de 15,5 s dans les essais
avec redémarrage contre 1,9 s sans redémarrage. Ce n'est pas un résultat.

## Plan
Isolation de 36 s (redémarrage 10/10 avec failureThreshold 3 en Phase 1b ; aucun essai à ft=6 n'a été fait à 36 s).
Design ABA pour contrôler la dérive : A1 (ft=3, 10 essais), B (ft=6, 15 essais), A2 (ft=3, 10 essais) = 35 essais,
dans cet ordre (calendrier `schedule_phase1c.csv`, essais 201 à 235). Passage de ft par patch du CR (pods recréés), comme en Phase 1b.

Mesure : en plus du writer interne habituel (inchangé), une sonde d'écriture lancée depuis l'hôte via `kubectl exec`
(une écriture environ toutes les 0,5 s, enregistrée dans `hostprobe.log`) survit au redémarrage du conteneur.
La sonde ajoute une faible charge d'écriture (1 à 2 écritures/s) sur le noeud isolé, avant, pendant et après
l'isolation : déclaré comme limite. Ses lignes portent trial = essai + 9000 et node = 'hostprobe' : elles
n'interfèrent pas avec la vérification des écritures acquittées.

## Hypothèses (écrites avant les essais)
- H9 (primaire) : le temps entre le début du heal et la première écriture de la sonde acquittée (T_serv) est plus long
  avec ft=3 (A1+A2) qu'avec ft=6 (B), la différence des médianes étant supérieure à 5 s. Test de Mann-Whitney bilatéral,
  IC bootstrap 95 % de la différence des médianes (10 000 rééchantillonnages, graine 2026).
- H10 : avec ft=6 et 36 s, 0 redémarrage sur 15 (borne haute exacte bilatérale 21,8 %) ; avec ft=3, au moins 18 redémarrages sur 20.
- H11 (contrôle de dérive) : les médianes de T_serv de A1 et A2 diffèrent de moins de 5 s. Sinon, l'écart A/B est
  rapporté avec cette réserve.
Si H9 est fausse (différence <= 5 s), le papier dira que le redémarrage a un coût faible dans ce banc.

## Mesures secondaires (descriptives)
Nombre d'écritures de la sonde en échec après le heal ; type de transfert d'état au redémarrage (IST ou SST) lu dans le
journal du nouveau conteneur ; compteur de redémarrages ; mêmes règles de validité que les Phases 1 et 1b
(horloge < 1 s, au moins une écriture acquittée avant la partition, cluster sain au départ).

## Analyse
`analyze_phase1c.py` (même définition de redémarrage que `analyze_phase1b.py`). Pas de calcul de puissance : l'écart
exploratoire (~13 s) est grand devant la résolution de la sonde (~0,5-1 s) ; les tailles sont fixées par le temps de banc.

## Durée
Environ 20 essais avec redémarrage x 7-8 min (règle des 310 s) + 15 essais sans redémarrage x 3 min : 3 à 4 h.

## Limites à écrire
Un seul système, une seule durée (36 s), une seule période de sonde ; sonde d'écriture qui ajoute une charge ;
résolution de 0,5 à 1 s ; ordre ABA et pods recréés entre blocs.
