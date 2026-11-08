# Chercher et corriger les courses de données avec ThreadSanitizer

Mode d'emploi pour le runtime réentrant (TXSERIES-PLAN.md, T1.4 / T1.6) :
compiler libcob et les programmes avec ThreadSanitizer (TSan), lancer
un banc multi-thread, lire les rapports et en déduire une correction.
Les commandes sont celles utilisées les 2026-11-01 et 2026-11-04.

## 1. Principe

TSan instrumente chaque accès mémoire du code compilé avec
`-fsanitize=thread`. Quand deux threads accèdent à la même adresse, au
moins l'un en écriture, sans synchronisation entre les deux (verrou,
atomique, création / jointure de thread), il affiche un rapport
« data race » avec les deux piles d'appels.

Conséquences pratiques :
- seul le code **compilé avec TSan** est surveillé : libcob, `cobc`, les
  modules COBOL et l'hôte C doivent tous l'être ; une course *à
  l'intérieur* d'une bibliothèque non instrumentée (libdb, libgmp,
  liblmdb…) n'est pas vue ;
- une course n'apparaît que si elle se produit pendant l'exécution :
  il faut un banc qui fait vraiment travailler plusieurs threads en
  même temps sur le code visé, et le lancer plusieurs fois ;
- l'exécution est 5 à 15 fois plus lente et consomme beaucoup plus de
  mémoire : réduire le nombre d'itérations si besoin.

## 2. Construire libcob avec TSan

Dans un répertoire de build **séparé** (ne pas mélanger avec `_build`) :

```sh
cd ~/GIT/COBOL/gnucobol4
mkdir -p _build-tsan && cd _build-tsan
setarch -R ../configure --enable-debug --with-xml2 --with-json \
    --with-db --with-lmdb --with-indexed=db \
    CFLAGS="-fsanitize=thread -g -O1" LDFLAGS="-fsanitize=thread"
setarch -R make -j8
```

- **`setarch -R` est indispensable sur cette machine** : sans lui, tout
  exécutable TSan s'arrête aussitôt avec
  `FATAL: ThreadSanitizer: unexpected memory mapping` (l'ASLR du noyau
  récent place les bibliothèques là où TSan veut sa mémoire fantôme).
  `setarch -R` désactive l'ASLR pour la commande et ses enfants ; il
  faut l'utiliser pour `configure` (qui exécute des programmes de
  test), pour `make` (qui exécute `cobc`) et pour chaque exécution.
- `-g` donne les numéros de ligne dans les rapports, `-O1` garde des
  piles lisibles sans être trop lent.
- V-ISAM et ODBC ont été laissés de côté (bibliothèques non
  instrumentées, inutiles pour le banc). Le build de la session
  précédente utilisait `--with-indexed=lmdb` ; prendre `db` pour
  tester le gestionnaire le plus utilisé.
- Après une modification de libcob : `cd _build-tsan && setarch -R make -j8`.
  Après une modification de `configure.ac` : `./autogen.sh` dans le
  source, puis `setarch -R ./config.status --recheck && setarch -R ./config.status`
  dans `_build-tsan`.

Pour utiliser ce build sans l'installer, toujours passer par son
`pre-inst-env` (il positionne `PATH`, `LD_LIBRARY_PATH`, `COB_CONFIG_DIR`…) :

```sh
T=~/GIT/COBOL/gnucobol4/_build-tsan
setarch -R $T/pre-inst-env cobc --info | head -3
```

## 3. Compiler et lancer le banc

Le banc de référence est le test « CALL in from C, execution contexts in
several threads » de `tests/testsuite.src/run_reentrant.at` : un hôte C
(`mt.c`) crée 8 threads, chacun avec son contexte, qui appellent 1000
fois le module COBOL `calc`.

### Récupérer les fichiers du test

Soit lancer le test dans le build normal en gardant son répertoire :

```sh
cd ~/GIT/COBOL/gnucobol4/_build
autofonce run --keep-all -k thread      # fichiers dans _autofonce/NNNN/
```

soit les extraire du `.at` (les `[[ ]]` du C doivent être retirés) :

```sh
mkdir -p /tmp/tsrun && cd /tmp/tsrun
python3 - <<'EOF'
s = open('/home/lefessan/GIT/COBOL/gnucobol4/tests/testsuite.src/run_reentrant.at').read()
t = s[s.index('AT_SETUP([CALL in from C, execution contexts in several threads])'):]
def grab(name, quoted):
    a = t.index('AT_DATA([%s], [%s' % (name, '[' if quoted else ''))
    a = t.index('\n', a) + 1
    b = t.index('\n' + (']])' if quoted else '])'), a)
    open(name, 'w').write(t[a:b] + '\n')
grab('calc.cob', False)
grab('mt.c', True)
EOF
```

### Compiler avec TSan

Le module COBOL et l'hôte C doivent être instrumentés : `-A` passe
l'option au compilateur C, `-Q` à l'éditeur de liens.

