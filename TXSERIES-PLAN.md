# Compatibilité GnuCOBOL 4 / IBM TXSeries — planification

État : brouillon, 2026-10-28. Version de TXSeries non encore choisie.

Objectif : pouvoir compiler avec GnuCOBOL des programmes COBOL CICS
(traduits par `cicstcl`) et les exécuter dans les serveurs d'application
(`cicsas`) d'une région TXSeries, avec la sémantique attendue par CICS.

Principes généraux :
- le runtime réentrant est **le seul mode** : pas d'option de
  compilation spécifique ;
- **pas de compatibilité ascendante** : l'ABI de libcob et le code
  généré peuvent changer librement, les programmes compilés avec une
  version antérieure n'ont pas à fonctionner (il faut les recompiler).

## Vue d'ensemble des travaux

| #  | Travail                                        | Dépend de | Bloqué par le choix de version ? |
|----|------------------------------------------------|-----------|----------------------------------|
| T1 | Runtime réentrant (contexte explicite, multi-thread) | —   | non                              |
| T2 | Runtime « hébergé » (pas d'exit, signaux, erreurs) | (T1)  | non                              |
| T3 | Choix de version TXSeries et étude de l'ABI    | —         | c'est le travail qui la fixe     |
| T4 | Dialecte : compiler le source traduit par `cicstcl` | T3 (partiel) | partiellement            |
| T5 | Intégration au chargement des programmes par `cicsas` | T1, T2, T3 | oui                    |
| T6 | Chaîne de build et préprocesseurs (EXEC SQL)   | T4, T5    | oui                              |
| T7 | Recette en région, performances, documentation | tous      | oui                              |

T1, T2 et T3 peuvent avancer en parallèle. T1 est le plus gros et le
seul qui ne dépend d'aucune information sur TXSeries : on le commence en
premier.

### T1 — Runtime réentrant
Voir la sous-planification détaillée plus bas.

### T2 — Runtime hébergé dans un processus serveur
Le runtime ne doit jamais terminer ni perturber le processus hôte.
- `STOP RUN`, `cob_stop_run` (`libcob/common.c:3520`), `cob_hard_failure`
  (`common.c:3570`), `cob_runtime_error` : remplacer l'appel à `exit()`
  par un retour contrôlé vers l'hôte (hook enregistré dans le contexte,
  p. ex. pour produire un ABEND CICS).
- Signaux : `cob_set_signal` (`common.c:1535`) installe des handlers qui
  finissent par `exit(sig)` ; il faut pouvoir ne pas les installer
  (CICS gère lui-même ses abends).
- Initialisation sans `argc`/`argv`, une seule fois par processus ;
  pas de `atexit` gênant.
- E/S console (`DISPLAY`, `ACCEPT`, screenio) : comportement défini
  (redirection, erreur propre) plutôt que blocage ou plantage.
- Pas de fuite mémoire d'une tâche à l'autre (processus de longue durée).

### T3 — Choix de version et étude de l'ABI TXSeries
- Choisir version et plateforme (probablement Linux x86_64 ; 32 ou 64 bits ?).
- Récupérer la sortie de `cicstcl` (COBOL IBM et Micro Focus) pour un
  jeu de programmes types.
- Comprendre comment `cicsas` charge un programme : définition de
  programme (PD, PathName), symbole d'entrée, rôle de `cicsmkcobol` /
  du runtime COBOL MF, modèle de threads de `cicsas`.
- Décider de la stratégie d'intégration (voir T5).

### T4 — Dialecte du source traduit
- Créer `config/txseries.conf` (dérivé de `mf.conf` ou `ibm.conf`).
- Ordre des octets / troncature / taille des `COMP` et `COMP-5`
  identiques à ce que TXSeries écrit dans l'EIB (`DFHEIBLK`).
- Constructions générées par le traducteur : `CALL ... USING BY VALUE`,
  `ADDRESS OF`, `SET ADDRESS OF`, `POINTER`, `GO TO ... DEPENDING ON`,
  directives `$SET` éventuelles.
- `PROCEDURE DIVISION USING DFHEIBLK DFHCOMMAREA`, COMMAREA de longueur
  variable (`EIBCALEN`).
- Tests autofonce sur des sources traduits réels.

