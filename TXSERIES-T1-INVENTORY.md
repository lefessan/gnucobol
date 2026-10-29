# T1.1 — Inventaire classé de l'état global de libcob

État : 2026-10-28, sur la branche `z-2026-10-29-reentrant`. Voir
`TXSERIES-PLAN.md` (T1).

Sources : `build_aux/list-mutable-globals.sh _build/libcob/.libs/*.o`
(362 symboles en `.bss`, `.data` et `.tbss`), recoupé à la main avec les
sources. Les variables compilées hors de ce build (`#ifdef`) et les
backends non construits ici (fisam/CI/DI/VB, foci, focextfh) sont pris
dans le source.

Classes :
- **C1 runtime** : fixé à l'init → `cob_runtime` (`rt`) ;
- **C2 contexte** : état d'une tâche → `cob_context` (`ctx->fichier.xxx`) ;
- **C3 cache partagé** : partagé et modifié en cours d'exécution → `rt` + verrou ;
- **C4 processus** : signaux, terminal, atexit… → T2 ou « un seul contexte à la fois » ;
- **CONST** : jamais modifié → `static const` ;
- **SCRATCH** : tampon temporaire → variable locale ou fournie par l'appelant ;
- **remove** : copie locale de `cobglobptr` / `cobsetptr`, remplacée par `ctx` / `ctx->rt`.

## Synthèse

| Groupe de fichiers | Lignes | C1 | C2 | C3 | C4 | CONST | SCRATCH | remove | ifdef / mort |
|---|---|---|---|---|---|---|---|---|---|
| common.c | 119 | 20 | 33 | 3 | 5 | 33 | 12 | 2 | 11 |
| call, intrinsic, numeric, move, strings, cobcapi, cconv | ~75 | 16 | 41 | 3 | 0 | 7 (+4) | 11 | 9 | 4 morts |
| fileio + backends | 87 | 14 | 31 | 7 | 0 | 26 | 9 | ~6 | — |
| screenio, termio, reportio, mlio, profiling, cobgetopt | 91 | 3 | 26 | 8 | 18 (terminal) | 3 | 24 | 9 | 9 |

Environ un quart des variables disparaissent sans effort de conception
(CONST, SCRATCH, remove, code mort). Le gros du travail est dans les
~130 variables C2 et les ~20 caches C3.

## Constats qui modifient le plan

