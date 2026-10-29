# T1.0 — Conception du runtime réentrant

État : brouillon, 2026-10-28. S'appuie sur `TXSERIES-PLAN.md` (T1),
`TXSERIES-T1-INVENTORY.md` (état global de libcob) et
`TXSERIES-T1-EXTERNALS.md` (fonctions externes).

## 1. Objectifs et contraintes

- Plusieurs **contextes** (une tâche CICS = une run unit COBOL) coexistent
  dans un même processus ; plusieurs peuvent être actifs en même temps,
  chacun dans un thread. Un contexte n'est actif que dans un thread à la
  fois, mais peut changer de thread entre deux activations.
- **Un seul mode** de compilation et de runtime, **pas de compatibilité
  ascendante** (ABI de libcob et code généré libres ; recompilation
  obligatoire).
- **Contexte explicite** : `cob_context *ctx` en premier argument de
  toute fonction qui touche un état.
- **TLS minimal** : un seul pointeur TLS, « contexte courant », utilisé
  uniquement aux frontières (§6).
- **Pas de donnée globale modifiable** dans libcob ni dans le code
  généré, hors d'une liste blanche vérifiée par
  `build_aux/list-mutable-globals.sh`.

## 2. Deux niveaux d'état

```
          processus                         tâche (run unit)
 ┌──────────────────────────┐      ┌───────────────────────────────┐
 │ cob_runtime  (rt)        │◄─────┤ cob_context  (ctx)            │
 │  réglages initiaux       │  1:N │  glob : cob_global            │
 │  table des modules (CALL)│      │  set  : copie des réglages    │
 │  slots d'instances       │      │  instances de programmes      │
 │  caches (BDB/LMDB env…)  │      │  EXTERNAL, env COBOL, locale  │
 │  verrous                 │      │  états des fichiers de libcob │
 └──────────────────────────┘      └───────────────────────────────┘
```

### 2.1 `cob_runtime`

