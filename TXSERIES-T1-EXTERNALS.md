# T1 — Fonctions externes : réentrance et sûreté en multi-thread

État : 2026-10-28. Complète `TXSERIES-T1-DESIGN.md`.

Méthode : `nm -u` sur tous les objets de `_build/libcob/.libs/*.o`
(406 symboles externes), plus une recherche dans les sources pour les
fonctions compilées hors de ce build (`#ifdef`, backends non construits :
fisam, foci). Classement selon la liste POSIX des fonctions non
thread-safe (XSH 2.9.1) et les annotations MT-Safe de la glibc.

Légende :
- **OK** : réentrant et thread-safe ;
- **OK-cond** : sûr sous une condition à garantir par libcob ;
- **REMPLACER** : choisir une autre fonction ;
- **PROCESSUS** : sûr mais agit sur tout le processus → changement de
  conception (voir DESIGN §7).

## 1. Fonctions à remplacer

| Fonction | Où | Problème | Remplacement POSIX | Windows |
|---|---|---|---|---|
| `strtok` | call.c (2), fileio.c:1866,1881, screenio.c:869,906, common.c:8107 | état interne statique | `strtok_r` | `strtok_s` |
| `localtime` | common.c:5062,5256,5578, fileio.c:4064,8715,8991, intrinsic.c (3) | tampon statique | `localtime_r` | `localtime_s` (ordre des arguments inversé) |
| `gmtime` | common.c:5095 | tampon statique | `gmtime_r` | `gmtime_s` |
| `ctime` | common.c:6290-6292 | tampon statique | `strftime` sur `localtime_r` | idem |
| `strerror` | common.c:1016 (`cob_get_strerror`), fileio.c:1120,1134,1243 | tampon statique possible | `strerror_r` — **attention** : variante GNU (rend `char *`) ≠ variante XSI (rend `int`) ; tester à `configure`, ou `strerror_l` | `strerror_s` |
| `getlogin` | common.c:10835 | tampon statique | `getlogin_r`, ou `getpwuid_r (geteuid ())` | `GetUserName` |
| `dirname` | flmdb.c:895 | peut modifier l'argument / tampon statique (POSIX) | fonction interne sur une copie | idem |
| `rand` / `srand` / `random` | intrinsic.c (si `DISABLE_GMP_RANDOM`) | état global | `gmp_randstate_t` par contexte (déjà le cas par défaut) ; sinon PRNG interne dans `ctx` | idem |
| `localeconv` | intrinsic.c (5) | tampon statique, dépend de la locale globale | `nl_langinfo_l (RADIXCHAR / THOUSEP / CRNCYSTR, loc)` | `_localeconv` + `_l` |
| `nl_langinfo` | intrinsic.c (2) | non garanti thread-safe par POSIX | `nl_langinfo_l (…, ctx->locale)` | équivalents `GetLocaleInfoEx` |
| `qsort` | common.c:4655,4657 (tri de table), intrinsic.c (`cob_intr_median`) | le comparateur lit un état global | tri interne prenant `ctx` (`qsort_r` a des signatures incompatibles glibc / BSD / `qsort_s`) | idem |
| `sigprocmask` | common.c:1613 | comportement non spécifié dans un processus multi-thread | `pthread_sigmask` | — |
| `signal` | common.c, fileio.c, screenio.c | sémantique variable | `sigaction` | `signal` (seul disponible) |
| `fork` + `execv` | fileio.c:4587-4594 (fichiers pipe), common.c | dans le fils, seules les fonctions async-signal-safe sont permises avant `exec` | `posix_spawn` + `posix_spawn_file_actions_adddup2` | `CreateProcess` |
| `system` | common.c:1177,6749,7214 | modifie SIGINT/SIGQUIT/SIGCHLD du processus pendant l'appel ; passe l'environnement du processus | `posix_spawn` + `waitpid`, environnement de la tâche | `_spawnve` / `CreateProcess` |
| `popen` / `pclose` | termio.c:380, fileio.c:4381,4404 | sûr dans la glibc récente, mais ne transmet pas l'environnement de la tâche | `posix_spawn` + `pipe` | `_popen` (à encadrer) |
| `alarm` + `SIGALRM` | fileio.c:3051-3077 (attente de verrou) | minuterie et handler globaux au processus | boucle `F_SETLK` + `nanosleep` jusqu'au délai | `LockFileEx` + attente |