### T5 — Intégration au chargement
Trois options, à trancher après T3 :
1. Se présenter comme un programme C (stub C → module COBOL).
2. Se présenter comme du Micro Focus (wrapper `cob` + runtime remplaçant
   celui produit par `cicsmkcobol`).
3. Compiler directement la sortie de `cicstcl -l COBOL` si les points
   d'entrée appelés ne dépendent pas du runtime MF.
Dans tous les cas, c'est le point d'entrée « frontière » (voir T1) qui
associe la tâche CICS à un contexte GnuCOBOL.
Sémantique `EXEC CICS LINK` / `XCTL` / `RETURN` vs `CALL` / `CANCEL`.

### T6 — Chaîne de build
Enchaînement `cicstcl` → (précompilateur SQL : GixSQL, ocesql…) → `cobc`
→ installation dans la région. Wrapper ou Makefile type.

### T7 — Recette
Programmes de démonstration en région réelle, charge concurrente,
mesures de performance (comparaison avec la version non réentrante),
documentation utilisateur.

---

## Sous-planification de T1 — Runtime réentrant

### Le problème, constaté dans le code

**Code généré.** Pour un programme simple, `cobc` produit (dans `prog.c.l.h`) :
```c
static unsigned int  initialized = 0;
static cob_module   *module = NULL;
static int           b_2;                 /* RETURN-CODE */
static cob_u8_t      b_17[4];             /* X (WORKING-STORAGE) */
static cob_field     f_17 = {4, b_17, &a_2};
static cob_field     f_19 = {10, NULL, &a_1};  /* LINKAGE */
```
et le corps du programme accède à l'état global par
`cob_module_global_enter (&module, &cob_glob_ptr, ...)` puis
`cob_glob_ptr->...`. WORKING-STORAGE, `cob_field`, `cob_module` et
l'indicateur d'initialisation sont des variables statiques du module :
**une seule instance par processus**. Sous CICS, chaque tâche doit voir
sa propre WORKING-STORAGE, et deux tâches peuvent s'exécuter en même
temps.

Existant réutilisable : LOCAL-STORAGE et `IS RECURSIVE` /
`-fstack-on-heap` allouent déjà des données par invocation
(`cobc/codegen.c` : `output_local_storage_pointer`, chemins
`prog->flag_recursive` vers les lignes 2462, 2956-3053, 8342), et les
`cob_field` y sont déjà non statiques.

**libcob.** ~520 fonctions exportées (`COB_EXPIMP` dans `common.h`),
qui accèdent presque toutes à un état global implicite. Nombre de
variables `static` de fichier (approx.) : `common.c` 90, `fileio.c` 41,
`intrinsic.c` 32, `numeric.c` 24, `screenio.c` 24, `call.c` 22,
`move.c` 18, `termio.c` 13, `profiling.c` 11, `fbdb.c` 10, autres < 10.
L'état central est `static cob_global *cobglobptr` (`common.c:310`) plus
`cobsetptr`. Quelques variables utilisent déjà `COB_TLS`
(`libcob/coblocal.h`) dans `common.c` (l. 325-343), `strings.c`,
`fbdb.c` : elles seront déplacées dans le contexte.

Points non réentrants repérés : `qsort` avec état global
(`common.c:4655`, `screenio.c:3392`), `strtok` (`call.c`, `fileio.c`,
`screenio.c`), `localtime` (`common.c:5062`, `fileio.c`).

### Principes de conception

- **Un seul mode** : tout le code généré et tout libcob sont réentrants.
  Aucune option `cobc`, aucune préservation de l'ABI actuelle.
- **Contexte explicite** : le contexte d'exécution est passé **en
  premier argument** des fonctions, partout où c'est possible :
  - toutes les fonctions exportées de libcob :
    `cob_move (cob_context *ctx, cob_field *src, cob_field *dst)`,
    `cob_add (ctx, ...)`, `cob_open (ctx, ...)`, etc. ;
  - toutes les fonctions internes de libcob qui touchent un état ;
  - les fonctions C générées pour les programmes COBOL ;
  - les callbacks (tri : `qsort_r` ou tri interne recevant `ctx`).
- **TLS minimal** : un seul pointeur « contexte courant » en TLS, utilisé
  **uniquement aux frontières** où l'on ne peut pas recevoir `ctx` en
  argument :
  - point d'entrée appelé par du code non COBOL (C, hôte CICS, appels
    COBOL → C → COBOL) ;
  - handlers de signaux ;
  - callbacks de bibliothèques tierces sans argument utilisateur.
  Toute variable `COB_TLS` existante disparaît au profit du contexte.
  Objectif mesurable : un nombre de variables TLS ≤ 1 (ou très proche),
  vérifié par script.
