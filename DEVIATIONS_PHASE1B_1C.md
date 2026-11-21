# DÃ©viations des Phases 1b et 1c (rÃ©digÃ© le 2026-11-21 17:18 UTC)

Phase 1b (tag prereg-phase1b)
- Le plan indique une borne haute "exacte Ã  95 %" de 25,9 % pour 0/10 : c'est la borne unilatÃ©rale ; les intervalles du papier sont bilatÃ©raux (30,8 %).
- Le script run-phase1b.ps1 a Ã©tÃ© corrigÃ© aprÃ¨s le tag (rÃ©glage de gestion d'erreurs qui interrompait un essai sur un avertissement mysql bÃ©nin ; chargement de netns-tools.ps1) : infrastructure uniquement.
- H6 est en partie fausse : 4/10 redÃ©marrages Ã  26 s (prÃ©vu : 0).
- L'essai 101 (32 s) a subi une collision de clÃ©s avec un essai test de mÃªme numÃ©ro (23 erreurs de clÃ© dupliquÃ©e, 4 aprÃ¨s l'isolation, aucune Ã©criture acquittÃ©e aprÃ¨s l'isolation) ; sensibilitÃ© sans cet essai : 9/9 Ã  32 s, point Ã  50 % inchangÃ© (26,8 s).
- Le bloc B (ft=6) a tournÃ© sur des pods recrÃ©Ã©s ; les bras 20 s et 30 s (ft=3) de la Phase 1 n'ont pas Ã©tÃ© entrelacÃ©s avec la Phase 1b.

Phase 1c (tag prereg-phase1c)
- Le critÃ¨re principal T_serv a Ã©tÃ© redÃ©fini aprÃ¨s un essai test et avant tout essai comptÃ© (restauration stable au lieu de la premiÃ¨re Ã©criture acquittÃ©e aprÃ¨s le heal).
- Les essais test utilisent le numÃ©ro 999 pour Ã©viter les collisions de clÃ©s.
- H11 (dÃ©rive A1 / A2 infÃ©rieure Ã  5 s) n'est pas satisfaite : Ã©cart des mÃ©dianes 7,3 s (p = 0,038).
- L'essai 230 (A2) a pris 587,5 s ; cause non Ã©tablie ; conservÃ©.
- Les scripts ont Ã©tÃ© corrigÃ©s pendant la phase (chargement de netns-tools.ps1, dÃ©tection des Ã©critures acquittÃ©es de la sonde, suppression d'un FAILED.txt pÃ©rimÃ©) : infrastructure uniquement.