```sh
T=~/GIT/COBOL/gnucobol4/_build-tsan
TS="-A -fsanitize=thread -Q -fsanitize=thread"
setarch -R $T/pre-inst-env cobc -x $TS mt.c -lpthread
setarch -R $T/pre-inst-env cobc -m $TS calc.cob
```

### Lancer

```sh
COB_LIBRARY_PATH=. setarch -R $T/pre-inst-env ./mt > out.txt 2> tsan.txt
echo $?          # 0 : aucun rapport ; 66 : TSan a trouvé au moins une course
cat out.txt      # résultat fonctionnel du banc ("thread N: 0 bad")
```

Une course ne se produit pas à chaque fois : **lancer au moins 10 fois**
avant de conclure qu'il n'y en a plus. Contrôle fait le 2026-11-04 en
remettant l'ancien cache de l'heure sans verrou : la course n'a été
signalée que dans 1 exécution sur 5.

```sh
for i in $(seq 10); do
  COB_LIBRARY_PATH=. setarch -R $T/pre-inst-env ./mt > out.txt 2> tsan$i.txt
  echo -n "$? "
done; echo
cat tsan*.txt | grep -c "WARNING: ThreadSanitizer"
```

Options utiles (variable `TSAN_OPTIONS`, séparées par des espaces) :

| Option | Effet |
|--------|-------|
| `log_path=tsan` | rapports dans `tsan.<pid>` au lieu de stderr |
| `halt_on_error=1` | s'arrêter au premier rapport |
| `history_size=7` | plus d'historique : utile si la pile « Previous » manque (`failed to restore the stack`) |
| `exitcode=0` | ne pas changer le code de retour (pour un script) |
| `suppressions=fichier` | ignorer des rapports connus (`race:nom_de_fonction` par ligne) |

## 4. Lire un rapport

Exemple réel (2026-11-04, cache de l'heure) :

```
WARNING: ThreadSanitizer: data race (pid=...)
  Write of size 8 at 0x7f... by thread T3:
    #0 set_cob_time_from_localtime libcob/common.c:5703
    #1 cob_get_current_date_and_time_from_os libcob/common.c:5841
    #2 cob_get_current_datetime libcob/common.c:5866
    #3 cob_intr_current_date_ctx libcob/intrinsic.c:4651
    ...
  Previous read of size 8 at 0x7f... by thread T7:
    #0 set_cob_time_from_localtime libcob/common.c:5689
    ...
  Location is global 'last_time.1' of size 8 at 0x7f... (libcob.so.7+0x...)
  Thread T3 (tid=..., running) created by main thread at:
    #0 pthread_create
    #1 main mt.c:52
SUMMARY: ThreadSanitizer: data race libcob/common.c:5703 in set_cob_time_from_localtime
```

(Les chemins apparaissent relatifs au répertoire de build, par exemple
`../../libcob/common.c:5754`.)

À regarder, dans l'ordre :
1. **les deux accès** (`Write … by thread T3` et `Previous read … by
   thread T7`) : la ligne `#0` de chaque pile donne l'instruction
   fautive, les lignes suivantes disent comment on y arrive (ici depuis
   `FUNCTION CURRENT-DATE`) ;
2. **`Location is`** : la donnée partagée. `global 'nom'` désigne une
   variable statique ou globale (`nom.N` : statique locale à une
   fonction) ; `heap block … allocated by thread …` désigne une zone
   allouée, avec la pile de l'allocation (souvent `cob_malloc` appelé
   depuis une initialisation de libcob ou du code généré) ;
3. les threads : `main thread` ou `T1…T8` créés par `main` du banc.

Pour avoir une vue d'ensemble quand il y a beaucoup de rapports :

```sh
grep SUMMARY tsan*.txt | sed 's/.*race //' | sort | uniq -c | sort -rn
```

Un rapport dans le code généré (`calc`, `calc_` dans la pile, sans
fichier) porte sur une donnée statique du module : générer le C avec
`cobc -C calc.cob` pour retrouver la variable (`calc.c.h`, `calc.c.l.h`).

## 5. Choisir la correction

Se demander d'abord : **cette donnée appartient-elle à une tâche ou au
processus ?** Puis appliquer le motif qui correspond (exemples tirés de
la branche, voir les commits cités) :