- **Deux niveaux d'état** :
  - `cob_runtime` (processus) : réglages issus de runtime.cfg
    (`cobsetptr`), caches partagés (modules chargés), en lecture seule
    après initialisation ou protégés par verrou ;
  - `cob_context` (tâche / run unit) : `cob_global`, instances des
    programmes, fichiers ouverts, EXTERNAL, état CALL/CANCEL,
    RETURN-CODE, états des modules de libcob (sous-structures par
    fichier : `ctx->fileio`, `ctx->intrinsic`, …), pointeur vers le
    `cob_runtime`.
- **Instance de programme** : toutes les données mutables d'un programme
  (storage WS, `cob_field` vers la WS, `cob_module`, `initialized`,
  `last_b_*`…) sont regroupées dans une structure allouée par contexte
  au premier appel. Les données immuables (attributs `a_*`, constantes,
  tables de noms et de hash) restent `static const` partagées.
- **Une tâche active dans un seul thread à la fois** : pas de verrou sur
  le contexte lui-même.

### Questions ouvertes (étape T1.0)

| Question | Proposition |
|----------|-------------|
| Signature des points d'entrée générés | Un seul symbole `PROG`, signature inchangée ; le contexte est lu en TLS à l'entrée (dans `cob_module_global_enter`), puis passé explicitement. La détection « appelé par C ou COBOL » (`cob_call_name_hash`) est conservée. |
| `CALL` dynamique | Inchangé (résolution de `NAME`, sous verrou de `rt`). |
| `CALL` statique | Inchangé. |
| `cob_field` vers la WS | Copies par instance (simple) ou base + offset calculé (moins de mémoire) — à mesurer. |
| Accès à l'instance dans le code généré | Recherche dans `ctx` par clé de module à l'entrée du programme, puis pointeur local `inst` passé aux sections/paragraphes et programmes imbriqués. |
| EXTERNAL | Par contexte (comme une run unit Micro Focus sous CICS) ; à confirmer en T3. |
| CANCEL / IS INITIAL | Agissent sur l'instance du contexte courant uniquement. |
| API C publique (`cobcapi.c`, `cob_resolve`, `cob_call`, `cob_get_*`…) | Toutes prennent `ctx` en premier argument. |
| Programme principal (`cobc -x`) | `main` généré : `cob_runtime_init` + `cob_context_create`, appel du programme, `cob_context_destroy`. |
| Plateformes | Linux/GCC en premier ; Windows et AIX à garder compilables (le peu de TLS restant passe par `COB_TLS`). |

Décidé le 2026-10-28, puis révisé le même jour : on garde un seul point
d'entrée par programme et le mécanisme actuel de détection C / COBOL
(voir `TXSERIES-T1-DESIGN.md` §4.1). L'idée de deux points d'entrée
`PROG__ctx` / `PROG` est abandonnée.

### Impact sur le schéma de compilation

La chaîne ne change pas (`cobc` → C → compilateur C → `.so` / exécutable,
mêmes options), mais la forme du C généré change en profondeur. Aujourd'hui
`prog.c.l.h` est inclus *dans* la fonction `PROG_` et toutes les données du
programme y sont des `static` locales à la fonction ; `frame_stack` et
`cob_procedure_params` sont déjà de vraies variables locales (pile).

Schéma cible pour le programme d'exemple :

```c
/* prog.c.h : niveau fichier */
static const cob_field_attr a_2 = {...};          /* inchangé : immuable */
struct P_instance {                                /* NOUVEAU : état mutable */
  cob_module      module;
  unsigned int    initialized;
  int             b_2;                             /* RETURN-CODE */
  cob_u8_t        b_17[4] __attribute__((aligned));/* X */
  cob_u8_t        b_18[10];                        /* Y */
  cob_field       f_17, f_19;
  unsigned char  *last_b_19;
};
static const cob_instance_key P_key = { "P", sizeof (struct P_instance),
                                        P_instance_init, P_instance_free };

/* prog.c */
int P (cob_u8_t *b_19)                             /* inchangé */
{ return P_ (0, b_19); }

static int P_ (const int entry, cob_u8_t *b_19)
{
  cob_context *ctx;                                /* contexte du thread (TLS) */
  struct P_instance *inst;
  if (cob_module_global_enter (&ctx, &P_desc, &P_slot, &inst, entry, st_name_hash))
    return -1;
  if (ctx->glob.cob_call_name_hash != 0xE9F5BD10)  /* détection C/COBOL inchangée */
  ...
  cob_add_int (ctx, &inst->f_17, 1, 0);
  memmove (inst->b_18, inst->f_19.data, 10);
  cob_display (ctx, 0, 1, 1, &inst->f_17);
}
```

