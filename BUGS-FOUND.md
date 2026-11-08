# Bugs trouvés en cours de travail

Bugs repérés dans GnuCOBOL pendant d'autres travaux, sans lien direct
avec ceux-ci. Ils ne sont pas encore corrigés.

Format : date, fichier:ligne, description, statut (vérifié dans le
source / signalé par une analyse, non vérifié).

## 2026-10-28 — trouvés pendant l'inventaire T1.1 (runtime réentrant)

### `libcob/screenio.c:866` — débordement de pile possible
- Statut : **vérifié** dans le source.
- `cob_field_to_string (control, buffer, COB_LARGE_MAX, CCM_UPPER)`
  écrit jusqu'à `COB_LARGE_MAX` (16383) octets dans
  `char buffer[COB_MEDIUM_BUFF]` (8192 octets, l. 858).
- Déclencheur : un champ CONTROL de plus de 8192 octets dans une
  instruction DISPLAY/ACCEPT avec `CONTROL`.
- Correction : passer `sizeof (buffer) - 1` ou `COB_MEDIUM_MAX`.

### `libcob/cobcapi.c:348` et `:395` — attribut statique partagé modifié
- Statut : **vérifié** dans le source ; **corrigé** dans le commit 83bbaa55
  (copie locale de l'attribut ; deux autres occurrences, dans
  `cob_put_s64_param` / `cob_put_u64_param`, corrigées aussi).
- `const_binll_attr.scale = f->attr->scale;` (de même pour
  `const_binull_attr`) écrit dans un `cob_field_attr` statique partagé
  (déclaré l. 53 et 55) à chaque appel.
- Effet : course de données entre threads ; et un appel réentrant
  (callback) pourrait voir une échelle erronée.
- Correction : attribut local à la fonction.

### `libcob/numeric.c` — cache `packed_value` qui ignore le signe
- Statut : signalé par une analyse, **non vérifié**.
- Le cache de la dernière valeur packed ne tient pas compte de
  l'indicateur du quartet de signe ; deux champs ne différant que par ce
  flag pourraient partager une valeur en cache erronée.

### `libcob/profiling.c` — `get_ns_time` : garde monotone inopérante
- Statut : **vérifié** dans le source le 2026-11-01 (`ns_time` n'est
  modifié que dans la branche `is_test`).
- La valeur `ns_time` mémorisée n'est jamais mise à jour hors mode test,
  donc la vérification censée garantir un temps croissant ne sert à rien.

### `libcob/common.c:1016` — `cob_get_strerror` non réentrant
- Statut : signalé par deux analyses, **non vérifié**.
- Le commentaire le dit réentrant, mais il appelle `strerror` (non
  réentrant) au lieu de `strerror_r`.

### `libcob/common.c` — `cob_module_err` mort
- Statut : **vérifié** le 2026-11-01 : écrit dans
  `cob_module_global_enter_ctx`, lu seulement dans du code `#if 0`
  (`cob_fatal_error_ctx`, cas `COB_FERROR_RECURSIVE`).
- Variable lue seulement dans du code `#if 0` : à supprimer.

## 2026-10-29 — trouvés pendant le test de compatibilité binaire

### `libcob/common.c:2405-2406, 2631, 2688-2690` — débordement de `exec_root` / `build_root`
- Statut : **vérifié** (plantage reproduit : « buffer overflow detected »
  dans `cob_setup_env` avec un build `-O2 -D_FORTIFY_SOURCE`).
- `static char exec_root [128]` est rempli par
  `sprintf (exec_root, "%s", p)` où `p` vient de `COB_DIR` ou du
  répertoire où `libcob` est trouvée via `LD_LIBRARY_PATH`, puis
  complété par `strcat (exec_root, SLASH_STR)`, sans contrôle de taille
  (de même `build_root`, initialisé avec le `--prefix`).
- Déclencheur : un répertoire de libcob (ou `COB_DIR`) de plus de
  127 caractères, par exemple un build dans un répertoire profond ;
  `cobc` lui-même plante au démarrage.