## 2. Fonctions sûres sous condition

| Fonction | Condition | Comment libcob la garantit |
|---|---|---|
| `getenv` | personne ne modifie l'environnement en parallèle | plus de `setenv`/`putenv`/`unsetenv` après l'init (DESIGN §7.2) |
| `setenv`, `putenv`, `unsetenv` (common.c:5916-5986, 10687 ; foci.c:290-300) | à n'appeler qu'avant la création des threads | seulement dans `cob_runtime_init` ; foci.c passe les identifiants par OCI |
| `setlocale` | idem : modifie la locale de tout le processus | un seul appel dans `cob_runtime_init` ; ensuite `newlocale` / `uselocale` par contexte |
| `strcoll`, `strftime`, `toupper`, `tolower`, `isprint`… (`__ctype_b_loc`), `strtol`, `sscanf`, `snprintf` | sûres (glibc : « MT-Safe locale »), mais suivent la locale du thread | `uselocale (ctx->locale)` dans `cob_context_enter` |
| `mktime`, `timezone`, `daylight`, `tzname` | sûres tant que `TZ` ne change pas ; les variables globales sont lues après `tzset` | `TZ` jamais modifiée après l'init ; préférer `tm_gmtoff` (glibc, BSD) à `timezone` pour le décalage UTC (common.c:5086) |
| `chdir`, `getcwd` | `chdir` change le répertoire de tout le processus | `ctx->cwd` et résolution des chemins relatifs (DESIGN §7.3) |
| `exit` | termine le processus | retour à l'hôte (T2) |
| `raise`, `kill` | `raise` vise le thread appelant (OK) | — |
| `setjmp` / `longjmp` | ne jamais sauter vers un `jmp_buf` d'un autre thread | `jmp_buf` dans `ctx`, et un contexte n'est actif que dans un thread |
| `dlopen`, `dlsym`, `dlclose` | sûres ; `dlerror` est par thread dans la glibc | table des modules sous `rt->lock_modules` ; message de `dlerror` copié sous le verrou (portabilité) |
| `stdin`, `stdout`, `stderr`, `fprintf`, `fputs`… | stdio est verrouillé, mais les flux sont partagés | DISPLAY de plusieurs tâches entrelacés au niveau de la ligne : acceptable, documenter ; T2 décide de la redirection |
| `gettext`, `textdomain`, `bindtextdomain` | `gettext` est sûr ; les deux autres seulement à l'init | messages fréquents traduits d'avance dans `rt` ; jamais de gettext dans un handler de signal |

## 3. Fonctions sûres (pas d'action)

Mémoire et chaînes : `malloc`, `calloc`, `realloc`, `free`, `mem*`,
`str*` (sauf `strtok`, `strerror`), `strdup`, `strcasecmp`, `atoi`,
`atol`, `bsearch`.
E/S de bas niveau : `open64`, `close`, `read`, `write`, `lseek64`,
`fcntl64` (mais voir §5 pour les verrous), `fstat64`, `stat`, `stat64`,
`access`, `mkdir`, `rmdir`, `rename`, `unlink`, `readlink`,
`canonicalize_file_name`, `ftruncate64`, `fdatasync`, `dup2`, `pipe`.
stdio : `fopen`, `fdopen`, `fmemopen`, `fclose`, `fread`, `fwrite`,
`fgets`, `fseek`, `ftell`, `fflush`, `getc`, `putc`, `flockfile`…
Processus : `getpid`, `getuid`, `geteuid`, `getgid`, `getegid`,
`getgroups`, `waitpid`, `clock_gettime`, `time`, `nanosleep`.
Signaux : `sigaction`, `sigemptyset`, `sigaddset`.
Hors sujet : `__stack_chk_fail`, `__tls_get_addr`, `__errno_location`.

## 4. Bibliothèques tierces