Conséquences pour `cobc/codegen.c` :

1. **Déclarations** : les données mutables (WS, FD, REPORT, SCREEN,
   registres spéciaux, `cob_field` non constants, `module`,
   `initialized`, `last_b_*`, pointeurs EXTERNAL) passent de `static`
   locales à des membres de `struct PROG_instance` au niveau fichier ;
   attributs, littéraux et tables restent `static const`.
2. **Références** : `b_N` → `inst->b_N`, `&f_N` → `&inst->f_N`. Les
   noms sont produits par quelques fonctions centrales de `codegen.c`
   (`output_base`, `output_param`…), le changement y est concentré.
3. **Initialisation** : les `cob_field` dont `data` pointe dans la WS ne
   peuvent plus être initialisés statiquement : fonction
   `PROG_instance_init` générée (ou table const de gabarits
   {taille, offset, attr} recopiée à l'allocation).
4. **Appels libcob** : `ctx` ajouté en premier argument de chaque appel
   généré.
5. **Points d'entrée** : inchangés (un symbole par `ENTRY`, même
   signature). `cob_module_global_enter` obtient le contexte courant
   (TLS) et l'instance ; la détection « appelé par C ou par COBOL » via
   `cob_call_name_hash` / `cob_call_params` est conservée, sur
   `ctx->glob`.
6. **CALL** : inchangé (statique et dynamique) ; l'appelant positionne
   `ctx->glob.cob_call_name_hash` / `cob_call_params` comme aujourd'hui.
7. **CANCEL / IS INITIAL** : libère / réinitialise l'instance dans
   `ctx` (le callback `PROG_ (-1)` actuel reste pour fermer les fichiers).
8. **Programmes imbriqués** : les éléments GLOBAL du parent étaient des
   `static` visibles directement ; il faut désormais le pointeur vers
   l'instance du parent (passé en argument ou retrouvé dans `ctx`).
9. **RECURSIVE / LOCAL-STORAGE** : déjà alloués par invocation, peu de
   changement ; la WS d'un programme RECURSIVE est simplement dans
   l'instance.
10. **Programme principal (`cobc -x`)** : `main` crée runtime et
    contexte. **Code C appelant du COBOL** (`cob_init` + `PROG (...)`) :
    doit créer un contexte et le rendre courant — à documenter.
11. **Version d'ABI** : `cob_check_version` (constructeur de module) doit
    refuser les modules compilés avec l'ancien schéma.
12. **Performance** : une indirection par `inst` (gardée en registre par
    le compilateur C) et un argument de plus par appel ; à mesurer en
    T1.7, comparé à l'alternative « base + offset » pour les champs.

### Étapes

**T1.0 — Conception (document court)**
- Trancher les questions ci-dessus.
- Spécifier l'API : `cob_runtime_init`, `cob_context_create`,
  `cob_context_destroy`, `cob_context_set_current` (frontières),
  structure des sous-états par fichier de libcob.
- Livrable : section « design » ajoutée à ce fichier.

**T1.1 — Inventaire classé de l'état global de libcob**
- Lister chaque variable `static` / globale / `COB_TLS` de `libcob/*.c`
  et la classer :
  1. constante après initialisation → `cob_runtime`, lecture seule ;
  2. état de tâche → `cob_context` (sous-structure du fichier) ;
  3. cache partagé (modules chargés par `call.c`, handles dl, tables
     de hash…) → `cob_runtime` + verrou ;
  4. purement processus (signaux, atexit) → relève de T2.
- Lister les appels libc non réentrants et les callbacks sans argument
  utilisateur.
- Livrable : tableau d'inventaire (fichier, variable, classe, action).
- Outil : script `nm` sur `libcob.so` (symboles en `.data`, `.bss`,
  `.tbss`) rejouable en CI ; il servira aussi à vérifier le résultat
  final (aucune donnée mutable globale hors liste blanche).