| Situation | Correction | Exemple |
|-----------|------------|---------|
| État d'une tâche rangé dans une statique (dernier message d'erreur, tampon de travail, indicateur) | le déplacer dans une structure du contexte allouée au premier usage (`ctx->call`, macro `call_state (ctx)`) | `be915744` (`call.c`) |
| Structure partagée par le processus et modifiée (table des programmes, liste des modules chargés, cache) | verrou : `COB_LOCK_DEFINE (x_lock);` puis `cob_lock_acquire (&x_lock)` / `cob_lock_release (&x_lock)` (`coblocal.h`) | `adf9e9ec` (`call.c`), `a80568ba` (cache de l'heure) |
| Valeur partagée écrite une seule fois puis seulement lue | lecture atomique (`cob_atomic_load_uint`), et écriture sous verrou avec seconde vérification | `e609be7c` (slot d'une unité de compilation) |
| Fonction de la libc qui renvoie un tampon statique (`localtime`, `gmtime`, `strtok`, `strerror`…) | variante réentrante (`localtime_r`…) derrière une fonction de libcob (`cob_localtime`) avec repli sous verrou | `034c30c7` |
| Structure partagée qui garde un pointeur vers une donnée d'un contexte | ne plus l'y ranger ; retrouver la donnée dans le contexte courant | `1f26a582` (module et CANCEL) |
| Donnée jamais modifiée mais déclarée modifiable | la rendre `const` (plus rien à protéger) | `1743e5c3` |

Règles du projet à respecter (voir TXSERIES-T1-DESIGN.md) :
- passer `ctx` en argument plutôt qu'utiliser un TLS ;
- ne **jamais** tenir un verrou pendant l'exécution d'un programme
  COBOL ni d'un rappel (risque d'interblocage : le programme peut
  rappeler libcob) : ne protéger que la lecture / mise à jour de la
  structure ;
- garder le verrou le plus court possible ; une fonction appelée avec
  le verrou s'appelle `…_locked` et le dit en commentaire ;
- l'initialisation (`cob_init_*`) et la fin (`cob_exit_*`) du processus
  tournent dans un seul thread et n'ont pas besoin de verrou.

## 6. Vérifier la correction

1. Reconstruire `_build-tsan`, recompiler le banc (le module dépend de
   `common.h` : le recompiler aussi), relancer 10 fois : aucun rapport,
   `0 bad` partout.
2. Si possible, montrer que le banc ou un test autofonce **échoue sans
   la correction** : `git stash push libcob/fichier.c`, reconstruire,
   relancer, puis `git stash pop`. Un test qui passe dans les deux cas
   ne teste rien ; il faut alors changer le scénario (c'est arrivé pour
   le test « CANCEL in one execution context »).
3. Build normal (`_build`, BDB) : tests ciblés
   (`autofonce run -k runreentrant`, `-k call`…), puis la suite
   complète `autofonce run -j 8` ; comparer les échecs avec la
   référence `_build/results-db.summary`.
4. Ajouter un test dans `tests/testsuite.src/run_reentrant.at` (jamais
   dans un fichier `.at` existant) si le scénario n'est pas couvert.
5. Noter dans `BUGS-FOUND.md` les bugs trouvés en passant, et dans
   `TXSERIES-PLAN.md` (T1.4) ce qui reste.
6. Un petit commit par correction, avec dans le message la course
   observée (« Found by ThreadSanitizer … »).

## 7. Pièges rencontrés

- ODBC avec le pilote SQLite (2026-11-07) : sous TSan, le banc
  multi-thread se bloque ou plante, avec des rapports à l'intérieur de
  `libsqlite3` / `libodbc` (non instrumentées), alors que le build
  normal passe 30 fois sur 30. Les courses de libcob (relecture des
  réglages, connexion simultanée au gestionnaire unixODBC) ont été
  trouvées avant ; ce qui reste est attribué à l'interaction de TSan
  avec ces bibliothèques. Un rapport dont toutes les lignes de pile
  sont dans une bibliothèque non instrumentée n'est pas une preuve.
- Fichiers INDEXED en BDB (test « INDEXED files in several threads ») :
  TSan affiche des milliers de `lock-order-inversion (potential
  deadlock)` **à l'intérieur de `libdb-5.3.so`** (mutex propres à BDB,
  qui a son propre détecteur d'interblocages). Ce ne sont pas des bugs
  de libcob : les filtrer avec un fichier de suppressions qui ne
  contient **que** `deadlock:libdb-5.3.so`,
  `TSAN_OPTIONS="suppressions=$PWD/tsan.supp"`. Ne pas y ajouter
  `race:libdb-5.3.so` : une suppression s'applique dès qu'une ligne de
  la pile correspond, elle cacherait aussi une course de libcob dont la
  pile passe par libdb. Supprimer les fichiers `__db.*` et `i*.dat*`
  entre deux exécutions si l'une s'est mal terminée.
- `unexpected memory mapping` : oubli de `setarch -R`.
- Rapports dans du code non instrumenté absents : un module COBOL
  compilé sans `-A -fsanitize=thread`, ou avec le `cobc` du build
  normal, n'est pas surveillé. Utiliser le `pre-inst-env` du build TSan
  pour tout.
- Le banc doit vraiment être concurrent : un `cob_resolve` dans `main`
  avant de lancer les threads (comme le faisait la première version du
  test) masque les courses de la résolution dynamique des `CALL`.
- TSan ne connaît pas les synchronisations « maison » (drapeau
  `volatile`, attente active) : utiliser les verrous et atomiques de
  `coblocal.h`, que TSan comprend.
- Une course bénigne en apparence (deux threads écrivent la même
  valeur) reste un comportement indéfini en C : la corriger plutôt que
  la supprimer avec un fichier de suppressions.