Créé une fois par processus, détruit à la fin du processus (ou par
l'hôte). Contenu :

| Champ | Contenu | Accès |
|---|---|---|
| `set0` | réglages lus dans runtime.cfg et l'environnement à l'init | lecture seule |
| `locale0` | `locale_t` initial (issu de l'environnement) | lecture seule |
| messages traduits | textes des signaux, `*_msgid` (pas de gettext dans un handler) | lecture seule |
| constantes calculées | puissances de 10 GMP, pi, sqrt 2, log… (calculées à l'init, plus de calcul paresseux) | lecture seule |
| `modules` | table des modules chargés : nom, handle, symboles, compteur de références | `lock_modules` |
| `slots` | compteur d'attribution des slots d'instance (§4.2) | atomique |
| `io_modules` | backends de fichiers chargés (`io_rtns`, `fileio_funcs`) | chargés à l'init, puis lecture seule |
| caches de backends | environnements BDB / LMDB par chemin, environnement ODBC | verrou par backend |
| `file_locks` | table interne des verrous d'enregistrements (§8) | `lock_files` |
| `temp_counter` | compteur pour les noms temporaires | atomique |
| `screen_owner` | contexte propriétaire du terminal curses | `lock_screen` |

Verrous : un mutex par ressource, jamais deux tenus en même temps sauf
dans l'ordre `lock_modules` → `lock_files` → verrous de backends
(à documenter dans le code).

### 2.2 `cob_context`

```c
struct cob_context {
	cob_runtime		*rt;
	cob_global		 glob;		/* ex-*cobglobptr, embarqué */
	cob_settings		 set;		/* copie de rt->set0, modifiable */

	/* instances de programmes */
	void			**inst;		/* indexé par slot (§4.2) */
	unsigned int		  inst_size;

	/* état COBOL de la run unit */
	struct cob_external	*externals;
	struct cob_env_overlay	*env;		/* surcharges d'environnement (§7.2) */
	locale_t		  locale;	/* locale de la tâche (§7.1) */
	int			  argc;		/* défaut : rt, surchargeable */
	char			**argv;

	/* états des modules de libcob, alloués à la demande */
	struct cob_common_state	*common;
	struct cob_call_state	*call;
	struct cob_numeric_state *numeric;	/* pool de décimaux, temporaires GMP */
	struct cob_intr_state	*intr;		/* anneau des résultats, temporaires */
	struct cob_strings_state *strings;
	struct cob_fileio_state	*fileio;	/* fichiers ouverts, journal… */
	struct cob_report_state	*report;
	struct cob_mlio_state	*mlio;
	struct cob_prof_state	*prof;
	struct cob_screen_state	*screen;	/* non NULL seulement si propriétaire du terminal */
	struct cob_backend_state *backend[COB_IO_MAX];	/* connexion ODBC/OCI, locker BDB… */

	/* frontière / sortie (T2) */
	struct cob_exit_hooks	*exit;		/* STOP RUN, erreur fatale → retour à l'hôte */
	jmp_buf			*return_jmp;
};
```

- Les sous-structures `cob_xxx_state` sont **opaques** : définies
  uniquement dans le fichier `.c` correspondant, allouées à la première
  utilisation par une fonction `cob_xxx_state_get (ctx)` (inline : test
  de NULL), libérées par `cob_xxx_state_free (ctx)` appelé à la
  destruction du contexte.
- `glob` est embarqué (pas de pointeur) : le code généré y accède
  directement (`ctx->glob.cob_call_params`…). Seuls `rt`, `glob` et
  `inst` sont utilisés par le code généré ; le reste est privé à libcob.
- La définition publique (`common.h`) expose le début de la structure ;
  la définition complète est dans `coblocal.h`. Les deux sont générées
  depuis une même source pour rester alignées (ou : la partie publique
  est le premier membre `struct cob_context_public pub`).

## 3. API publique

```c
/* processus */
cob_runtime *cob_runtime_init (int argc, char **argv, const struct cob_runtime_options *opts);
void         cob_runtime_finish (cob_runtime *rt);

/* tâche */
cob_context *cob_context_create (cob_runtime *rt);
void         cob_context_destroy (cob_context *ctx);   /* ferme fichiers, libère instances */

/* frontière (TLS) */
cob_context *cob_context_enter (cob_context *ctx);     /* rend courant dans ce thread, applique la locale ; renvoie le précédent */
void         cob_context_leave (cob_context *prev);    /* restaure le précédent */
cob_context *cob_get_current_context (void);           /* NULL si aucun */
```

- `cob_runtime_options` : chemin de runtime.cfg, installation ou non des
  handlers de signaux (T2), hooks de sortie (T2), mode « un seul
  contexte » pour les exécutables classiques.
- `cob_init (argc, argv)` disparaît ; le `main` généré par `cobc -x`
  devient :

```c
int main (int argc, char **argv)
{
	cob_runtime *rt  = cob_runtime_init (argc, argv, NULL);
	cob_context *ctx = cob_context_create (rt);
	cob_context *prev = cob_context_enter (ctx);
	int ret = PROG (...);
	cob_context_leave (prev);
	cob_context_destroy (ctx);
	cob_runtime_finish (rt);
	return ret;
}
```

- Hôte multi-tâches (cicsas simulé, futur T5) : un `rt` ; par tâche
  `create` → `enter` → appel → `leave` → `destroy` (ou contexte conservé
  entre deux activations pseudo-conversationnelles si besoin).

## 4. Code généré

### 4.1 Points d'entrée : un seul, comme aujourd'hui (révisé le 2026-10-28)

Le mécanisme actuel est **conservé** : c'est le programme qui devine s'il
est appelé depuis C ou depuis COBOL, en comparant
`cob_call_name_hash` (positionné par l'appelant COBOL, remis à 0 par
l'API C `cob_call` & co.) au hash de ses noms d'entrée, et le nombre de
paramètres reste transmis dans `cob_call_params`. Seul l'endroit où
sont rangés ces champs change : `ctx->glob` au lieu de `*cobglobptr`.

Pour chaque `PROGRAM-ID` / `ENTRY` `P` :
- un seul symbole exporté, `int P (args...)`, **signature inchangée** ;
- à l'entrée, le programme obtient le contexte du thread, là où il
  obtient aujourd'hui le pointeur global :
```c
int P (cob_u8_t *b_19)
{
	return P_ (0, b_19);
}
static int P_ (const int entry, cob_u8_t *b_19)
{
	cob_context *ctx;
	...
	if (cob_module_global_enter (&ctx, &P_desc, &P_slot, &inst, entry, st_name_hash))
		return -1;
	/* ensuite : ctx et inst passés explicitement partout */
	if (ctx->glob.cob_call_name_hash != 0xE9F5BD10) {
		ctx->glob.cob_call_from_c = 1;	/* Called by C */
	...
```
- `cob_module_global_enter` lit le contexte courant (TLS), échoue avec
  une erreur runtime explicite s'il n'y en a pas, puis fait ce qu'il fait
  aujourd'hui (pile de modules, compteur de paramètres) et rend
  l'instance (§4.2).

Coût : une lecture TLS par entrée de programme, à la place de l'appel
actuel qui renvoie le pointeur global ; négligeable devant le coût d'un
`CALL`. À l'intérieur du programme et dans libcob, `ctx` est ensuite
toujours passé en premier argument.

Alternative écartée : deux points d'entrée `P__ctx (ctx, …)` / `P (…)`.
Elle évitait la lecture TLS, mais changeait le mécanisme de détection
C / COBOL, doublait les symboles exportés et compliquait le `CALL`
dynamique (deux ABI à mémoriser).

### 4.2 Instances de programmes

- Chaque programme a un descripteur statique constant et un slot :
```c
static const cob_program_desc P_desc = {
	"P", sizeof (struct P_instance), P_instance_init, P_instance_free, P_cancel
};
static unsigned int P_slot;	/* liste blanche : écrit une seule fois, atomiquement */
```
- `P_slot` est attribué au premier appel (dans n'importe quel contexte)
  par `cob_program_slot (rt, &P_slot)` : compare-and-swap sur un
  compteur de `rt`. C'est la seule donnée modifiable du code généré, et
  elle est identique pour tous les contextes (pas d'état de tâche).
- Accès en tête de `P_` :
```c
struct P_instance *inst = (P_slot && P_slot < ctx->inst_size && ctx->inst[P_slot])
	? ctx->inst[P_slot] : cob_program_instance (ctx, &P_desc, &P_slot);
```
  Chemin rapide : deux tests et une indirection. `cob_program_instance`
  attribue le slot si besoin, agrandit `ctx->inst`, alloue et initialise
  l'instance.
- Contenu de `struct P_instance` : `cob_module`, `initialized`, WS,
  FILE SECTION, REPORT, SCREEN, registres spéciaux, `cob_field`
  modifiables, pointeurs `d0..dN` vers les décimaux, `prof_info`,
  pointeurs EXTERNAL, `last_b_*`, LINKAGE hors USING.
- Reste `static const` : attributs, littéraux, tables de noms, hash,
  `cob_module_path`, descripteurs.
- `cob_field` vers la WS : **copies par instance**, initialisées par
  `P_instance_init` depuis une table constante de gabarits
  `{taille, offset dans l'instance, attr}`. L'alternative base + offset
  sera mesurée en T1.7.
- Programmes imbriqués : chaque programme imbriqué a sa propre instance ;
  l'accès aux éléments GLOBAL du parent passe par un pointeur
  `parent_inst` obtenu par le slot du parent (même mécanisme).
- `CANCEL` : `cob_cancel (ctx, name)` appelle `P_cancel (ctx, inst)`
  (fermeture des fichiers) puis libère l'instance du contexte.
  `IS INITIAL` : réinitialisation de l'instance à chaque entrée.
- LOCAL-STORAGE et RECURSIVE : inchangés (alloués par invocation).

### 4.3 CALL

Inchangé dans son principe : l'appelant positionne
`ctx->glob.cob_call_name_hash` et `ctx->glob.cob_call_params`, puis
appelle `NAME (args)`, statiquement ou via le pointeur résolu. Le
contexte courant du thread est déjà le bon (un `CALL` ne change pas de
thread), il n'y a rien à positionner autour de l'appel. Les fonctions C
appelées peuvent rappeler du COBOL ou l'API C de libcob sans rien faire
de spécial.

- Dynamique : `cob_resolve (ctx, name)` ; la résolution (dlopen/dlsym)
  se fait sous `rt->lock_modules`, le résultat est mis en cache dans
  `ctx->call` pour éviter le verrou aux appels suivants.
- Routines système CBL_* : appelées comme aujourd'hui ; leur
  implémentation dans libcob obtient le contexte courant à l'entrée,
  comme un programme.

## 5. Conventions dans libcob

**Noms `_ctx` et compatibilité (décidé le 2026-10-29).** Une fonction qui
prend le contexte s'appelle `NOM_ctx (cob_context *ctx, ...)` ; l'ancien
nom `NOM (...)` est conservé avec sa signature d'origine et appelle
`NOM_ctx (COB_CTX_COMPAT, ...)`, c'est-à-dire avec le contexte courant
du thread. Conséquences :
- compatibilité des sources : le code C utilisateur, `cobcapi.h`,
  `cobcrun`, `cobfile` et les tests en C sont inchangés ;
- compatibilité binaire en mode « un seul contexte » : un module compilé
  par un ancien `cobc` appelle les anciens noms (y compris
  `cob_module_global_enter`) et fonctionne (vérifié avec des modules
  compilés au commit `9b07acac`) ; il n'est pas réentrant (WORKING-STORAGE
  en `static`) : `COB_CTX_COMPAT` devra lever une erreur quand plusieurs
  contextes sont utilisés (T1.5) ;
- le code généré et libcob n'appellent que les noms `_ctx` (vérifié par
  script : aucun appel interne aux anciens noms) ;
- les fonctions de compatibilité sont placées juste après la fonction
  `_ctx` correspondante (même bloc `#ifdef`) ; pour une fonction
  variadique, le corps est dans `static NOM_va_ctx (..., va_list)` (les
  `va_start` y deviennent des `va_copy`), appelé par `NOM_ctx` et par
  `NOM` ;
- les fonctions auxiliaires générées par `codeoptim.c` gardent leur nom
  (table `ctx_helpers` de codegen.c).

- Toute fonction exportée qui touche un état : `ctx` en premier
  paramètre. Les fonctions pures (conversion sans état, comparaison de
  champs sans collating…) peuvent ne pas le prendre ; à décider fonction
  par fonction lors de T1.2, en préférant **le prendre** en cas de doute
  (paramètre ignoré bon marché, évite de changer l'API plus tard).
- Fonctions internes : idem, `ctx` en premier.
- Allocations : `cob_malloc` / `cob_free` restent sans contexte
  (malloc/free) ; ce qui doit être libéré à la destruction du contexte
  est rattaché à une sous-structure de `ctx`.
- Messages d'erreur : `cob_runtime_error (ctx, fmt, ...)`.
- Plus de copies `cobglobptr`/`cobsetptr` dans les fichiers ; les
  macros de `coblocal.h` (`COB_MODULE_PTR`…) prennent `ctx`
  (`COB_MODULE_PTR(ctx)` → `(ctx)->glob.cob_current_module`).
- Les callbacks de bibliothèques tierces qui ont un argument utilisateur
  reçoivent `ctx` (ou une structure qui le contient) : SAX libxml2,
  comparateurs BDB (`db->app_private`), tri.
- Exception assumée au « `ctx` en premier argument » : les fonctions C
  générées pour les programmes COBOL gardent leur signature (§4.1).
- Ajout de `ctx` dans le code généré : `output_funcall` (codegen.c)
  l'insère pour les fonctions de la table `ctx_functions` ; pendant la
  migration fichier par fichier, la table liste les fonctions converties.
  À la fin, règle « toute fonction `cob_` », **sauf** les fonctions
  auxiliaires `cob_add_*`, `cob_sub_*`, `cob_cmp_*`… que `codeoptim.c`
  génère dans le programme : elles prennent `ctx` seulement si elles
  appellent libcob (`cob_add_int`, `cob_get_int`).
- Dans libcob, un appel à une fonction convertie depuis une fonction qui
  n'a pas encore `ctx` utilise `COB_CTX_TODO` (lecture du contexte
  courant) ; toutes ces occurrences doivent avoir disparu à la fin de
  T1.3 (compte suivi par `grep -c COB_CTX_TODO`).
- Les modules compilés avec un ancien `cobc` (y compris
  `extras/*.so`, que `make` ne recompile pas) plantent au lieu d'être
  refusés : la vérification de version d'ABI (§9) est à faire tôt.
- Tri : implémentation interne (fusion) prenant `ctx` et l'état du tri,
  au lieu de `qsort` / `qsort_r` (signatures incompatibles entre glibc,
  BSD et Windows).

## 6. Frontières et TLS

Une seule variable TLS dans libcob : `cob_current_context`
(`COB_TLS cob_context *`). Elle est lue uniquement par :
1. l'entrée de chaque programme COBOL (`cob_module_global_enter`, §4.1)
   et des routines CBL_* ;
2. les points d'entrée C publics sans `ctx` qui doivent subsister
   (`EXTFH`, éventuels points d'entrée appelés par un hôte) ;
3. les handlers de signaux (T2) ;
4. les callbacks sans argument utilisateur (CBL_EXIT_PROC,
   CBL_ERROR_PROC, `ioversion`…).

Elle est écrite uniquement par `cob_context_enter` / `cob_context_leave`.
Les anciens `COB_TLS` (`strings.c`, `common.c`, `fbdb.c`) disparaissent.

## 7. Ressources globales au processus

### 7.1 Locale
- `setlocale` appelé une seule fois, dans `cob_runtime_init`.
- Chaque contexte a son `locale_t` (créé par `newlocale` /
  `duplocale`) ; `SET LOCALE` modifie `ctx->locale`.
- `cob_context_enter` fait `uselocale (ctx->locale)` (par thread, géré
  par la libc — ce n'est pas un TLS de libcob) : les fonctions
  dépendantes de la locale (`strcoll`, `strftime`, `toupper`, `isprint`,
  `strtod`…) suivent alors la locale de la tâche sans les réécrire.
- `localeconv` et `nl_langinfo` sont remplacés par
  `nl_langinfo_l (…, ctx->locale)` (`localeconv` rend un tampon statique).
- Windows : `_configthreadlocale (_ENABLE_PER_THREAD_LOCALE)` + `setlocale`
  à l'entrée, ou `_create_locale` et fonctions `_l`.

### 7.2 Environnement
- libcob n'appelle plus jamais `setenv` / `putenv` / `unsetenv` après
  l'init : `getenv` devient alors sûr.
- `DISPLAY … UPON ENVIRONMENT-VALUE`, `cob_putenv` : écrivent dans
  `ctx->env` (surcharges, y compris suppressions).
- `cob_getenv (ctx, name)` : surcharge de `ctx->env`, sinon `getenv`.
- Processus fils (`CALL "SYSTEM"`, fichiers pipe, `DISPLAY UPON` pipe) :
  environnement construit depuis `environ` + `ctx->env`, passé à
  `posix_spawn`.
- Les variables `COB_*` sont lues une fois à l'init dans `rt->set0` ;
  `cob_rescan_env_vals` ne met à jour que `ctx->set`.
- foci.c : identifiants Oracle passés par les paramètres de connexion
  OCI, plus par `putenv`.

### 7.3 Répertoire courant
- `CBL_CHANGE_DIR` (`chdir`) change le répertoire de tout le processus.
  Proposition : `ctx->cwd` (chemin) ; les chemins de fichiers relatifs
  sont résolus par libcob contre `ctx->cwd`. En mode « un seul
  contexte », on garde `chdir` en plus pour les programmes C appelés.

### 7.4 Processus fils
- `fork` + `execv` / `system` / `popen` → `posix_spawn` (sûr dans un
  processus multi-thread, ne touche pas aux dispositions des signaux du
  processus, permet de passer l'environnement de la tâche).

### 7.5 Signaux, sortie, minuteries (détail en T2)
- `signal` → `sigaction` ; `sigprocmask` → `pthread_sigmask`.
- Attente de verrou avec `alarm` + `SIGALRM` (fileio.c:3051-3077) :
  minuterie et handler globaux au processus → remplacée par une boucle
  `F_SETLK` + `nanosleep` jusqu'au délai.
- `exit` / `STOP RUN` / erreurs fatales : retour à l'hôte via
  `ctx->exit` (T2).

## 8. Fichiers

- État des fichiers ouverts dans `ctx->fileio` ; à la destruction du
  contexte, fermeture de tous ses fichiers (comportement de fin de run
  unit).
- **Verrous d'enregistrements** : les verrous `fcntl` classiques sont par
  processus. Choix :
  - Linux : `F_OFD_SETLK` / `F_OFD_GETLK` (verrous par description de
    fichier ouvert : chaque `open` d'une tâche est distinct) ;
  - en plus, table interne `rt->file_locks` (clé : périphérique +
    inode + offset) pour les plateformes sans OFD et pour connaître la
    tâche propriétaire (statut 51 / `blockpid` → identifiant de tâche).
- Backends :
  - BDB : environnement partagé dans `rt`, ouvert avec `DB_THREAD` ; un
    locker (`lock_id`) par contexte ; collating via `db->app_private` ;
  - LMDB : environnements dans `rt`, un par chemin, compteur de
    références, `MDB_NOTLS` ; transactions par contexte ;
  - ODBC : handle d'environnement dans `rt`, connexion et curseurs par
    contexte ;
  - OCI : `OCI_THREADED`, environnement dans `rt`, session par contexte ;
  - ISAM (C-ISAM, D-ISAM, VBISAM) : si la bibliothèque n'est pas
    thread-safe (`iserrno` global), mutex global autour de chaque appel
    ISAM + copie de `iserrno` sous le mutex (voir EXTERNALS).
- Chargement des backends : tous ceux configurés sont chargés dans
  `cob_runtime_init` ; plus de chargement paresseux en cours d'exécution.
- Noms temporaires : pid + compteur atomique de `rt` + identifiant de
  contexte.

## 9. Divers

- **EXTERNAL** : par contexte (`ctx->externals`), à confirmer en T3.
- **Décimaux** : pool par contexte (`ctx->numeric`) ; les pointeurs
  `d0..dN` d'un programme sont dans son instance. État survivant entre
  appels (`cob_d_remainder`, `move_field`, `cob_not_finite`) dans
  `ctx`, ou transformé en paramètre quand c'est simple.
- **Intrinsèques** : anneau de résultats dans `ctx->intr` (durée de vie
  inchangée : 32 appels).
- **Aléatoire** : `gmp_randstate_t` par contexte ; plus de `rand` /
  `srand`.
- **getopt** : `cob_getopt_r (struct cob_getopt_state *, …)` pour cobc,
  cobcrun, cobfile ; `CBL_GC_GETOPT` utilise `ctx->common->getopt`.
- **screenio** : terminal unique, `rt->screen_owner` ; le premier
  contexte qui fait un ACCEPT/DISPLAY écran en devient propriétaire,
  les autres reçoivent une erreur runtime.
- **Profiling** : compteurs dans l'instance ; agrégation à la
  destruction du contexte sous verrou.
- **Version d'ABI** : `cob_check_version` compare une version d'ABI
  incrémentée ; tout module de l'ancien schéma est refusé.

## 10. Liste blanche des données modifiables globales

Vérifiée par `build_aux/list-mutable-globals.sh` en CI :
- `cob_current_context` (TLS, libcob) ;
- `P_slot` (code généré, un par programme, écrit une fois par CAS) ;
- (si nécessaire) le pointeur vers l'unique `cob_runtime` utilisé par
  les handlers de signaux.

## 10 bis. Fonctions exportées sans variante `_ctx` (état après T1.2)

Toutes les fonctions exportées de libcob ont une variante `NOM_ctx`, sauf :
- **pures** (aucun état) : `cob_s32_pow`, `cob_s64_pow`,
  `cob_valid_date_format`, `cob_valid_time_format`,
  `cob_valid_datetime_format`, `cob_get_name_hash`,
  `cob_encode_program_id`, `cob_field_constant`, `cob_field_value`,
  `cob_field_content`, `cob_is_valid_uri`, `cob_is_xml_namechar`,
  `cob_is_xml_namestartchar` — plusieurs sont utilisées par `cobc` ;
- **frontières appelées depuis COBOL** (ABI C, contexte courant lu à
  l'entrée) : routines système `cob_sys_*` (CBL_*), et `cob_getenv`
  (appelée par `CALL STATIC "cob_getenv"` dans la suite de tests) ;
- **frontières appelées depuis C** : API de compatibilité Micro Focus
  (`cobcapi.c`, macros `cobcall`, `cobsetjmp`…, qui passent
  `cob_get_current_context ()`), fonctions écran pour le C
  (`cob_display_text`, `cob_display_formatted_text`, `cob_get_char`,
  `cob_set_cursor_pos`, `cob_get_scr_cols`, `cob_get_scr_lines`),
  `cob_get_current_context`, `cob_get_global_ptr` ;
- **niveau processus**, utilisées par `cobc`, `cobcrun`, `cobfile` qui
  n'ont pas de contexte : `cob_init`, `cob_init_nomain`,
  `cob_common_init`, `cob_extern_init`, `cob_malloc`, `cob_free`,
  `cob_realloc`, `cob_strdup`, `cob_fast_malloc`, `cob_setenv`,
  `cob_getenv_direct`, `cob_getenv_value`, `cob_expand_env_string`,
  `cob_setup_env`, `cob_relocate_string`, `cob_temp_name`,
  `cob_incr_temp_iteration`, `cob_get_current_date_and_time`,
  `cob_set_date_from_epoch`, `cob_raise`, `cob_reg_sighnd`, signaux
  (`cob_get_sig_name`…), `cob_hard_failure*`, `cob_check_version`
  (constructeur de module), `print_info*`, `print_runtime_conf`,
  `cob_tidy`, `cob_sleep_msec`.
  En T1.3, celles qui ont un état le prennent dans `cob_runtime`.

Dans libcob, les appels depuis une fonction qui n'a pas encore `ctx`
passent `COB_CTX_TODO` (882 occurrences à la fin de T1.2) : leur
élimination par propagation de `ctx` aux fonctions internes est le
premier travail de T1.3.

## 11. Points ouverts

| Point | Option par défaut | Décision |
|---|---|---|
| Partie publique de `cob_context` | premier membre `pub` | à trancher en T1.2 |
| Résolution relative des chemins (`ctx->cwd`) | oui | à confirmer |
| Contexte conservé entre deux activations d'une tâche | possible (API le permet) | dépend de T3/T5 |
| EXTERNAL par contexte | oui | confirmer en T3 |
| Windows : locale par thread | `_configthreadlocale` | à valider |
| Bibliothèques ISAM non thread-safe | mutex global | voir EXTERNALS |
| Modules compilés avec l'ancien schéma | acceptés via les anciens noms (compatibilité, §5), en mode un seul contexte | décidé le 2026-10-29 ; erreur en mode multi-contexte à faire en T1.5 |
| Fonctions libcob appelées directement depuis COBOL par `CALL` | garder l'ABI C pour celles qui sont documentées comme appelables | à recenser |

## 12. Correspondance avec les étapes

- **T1.2** : `cob_runtime`, `cob_context` (avec `glob` et `set`), API §3,
  `ctx` partout (signatures + codegen), un seul contexte réel.
- **T1.3** : sous-structures opaques, migration fichier par fichier.
- **T1.4** : verrous de `rt`, locale, environnement, `posix_spawn`,
  remplacements libc (`TXSERIES-T1-EXTERNALS.md`), backends.
- **T1.5** : instances et slots, `cob_module_global_enter` avec contexte
  courant, CANCEL.
- **T1.6** : banc de test, liste blanche en CI.