1. **Les réglages runtime ne sont pas en lecture seule.** `cob_settings`
   et `gc_conf` sont réécrits après l'init : `cob_rescan_env_vals()`
   (après `DISPLAY UPON ENVIRONMENT-VALUE`, `cob_putenv`),
   `set_config_val`, ouverture paresseuse du fichier SYSPUNCH
   (termio.c:405-418). Proposition : **copie des réglages par contexte**
   (`ctx->set`), initialisée depuis `rt` — pas de verrou, et cohérent
   avec CICS (une tâche ne doit pas modifier les réglages d'une autre).
2. **La locale est globale au processus.** `setlocale` est utilisé par
   SET LOCALE, LOCALE-DATE/TIME/COMPARE, `cob_sys_printable`,
   `cob_dump_module`, et le pliage des noms de `CALL` dépend de la locale
   courante. Il faut passer à `newlocale` / `uselocale` et aux variantes
   `_l` (`strftime_l`, `strcoll_l`, `nl_langinfo_l`, `isprint_l`), avec
   les équivalents Windows. Nouvelle étape dans T1.4.
3. **L'environnement est global au processus.** `setenv`/`putenv`
   (`DISPLAY UPON ENVIRONMENT-VALUE`, foci.c:290-300 pour Oracle)
   concurrencent les nombreux `getenv`. Proposition : environnement
   COBOL par contexte (surcharges dans `ctx`, repli sur `getenv` en
   lecture), lecture une fois à l'init des variables `COB_*`.
4. **Les verrous d'enregistrements `fcntl` sont par processus.** Deux
   tâches d'un même processus ne se bloquent pas, et fermer un
   descripteur libère tous les verrous du processus sur ce fichier. Il
   faut `F_OFD_SETLK` (Linux) ou une table de verrous interne au runtime.
   Même problème dans les bibliothèques ISAM. Gros sujet pour CICS, où
   plusieurs tâches accèdent aux mêmes fichiers.
5. **Bibliothèques tierces non prêtes pour le multi-thread :**
   - BDB : environnement ouvert sans `DB_THREAD`, un seul `bdb_lock_id`
     (il en faut un par tâche) ;
   - LMDB : un environnement par fichier ouvert, or LMDB interdit d'ouvrir
     deux fois le même environnement dans un processus → cache
     d'environnements par chemin dans `rt` ;
   - ODBC / OCI : la connexion (`db[1]`) doit être par tâche ; OCI sans
     `OCI_THREADED` ;
   - C-ISAM / D-ISAM / VBISAM classiques : `iserrno` etc. globaux → mutex
     global sauf build thread-safe ;
   - libltdl : non thread-safe → `dlopen`/`dlsym`/`dlerror` sous le
     verrou de `rt` ;
   - libxml2 : `xmlSetStructuredErrorFunc` global jamais restauré,
     `xmlCleanupParser` uniquement à la fin du runtime.
6. **`call_table` mélange deux niveaux.** Nom, fonction, handle, chemin :
   processus (`rt` + verrou). `p->module` (instance, état CANCEL) : par
   contexte. CANCEL physique (`lt_dlclose`) → compteur de références.
   (L'idée d'une ABI `__ctx` par entrée est abandonnée, voir DESIGN §4.1.)
7. **Impacts sur le code généré découverts :**
   - le pool de décimaux (`cob_decimal_base`, numeric.c) est partagé
     par tous les programmes non récursifs, et les pointeurs `d0..dN`
     générés sont des statiques de programme → à mettre dans l'instance ;
   - compteurs de profiling `prof_info` en statique de module
     (codegen.c:14801) → instance ;
   - état SORT : `cob_table_sort_init` doit rendre l'état au lieu de
     `share_sort_state` (changement d'API et de codegen) ;
   - CBL_* de `system_tab` : obtiennent le contexte courant à l'entrée.
8. **État qui survit entre deux appels de libcob** (à garder en C2, ou à
   transformer en paramètre) : `cob_d_remainder` (DIVIDE … REMAINDER),
   `move_field` (indirect put/get), `cob_not_finite`, anneau de 32
   résultats d'intrinsèques (`calc_base`).
9. **Signaux et `longjmp`** : `cob_sig_handler` et `catch_sig_jmp`
   lisent et écrivent l'état de la tâche → passent par le pointeur TLS
   du contexte courant (une des frontières prévues). Les messages des
   signaux doivent être traduits d'avance dans `rt` (pas de gettext dans
   un handler).
10. **Effets globaux au processus pour T2** : `chdir` (CBL_CHANGE_DIR),
    fichiers pipe en `fork`/`execv` (→ `posix_spawn`), noms temporaires
    pid + compteur (compteur atomique dans `rt`), CBL_EXIT_PROC /
    CBL_ERROR_PROC (fin de run unit ou fin de processus ?), curses (un
    seul terminal : screenio réservé à un contexte à la fois).
11. **API publique hors contexte** : `cob_getopt` (`cob_optarg`,
    `cob_optind`…) est utilisée par cobc, cobcrun, cobfile → variante
    `_r` avec état explicite ; `EXTFH` est un point d'entrée C → passe
    par le contexte courant TLS.
12. **Appels libc non réentrants** à remplacer : `strtok` (call.c,
    fileio.c, screenio.c, common.c:8107), `localtime`/`gmtime` (common.c,
    fileio.c, intrinsic.c), `strerror` (common.c:1016 — `cob_get_strerror`
    se dit réentrant à tort —, fileio.c), `getlogin`, `dirname`,
    `qsort` avec état global (common.c:4655-4657, `cob_intr_median`),
    `rand`/`srand` (si `DISABLE_GMP_RANDOM`).

## Bugs trouvés au passage

Consignés dans `BUGS-FOUND.md`.

---

# Annexes : tableaux détaillés par fichier

Les annexes sont les tableaux produits pendant l'analyse ; certaines sont
en anglais.

## Inventory of mutable globals — libcob/common.c

Source: `_build/libcob/common.o` (globals.tsv, 104 symbols) + `nm` (adds
`is_test`, `cob_statement_name`, `MAX_MODULE_ITERS`, `const_alpha_attr`,
`const_bin_nano_attr`, `cob_exception_tab_code`, missing from the tsv) + source
scan for `#ifdef`-ed variables (`COB_DEBUG_LOG` is undefined on this build,
`HAVE_DESIGNATED_INITS` is defined, `_MSC_VER` is not).

Notation: `ctx` = `cob_context *`, `ctx->common` = sub-struct for common.c,
`ctx->glob` = what is today `cob_global` (`cobglobptr`), `rt` = `ctx->rt`
(`cob_runtime *`), `rt->set` = what is today `cob_settings` (`cobsetptr`).

| file | line | variable | class | action | note |
|---|---|---|---|---|---|
| common.c | 249 | COB_ZEROES_ALPHABETIC | CONST | `const char *const` | pointer never reassigned; exported |
| common.c | 261 | COB_SPACES_ALPHABETIC | CONST | `const char *const` | same |
| common.c | 272 | MAX_MODULE_ITERS | CONST | keep (or `#define`) | already const, .rodata |
| common.c | 300 | cob_initialized | C4 | rt->initialized (process) + "ctx != NULL" checks | process init flag; also read in cob_sig_handler; most `if (!cob_initialized)` tests become "ctx/rt valid" |
| common.c | 301 | check_mainhandle | C4 | arg of cob_runtime_init() | set by cob_init_nomain only, passed to cob_init_call |
| common.c | 302 | cob_argc | C2 | ctx->common.argc (default from rt->argc) | set at init, overridable by cob_command_line(); CICS task has its own (empty) args |
| common.c | 303 | cob_argv | C2 | ctx->common.argv (default from rt->argv) | same; also used by stack-trace printing |
| common.c | 304 | cob_alloc_base | C2 | ctx->common.alloc_base | cob_cache_malloc list, freed at run-unit end |
| common.c | 305 | cob_module_list | C2 | ctx->common.module_list | all activated cob_module of the run unit |
| common.c | 306 | cob_module_err | C2 | ctx->common.module_err (or remove) | only read in `#if 0` code -> write-only, can be dropped |
| common.c | 307 | cob_last_sfile | C2 | ctx->common.trace_last_sfile | TRACE state |
| common.c | 308 | cob_last_progid | C2 | ctx->common.trace_last_progid | TRACE state |
| common.c | 310 | cobglobptr | - | remove (use ctx->glob) | cached global pointer |
| common.c | 311 | cobsetptr | - | remove (use rt->set) | BUT settings are mutated at runtime (SET ENVIRONMENT -> cob_rescan_env_vals, cob_set_runtime_option, CBL_* toggles): needs per-ctx overlay or lock, see notes |
| common.c | 313 | module_unload | C2 | ctx->common.module_unload | paired with return_jmp_buf in cob_call_with_exception_check |
| common.c | 315 | last_exception_code | C2 | ctx->common.last_exception_code (or ctx->glob) | |
| common.c | 316 | active_error_handler | C2 | ctx->common.active_error_handler | CBL_ERROR_PROC recursion guard |
| common.c | 317 | in_stop_run | C2 | ctx->common.in_stop_run | also read/written in cob_sig_handler (via TLS current ctx) |
| common.c | 319 | const_alpha_attr | CONST | keep | already static const |
| common.c | 321 | const_bin_nano_attr | CONST | keep | already static const |
| common.c | 325 | cob_local_env (COB_TLS) | C2 | ctx->common.local_env | DISPLAY ... UPON ENVIRONMENT-NAME, persists to next ACCEPT/DISPLAY |
| common.c | 326 | cob_local_env_size (COB_TLS) | C2 | ctx->common.local_env_size | |
| common.c | 327 | current_arg (COB_TLS) | C2 | ctx->common.current_arg | ACCEPT ARGUMENT-VALUE cursor |
| common.c | 328 | commlnptr (COB_TLS) | C2 | ctx->common.commlnptr | DISPLAY UPON COMMAND-LINE |
| common.c | 329 | commlncnt (COB_TLS) | C2 | ctx->common.commlncnt | |
| common.c | 331 | basext | C2 | ctx->common.externals | EXTERNAL items, per run unit (per plan) |
| common.c | 340 | share_sort_state (COB_TLS) | SCRATCH | sort_state returned by cob_table_sort_init / passed to init_key & sort; qsort_r | lives only between table_sort_init and table_sort; API change in codegen |
| common.c | 342 | cob_source_file (COB_TLS) | C2 | ctx->common.source_file (or ctx->glob) | read in signal handler via TLS ctx |
| common.c | 343 | cob_source_line (COB_TLS) | C2 | ctx->common.source_line | same |
| common.c | 345 | is_test | C1 | rt->is_test | env COB_IS_RUNNING_IN_TESTMODE at init; COB_HIDDEN, used by profiling.c |
| common.c | 348 | cob_statement_name | CONST | `const char *const[]` | never written with designated inits |
| common.c | 356 | cob_statement_name (no desig. inits) | ifdef | C1 rt or CONST | filled once by init_statement_list() |
| common.c | 361 | cob_debug_check_open | ifdef | C1 rt->debug.check_open (once) | COB_DEBUG_LOG |
| common.c | 362 | cob_debug_log_time | ifdef | C1 rt->debug.log_time | COB_DEBUG_LOG |
| common.c | 363 | cob_debug_file | ifdef | C3 rt->debug.file + lock | shared FILE*, may alias trace file |
| common.c | 364 | cob_debug_level | ifdef | C1 rt->debug.level | |
| common.c | 365 | cob_debug_mod | ifdef | C1 rt->debug.mod | |
| common.c | 368 | cob_debug_modules | ifdef | C1 rt->debug.modules | |
| common.c | 370 | cob_debug_file_name | ifdef | C1 rt->debug.file_name | |
| common.c | 373 | strbuff | SCRATCH | remove: cob_strcat returns fresh malloc, caller frees | only used for building config strings (call.c preload, common.c) |
| common.c | 375 | cob_process_id | C4 | rt->pid (reset on fork) | cache of getpid() |
| common.c | 376 | cob_temp_iteration | C3 | rt->temp_iteration, atomic increment | must stay process-wide: temp names = pid+counter, per-ctx would collide |
| common.c | 378 | conf_runtime_error_displayed | C1 | rt->conf_err.displayed (or local struct of cob_load_config) | config loading only |
| common.c | 379 | last_runtime_error_line | C1 | rt->conf_err.line | config loading only |
| common.c | 380 | last_runtime_error_file | C1 | rt->conf_err.file | config loading only |
| common.c | 386 | dyn_attr_list | C2 | ctx->common.dyn_attr_list | elements are cob_cache_malloc'd (ctx-owned); could be C3+lock if moved to rt alloc |
| common.c | 388 | runtime_err_str | C2 | ctx->common.runtime_err_str[] | last runtime error, read by cob_last_runtime_error() |
| common.c | 389 | exit_code | C2 | ctx->common.exit_code | run-unit exit code, also set by signal handler |
| common.c | 393 | return_jmp_buf | C2 | ctx->common.return_jmp_buf | longjmp from STOP RUN/errors/signals back to host caller; signal path via TLS ctx |
| common.c | 394 | return_jmp_buffer_set | C2 | ctx->common.return_jmp_set | |
| common.c | 398 | sig_is_handled | C4 | keep process-global (volatile sig_atomic_t) | T2 |
| common.c | 402 | cob_ext_sighdl | C4 | rt->ext_sighdl | callback without user arg (int sig) |
| common.c | 405 | time_as_filetime_func | ifdef | C1 rt (or static resolved once) | _MSC_VER only |
| common.c | 410 | cob_exception_tab_name | CONST | keep | already `const char *const` (.data only due to relocs) |
| common.c | 418 | cob_exception_tab_code | CONST | keep | already static const |
| common.c | 431 | cob_switch | C2 | ctx->common.switches[] (init copy of rt->switch_dflt) | env COB_SWITCH_n at init, then SET switch / CBL_TOGGLE / runtime option |
| common.c | 434 | b2i | CONST | static const | lookup table, never written |
| common.c | 465 | exit_hdlrs | C2 | ctx->common.exit_hdlrs | CBL_EXIT_PROC, run at STOP RUN; callback `int(*)(void)` no user arg; T2 must decide process-exit vs run-unit-exit |
| common.c | 471 | hdlrs | C2 | ctx->common.error_hdlrs | CBL_ERROR_PROC; callback `int(*)(char*)` no user arg |
| common.c | 474 | setting_group | CONST | static const + `_()` at use site | overwritten with translations in print_runtime_conf |
| common.c | 478 | lwrupr | CONST | static const | config_tbl.enums must become `const struct config_enum *` |
| common.c | 479 | notset | CONST | static const | idem |
| common.c | 480 | never | CONST | static const | idem |
| common.c | 481 | beepopts | CONST | static const | idem |
| common.c | 482 | timeopts | CONST | static const | idem |
| common.c | 483 | coeopts | CONST | static const | idem |
| common.c | 484 | syncopts | CONST | static const | idem |
| common.c | 485 | varseqopts | CONST | static const | idem |
| common.c | 491 | relopts | CONST | static const | idem |
| common.c | 496 | format_opts | CONST | static const | idem |
| common.c | 510 | file_format_dflt | CONST | static const | lines 500/505 are ifdef variants (WITH_FILE_FORMAT) |
| common.c | 511 | varrel_dflt | CONST | static const | idem (501/506 ifdef) |
| common.c | 512 | fixrel_dflt | CONST | static const | idem (502/507 ifdef) |
| common.c | 513 | varseq_dflt | C1 | rt (or CONST via stringified WITH_VARSEQ) | sprintf'd in cob_load_config when !WITH_FILE_FORMAT (l.9139); better: compile-time string |
| common.c | 515 | shareopts | CONST | static const | |
| common.c | 516 | retryopts | CONST | static const | |
| common.c | 517 | dict_opts | CONST | static const | |
| common.c | 519 | dups_opts | CONST | static const | |
| common.c | 520 | bdborder | CONST | static const | |
| common.c | 525 | min_conf_length | C1 | local in print_runtime_conf (or rt) | lazy, only for --runtime-conf output |
| common.c | 526 | not_set | C1 | local in print_runtime_conf (or rt) | translated "not set" |
| common.c | 535 | gc_conf | C1 | rt->conf_tbl (copy of a static const template) | status flags (STS_*), set_by, config_num, default_val mutated during load AND at runtime by cob_rescan_env_vals / cob_set_runtime_option -> lock or per-ctx copy |
| common.c | 648 | signals | C1 | rt->signals (or CONST + rt->sig_desc[]) | descriptions translated once at init; read in signal handler, must be precomputed (no gettext in handler) |
| common.c | 701 | signal_msgid | C1 | rt->msg.signal | translated at init; exported |
| common.c | 702 | warning_msgid | C1 | rt->msg.warning | idem |
| common.c | 703 | more_stack_frames_msgid | C1 | rt->msg.more_frames | idem |
| common.c | 715 | abort_reason | C2 | ctx->common.abort_reason[] | written by cob_sig_handler and cob_runtime_error (via TLS ctx in handler) |
| common.c | 716 | dump_trace_started | C2 | ctx->common.dump_trace_started | "dump only once" guard; signal handler via TLS ctx |
| common.c | 1033 | ss_itoa_buf | SCRATCH | local buffer passed to ss_itoa_u10() by intcat_to_buff | used from signal handler: two concurrent signals/threads clobber it |
| common.c | 2383 | file_path_name | SCRATCH | caller-provided buffer for cob_find_path/cob_find_path_internal | returned pointer to static |
| common.c | 2384 | exec_len | C1 | rt->reloc.exec_len | cob_setup_env (cobcrun/cobc/cob_init) |
| common.c | 2384 | build_len | C1 | rt->reloc.build_len | |
| common.c | 2384 | exec_chg | C1 | rt->reloc.exec_chg | |
| common.c | 2385 | exec_cfg_dir | C1 | rt->reloc.cfg_dir (compute in cob_setup_env) | today lazily set inside cob_getenv_value (race) |
| common.c | 2386 | exec64 | C1 | rt->reloc.exec64 | |
| common.c | 2387 | exec_root | C1 | rt->reloc.exec_root | |
| common.c | 2388 | build_root | C1 | rt->reloc.build_root | modified (slash appended) at setup, else const COB_BLD_PREFIX |
| common.c | 2435 | usr_exc | CONST | static const / use PERM_UX | never written |
| common.c | 2436 | grp_exc | CONST | static const | |
| common.c | 2437 | oth_exc | CONST | static const | |
| common.c | 2685 | getenv_work (cob_getenv_value) | SCRATCH | local in cob_getenv_value(), always cob_strdup | LOCALEDIR path returns the static itself -> strdup too |
| common.c | 2738 | str_work (cob_relocate_string) | SCRATCH | caller buffer or malloc'd result | used by cobc only |
| common.c | 2986 | excp_mod (cob_set_exception) | C2 | ctx->common.excp_mod[] | pointed to by glob->last_exception_id |
| common.c | 2987 | excp_sec (cob_set_exception) | C2 | ctx->common.excp_sec[] | -> last_exception_section |
| common.c | 2988 | excp_para (cob_set_exception) | C2 | ctx->common.excp_para[] | -> last_exception_paragraph |
| common.c | 5025 | last_time (set_cob_time_from_localtime) | C3 | ctx->common.last_time (prefer per-ctx) | localtime cache; per-ctx avoids lock |
| common.c | 5026 | last_cobtime (set_cob_time_from_localtime) | C3 | ctx->common.last_cobtime (prefer per-ctx) | idem; FIXME says reset on locale change |
| common.c | 6332 | tmpdir (cob_gettmpdir) | C1 | rt->tmpdir (compute at init / once) | lazy init today (race on first use) |
| common.c | 11278 | sectname | CONST | `static const char *const` | |
| common.c | 11282 | sectdump | CONST | static const | |
| common.c | 11286 | sym_idx | SCRATCH | field of local dump_state in cob_dump_symbols, passed down | recursion state of cob_dump_table/sub |
| common.c | 11287 | sym_sub | SCRATCH | idem | |
| common.c | 11288 | sym_size | SCRATCH | idem | |
| common.c | 11290 | save_sig_env | C2 | ctx->common.dump_sig_env | jmp target for catch_sig_jmp (signal handler, no user arg -> TLS ctx) |
| common.c | 11394 | skipgrp (cob_dump_symbols) | SCRATCH | volatile local in cob_dump_symbols | reset each loop; volatile needed (setjmp) |
| common.c | 11395 | skpsym (cob_dump_symbols) | SCRATCH | volatile local in cob_dump_symbols | only meaningful within one dump |
| common.c | 11620 | wrk (cob_get_env) | SCRATCH | local buffer in cob_get_env | used when envused == NULL |
| common.c | 11857 | cob_debug_hdr | ifdef | C2 ctx->common.debug_hdr | COB_DEBUG_LOG |
| common.c | 11858 | cob_debug_prv_line | ifdef | C2 ctx->common.debug_prv_line | COB_DEBUG_LOG |

Notes on `cobsetptr`/`gc_conf` mutation at runtime: `cob_rescan_env_vals()` is
called after `DISPLAY ... UPON ENVIRONMENT-VALUE` (l.6048), `cob_putenv` (l.5988),
and the runtime-option setters write directly into `cob_settings`
(`set_config_val`, l.8367; side effects on `cob_switch`, screenio). So
`rt->set` is not read-only after init. Options: (a) per-ctx copy of
`cob_settings` (copy-on-create from rt, mutations local to the task), (b) a
rwlock on rt->set + gc_conf. (a) matches CICS semantics better.

### Non-reentrant libc calls / process-wide side effects

| line | call | function | note |
|---|---|---|---|
| 738 | setlocale | cob_exit_common | restore process locale |
| 1016 | strerror | cob_get_strerror | use strerror_r (comment claims "reentrant", it is not) |
| 1177, 6749, 7214 | system | create_dumpfile, cob_sys_system, cob_sys_x91 | forks a shell, SIGCHLD handling process-wide |
| 1198-1292, 1540-1582 | sigaction / signal | cob_sig_handler, cob_set_signal | process-wide (T2) |
| 1600-1623 | sigprocmask + sigaction | cob_set_dump_signal | sigprocmask undefined in MT -> pthread_sigmask; installs process-wide handler during a dump (conflicts across tasks) |
| 1368, 3529, 3586, 3622 | longjmp(return_jmp_buf) | signal handler, cob_stop_run, cob_hard_failure, cob_fatal_error | longjmp from signal handler into the right task needs TLS ctx |
| 2511, 2562 | getcwd | cob_find_path_internal | ok (writes to static buffer file_path_name) |
| 2574, 2612, 2618, 2620, 2687, 2834, 6085, 6100, 6315, 6382, 8198, 8893, 9113, 9440, 10539, 10686, 10725, 10811, 11628-11682 | getenv | various | safe only if no concurrent setenv/putenv; returned pointer may be invalidated |
| 5916-5955, 5986, 6041 | setenv / unsetenv / putenv | cob_setenv, cob_unsetenv, cob_putenv, cob_display_environment | process environment shared by all tasks; DISPLAY UPON ENVIRONMENT-VALUE in one task is visible to all and races with getenv |
| 8852ff | setenv (config "setenv"/"unsetenv") | cb_config_entry | init time only |
| 10687 | putenv | cob_init | init time only |
| 4655, 4657 | qsort with global comparator state | cob_table_sort (sort_compare, sort_compare_collate use share_sort_state) | use qsort_r (glibc/BSD arg order differ) or internal sort taking state |
| 5062 | localtime | set_cob_time_from_localtime | use localtime_r |
| 5095 | gmtime | set_cob_time_from_localtime (no tm_gmtoff path) | use gmtime_r; tmptr reused after mktime |
| 5256 | localtime | cob_get_current_datetime | localtime_r |
| 5578 | localtime | check_current_date | localtime_r |
| 5093, 5096, 5266, 5603 | mktime | | reads TZ (tzset), ok-ish |
| 7427 | fork | cob_sys_fork | resets cob_process_id; unsafe in MT host |
| 7791-7803 | setlocale (save/switch/restore LC_CTYPE) | cob_sys_printable | process-wide, races between tasks -> uselocale/newlocale per thread or isprint_l |
| 7905-7943 | setlocale | cob_set_locale | SET LOCALE: process-wide; per-ctx locale needs uselocale() at task switch |
| 10729-10763 | setlocale | cob_init | init time |
| 11551-11567 | setlocale (save/switch/restore LC_CTYPE) | cob_dump_module | same as cob_sys_printable |
| 8107-8108 | strtok | var_print | use strtok_r (info output only) |
| 10527-10531 | bindtextdomain / textdomain | cob_common_init | init time, process-wide |
| 10835 | getlogin | cob_init | getlogin_r; init time |
| 10570 | setjmp(return_jmp_buf) | cob_call_with_exception_check | buffer must be per ctx |
| 11441 / 11294 | setjmp / longjmp(save_sig_env) | cob_dump_symbols / catch_sig_jmp | jump from signal handler; per ctx via TLS |

Not found: ctime, asctime, rand/srand, readdir, tmpnam/tempnam, getpw*, strsignal.

#### Callbacks without a user argument

| line | callback | note |
|---|---|---|
| 1189 | `cob_sig_handler(int)` | signal handler: must fetch TLS current ctx (only async-safe ops) |
| 11292 | `catch_sig_jmp(int)` (via cob_set_dump_signal) | needs ctx->common.dump_sig_env -> TLS ctx |
| 402 / 4320 | `cob_reg_sighnd(void (*)(int))` -> cob_ext_sighdl | user external signal handler, process-wide |
| 461 / 6477 | CBL_EXIT_PROC handlers `int (*proc)(void)` | invoked at STOP RUN; if they call libcob they need TLS ctx (or change signature to take ctx) |
| 468 / 6599 | CBL_ERROR_PROC handlers `int (*)(char *)` | invoked from cob_runtime_error; same |
| 2202 / 2231 | `sort_compare`, `sort_compare_collate` (qsort) | rely on share_sort_state -> qsort_r |
| ~855 | `mod->module_cancel.funcint(int)` | generated cancel entry, called with -20 at exit; will take ctx in new codegen |

## Mutable globals inventory: call.c, intrinsic.c, numeric.c, move.c, strings.c, cobcapi.c, cconv.c

Source: globals.tsv (built objects) + grep of the sources for `#ifdef`'d variables.
None of these 7 files has a function-local static (checked: no indented `static` in the sources, no `foo.N` symbols).
cconv.o has no entry in globals.tsv: its only mutable tables are compiled out (`HAVE_DESIGNATED_INITS` is set).
Line numbers are in libcob/<file> at the current HEAD.

Classes: C1 runtime (rt), C2 context (ctx), C3 shared cache (rt + lock), C4 process (T2), CONST, SCRATCH, ifdef (compiled out in the current build; the class is also given).

| file | line | variable | class | action | note |
|---|---|---|---|---|---|
| call.c | 99 | errbuf[64] | ifdef(_WIN32) SCRATCH | write into ctx->call.resolve_error_buff | Win32 `lt_dlerror()` emulation returns a static buffer |
| call.c | 166 | call_table | C3 | rt->call.table + lock; split per-ctx part | name/func/handle/path/no_phys_cancel are process-wide; `p->module` (set by cob_set_cancel, cleared by cancel/cob_module_clean) is per program instance, so it goes in ctx->call.modules (name->cob_module*) |
| call.c | 168 | base_preload_ptr | C3 | rt->call.preload + lock | mostly filled at init, but cob_try_preload can run later (debugger); add_to_preload also changes settings->cob_preload_str |
| call.c | 169 | base_dynload_ptr | C3 | rt->call.dynload + lock | dlopen handle cache; physical CANCEL dlcloses, so it needs a refcount across ctxs |
| call.c | 171 | cobglobptr | - | remove (use ctx) | |
| call.c | 172 | cobsetptr | - | remove (use ctx->rt) | |
| call.c | 174 | resolve_path | C1 | rt->call.resolve_path | built from COB_LIBRARY_PATH; cob_set_library_path is only called from cob_init_call |
| call.c | 175 | resolve_error | C2 | ctx->call.resolve_error | last error, read and reset by cob_resolve_error() |
| call.c | 176 | resolve_alloc | C1 | rt->call.resolve_alloc | storage behind resolve_path |
| call.c | 177 | resolve_error_buff | C2 | ctx->call.resolve_error_buff[CALL_BUFF_SIZE] | can be an inline array |
| call.c | 178 | call_buffer | SCRATCH | ctx->call.buff | cob_get_buff: name buffer in cob_call_field/cob_cancel_field; size depends on the field, so it is kept as a growing ctx buffer |
| call.c | 179 | call_filename_buff | SCRATCH | local in cob_resolve_internal() | char[COB_NORMAL_BUFF]; insert/cache_dynload copy it |
| call.c | 182 | mainhandle | C1 (ifndef COB_BORKED_DLOPEN) | rt->call.mainhandle | dlopen(NULL) at init |
| call.c | 185 | call_lastsize | SCRATCH | ctx->call.buff_size | goes with call_buffer |
| call.c | 186 | resolve_size | C1 | rt->call.resolve_size | |
| call.c | 187 | cob_jmp_primed | C2 | ctx->call.jmp_primed | cob_savenv/cob_longjmp (ifndef COB_WITHOUT_JMP) |
| call.c | 193 | system_tab[] | C1 | static const with the hash precomputed (or rt->call.sys_hash[]) | only syst_hash_val is written, once in cob_init_call; a second runtime rewrites it (racy but idempotent) |
| call.c | 268 | init_valid_char | ifdef(!HAVE_DESIGNATED_INITS) CONST | remove | drop the lazy-init fallback |
| call.c | 269 | valid_char[256] | ifdef(!HAVE_DESIGNATED_INITS) CONST | static const (spell out the full initializer) | the designated-init variant at l.202 is already const |
| intrinsic.c | 75 | cobglobptr | - | remove (use ctx) | |
| intrinsic.c | 81 | move_field | C2 | ctx->intr.move_field | survives from cob_put_indirect_field to cob_get_indirect_field |
| intrinsic.c | 83-87 | d1,d2,d3,d4,d5 | C2 (scratch) | ctx->intr.d[5] | temporaries for one operation; mpz_init2(1536) is costly, so keep them in ctx rather than on the stack |
| intrinsic.c | 90 | rand_float | C2 (ifndef DISABLE_GMP_RANDOM) | ctx->intr.rand_float | FUNCTION RANDOM state for the run unit |
| intrinsic.c | 91 | rand_state | C2 (ifndef DISABLE_GMP_RANDOM) | ctx->intr.rand_state | gmp_randstate_t |
| intrinsic.c | 93 | rand_needs_seeding | C2 | ctx->intr.rand_needs_seeding | also tells cob_exit_intrinsic whether rand_* need clearing |
| intrinsic.c | 95 | cob_mexp | C2 (scratch) | ctx->intr.mexp | do not merge with ctx->num.mexp: intrinsic code calls numeric code, so both can be in use at once |
| intrinsic.c | 96 | cob_mpzt | C2 (scratch) | ctx->intr.mpzt | |
| intrinsic.c | 98 | cob_mpft | C2 (scratch) | ctx->intr.mpft | |
| intrinsic.c | 99 | cob_mpft2 | C2 (scratch) | ctx->intr.mpft2 | |
| intrinsic.c | 100 | cob_mpft_get | dead | remove | only init/clear, never used |
| intrinsic.c | 102 | cob_pi | C1 | rt->intr.pi | lazily computed constant; compute at rt init (or pthread_once); concurrent read-only use of an mpf is safe |
| intrinsic.c | 103 | cob_sqrt_two | C1 | rt->intr.sqrt_two | same as cob_pi |
| intrinsic.c | 104 | cob_log_half | C1 | rt->intr.log_half | same as cob_pi |
| intrinsic.c | 105 | cob_log_ten | C1 | rt->intr.log_ten | same; it is computed with cob_mpf_log, which uses ctx temporaries, so compute it at init with the init ctx |
| intrinsic.c | 106-109 | set_cob_pi/sqrt_two/log_half/log_ten | C1 | remove (eager init) or rt once-flags | today they are checked unlocked on every call |
| intrinsic.c | 120 | calc_base | C2 | ctx->intr.calc[COB_DEPTH_LEVEL] | ring of 32 result fields; a returned cob_field* stays valid only until 32 more intrinsic calls in the same ctx |
| intrinsic.c | 121 | curr_field | C2 | ctx->intr.curr_field | the result pointer returned by every cob_intr_* |
| intrinsic.c | 122 | curr_entry | C2 | ctx->intr.curr_entry | |
| numeric.c | 87 | cobglobptr | - | remove (use ctx) | |
| numeric.c | 143-145 | cob_d1,cob_d2,cob_d3 | C2 (scratch) | ctx->num.d1..d3 | per-operation; cob_div_quotient uses them all; cob_decimal_print uses d3 |
| numeric.c | 146-147 | cob_t1,cob_t2 | C2 (scratch) | ctx->num.t1,t2 | add/sub/cmp alignment |
| numeric.c | 148 | cob_d_remainder | C2 | ctx->num.d_remainder | real state across calls: cob_div_quotient sets it, cob_div_remainder reads it |
| numeric.c | 150 | cob_decimal_base | C2 | ctx->num.dec_pool[COB_MAX_DEC_STRUCT] | handed to generated code by cob_decimal_alloc; all non-recursive programs share the pool; the generated `d0..dN` pointers are program statics, so codegen must take them from ctx |
| numeric.c | 152-154 | cob_mexp,cob_mpzt,cob_mpzt2 | C2 (scratch) | ctx->num.mexp,mpzt,mpzt2 | |
| numeric.c | 155 | cob_mpz_ten34m1 | C1 | rt->num.ten34m1 | constant computed at init, read-only |
| numeric.c | 156 | cob_mpz_ten16m1 | C1 | rt->num.ten16m1 | same |
| numeric.c | 157 | cob_mpze10[] | C1 | rt->num.pow10[COB_MAX_BINARY+1] | read-only after init (mpz_set/mpz_cmpabs/mpz_remove only read it) |
| numeric.c | 159 | cob_mpft | C2 (scratch) | ctx->num.mpft | |
| numeric.c | 160 | cob_mpft_get | C2 (scratch) | ctx->num.mpft_get | cob_decimal_get_mpf |
| numeric.c | 162 | i64_spaced_out | CONST | static const cob_u64_t = 0x2020202020202020 | memset to spaces at init |
| numeric.c | 164 | packed_value[20] | SCRATCH | local in cmp_packed_intern() | one-entry cache; the cache key ignores COB_FIELD_NO_SIGN_NIBBLE(f) (latent bug) |
| numeric.c | 165 | last_packed_val | SCRATCH | remove (with the cache) | |
| numeric.c | 166 | cob_not_finite | C2 | ctx->num.not_finite (better: out-param) | set in cob_decimal_get_double, read later in cob_decimal_get_field |
| numeric.c | 2731 | h2b[256] | CONST | static const | read only |
| numeric.c | 2743 | b2h[256] | CONST | static const | read only |
| move.c | 40 | cobglobptr | - | remove (use ctx) | |
| move.c | 41 | cobsetptr | - | remove | set in cob_init_move but never read |
| move.c | 44-46 | cob_locale_edit,cob_lc_dec,cob_lc_thou | ifdef(#if 0) | delete | dead code |
| move.c | 62 | all_numeric_data | SCRATCH | local in cob_move_all() (with a local cob_field) | memset then cob_move; all_numeric_field (l.63) is const but points at this buffer |
| move.c | 2495 | chopcompx[7] | CONST | static const | |
| move.c | 3021 | ebcdic_pos[11] | CONST | static const | |
| move.c | 3022 | ebcdic_neg[11] | CONST | static const | |
| strings.c | 97 | cobglobptr | - | remove (use ctx) | |
| strings.c | 105 | share_inspect_state | C2 (COB_TLS, exported) | ctx->str.inspect | the *_intern functions already take `st`; cob_exit_strings frees only the calling thread's copy (leaks in other threads) |
| strings.c | 106 | share_string_state | C2 (COB_TLS, exported) | ctx->str.string | |
| strings.c | 107 | share_unstring_state | C2 (COB_TLS, exported) | ctx->str.unstring | holds the growing dlm_list |
| strings.c | 109 | figurative_ptr | C2 (scratch) | ctx->str.fig_buf | growing buffer that alpha_fld points to during an INSPECT REPLACING/CONVERTING |
| strings.c | 110 | figurative_size | C2 (scratch) | ctx->str.fig_size | |
| strings.c | 112 | alpha_fld | SCRATCH | local cob_field in the callers (alloc_figurative fills the caller's field) | used only within one call |
| strings.c | 113 | str_cob_low | SCRATCH | local cob_field in the callers | rebuilt from COB_MODULE_PTR->collating_sequence on each use |
| cobcapi.c | 51 | const_float_attr | CONST | static const | only memcpy'd from |
| cobcapi.c | 53 | const_binll_attr | SCRATCH | local attr in cob_get_s64_param()/cob_put_s64_param() | `.scale` is written on every call (l.348, 652): a data race today |
| cobcapi.c | 55 | const_binull_attr | SCRATCH | local attr in cob_get_u64_param()/cob_put_u64_param() | `.scale` is written (l.396, 710) |
| cobcapi.c | 58 | capi_lastsize | C2 | ctx->capi.buf_size | |
| cobcapi.c | 59 | capi_buffer | C2 | ctx->capi.buf | returned by cob_get_field_str_buffered; valid until the next call in the same ctx |
| cobcapi.c | 60 | cobglobptr | - | remove (use ctx) | |
| cobcapi.c | 61 | cobsetptr | - | remove | never read |
| cobcapi.c | 68 | head_watch | C2 | ctx->capi.watch_list | debugger watch list; entries point to the cob_module of this run unit |
| cconv.c | 92 | lower_tab[256] | ifdef(!HAVE_DESIGNATED_INITS) CONST | static const (drop the fallback) | l.35 is already const |
| cconv.c | 93 | upper_tab[256] | ifdef(!HAVE_DESIGNATED_INITS) CONST | static const (drop the fallback) | l.63 is already const |

### Non-reentrant libc / library calls

| file:line | call | context | fix |
|---|---|---|---|
| call.c:392 | strtok | cob_set_library_path (init only) | strtok_r |
| call.c:2113-2114 | strtok | cob_init_call, COB_PRE_LOAD list | strtok_r |
| call.c:120,630,915,934,948,967,1169,1177 | dlerror / lt_dlerror | resolve, preload, cob_load_lib | glibc/musl dlerror is per thread, but the "clear, dlopen, dlerror" sequence must not interleave; libltdl's lt_dlerror is process-global, so do it under the rt->call lock; strcpy(reason, ...) at 1169/1177 has no bound |
| call.c:101-104 | static errbuf (Win32 lt_dlerror) | ifdef _WIN32 | ctx buffer |
| call.c (lt_dlopen/lt_dlsym/lt_dlclose, lt_dlinit 2086) | libltdl | everywhere | libltdl 2.x is not thread-safe: serialize under the rt lock; lt_dlinit/lt_dlexit are refcounted per process (C4/T2) |
| call.c:759,766,891,893 | toupper/tolower/isupper/islower | name folding | use the global locale, which intrinsic.c setlocale() changes; use ASCII-only helpers (cob_toupper) |
| cconv.c:158 | getenv("COB_CONFIG_DIR") | cob_load_collation | read once into rt->settings (config_dir) |
| intrinsic.c:1787 | localtime | get_interval_and_current_year_from_args | localtime_r |
| intrinsic.c:5725 | localtime | cob_intr_year_to_yyyy | localtime_r |
| intrinsic.c:5861 | localtime | get_seconds_past_midnight | localtime_r |
| intrinsic.c:1817,1826 | setlocale(LC_TIME)/setlocale(LC_ALL, cob_locale) | locale_time (LOCALE-TIME) | process-wide: newlocale + nl_langinfo_l/strftime_l (_create_locale/_strftime_l on Win32) |
| intrinsic.c:1822 | nl_langinfo(T_FMT) | locale_time | returns a static buffer: nl_langinfo_l |
| intrinsic.c:6001,6006 | setlocale | cob_intr_locale_date | same as locale_time |
| intrinsic.c:6004 | nl_langinfo(D_FMT) | cob_intr_locale_date | nl_langinfo_l |
| intrinsic.c:6555,6574 | setlocale(LC_COLLATE)/setlocale(LC_ALL) | cob_intr_locale_compare | strcoll_l with a newlocale object |
| intrinsic.c:6171,6206,6241,6276,6311 | localeconv | cob_intr_mon_decimal_point, num_decimal_point, mon_thousands_sep, num_thousands_sep, currency_symbol | static struct that setlocale invalidates: nl_langinfo_l(RADIXCHAR/THOUSEP/CRNCYSTR), or cache in rt at init (C1) |
| intrinsic.c:5421 | qsort(comp_field) | cob_intr_median | the comparator gets no user argument but calls cob_cmp, which needs ctx (module collating sequence): own sort or a qsort_r wrapper (glibc and BSD argument orders differ) |
| intrinsic.c:5566,5568,5575,5577 | srandom/srand/random/rand | cob_intr_random, DISABLE_GMP_RANDOM only | process-global PRNG: erand48/rand_r-like state in ctx->intr |
| intrinsic.c:1882,6042 | GetTimeFormat/GetDateFormat | Win32 | reentrant, OK |
| numeric.c:4732 | cob_raise(SIGFPE) | POW_IMPL (cob_s32_pow/cob_s64_pow, negative power with base 0) | process signal: T2 (C4) |

No libc problems found in move.c, strings.c, or cobcapi.c (strcasecmp/strcpy only).

### Callbacks without a user argument (ctx cannot be passed)

| file:line | callback | fix |
|---|---|---|
| intrinsic.c:574 / 5421 | comp_field for qsort | see above (own sort taking ctx) |
| call.c:462-463 | `module_cancel.funcint(-1)` in do_cancel_module | generated cancel entry should become `PROG__cancel(ctx, -1)`, or get a ctx-taking variant |
| call.c:1360-1361 | `cob_cstr_cancel.funcint(-1)` in cob_cancel_field (contained programs) | same |
| call.c:193 system_tab / 1241-1251 | CBL_* / SYSTEM routines returned as plain C entry points (syst_call) | ~~give them `__ctx` variants~~ superseded: they read the current context at entry (DESIGN §4.1) |
| call.c:1370+ (cob_call), 1638 (cob_func), 1648 (cob_call_cobol), 1757 (cob_call_entry) | call through `funcint(void*,...)` without ctx | ~~`NAME__ctx` resolution~~ superseded: unchanged C ABI, callee reads the current context (DESIGN §4.1) |
| call.c:1053-1068 | cob_set_cancel stores m->module_entry.funcvoid | same ABI flag needed |

## Inventory of mutable globals: libcob file I/O (fileio.c + file-handler backends)

Scope: fileio.c, fextfh.c, focextfh.c, fsqlxfd.c, fbdb.c, flmdb.c, fodbc.c, foci.c, fisam.c,
and libcobci.c / libcobdi.c / libcobvb.c / libcobvc.c. The four libcob*.c files are 24-line
wrappers (`#define IS_ISAM_LIB` + `#define FOR_xISAM` + `#include "fisam.c"`), so they have the
same globals as fisam.c: one private copy per backend module. fsqlxfd.c is also compiled into
each SQL/DB module (libcobdb, libcoblm, libcobod, libcobvc and libcob), with its own statics in
each copy.

Built here: fileio, fextfh, fsqlxfd, fbdb, flmdb, fodbc, libcobvc (and therefore fisam with FOR_VISAM).
Not built here (checked in the source only): foci (WITH_OCI), focextfh (WITH_INDEX_EXTFH / WITH_SEQRA_EXTFH),
libcobci, libcobdi and libcobvb.

The `ifdef` marker in the note column means the variable is only compiled under the stated condition.

Action notation: `ctx->fileio.x` is the per-task file-I/O sub-struct, `ctx->db.x` is per-task
DB-backend state (one sub-struct per backend, kept in a per-backend slot of ctx), and `rt->fileio.x`
is the per-process runtime.

### Table

| file | line | variable | class | action | note |
|---|---|---|---|---|---|
| fileio.c | 201 | `file_globptr` (exported) | C2 | remove (use ctx) | `cobglobptr` is #defined to it in fileio.h:24, and backend modules use it as well |
| fileio.c | 202 | `file_setptr` (exported) | C1 | remove (use ctx->rt) | `cobsetptr` is #defined to it. NB: init writes into it (cob_sort_chunk, var*_type at 10169-10188, bdb_home and lmdb_home defaults), so finish all of it during rt init |
| fileio.c | 204 | `delete_file_status` | C2 | ctx->fileio.delete_file_status | set by DELETE FILE and read by save_status |
| fileio.c | 205 | `eop_status` (exported) | C2 | ctx->fileio.eop_status | pending EOP exception between WRITE and save_status |
| fileio.c | 206 | `check_eop_status` | C2 | ctx->fileio.check_eop | set in cob_write and read by the LINAGE code. Could be passed as a parameter instead |
| fileio.c | 208 | `file_cache` | C2 | ctx->fileio.file_cache | list of the run unit's open files, used for implicit CLOSE at exit |
| fileio.c | 210 | `file_open_env` | C2 | ctx->fileio.file_open_env | slice of runtime_buffer, holds the ASSIGN name |
| fileio.c | 211 | `file_open_name` | C2 | ctx->fileio.file_open_name | resolved name, read across many functions |
| fileio.c | 212 | `file_open_buff` | C2 | ctx->fileio.file_open_buff | also exported to backends through `file_api.file_open_buff` |
| fileio.c | 213 | `file_open_io_env` | C2 | ctx->fileio.io_env | pointer into getenv() storage, set during mapping and read in open |
| fileio.c | 215 | `runtime_buffer` | C2 | ctx->fileio.runtime_buffer | 4*COB_FILE_BUFF block that backs the three buffers above. Also returned by cob_get_filename_print |
| fileio.c | 217 | `chk_file_path` | C1 | remove (compute file_paths in rt init) | flag meaning "do it once" |
| fileio.c | 218 | `chk_filename_spaces` | C1 | rt->fileio.filename_spaces | read from COB_FILENAME_SPACES once |
| fileio.c | 221 | `file_api` | C3 | split: rt->fileio.api (callbacks, io_funcs, file_paths) + pass ctx | glbptr/setptr: remove. file_open_buff: ctx. io_funcs is filled lazily (see io_rtns). The struct is handed to every backend, so change the backend API so that it receives ctx |
| fileio.c | 223 | `qblfd` | C2 | ctx->fileio.qbl.fd | QBL (rollback journal) belongs to the run unit |
| fileio.c | 224 | `qblfilename[256]` | C2 | ctx->fileio.qbl.filename | name comes from cob_temp_name. Needs a per-task unique name, see the cob_temp_iteration note |
| fileio.c | 225 | `qblhdrsz` | C2 | ctx->fileio.qbl.hdrsz | |
| fileio.c | 240 | `qbl_hdr` | C2 | ctx->fileio.qbl.hdr | grown buffer |
| fileio.c | 241 | `qbl_tmp` | C2 | ctx->fileio.qbl.tmp | grown buffer |
| fileio.c | 244 | `file_paths` | C1 | rt->fileio.file_paths | split of COB_FILE_PATH, computed once |
| fileio.c | 245 | `prefix[]` | CONST | none | already `const char *const` (it sits in .data only because of relocations) |
| fileio.c | 271 | `sequential_funcs` | CONST | static const | never written |
| fileio.c | 290 | `lineseq_funcs` | CONST | static const | |
| fileio.c | 309 | `relative_funcs` | CONST | static const | |
| fileio.c | 328 | `not_available_funcs` | CONST | static const | |
| fileio.c | 347 | `fileio_funcs[COB_IO_MAX]` | C3 | rt->fileio.io_funcs + lock/once | filled by the backend `ioinit` on lazy cob_load_module. Alternative: load every configured module at rt init, which makes it C1 |
| fileio.c | 369 | `io_rtns[]` (.loaded/.config) | C3 | rt->fileio.io_rtns + lock/once | .config is C1 (set at init). .loaded is mutated lazily. Name/module/entry/desc are const, so split them into a const table |
| fileio.c | 536 | `file_format[12]` | CONST | static const char *const | |
| fileio.c | 537 | `dict_ext` | CONST | static const char *const | |
| fileio.c | 111 | `heap_array[512]` (VFILE) | C2 | ctx->fileio.vfile heaps (alloc lazily) | 24 KB. CBL_OPEN_VFILE handles. A comment says it is meant to be shared over all threads. If that is required, make it C3 + lock |
| fileio.c | 1340 | `module_errmsg[256]` | C3 | rt->fileio.io_rtns[i].errmsg (under the load lock) | written by cob_load_module and read by output_io_module_error |
| fileio.c | 1341 | `module_msg[256]` | SCRATCH | ctx->fileio.msgbuf or caller buffer | return buffer of cob_io_version |
| fileio.c | 3981 | `mfhdrmark2[4]` | CONST | static const | |
| fileio.c | 3982 | `mfhdrmark4[4]` | CONST | static const | |
| fileio.c | 10033 | `implicit_close_of_msgid` (exported) | C1 | rt->fileio.implicit_close_msgid | gettext result, set at init |
| fileio.c | 10039 | `output_done` (fn static, cob_exit_fileio_msg_only) | C2 | ctx->fileio.exit_msg_done | "once" flag at run-unit exit. C4 if it stays process-exit only |
| fextfh.c | 35 | `fcd_file_list` | C2 | ctx->fileio.fcd_list | FCD to cob_file mapping. FCDs belong to programs, so the list is per task |
| fextfh.c | 37 | `tmpfcd` | SCRATCH | local in EXTFH (FCD2 to FCD3) or ctx | ifdef `!COB_64_BIT_POINTER` |
| fextfh.c | 1465 | `keywrk[80]` (fn static) | SCRATCH | ctx->fileio.keywrk or stack in the caller | kf->data points to it after return, so it must outlive the call |
| fextfh.c | 39-40 | `alnum_attr`, `compx_attr` | CONST | none | already const |
| focextfh.c | 30 | `fileio_funcs` | C1 | remove (use a->io_funcs / rt) | copied pointer. ifdef WITH_INDEX_EXTFH or WITH_SEQRA_EXTFH |
| focextfh.c | 77/270/288 | `ext_indexed_funcs`, `ext_sequential_funcs`, `ext_relative_funcs` | CONST | static const | ifdef as above |
| focextfh.c | 31 | `io_rtn_name[]` | CONST | static const char *const | ifdef |
| fsqlxfd.c | 152 | `high_value[6]` | C2 | ctx->db (inside struct db_state) | lazy: from SQL_HIGH_VALUE(S) env (C1 part), then overridden by db type (mysql/postgres), which is a per-connection property. One copy per module |
| fsqlxfd.c | 153 | `len_high_value` | C2 | db_state->len_high_value | same as above |
| fsqlxfd.c | 671 | `daysinmonth[]` | CONST | static const short | |
| fsqlxfd.c | 1932 | `condname[20]` | CONST | static const char *const | ifdef COB_DEBUG_LOG |
| fsqlxfd.c | 1935 | `condstr[9]` | CONST | static const char *const | |
| fbdb.c | 51 | `ext_indexed_funcs` | CONST | none | already const |
| fbdb.c | 71 | `bdb_env` | C3 | rt->bdb.env + lock (open with DB_THREAD) | nulled by the panic callback. The env is shareable across threads only if opened with DB_THREAD, which the current flags (CREATE, INIT_MPOOL, INIT_CDB) do not set. Per-ctx is possible but costs one env per task on the same home |
| fbdb.c | 72 | `bdb_home_dir` | C1 | rt->bdb.home_dir | copy of bdb_home, used to remove the env at exit |
| fbdb.c | 73 | `bdb_buff` | SCRATCH | ctx->bdb.buff, or local in ix_bdb_open with bdb_nofile writing into it | path filled by bdb_nofile and read later in open (1346, 1451) |
| fbdb.c | 74 | `bdb_data_dir` | C1 | rt->bdb.data_dirs | from env->get_data_dirs after the join |
| fbdb.c | 75 | `record_lock_object` | SCRATCH | ctx->bdb.rlo (or per-file buffer) | grown buffer for lock DBTs |
| fbdb.c | 76 | `rlo_size` | SCRATCH | ctx->bdb.rlo_size | |
| fbdb.c | 77 | `bdb_lock_id` | C2 | ctx->bdb.locker_id | BDB locker ID. Must be per task, otherwise record locks from two tasks do not conflict. Allocate it via env->lock_id at the task's first open and free it at run-unit end |
| fbdb.c | 78 | `bdb_join` | C3 | rt->bdb.joined (once/lock) | lazy env join at the first OPEN |
| fbdb.c | 110 | `bdb_app_data` (COB_TLS) | C2 | remove: use `db->app_private` (set per DB handle) in bdb_bt_compare | the TLS hack passes the collating sequence to the compare callback. DB* is available in the callback |
| fbdb.c | 327 | `buff[64]` (fn static, ix_bdb_version) | C1 | rt->bdb.version or static const / caller buffer | the ioversion() callback has no args |
| fbdb.c | 344 | `bdb_err_tear_down` | C3 | rt->bdb.tear_down (atomic) | set by the panic event callback, which can run from any thread |
| flmdb.c | 51 | `lmdb_funcs` | CONST | none | already const |
| flmdb.c | 71 | `db_buff` | SCRATCH | local in lmdb_open (char[COB_FILE_MAX]) | path built in open and used in the same call |
| flmdb.c | 72 | `db_data_dir` | CONST | delete | only ever set to NULL |
| flmdb.c | 93 | `versbuff[60]` (fn static) | CONST | static const string via preprocessor stringify | ioversion has no args. Contents are compile-time |
| flmdb.c | 366 | `line[128]` (fn static, local_file) | SCRATCH | local in local_file() | |
| flmdb.c | 367 | `devname[128]` (fn static, local_file) | SCRATCH | caller buffer | returned through *pname. Also note the FILE* leaks (no fclose) |
| flmdb.c | 1577 | (writes `cobglobptr`/`cobsetptr` = file_globptr/file_setptr) | C1 | remove (use ctx) | the backend init overwrites libcob's exported pointers |
| fodbc.c | 41 | `condname[20]` | CONST | static const char *const | ifdef COB_DEBUG_LOG |
| fodbc.c | 63 | `odbc_indexed_funcs` | CONST | none | already const |
| fodbc.c | 83 | `db_join` | C2 | ctx->odbc.joined | lazy connect at the first OPEN or DELETE FILE |
| fodbc.c | 84 | `db[1]` (struct db_state, 752 B) | C2 | ctx->odbc.db (per-task connection) | holds HENV/HDBC, transaction state (autocommit, updatesDone, COMMIT/ROLLBACK), dbStatus and DB type flags. COMMIT belongs to the run unit, so the HDBC cannot be shared between tasks. Only SQLHENV could be C3 (rt->odbc.henv). A pool is optional (C3 + lock, lease per task) |
| fodbc.c | 85 | `useDriverCursor` | CONST | static const (or rt option) | never written |
| fodbc.c | 86 | `useIfneededCursor` | CONST | static const (or rt option) | never written |
| fodbc.c | 87 | `varFetch[256]` | C2 | db_state->varFetch | result of the last single-row odbcStmt, read by callers |
| fodbc.c | 88 | `varFetch2[256]` | C2 | db_state->varFetch2 | |
| foci.c | 51 | `oci_indexed_funcs` | CONST | none | already const. ifdef WITH_OCI |
| foci.c | 71 | `db_join` | C2 | ctx->oci.joined | ifdef WITH_OCI |
| foci.c | 72 | `db[1]` (struct db_state) | C2 | ctx->oci.db | OCIEnv, service context and transaction state. ifdef WITH_OCI. Env created without OCI_THREADED, so it cannot be shared |
| foci.c | 73 | `varFetch[80]` | C2 | db_state->varFetch | ifdef WITH_OCI |
| foci.c | 96 | `versbuff[60]` (fn static) | CONST | static const string | ifdef WITH_OCI + OCI_MAJOR_VERSION |
| fisam.c (+libcobci/di/vb/vc) | 72 | `isam_globptr` | C2 | remove (use ctx) | `cobglobptr` is #defined to it |
| fisam.c (+libcob*) | 73 | `isam_setptr` | C1 | remove (use ctx->rt) | `cobsetptr` is #defined to it |
| fisam.c (+libcob*) | 136 | `vbisam_rtd` | C2 | ctx->isam.rtd (fetch VB_GET_RTD per thread/task) | ifdef VB_RTD (VBISAM 2.1.1+/V-ISAM). If VB_GET_RTD is thread-local inside VBISAM, caching it once at init is wrong for other threads |
| fisam.c (+libcob*) | 232 | `ext_indexed_funcs` | CONST | none | already const |
| fisam.c (+libcob*) | 253 | `max_keycomp` | C1 | rt->isam.max_keycomp (or a compile-time const) | clamped in init and again in isam_version. The value comes from NPARTS/ISMAXPARTS, so it can be a constexpr |
| fisam.c (+libcob*) | 254 | `isam_name` | C1 | static const per build (#if) | set in init from #if branches. Never differs at runtime |
| fisam.c (+libcob*) | 820 | `msg[64]` (fn static, isam_version) | C1 | rt->isam.version or caller buffer | ioversion() takes no args |

Counts (table rows; the libcob*.c copies are counted once with fisam.c, and the focextfh funcs row covers 3 variables):
- C1 (runtime): 14
- C2 (context): 31
- C3 (shared cache): 7
- C4 (process): 0 among the variables. C4 concerns are listed in the next section
- CONST: 26 (about 8 of them are already const or only need an extra `const`)
- SCRATCH: 9

Pure "cached global pointer" copies, to be removed and replaced by ctx / ctx->rt: `file_globptr`, `file_setptr`,
`isam_globptr`, `isam_setptr`, the writes in flmdb.c:1577, and `fileio_funcs` in focextfh.c.

### Non-reentrant libc calls

| file:line | call | fix |
|---|---|---|
| fileio.c:1866, 1881 | `strtok` (cob_chk_file_mapping) | `strtok_r` |
| fileio.c:4064 | `localtime` (MF file header) | `localtime_r` |
| fileio.c:8715, 8991 | `localtime` (CBL_CHECK_FILE_EXIST / file info) | `localtime_r` |
| fileio.c:1120, 1134, 1243 | `strerror` | `strerror_r`. Note that `cob_get_strerror()` (common.c:1011) also calls plain `strerror`, despite its "reentrant" comment |
| fsqlxfd.c:1088, 1400 | `cob_get_strerror` | same as above |
| fileio.c:5331-5332, 5491 | `setlocale(LC_CTYPE, ...)` save/restore around LS validation | `uselocale`/newlocale per ctx. ifdef COB_EXPERIMENTAL && HAVE_SETLOCALE |
| fileio.c:1477; fodbc.c:1176; foci.c:909; fsqlxfd.c:1045, 1389, 1847-1899 | `getenv` (COB_SCHEMA_DIR, COB_SCHEMA_NAME, <schema>_DSN/_UID/_PWD/...) | safe only while nobody setenv's. Cache in rt at init, or read through a locked env snapshot |
| fileio.c:1554-1633, 10159; fsqlxfd.c:1829 | `cob_get_env` (DD_/dd_/IO_ mapping, IO_OPTIONS, SQL_HIGH_VALUE) | the result pointer is kept in `file_open_io_env` across calls. A concurrent SET ENVIRONMENT (setenv) can invalidate it, so copy it into ctx |
| flmdb.c:377, 888 | `getenv` (MDB_NO_LOCAL_FS_CHK, MDB_NO_SHARED_FS_CHK) | move to rt settings, as the TODO in the code already says |
| foci.c:290, 295, 300 | `putenv` (ORACLE_UID/PWD/SID), malloc'd strings leaked | must not modify the process environment from a task. Pass the values to OCI directly. ifdef WITH_OCI |
| flmdb.c:895 | `dirname` | POSIX allows a static result. Use a manual strrchr on a local copy |
| fileio.c:8866 (CBL_CHANGE_DIR) | `chdir` | changes the process-wide cwd for all tasks. C4: keep a per-ctx cwd and resolve relative paths against it (or use openat) |
| fileio.c:4565-4600 | `fork` + `execv` (pipe files) and `signal(SIGPIPE, SIG_IGN)` | C4: signal disposition is process-wide. The fork child calls cob_runtime_error/cob_stop_run, which is not async-signal-safe in an MT process. Use posix_spawn |
| fileio.c:3040 (and every fcntl lock) | `fcntl` F_SETLK record/file locks, compared against `cob_sys_getpid()` | POSIX record locks are per process: two tasks in the same process never conflict, and close() of any fd on the file drops all of the process's locks. Use OFD locks (F_OFD_SETLK, Linux/glibc 2.20+) or an in-process lock table in rt (C3) |
| fileio.c:7333, 9177-9178 | `cob_temp_name` + `cob_incr_temp_iteration` (common.c: global `cob_temp_iteration`, name built from pid) | two tasks can get the same QBL/sort temp name. Use an atomic counter in rt, or put a task id in the name |
| fbdb.c (many) | `db_strerror` | returns a static buffer for unknown codes (safe for known codes) |
| flmdb.c:493 | `mdb_strerror` | falls back to `strerror` for system errors |

No qsort, rand, readdir, tmpnam, ctime, gmtime, asctime or strtok_r misuse found in these files.
SORT uses its own merge with `cob_file_sort_compare(k1, k2, void *pointer)`, which already takes a user arg.

### Callbacks without a user argument

- `struct cob_fileio_funcs.ioversion(void)`: every backend returns a static buffer (fbdb buff, flmdb versbuff,
  foci versbuff, fisam msg), and fileio uses module_msg. Make it return a const string or take `(char *buf, size_t)`.
- `ioinit(cob_file_api *)`, `ioexit(cob_file_api *)`, `iofork(cob_file_api *)`: these get file_api but no ctx.
  They are process-level hooks (C3/C4), so passing rt is enough. The other `cob_fileio_funcs` entries need `ctx`
  (or `ctx` reachable from cob_file).
- `file_api` callbacks `add_file_cache` / `del_file_cache` / `chk_file_mapping` / `cob_write_dict` /
  `cob_read_dict` / `cob_file_write_opt` take no ctx and touch ctx state (file_cache, file_open_*). Add ctx.
- BDB `bdb_bt_compare(DB*, const DBT*, const DBT*[, size_t*])`: there is no user arg, so the code uses the
  COB_TLS `bdb_app_data` hack. Use `db->app_private` instead (the DB handle is per file, and the collating
  sequence is per key, so set it per key's DB).
- BDB `bdb_err_event(DB_ENV*, u_int32_t, void*)`: use `env->app_private` to reach rt. It mutates `bdb_env`
  and `bdb_err_tear_down` from whatever thread hits the panic, so these need to be atomic.
- BDB `set_alloc(cob_malloc, realloc, cob_free)`: cob_malloc's failure path calls cob_runtime_error, which
  needs ctx. Only the TLS "current ctx" is available there.
- fextfh.c `EXTFH()` / `EXTFH3()`: a C entry point with auto `cob_init` (fextfh.c:1515). This is a boundary
  function, so it must take ctx from the TLS current context, or create one.
- CBL_*_VFILE and CBL_CHANGE_DIR etc. are called from COBOL with params read through `cobglobptr->cob_call_params`
  and `COB_MODULE_PTR`. They need ctx through the standard call ABI.

### Third-party library thread-safety

- **Berkeley DB** (fbdb): the env is opened `DB_CREATE|DB_INIT_MPOOL|DB_INIT_CDB` without `DB_THREAD`, so DB_ENV/DB/DBC
  handles must not be used concurrently by several threads. To share one env per process (recommended: one env
  per home dir, C3), add `DB_THREAD` (and then use DB_DBT_MALLOC/USERMEM for returned DBTs). Cursors and DB
  handles should stay per file, and files are per ctx. The locker id (`bdb_lock_id`) must become per task, or tasks
  will not lock each other out. CDS (`DB_INIT_CDB`) allows a single writer per database at a time, so tasks
  serialize on writes. Threads that hold cursors and wait on each other can deadlock, and `set_lk_detect` only covers
  the lock subsystem. `ix_bdb_exit_fileio` closes and `remove`s the env at process exit: that must happen only once,
  when the last task ends (rt refcount).
- **LMDB** (flmdb): the code creates one `MDB_env` per opened file (`p->db_env`). LMDB forbids opening the same
  environment twice in one process (closing one releases the other's POSIX locks), so two tasks opening the same file
  would break. A process-wide env cache keyed by path is needed (C3 + lock, refcounted). Without `MDB_NOTLS`, read txns
  are bound to the creating thread: add `MDB_NOTLS` if a task can migrate between threads. Write txns are
  exclusive per env (other tasks block), and a txn must never cross threads. `get_dupno` allocates nested txns.
- **ODBC** (fodbc): SQLHENV can be shared (with the DM thread-safe on unixODBC/Windows, which is normal). An SQLHDBC
  holds the transaction (COMMIT/ROLLBACK/autocommit), so it must be per task (C2). Statements (`fx->key[]...handle`)
  live in `struct file_xfd`, which is loaded per file (`cob_load_xfd(db, f, ...)`), so they are per ctx once db moves.
  Driver thread-safety varies (SQLite and some MySQL drivers need serialized mode). Option: an rt-level connection pool
  that leases one HDBC per task.
- **Oracle OCI** (foci): `OCIEnvCreate(..., OCI_DEFAULT|OCI_NO_UCB ...)` or `OCI_OBJECT` without `OCI_THREADED`, so the
  env must not be shared between threads. Either create one env per ctx (simple, matches the current code) or
  one shared `OCI_THREADED` env with a per-task service context/session (C3). `putenv` of credentials is
  process-global (see above).
- **C-ISAM / D-ISAM / VBISAM / V-ISAM** (fisam + libcob{ci,di,vb,vc}): `iserrno`, `isrecnum`, `isreclen` and `isstat1/2` are
  process globals in C-ISAM and classic D-ISAM/VBISAM (45 ISERRNO uses in fisam.c). C-ISAM is not thread-safe.
  D-ISAM has a thread-safe build (per-thread iserrno via a function macro), so check the installed build. VBISAM 2.1.1+
  and V-ISAM expose `vb_rtd_t` through `VB_GET_RTD`: it must be fetched per thread/ctx, not cached once in a
  static. Internal isfd tables and fcntl locking are per process (same issue as the fcntl locks above), and
  `iscleanup()` in exit is process-wide (C4). Short of a TS build, all xISAM calls need a global mutex (C3 lock).
- fsqlxfd.c is linked into every DB module, so each module has its own copy of `high_value`. Moving it into
  `struct db_state` fixes both the duplication and the per-connection dependency.

## Inventaire des globales mutables : screenio.c, termio.c, reportio.c, mlio.c, profiling.c, cobgetopt.c

Sources : `globals.tsv` (nm des .o construits) recoupé avec le source (libcob/*.c, HEAD de travail).
`ifdef` = absent du binaire construit ici (branche compilée hors). Les variables déjà `static const`
(`const_alpha_attr`, `const_num_attr`, `bin_digits`, `xml_event_name_len` dans la variante designated-init) ne sont pas listées.

Classes : C1 runtime, C2 context, C3 cache partagé, C4 process (C4-terminal = lié à l'unique terminal curses),
CONST, SCRATCH. « remove » = copie en cache de `cobglobptr`/`cobsetptr`.

| file | line | variable | class | action | note |
|---|---|---|---|---|---|
| screenio.c | 128 | cob_mask_accept | C4-terminal | rt->screen.mask_accept | HAVE_MOUSEMASK ; reflète le mousemask() appliqué au terminal |
| screenio.c | 129 | cob_mask_routine | CONST | static const (=0) or remove | jamais écrite, seulement lue en 5223 |
| screenio.c | 160 | cobglobptr | remove | remove (use ctx / ctx->rt) | positionnée dans cob_init_screenio 5285 |
| screenio.c | 161 | cobsetptr | remove | remove (use ctx->rt->settings) | idem |
| screenio.c | 168 | cob_base_inp | SCRATCH | per-ACCEPT struct (stack) or ctx->screen.inp_buf | tableau de champs d'un ACCEPT ; malloc réutilisé, libéré à l'exit |
| screenio.c | 169 | totl_index | SCRATCH | per-ACCEPT struct | nb de champs de l'ACCEPT en cours |
| screenio.c | 170 | cob_has_color | C4-terminal | rt->screen.has_color | calculé après initscr/start_color |
| screenio.c | 171 | global_return | SCRATCH | per-ACCEPT struct | code retour remis à 0 en début d'ACCEPT |
| screenio.c | 172 | cob_current_y | SCRATCH | per-statement struct | écrit dans cob_move_cursor/prep, lu dans prep_input |
| screenio.c | 173 | cob_current_x | SCRATCH | per-statement struct | idem |
| screenio.c | 174 | fore_color | C4-terminal | rt->screen.fore_color | couleur courante de la fenêtre active (panels) |
| screenio.c | 175 | back_color | C4-terminal | rt->screen.back_color | idem |
| screenio.c | 176 | stdscr_fore_color | C4-terminal | rt->screen.stdscr_fore | lu de pair_content(0) à l'init |
| screenio.c | 177 | stdscr_back_color | C4-terminal | rt->screen.stdscr_back | idem |
| screenio.c | 178 | origin_y | SCRATCH | per-statement struct | origine LINE de l'écran en cours d'ACCEPT/DISPLAY |
| screenio.c | 179 | origin_x | SCRATCH | per-statement struct | idem COL |
| screenio.c | 180 | display_cursor_y | C4-terminal | rt->screen.display_cursor_y | position « suivante » après DISPLAY ; per-ctx seulement si un écran par tâche |
| screenio.c | 181 | display_cursor_x | C4-terminal | rt->screen.display_cursor_x | idem |
| screenio.c | 182 | accept_cursor_y | C4-terminal | rt->screen.accept_cursor_y | idem après ACCEPT |
| screenio.c | 183 | accept_cursor_x | C4-terminal | rt->screen.accept_cursor_x | idem |
| screenio.c | 184 | pending_accept | C4-terminal | rt->screen.pending_accept | DISPLAY sans ACCEPT -> attente d'une touche à l'exit |
| screenio.c | 185 | got_sys_char | C4-terminal | rt->screen.got_sys_char | lecture en 2 temps de x'00'+touche (CBL_READ_KBD_CHAR) |
| screenio.c | 186 | save_cursor_x | C4-terminal | rt->screen.save_cursor_x | curseur stdscr sauvé avant bascule de panel |
| screenio.c | 187 | save_cursor_y | C4-terminal | rt->screen.save_cursor_y | idem |
| screenio.c | 188 | mywin | C4-terminal | rt->screen.win | fenêtre curses active (stdscr ou panel) |
| screenio.c | 251 | my_panels[20] | C4-terminal | rt->screen.panels | WITH_PANELS ; PANEL*/WINDOW* curses |
| screenio.c | 277 | curr_setting_mouse_flags | C4-terminal | rt->screen.mouse_flags | HAVE_MOUSEMASK ; cache du dernier mousemask() |
| screenio.c | 793 | control_attrs[] | CONST | static const | table triée pour bsearch, jamais modifiée |
| screenio.c | 4790 | first_accept (cob_screen_accept) | C3 | rt->warned flag (atomic) or ctx | ifdef (!WITH_EXTENDED_SCREENIO) ; avertissement unique |
| screenio.c | 4818 | first_accept (cob_accept_field) | C3 | rt->warned flag (atomic) or ctx | ifdef (!WITH_EXTENDED_SCREENIO) ; idem |
| screenio.c | 5204 | prev_cursor_mode | C4-terminal | rt->screen.cursor_mode | dernier curs_set() appliqué |
| termio.c | 48 | cobglobptr | remove | remove (use ctx) | posé dans cob_init_termio |
| termio.c | 49 | cobsetptr | remove | remove (use ctx->rt->settings) | idem |
| termio.c | 51 | no_syspunch_error_raised | C3 | rt flag (atomic) or ctx->term.xxx | avertissement unique ; lié à settings->cob_display_punch_file muté paresseusement |
| termio.c | 689 | dump_null_adrs | C2 | ctx->dump.null_adrs | état d'un DUMP réparti sur plusieurs appels cob_dump_field |
| termio.c | 795 | dump_prev_data[] | C2 | ctx->dump.prev_data | idem (compression des occurrences identiques) |
| termio.c | 796 | dump_index | C2 | ctx->dump.index | idem |
| termio.c | 798 | dump_idx[] | C2 | ctx->dump.idx | idem |
| termio.c | 799 | dump_idx_first[] | C2 | ctx->dump.idx_first | idem |
| termio.c | 800 | dump_idx_last[] | C2 | ctx->dump.idx_last | idem |
| termio.c | 801 | dump_skip[] | C2 | ctx->dump.skip | idem |
| termio.c | 803 | pending_dump_name[] | C2 | ctx->dump.pending_name | idem (~212 octets) |
| reportio.c | 35 | cobrpglobptr | remove | remove (use ctx) | posé dans cob_init_reportio 1399 |
| reportio.c | 36 | cobrpsetptr | remove | remove (use ctx->rt->settings) | idem |
| reportio.c | 57 | active_reports[10] | C2 | ctx->report.active | registre des rapports INITIATE pour nettoyage à l'exit ; limite fixe 10 |
| reportio.c | 1425 | rc (cob_report_initiate) | SCRATCH | local in cob_report_initiate() | `static` inutile |
| reportio.c | 1426 | rr (cob_report_initiate) | SCRATCH | local in cob_report_initiate() | idem |
| reportio.c | 1427 | sc (cob_report_initiate) | SCRATCH | local in cob_report_initiate() | idem |
| reportio.c | 1428 | k (cob_report_initiate) | SCRATCH | local in cob_report_initiate() | idem |
| reportio.c | 1529 | rc (cob_report_terminate) | SCRATCH | local in cob_report_terminate() | idem |
| reportio.c | 1530 | rr (cob_report_terminate) | SCRATCH | local in cob_report_terminate() | idem |
| reportio.c | 1531 | pl (cob_report_terminate) | SCRATCH | local in cob_report_terminate() | idem |
| reportio.c | 1659 | rc (cob_report_generate) | SCRATCH | local in cob_report_generate() | idem |
| reportio.c | 1660 | rr (cob_report_generate) | SCRATCH | local in cob_report_generate() | idem |
| reportio.c | 1661 | pl, sl (cob_report_generate) | SCRATCH | local in cob_report_generate() | idem |
| reportio.c | 1662 | maxctl, ln, num, gengrp, last_use, ctlidx | SCRATCH | local in cob_report_generate() | tous initialisés avant usage (last_use=0 à l'entrée, l.1701) |
| mlio.c | 130 (143) | xml_event_name[] | CONST | `const char *const` | 216 o .data exporté ; jamais écrit avec designated inits ; variante l.143 (ifdef !HAVE_DESIGNATED_INITS) remplie une fois par init_xml_event_list -> C1 / mieux : initialiseur positionnel const |
| mlio.c | 144 | xml_event_name_len[] | C1 | static const (positional init) | ifdef (!HAVE_DESIGNATED_INITS) ; rempli une fois dans cob_init_mlio |
| mlio.c | 183 | cobglobptr | remove | remove (use ctx ; ctx stocké dans struct xml_state) | les callbacks SAX utilisent COB_MODULE_PTR via cette globale |
| mlio.c | 1589 | last_error_code (xml_error_handler) | C2 | state->last_error_code (struct xml_state) | par parse ; dédoublonnage des messages d'erreur |
| mlio.c | 1729 | first_xml (xml_parse, WITH_XML2) | C3 | rt warned flag (atomic) or ctx | avertissement unique « XML PARSE is unfinished » |
| mlio.c | 2035 | first_xml (xml_generate stub) | C3 | rt warned flag (atomic) or ctx | ifdef (!WITH_XML2) |
| mlio.c | 2057 | first_xml (xml_parse stub) | C3 | rt warned flag (atomic) or ctx | ifdef (!WITH_XML2) |
| mlio.c | 2182 | first_json (cob_json_generate stub) | C3 | rt warned flag (atomic) or ctx | ifdef (no JSON lib) |
| profiling.c | 54 | prof_info_list | C3 | rt->prof.modules + lock | infos par module ; le pointeur est aussi en `static prof_info` dans le code généré (codegen.c:14801), donc compteurs par module process-wide ; per-ctx possible seulement si le stockage module devient per-ctx |
| profiling.c | 58 | start_times | C2 | ctx->prof.start_times | pile d'appels des procédures de la tâche |
| profiling.c | 59 | called_procedures | C2 | ctx->prof.called_procedures | idem |
| profiling.c | 60 | called_runtimes | C2 | ctx->prof.called_runtimes | idem |
| profiling.c | 62 | max_prof_depth | C2 | ctx->prof.max_depth | taille des 3 tableaux |
| profiling.c | 63 | current_idx | C2 | ctx->prof.current_idx | sommet de pile |
| profiling.c | 66 | is_active | C2 | ctx->prof.active (+ rt->prof.enabled C1) | init paresseuse depuis settings ; remis à 0 sur débordement/exit |
| profiling.c | 70 | clockid | C1 | rt->prof.clockid | HAVE_CLOCK_GETTIME ; choisi une fois (prof_setup_clock) -> le faire dans l'init runtime |
| profiling.c | 75 | qpc_freq | C1 | rt->prof.qpc_freq | ifdef (_WIN32) |
| profiling.c | 79 | cobglobptr | remove | remove (use ctx) | |
| profiling.c | 80 | cobsetptr | remove | remove (use ctx->rt->settings) | |
| profiling.c | 89 | ns_time (get_ns_time) | C2 | ctx->prof.last_ns | horloge factice en mode test ; hors test jamais mise à jour -> garde de monotonie inopérante (bug) |
| cobgetopt.c | 81 | getopt_initialized | C2 | struct cob_getopt_state ; ctx->getopt | style glibc `_getopt_data` passé explicitement |
| cobgetopt.c | 90 | nextchar | C2 | struct cob_getopt_state | |
| cobgetopt.c | 121 | ordering | C2 | struct cob_getopt_state | |
| cobgetopt.c | 131 | first_nonopt | C2 | struct cob_getopt_state | |
| cobgetopt.c | 132 | last_nonopt | C2 | struct cob_getopt_state | |
| cobgetopt.c | 143 | cob_optarg (exported) | C2 | struct cob_getopt_state.optarg | API publique (cobgetopt.h) ; utilisée par cobc, cobcrun, cobfile, common.c CBL_GC_GETOPT |
| cobgetopt.c | 159 | cob_optind (exported) | C2 | struct cob_getopt_state.optind | idem |
| cobgetopt.c | 165 | cob_opterr (exported) | C2 | struct cob_getopt_state.opterr | idem |
| cobgetopt.c | 172 | cob_optopt (exported) | C2 | struct cob_getopt_state.optopt | idem |

#### Remarques transverses

- **screenio** : tout l'état durable est lié au terminal curses unique (C4-terminal) → un sous-struct `rt->screen`
  (ou `cob_terminal`) possédé par un seul contexte à la fois (« single-context only »). Le seul état vraiment per-task,
  c'est l'état propre à une instruction (`cob_base_inp`, `totl_index`, `global_return`, `origin_*`, `cob_current_*`),
  qui doit devenir un struct `screen_accept_state` sur la pile, passé aux fonctions internes.
  Le statut terminal est aussi dans `cob_global` (`cob_screen_initialized`, `COB_MAX_Y_COORD/X`, etc., dans common.c) : il faut le déplacer avec `rt->screen`.
- **cobgetopt** : sert aussi au compilateur et aux outils (cobc, cobcrun, cobfile), sans contexte libcob. Je recommande
  une API `cob_getopt_long_long_r (struct cob_getopt_state *, ...)` (comme glibc `_getopt_internal_r`), avec une instance
  locale dans les outils et `ctx->getopt` pour CBL_GC_GETOPT. Note : getopt permute `cob_argv` (état process).
  `_getopt_initialize` appelle aussi `cob_common_init(NULL)` (init process, voir T2).
- **termio** : `cob_display_punch_file` / `_filename` de `cob_settings` sont ouverts paresseusement et libérés à l'exécution (termio.c:405-418) :
  les settings ne sont donc pas en lecture seule (C3 + verrou, ou à ouvrir à l'init).
- **reportio** : les 17 « static » locales sont du pur bruit. Elles cassent déjà toute récursion/réentrance.
- **Bug relevé au passage** : screenio.c:866, `cob_field_to_string (control, buffer, COB_LARGE_MAX, ...)` avec
  `char buffer[COB_MEDIUM_BUFF]` (8192 octets) alors que la limite passée est 16383 : débordement de pile possible.

### Appels libc non réentrants

| file:line | appel | remarque / action |
|---|---|---|
| screenio.c:869, 906 | `strtok` | dans adjust_attr_from_control_field → `strtok_r` (buffer déjà local) |
| screenio.c:963 | `bsearch` | comparateur sans état global ; OK une fois `control_attrs` passé en const |
| screenio.c:3392 | `qsort` | comparateur `compare_yx` sans état global ; OK |
| screenio.c:5882, 5902 | `getenv("COB_IS_RUNNING_IN_TESTMODE")` | lire une fois dans rt (C1) |
| screenio.c:1162, 1165 | `signal(SIGTTIN/SIGTTOU)` | code mort (`#if 0`) ; C4 si un jour réactivé |
| screenio.c:1173, 1176, 1201, 1202 | `setlocale` | code mort (`#if 0`) ; process-wide |
| screenio.c:1154-1155 | `fflush(stdout/stderr)` | flux process-wide (C4) |
| termio.c:1061 | `cob_raise(SIGINT)` | sur ^C en lecture console : signal process (C4/T2) |
| termio.c:455, 1031 | `fflush` | stdout process-wide |
| cobgetopt.c:470 | `getenv("POSIXLY_CORRECT")` | à chaque initialisation ; à lire une fois (rt) ou passer en paramètre |
| cobgetopt.c:329-753 | `fprintf(stderr, ...)` | messages d'erreur directs sur stderr (pas de réentrance en jeu, mais à router via ctx) |
| profiling.c:570 | `cob_get_strerror()` | wrapper de common.c ; vérifier qu'il utilise `strerror_r` |
| profiling.c:106 | `clock_gettime(clockid)` | réentrant ; `clockid` en C1 |
| profiling.c:538 | `cob_open_logfile` | fichier de profil unique pour le process : il faut un nom ou un verrou par ctx si plusieurs contextes profilent |
| mlio.c | (aucun appel libc non réentrant trouvé) | |
| reportio.c | (aucun) | |

### Callbacks sans argument utilisateur / dépendant d'un état global

- **libxml2 SAX** (mlio.c ~1735-1750, `xml_startDocument`, `xml_startElement[Ns]`, `xml_characters`, …) : reçoivent `void *ctx`
  = `struct xml_state *`. Pour passer le contexte, ajouter `cob_context *ctx` dans `struct xml_state` : ces
  callbacks appellent `set_xml_event/set_xml_code` → `COB_MODULE_PTR` → `cobglobptr`.
- **libxml2 error handler** : `xmlSetStructuredErrorFunc (state, xml_error_handler)` (mlio.c:1780) installe un handler
  *global* (thread-local dans un libxml2 compilé avec threads, mais global par thread : deux parses imbriqués ou
  entrelacés sur un même thread s'écrasent, et le handler n'est jamais restauré). Utiliser plutôt le handler par parser
  (`xmlCtxtSetErrorHandler`, libxml2 ≥ 2.13, ou `ctxt->sax->serror` / `sax.serror` + `xmlSchemaSetValidStructuredErrors`).
  `last_error_code` (static dans ce handler) → `struct xml_state`.
- **json-c / cJSON** : aucun callback utilisé. cJSON : `cJSON_InitHooks` n'est pas appelé (TODO en mlio.c:2116). C'est un état global de cJSON,
  à ne pas utiliser (ou à n'appeler qu'une fois à l'init rt).
- **curses** : aucun callback enregistré par libcob. En revanche, ncurses installe son propre handler SIGWINCH/SIGTSTP
  à `initscr()` (C4, interaction avec les handlers de signal de libcob/T2).

### Sûreté vis-à-vis des threads des bibliothèques tierces

- **ncurses / PDCurses** : non thread-safe (état global `stdscr`, `COLOR_PAIRS`, `LINES/COLS`, panels, mousemask,
  `curs_set`). La variante `ncursest` (`--with-pthread`, `use_screen`/`use_window`) existe mais n'est pas utilisée. Un seul
  terminal par process : screenio doit rester « single-context only », avec un verrou ou un propriétaire unique de `rt->screen`.
  `_nc_freeall()` (screenio.c:4714) et `endwin()` sont des opérations process. PDCurses : `PDC_set_blink/bold`, globaux.
- **libxml2** : thread-safe si compilé avec threads, à condition que `xmlInitParser()` soit appelé une fois dans le thread
  principal (`LIBXML_TEST_VERSION` dans cob_init_mlio le fait implicitement). Problème : `xmlCleanupParser()` dans
  cob_exit_mlio (mlio.c:2235) est process-wide. Il ne doit être appelé qu'à la fin du runtime, jamais à la fin d'un contexte (T2).
  Les push parsers, TextWriter et xmlBuffer sont par instance : OK. Les handlers d'erreur globaux posent problème (voir plus haut).
- **cJSON** : thread-safe pour des objets distincts, sauf `cJSON_InitHooks` (global) et `cJSON_GetErrorPtr` (global,
  non utilisé ici).
- **json-c** : thread-safe pour des objets distincts. Les réglages globaux (`json_c_set_serialization_double_format`,
  `json_global_set_string_hash`) ne sont pas utilisés : OK. `json_object_to_json_string_ext` renvoie un buffer
  propre à l'objet : OK.