- Correction : `snprintf` avec `sizeof (exec_root)` et contrôle de la
  place restante avant d'ajouter le séparateur, ou allocation dynamique
  (`COB_FILE_MAX` au lieu de 128).

## 2026-11-04 — trouvés pendant T1.4 (verrou de `call.c`)

### `libcob/call.c:1670, 1803, 1937` — mauvais arguments au-delà de 150 dans `cob_call`
- Statut : **vérifié** dans le source (non reproduit par un test).
- Dans `cob_call_ctx`, `cob_call_cobol_va_ctx` et `cob_call_entry_va_ctx`,
  la liste des arguments transmis contient
  `pargv[148], pargv[149], pargv[130], pargv[131]` au lieu de
  `pargv[150], pargv[151]` : avec `MAX_CALL_FIELD_PARAMS` = 192 (valeur
  par défaut), les 151ᵉ et 152ᵉ paramètres reçoivent les 131ᵉ et 132ᵉ.
- Dans le bloc `MAX_CALL_FIELD_PARAMS > 192`, il manque aussi
  `pargv[196..199]` et `pargv[236..239]` : les paramètres suivants sont
  décalés (et la liste a moins d'arguments que le prototype : erreur de
  compilation avec 252).
- Déclencheur : `cob_call` (ou `CALL` via ces fonctions) avec plus de
  150 paramètres.
- Correction : corriger les indices dans les trois listes.

## 2026-11-05 — trouvés pendant T1.4 (LMDB en multi-thread)

### `libcob/flmdb.c` `local_file` — `/proc/partitions` jamais fermé
- Statut : **vérifié** dans le source ; **corrigé** (commit « LMDB in
  several threads »).
- `local_file` ouvre `/proc/partitions` à chaque OPEN d'un fichier LMDB
  (contrôle « shared filesystem ») et ne le ferme jamais : un
  descripteur de fichier perdu par OPEN, jusqu'à `EMFILE` dans un
  processus de longue durée.
- Ses tampons `line` et `devname` étaient statiques : deux threads qui
  ouvrent un fichier en même temps pouvaient lire une ligne corrompue
  et conclure à tort à un système de fichiers partagé (statut 30,
  « shared filesystem detected! »), reproduit avec le banc à 8 threads.

### `libcob/flmdb.c` `get_dupno` — fuite mémoire
- Statut : **vérifié** dans le source ; **corrigé** (commit « fix memory
  leak in get_dupno »).
- `txn = cob_malloc (sizeof (MDB_txn *))` et
  `cursor = cob_malloc (sizeof (MDB_cursor *))`, puis
  `mdb_txn_begin (…, &txn)` et `mdb_cursor_open (…, &cursor)`
  remplacent les pointeurs : les deux allocations sont perdues à chaque
  appel (écriture avec clé alternée à doublons).
- Correction : supprimer les deux `cob_malloc`.

## 2026-11-07 — trouvés pendant T1.4 (verrous des fichiers RELATIVE)

### `libcob/fileio.c` `cob_file_unlock` — UNLOCK ne libère pas les verrous d'enregistrements
- Statut : **vérifié** (reproduit avec deux processus : après
  `READ … WITH LOCK` puis `UNLOCK`, l'autre processus obtient toujours
  le statut 51).
  **Corrigé** le 2026-11-07 (commit « UNLOCK releases the record locks
  of SEQUENTIAL and RELATIVE files »).
- Pour les fichiers non INDEXED, `cob_file_unlock` ne libère que le
  verrou de fichier (`flag_file_lock`), jamais les verrous
  d'enregistrements posés par `lock_record`.

### `libcob/fileio.c` — `prev_lock` jamais renseigné
- Statut : **vérifié** dans le source.
- `f->prev_lock` est lu (libération du verrou précédent à la lecture
  suivante, `flag_lock_rls`, verrouillage automatique) mais n'est
  jamais affecté : pour les fichiers RELATIVE, les verrous
  d'enregistrements s'accumulent jusqu'au CLOSE.