**T1.2 — Squelette : `cob_runtime`, `cob_context` et passage de `ctx`**
- Créer les structures et l'API de T1.0.
- Ajouter `cob_context *ctx` en premier argument des fonctions générées
  et de toutes les fonctions exportées de libcob, avec mise à jour de
  `codegen.c` dans le même commit. À ce stade `ctx` peut encore pointer
  vers un état global unique : on change les signatures d'abord, l'état
  ensuite.
- Remplacer `cob_module_global_enter (&module, &cob_glob_ptr, ...)` par
  une fonction qui prend `ctx`.
- Toute la suite de tests doit passer.

**T1.3 — Migration de l'état de libcob dans le contexte**
- Fichier par fichier, déplacer les variables de classe 2 dans la
  sous-structure de `ctx` et celles de classe 1 dans `cob_runtime` ;
  propager `ctx` aux fonctions internes concernées.
- Ordre : `common.c`, `call.c`, `numeric.c`, `move.c`, `intrinsic.c`,
  `strings.c`, `fileio.c` (et backends), `termio.c`, `screenio.c`,
  `reportio.c`, `mlio.c`, `profiling.c`, `cobcapi.c`.
- Supprimer les `COB_TLS` existants.
- Toute la suite de tests passe après chaque fichier.

**T1.4 — Caches partagés et thread-safety**
- Verrous autour des caches de classe 3, en particulier la résolution
  dynamique des `CALL` et la table des modules dans `call.c`.
- Remplacer `strtok` → `strtok_r`, `localtime` → `localtime_r`,
  `qsort` → `qsort_r` (ou tri interne), revoir `getenv`/`setenv`,
  `setlocale`, `rand`.
- Bibliothèques tierces : GMP (ok si objets séparés), backends ISAM /
  BDB / LMDB / ODBC, ncurses (déclaré non supporté en multi-thread).
- Ajouts issus de l'inventaire (`TXSERIES-T1-INVENTORY.md`) :
  - réglages runtime copiés par contexte (`ctx->set`), car réécrits en
    cours d'exécution ;
  - locale par contexte : `newlocale` / `uselocale` et variantes `_l` ;
  - environnement COBOL par contexte (surcharges `setenv` dans `ctx`) ;
  - verrous d'enregistrements : `F_OFD_SETLK` ou table de verrous
    interne (les verrous `fcntl` classiques sont par processus) ;
  - BDB `DB_THREAD` + un locker par tâche, cache d'environnements LMDB
    par chemin, connexions ODBC/OCI par tâche, mutex global pour les
    ISAM non thread-safe, libltdl sous verrou.

**T1.5 — Code généré : instances de programme par contexte**
- Générer une structure d'instance par programme, allouée dans `ctx` au
  premier appel, et passer `inst` dans le code du programme.
- `cob_module_global_enter` : obtenir le contexte courant et
  l'instance ; garder la détection C / COBOL existante.
- Partir des chemins `flag_recursive` / `cb_flag_stack_on_heap`
  existants pour les `cob_field` non statiques.
- Traiter : WORKING-STORAGE, FILE SECTION (FD), REPORT, SCREEN,
  registres spéciaux, `initialized`, `module`, programmes imbriqués,
  `ENTRY` multiples, `IS INITIAL`, `CANCEL`, EXTERNAL.

**T1.6 — Banc de test réentrance (hôte simulé)**
- Un petit hôte C (dans `tests/`) qui simule `cicsas` : crée N contextes,
  appelle les mêmes programmes depuis plusieurs contextes en séquence
  puis depuis plusieurs threads en parallèle, vérifie l'isolation des
  WORKING-STORAGE, détruit les contextes.
- Nouveaux tests autofonce : isolation WS, `IS INITIAL` / `CANCEL` par
  contexte, fichiers ouverts dans deux contextes, `CALL` dynamique
  concurrent, COBOL → C → COBOL (frontière TLS), EXTERNAL.