| Bibliothèque | Statut | Conditions / actions |
|---|---|---|
| **GMP** (`__gmpz_*`, `__gmpf_*`, `gmp_rand*`) | réentrante | aucun objet `mpz`/`mpf`/`randstate` partagé entre contextes (temporaires dans `ctx`, constantes calculées à l'init dans `rt` puis lues seulement) ; `mp_set_memory_functions` uniquement à l'init |
| **libltdl** (`lt_dl*`) | non thread-safe (libtool 2.x n'a plus `lt_dlmutex_register`) | ce build utilise `dlopen` directement ; si ltdl reste utilisé ailleurs : tous les appels sous `rt->lock_modules` |
| **ncurses** + panel | non thread-safe (variante `ncursest` avec `use_screen`, non utilisée) | un seul contexte propriétaire du terminal (DESIGN §9) ; ncurses installe ses handlers SIGWINCH/SIGTSTP au `initscr` → T2 |
| **libxml2** | thread-safe si `xmlInitParser` est appelé une fois avant les threads | `xmlInitParser` dans `cob_runtime_init` ; remplacer `xmlSetStructuredErrorFunc` (état par thread, jamais restauré, mlio.c:1780) par des handlers par parser (`xmlCtxtSetErrorHandler` / `xmlSchemaSetParserStructuredErrors`) ; `xmlCleanupParser` seulement dans `cob_runtime_finish` |
| **cJSON** | réentrante pour ce qu'utilise libcob | `cJSON_InitHooks` (global) jamais appelé après l'init ; `cJSON_GetErrorPtr` (global) non utilisé — à garder ainsi |
| **Berkeley DB** (`db_create`, `db_env_create`…) | thread-safe si l'environnement et les handles sont ouverts avec `DB_THREAD` | ajouter `DB_THREAD` ; un locker (`lock_id`) par contexte ; `db_strerror` OK |
| **LMDB** (`mdb_*`) | thread-safe ; un environnement ne doit être ouvert qu'une fois par processus ; une transaction d'écriture appartient à un thread | cache d'environnements par chemin dans `rt` ; `MDB_NOTLS` (un contexte peut changer de thread entre deux activations) ; transactions dans `ctx` |
| **unixODBC** (`SQL*`) | gestionnaire thread-safe ; dépend du pilote | environnement dans `rt`, connexions et instructions par contexte ; documenter que le pilote doit être thread-safe |
| **Oracle OCI** (foci.c, non construit ici) | thread-safe avec `OCI_THREADED` | ajouter `OCI_THREADED` ; plus de `putenv` (identifiants dans les paramètres de connexion) |
| **VBISAM** (`is*`, `iserrno`, `isrecnum`, `isreclen`) | non thread-safe : `iserrno` et `isrecnum` sont des globales ; état interne global | mutex global de `rt` autour de chaque appel ISAM, copie de `iserrno` / `isrecnum` / `isreclen` dans `ctx` avant de relâcher le mutex |
| **C-ISAM / D-ISAM** (non construits ici) | versions classiques non thread-safe ; des variantes thread-safe existeraient selon l'éditeur — **à vérifier** | même mutex global par défaut ; utiliser la variante thread-safe si disponible |

## 5. Problèmes de sémantique « par processus » (pas de fonction de remplacement directe)

- **Verrous d'enregistrements `fcntl` (`F_SETLK`)** : appartiennent au
  processus, donc deux tâches du même processus ne se bloquent pas, et
  `close` sur n'importe quel descripteur du fichier libère tous les
  verrous du processus. → `F_OFD_SETLK` (Linux ≥ 3.15, et d'autres
  systèmes récents) et table de verrous interne (DESIGN §8).
- **Comparaison `lck.l_pid == getpid ()`** (fileio.c:3040) pour savoir si
  le verrou est « à moi » : faux dès que deux tâches partagent le
  processus → propriétaire = contexte, via la table interne.
- **Répertoire courant, environnement, locale, dispositions des signaux,
  flux standard** : voir DESIGN §7.

## 6. Contrôle automatique

Ajouter à la CI (T1.6) une vérification `nm -u` de libcob contre une
liste noire : `strtok`, `localtime`, `gmtime`, `ctime`, `asctime`,
`strerror`, `getlogin`, `rand`, `srand`, `random`, `localeconv`,
`nl_langinfo`, `sigprocmask`, `signal`, `fork`, `system`, `popen`,
`alarm`, `setlocale`/`setenv`/`putenv`/`unsetenv`/`chdir` (autorisés
seulement dans l'objet d'initialisation), `dirname`, `basename`,
`readdir`, `getpwnam`, `getpwuid`, `tmpnam`.