## 2026-11-07 — trouvés pendant T1.4 (réglages par contexte)

### `libcob/common.c` `set_config_val` — post-traitements jamais faits
- Statut : **vérifié** dans le source, non corrigé.
- `if (data == (char *)cobsetptr->cob_trace_filename …)` et
  `if (data == (void *)cobsetptr->cob_date)` comparent l'adresse du
  champ (`data`) à sa valeur (la chaîne) : la condition est toujours
  fausse, donc changer `COB_TRACE_FILE` ou `COB_CURRENT_DATE` par une
  relecture de l'environnement (DISPLAY UPON ENVIRONMENT-VALUE,
  `cob_putenv`) n'ouvre pas le nouveau fichier de trace et ne recalcule
  pas la date fixée.
- Correction : comparer `data_loc` à
  `offsetof (cob_settings, cob_trace_filename)` / `cob_date`.

## 2026-11-07 — trouvés pendant T2 (build avec AddressSanitizer)

### `cobc/codegen.c:347` `get_field_name` — lecture hors limites
- Statut : **vérifié** (AddressSanitizer, heap-buffer-overflow en
  compilant `extras/CBL_OC_DUMP.cob`) ; **corrigé** (commit « fix read
  beyond the name in get_field_name »).
- `memcmp (f->name, "FILLER ", 7)` lit 7 octets même quand le nom est
  plus court : lecture après la fin de la chaîne allouée.
- Correction : `strncmp`, qui s'arrête à la fin du nom.

### `libcob/fileio.c` (tube bidirectionnel `|commande`) — enfant après `fork`
- Statut : **vérifié** dans le source ; **corrigé** (commit « safe
  child process of a bidirectional pipe »).
- Après `fork`, l'enfant appelait `cob_runtime_error_ctx` et
  `cob_stop_run_ctx` en cas d'échec de `dup2`, et `exit (-1)` si
  `execv` échouait : `exit` vide dans l'enfant les tampons stdio hérités
  du parent (sorties écrites deux fois), et STOP RUN y exécute la fin de
  run unit (fichiers, procédures de sortie) du parent ; avec une
  frontière de contexte (T2), le `longjmp` reprendrait le code de l'hôte
  dans l'enfant.
- Correction : seulement `write` et `_exit (127)` dans l'enfant.

## 2026-11-08 — trouvés pendant T4 (sources traduits par TXSeries)

### `cobc/parser.y` `check_not_88_level` — plantage sur ADDRESS OF d'un élément non défini
- Statut : **vérifié** (reproduit : `SET P TO ADDRESS OF UNDEF` avec
  `UNDEF` non défini) ; **corrigé** (commit « fix crash on ADDRESS OF
  an undefined item »).
- Après l'erreur « 'UNDEF' is not defined », `CB_FIELD_PTR` convertit la
  référence, qui pointe vers `cb_error_node`, en champ : « invalid cast
  from 'internal error node' type CONSTANT to type FIELD », abandon de
  la compilation (« Please report this! »). Code amont (janvier 2025).
- Déclencheur réel : un source traduit par `cicstran` dont la copybook
  BMS (générée par `cicsmap`) manque.
- Correction : renvoyer la référence telle quelle quand elle ne désigne
  pas un champ.

### `cobc/cobc.c` `process_command_line` — fuite du nom du dialecte
- Statut : **vérifié** (LeakSanitizer, 8 octets à chaque compilation
  avec `-std=`) ; **corrigé** (commit « fix leak of the name of the
  dialect »).
- `cb_dialect = cobc_strdup (ext)` (option `-std=` et `WITH_STD`)
  n'est jamais libéré : toute compilation avec `-std=` échoue sous
  AddressSanitizer (détection des fuites).
- Correction : un tampon statique au lieu d'une allocation.