- Exécution sous ThreadSanitizer et Valgrind/ASan (fuites à la
  destruction d'un contexte).
- Script de contrôle : pas de donnée mutable globale ni de TLS hors
  liste blanche dans `libcob.so` et dans le code généré.

**T1.7 — Performances**
- Comparer avec la version actuelle (non réentrante) sur quelques
  benchmarks ; optimiser les points chauds (accès à l'instance,
  indirections).

### Ordre et jalons

1. **J1** : T1.0 + T1.1 (conception + inventaire) — pas de code de
   production, permet de chiffrer précisément la suite.
   T1.1 fait le 2026-10-28 : `TXSERIES-T1-INVENTORY.md`, script
   `build_aux/list-mutable-globals.sh`.
   T1.0 rédigé (brouillon à valider) le 2026-10-28 :
   `TXSERIES-T1-DESIGN.md`, et `TXSERIES-T1-EXTERNALS.md` pour les
   fonctions externes.
2. **J2 (T1.2) fait le 2026-10-29** : `cob_runtime` / `cob_context`
   (contexte courant en TLS, `cob_module_global_enter` le rend au
   programme), ~400 fonctions exportées prennent `ctx` en premier
   argument, `cobc` le passe (table `ctx_functions` dans codegen.c) ;
   suite de tests sans régression. Exceptions listées dans
   `TXSERIES-T1-DESIGN.md` §10 bis ; 882 `COB_CTX_TODO` restent pour
   T1.3.
   Puis, le même jour : les fonctions qui prennent le contexte sont
   renommées `NOM_ctx`, les anciens noms restent pour la compatibilité
   (sources, et binaire en mode un seul contexte ; DESIGN §5).
   (J2 : T1.2 — `ctx` passé partout (changement d'ABI), état encore
   unique.)
3. **J3 (T1.3) en cours** : 2026-10-31, `ctx` propagé aux fonctions
   internes de libcob (`COB_CTX_TODO` : 883 → 102, voir DESIGN §10 bis).
   Puis : API interne des gestionnaires de fichiers avec `ctx`
   (`COB_CTX_TODO` → 43) ; état de `strings.c` et état thread-local de
   `common.c` dans le contexte ; collation BDB dans `app_private`.
   **Le seul TLS restant dans libcob est `cob_current_context`.**
   Puis : les copies par fichier du pointeur global (`cobglobptr`,
   `file_globptr`…) remplacées par `ctx->glob`, et celles du pointeur
   de réglages par `ctx->settings` (encore partagé : copie par contexte
   à faire). Puis l'état de `numeric.c`, `intrinsic.c`, `reportio.c`,
   `termio.c`, `cobcapi.c`, `fextfh.c`, `profiling.c` dans le contexte
   (une structure opaque par fichier). Variables globales modifiables :
   362 au départ, 247 restent (2026-11-01). Puis `fileio.c`, état de
   « run unit » de `common.c` (modules, EXTERNAL, SWITCH, trace…),
   constantes (tables de configuration, `fsqlxfd.c`…), et le script
   ignore `.data.rel.ro` : 187 restent. Ce qui reste demande surtout des
   décisions de T1.4 / T2 : table des modules (`call.c`, verrou),
   backends (BDB, LMDB, ODBC), terminal (`screenio.c`), réglages par
   contexte, état lié aux signaux et à STOP RUN, tampons de retour
   statiques, constantes calculées → `cob_runtime`.
   Reste : statiques de `common.c` (97), `fileio.c` (34), `screenio.c`
   (27, terminal unique), `fsqlxfd.c` (20), `call.c` (14), `fbdb.c`… ; réglages par
   contexte (et `cobsetptr` de `common.c`) ; callbacks de tri ; état
   des fonctions de niveau processus → `cob_runtime`.
3. **J3** : T1.3 + T1.4 — libcob sans état global mutable, thread-safe.
4. **J4** : T1.5 + T1.6 — instances de programme par contexte, banc de
   test multi-thread.
5. **J5** : T1.7 — mesures et optimisations.

### Risques

- Volume du changement de signature (~520 fonctions exportées + tous les
  appels générés) → le faire tôt (J2), de manière mécanique, et séparé
  de la migration d'état.
- Volume de l'état global plus grand que prévu (backends de fichiers,
  screenio) → limiter le périmètre multi-thread au début (screenio exclu).
- Extensions et code C utilisateur appelant libcob (`cobcapi.c`, C
  appelé par `CALL`) : tous doivent être adaptés au nouveau `ctx`.
- Divergence forte avec l'amont GnuCOBOL (changement d'ABI) → découper
  en commits mécaniques et lisibles, pour faciliter les fusions.
