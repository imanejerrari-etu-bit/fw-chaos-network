# Amendment 3 (Phase 1)

Date de rÃ©daction : 2026-11-21 17:18 UTC (rÃ©digÃ© aprÃ¨s l'inspection de la qualitÃ© des donnÃ©es de la Phase 1 : les rÃ©sultats Ã©taient visibles Ã  ce moment-lÃ ).

## Objet
Exclusion des essais PXC 1 et 2 de l'analyse principale.

## Raison (vÃ©rifiable indÃ©pendamment des rÃ©sultats)
Ces deux essais ont tournÃ© le 8 novembre 2026 Ã  13h31 et 13h33 UTC, avant l'Amendment 2 (commit de 18h00 UTC). Leurs rÃ¨gles iptables visaient 10.244.2.4, ancienne adresse d'un pair ; l'adresse Ã©tait 10.244.2.3 dans les 38 essais suivants de la Phase 1. Un lien est restÃ© intact : le noeud est restÃ© dans le primary component et a acquittÃ© 91 (essai 1) et 53 (essai 2) Ã©critures pendant la pÃ©riode d'isolation prÃ©vue.

## Effet sur les hypothÃ¨ses
Aucun changement des hypothÃ¨ses ni des tailles d'Ã©chantillon. Les rÃ©sultats avec et sans ces essais sont rapportÃ©s dans le papier (avec : 1 essai sur 30 Ã  20 s et 1 sur 10 Ã  30 s avec Ã©criture acquittÃ©e aprÃ¨s l'isolation ; H3, H4 et H5 inchangÃ©es).

## Corrections liÃ©es Ã  d'autres amendements
- La phrase "before any campaign data" de l'Amendment 2 est inexacte : les essais 1 et 2 l'ont prÃ©cÃ©dÃ©.
- La rÃ¨gle d'application en un seul appel et les bras 20 s / 30 s appartiennent Ã  l'Amendment 1 (inclus dans le tag prereg-phase1).
