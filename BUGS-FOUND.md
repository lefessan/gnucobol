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
