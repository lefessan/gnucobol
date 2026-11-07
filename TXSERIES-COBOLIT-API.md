# API de TXSeries pour COBOL-IT et CobolCloud

Notes de rétro-ingénierie sur la façon dont IBM TXSeries 11.1 charge et
exécute des programmes COBOL compilés par COBOL-IT ou CobolCloud, en vue
de faire passer GnuCOBOL pour l'un des deux (tâche T5 de
`TXSERIES-PLAN.md`).

Sources : version d'évaluation de TXSeries 11.1 pour Linux x86-64
(`TXSeries111-Evaluation-Linux-x86_64_Container-Image.tar`, chaîne de
version « TXSeries 11.1.0.0 64-bit Evaluation s111-L241206 », image
`localhost/ibm-txseries-trial:11.1.0.0`, base UBI 8). Objets et scripts
examinés avec `nm`, `objdump -dr`, `strings`, et par exécution de
`cicstran` / `cicstcl` dans le conteneur. Aucune source IBM ni COBOL-IT
n'a été consultée ; la documentation publique de COBOL-IT
(microfocus.com) n'est plus en ligne.

Légende : **[vérifié]** = lu dans le code machine ou observé à
l'exécution ; **[déduit]** = interprétation, à confirmer en région.

---

## 1. Vue d'ensemble

TXSeries choisit une *méthode de langage* d'après l'extension du
`PathName` de la définition de programme (PD). Chaque méthode est un
objet partagé `cicspr<LANG>` placé dans `$CICSPATH/bin`, construit sur
le site du client en liant un objet IBM avec le runtime du compilateur
COBOL :

| Méthode  | Extension des programmes | Script         | Objet IBM           | Runtime lié | Variable d'installation |
|----------|--------------------------|----------------|---------------------|-------------|-------------------------|
| COBOLIT  | `.so`                    | `cicsmkcobolit`| `lib/pinca_cobolit.o` | `-lcobit`  | `COBOLITDIR`            |
| COBCLD   | `.cld` (et `.cldf` ?)    | `cicsmkcobcld` | `lib/pinca_cobcld.o`  | `-lcobcld` | `COBOLCLDIR`            |

Extensions et noms de méthodes : chaînes `.cld`, `.cldf`, `COBCLD`,
`PINCA_LANG_COBCLD`, `PINCA_METHOD_COBCLD`, `PINCA_LANG_COBOLIT`… dans
`lib/libcicsrt.so` **[vérifié]**. Dans l'IVP, les PD COBCLD n'ont pas
d'extension (`PathName="$BINDIR/COBCLD/dfhcall"`), les fichiers
construits s'appellent `dfhcall.cld` **[vérifié]**.

Les deux objets IBM sont **le même code source** (`pinca_cobolit.c`
compilé deux fois, les noms de fonctions et messages de COBCLD gardent
« CobolIT ») et utilisent **exactement la même API de runtime**
**[vérifié]**. Différence décisive :

- `pinca_cobolit.o` est compilé sans prototypes pour `cob_resolve` et
  `cob_enterprise_set_current_region` : `mov eax,0` avant l'appel puis
  `cdqe` après, donc le résultat (un pointeur de fonction, un pointeur
  de « rtd ») est **tronqué à 32 bits signés**. En 64 bits, un `.so`
  chargé par `dlopen` est au-dessus de 4 Go : ce chemin ne peut pas
  fonctionner tel quel. Le script `cicsmkcobolit` contient d'ailleurs
  encore `gcc -m32` et `CICS_DIR=/opt/ibm/cics`, qui n'existe pas dans
  l'image 64 bits **[vérifié]**.
- `pinca_cobcld.o` a les prototypes (pas de `cdqe`, le résultat est
  gardé sur 64 bits) et `cicsmkcobcld` n'a ni `-m32` ni chemin en dur
  (`CICS_DIR=$CICSPATH`) **[vérifié]**.

**Conclusion : en 64 bits, la cible est la méthode COBCLD (CobolCloud).**

### Ce qu'est CobolCloud

Aucune information publique trouvée (ni « CobolCloud », ni `cldsql`,
`COBOLCLDIR`, `libcobcld`). Ce que dit TXSeries :

- messages `ERZ058557E` à `ERZ058562I` (`cicsmkcobcld`), `ERZ001049E`
  « Loading of CobolCloud module %1$s failed with CobolCloud runtime
  error (%2$s) », `ERZ001050E` « CobolCloud runtime exception (%1$s)
  received for module %2$s » **[vérifié]** ;
- le compilateur s'appelle `cobc` et accepte les options de COBOL-IT
  (`-fthread-safe`, `-fnotrunc`, `-m`, `-o`), plus `-preprocess=<script>`
  et `-lcldsql` (précompilateur SQL « cldsql », installé par défaut dans
  `/opt/cobolcloud`, copybooks dans `share/cldsql/copy`) d'après
  `examples/RM_support/PostgreSQL/uxa1_psqlcob.mk` **[vérifié]** ;
- son runtime expose la même API que `libcobit`, `rtd` compris.

**[déduit]** CobolCloud est un successeur 64 bits de COBOL-IT (même
famille OpenCOBOL), intégré à TXSeries au plus tard en 11.1.

---

## 2. Construction de la méthode : `cicsmkcobcld`

Script ksh. Commande réelle (fin du script) **[vérifié]** :

```sh
gcc -fPIC -shared -e PinCA_InitLang \
    -o $OutputDir/cicsprCOBCLD \
    -L$CICSPATH/lib -L/usr/local/lib -L/usr/lib -L/lib -L$COBOLCLDIR/lib \
    -lcobcld -lcicsrt \
    $CICSPATH/lib/pinca_cobcld.o $RES_FLAGS $LibrarySearchPath $LibraryList $ARGUMENTS
```

- refuse de tourner si `COBOLCLDIR` n'est pas défini (`ERZ058558W`) ;
- options : `-o dir`, `-d DB2|ORACLE|POSTGRESQL` (ajoute les
  bibliothèques du gestionnaire de ressources), `-L`, `-l`, objets ;
- point d'entrée de la méthode : `PinCA_InitLang`.

Pour nous : il suffit de fournir `$COBOLCLDIR/lib/libcobcld.so` (ou
`.a`). Voir § 7 pour le choix entre les deux.

---

## 3. Symboles attendus du runtime

Symboles indéfinis de `pinca_cobcld.o`, hors TXSeries et libc
**[vérifié]** :

```
cob_get_rtd                         cob_resolve
cob_init                            cob_resolve_error
cob_enterprise_set_current_region   cob_runtime_debugger_init
cob_enterprise_get_current_region   cob_runtime_debugger_activate
cob_enterprise_cancel_region        cob_dump_debug_info
CBL_ERROR_PROC                      CBL_EXIT_PROC
```

Utilisation par fonction de `pinca_cobcld.o` **[vérifié]** :

| Fonction IBM            | Appels du runtime |
|-------------------------|-------------------|
| `PinCA_InitLang`        | `cob_get_rtd`, `cob_init` (via `PinCA_SetCobolITErrorHandling` : `CBL_ERROR_PROC`, `CBL_EXIT_PROC`) |
| `PinCA_LoadCOBCLD`      | `cob_enterprise_cancel_region`, `cob_enterprise_set_current_region`, `cob_resolve`, `cob_resolve_error` |
| `PinCA_UnloadCOBCLD`    | `cob_get_rtd`, `cob_enterprise_get_current_region`, `cob_enterprise_set_current_region` |
| `PinCA_COBCLDNewCopy`   | `cob_enterprise_cancel_region` |
| `PinCA_StartCOBCLD`     | `cob_get_rtd` (×6), `cob_runtime_debugger_init`, `cob_runtime_debugger_activate`, `cob_dump_debug_info` (×3) |

### Signatures reconstituées

Types d'après les registres (System V x86-64) ; noms des paramètres
inventés.

```c
typedef struct cob_rtd cob_rtd;     /* opaque pour IBM, sauf champs § 4 */

cob_rtd *cob_get_rtd (void);                         /* prototypé */
void     cob_init (cob_rtd *rtd, int argc, char **argv);  /* (rtd, 0, NULL) */

cob_rtd *cob_enterprise_set_current_region (cob_rtd *rtd, int region);
int      cob_enterprise_get_current_region (cob_rtd *rtd);
void     cob_enterprise_cancel_region (cob_rtd *rtd, int region, int mode);

void    *cob_resolve (cob_rtd *rtd, const char *name);   /* NULL si échec */
char    *cob_resolve_error (cob_rtd *rtd);               /* message */

void     cob_runtime_debugger_init (void);     /* appelé sans argument */
void     cob_runtime_debugger_activate (cob_rtd *rtd, int port_or_flag);
void     cob_dump_debug_info (cob_rtd *rtd);

/* convention Micro Focus : flag = 0 installer, sinon retirer */
int      CBL_ERROR_PROC (unsigned char *flag, void *proc_ptr_ref);
int      CBL_EXIT_PROC  (unsigned char *flag, void *proc_ptr_ref);
```

Remarques :
- `cob_get_rtd` est le seul appel dont le résultat est utilisé sans
  conversion dans `pinca_cobolit.o` (il était prototypé même là).
- Dans `pinca_cobcld.o`, `cob_resolve_error` renvoie un pointeur (le
  message de `ERZ001049E`) **[vérifié]**.
- `cob_init` porte le même nom que celui de libcob (`cob_init (int,
  char **)`) mais une autre signature ; de même `cob_resolve` (libcob :
  `cob_resolve (const char *)`). Voir § 7.

---

## 4. Le « rtd » (runtime data)

Handle d'état du runtime COBOL-IT, obtenu par `cob_get_rtd ()` et
mémorisé dans la variable commune `rtd` de l'objet IBM. Champs touchés
directement par IBM **[vérifié]** :

| Décalage | Taille | Accès | Où | Sens **[déduit]** |
|----------|--------|-------|----|-------------------|
| `0x000`  | `int`  | écrit `1` | `PinCA_InitLang`, avant `cob_init` | mode « embarqué » / multi-thread |
| `0x040`  | `jmp_buf` (200 octets, jusqu'à `0x108`) | `_setjmp (rtd + 0x40)` | `PinCA_StartCOBCLD`, juste avant d'appeler le programme | point de retour de STOP RUN / erreur fatale |
| `0x108`  | `int`  | écrit `1` | `PinCA_StartCOBCLD`, avant le `setjmp` | « un point de retour est armé » |

Dans `PinCA_StartCOBCLD`, la valeur de retour de `_setjmp` est examinée :
`0` → appeler le programme ; `1 … 0x7e` → `cob_dump_debug_info (rtd)` puis
fin ; autre → `cob_dump_debug_info (rtd)` aussi **[vérifié]**. Le runtime
doit donc faire `longjmp (rtd + 0x40, code)` sur STOP RUN ou erreur,
au lieu de `exit`. C'est exactement la frontière de T2
(`cob_call_with_exception_check_ctx`), avec un `jmp_buf` fourni par
l'hôte.

**[déduit]** `cob_get_rtd ()` renvoie le rtd du thread courant (il est
rappelé à chaque démarrage de programme, jamais mis en cache sauf dans
`PinCA_InitLang`).

---

## 5. Cycle de vie d'un programme

### 5.1 Initialisation de la méthode (`PinCA_InitLang`) **[vérifié]**
1. Remplit la table `CICSAPIMethod_COM` avec les points d'entrée
   `*_COBCLD` (voir § 6).
2. `PinCA_SetCobolITErrorHandling ('0')` :
   `CBL_ERROR_PROC (&c, &PinCA_CobolITErrorHandler)` et
   `CBL_EXIT_PROC (&c, &PinCA_CobolITExitHandler)` avec `c = '0'`
   (**le caractère `'0'`, 0x30, pas l'octet 0**).
3. `putenv ("COB_ERROR_FILE=error.txt")`.
4. `rtd = cob_get_rtd (); *(int *)rtd = 1; cob_init (rtd, 0, NULL);`
5. `CancelType = getenv ("CICS_DISABLE_COBCLD_CACHE") ? 1 : 0;`

### 5.2 Chargement (`PinCA_LoadCOBCLD (?, pathname)`) **[vérifié]**
1. `name` = nom de base du `PathName`, sans extension (`strrchr '/'`,
   puis coupure au dernier `'.'`), copié sur 257 octets au plus.
2. `region = <mot de 16 bits à TCA+0x2750+0xaa4> + 1`, plafonné à 15
   (message « COBOL-IT Region exceeds COBIT_MAX_REGION. Program will run
   in COBIT_MAX_REGION »). **[déduit]** niveau d'imbrication `EXEC CICS
   LINK` de la tâche : une « région » COBOL-IT par niveau de LINK, pour
   que deux niveaux aient des données de travail distinctes.
3. `cob_enterprise_cancel_region (rtd, region, CancelType);`
4. `r = cob_enterprise_set_current_region (rtd, region);`
5. `entry = cob_resolve (r, name);` sous un gestionnaire d'exceptions
   DCE ; si `entry == NULL` : `ERZ001049E` avec `cob_resolve_error (r)`.
6. `entry` est gardé dans une variable statique de l'objet.

### 5.3 Exécution (`PinCA_StartCOBCLD`) **[vérifié]**
1. `cob_get_rtd ()->[0x108] = 1; if (_setjmp (cob_get_rtd () + 0x40)) …`
2. Si le débogage est configuré :
   `cob_runtime_debugger_init (); cob_runtime_debugger_activate (rtd, n);`
3. `entry (eib, commarea);` : appel C direct avec **deux arguments
   pointeurs** (DFHEIBLK, DFHCOMMAREA), comme le point d'entrée d'un
   programme GnuCOBOL `PROCEDURE DIVISION USING DFHEIBLK DFHCOMMAREA`.

### 5.4 Fin de programme (`PinCA_UnloadCOBCLD`) **[vérifié]**
```c
int cur = cob_enterprise_get_current_region (cob_get_rtd ());
if (cur != 0)
    cob_enterprise_set_current_region (rtd, cur - 1);
```
(retour au niveau de LINK appelant).

### 5.5 NEWCOPY (`PinCA_COBCLDNewCopy`) **[vérifié]**
```c
for (r = 1; r <= 15; r++)
    cob_enterprise_cancel_region (rtd, r, 1);
```

### 5.6 Gestionnaires d'erreur et de sortie **[vérifié]**
- `PinCA_CobolITErrorHandler (char *msg)` (trace « (%s) ») →
  `PinCA_HandleCobolITRTSError` : enregistre un abend (`SupER_StoreAbend`,
  code dérivé de `U0101`/`APCT`…), journal, puis `SupOS_ServerExit` :
  une erreur d'exécution COBOL termine l'application server.
- `PinCA_CobolITExitHandler (void)` → `PinCA_HandleCobolITRTSExit` :
  appelé à la sortie du runtime (STOP RUN non rattrapé), abend
  (`A011` ?) puis `SupOS_ProcessExit`.
- `cob_exit_proc (void *, int)` : fonction vide définie par IBM.

---

## 6. Ce que le programme COBOL appelle

### 6.1 Code produit par le traducteur
`cicstran -lCOBCLD` produit **le même source** que `-lCOBOLIT`
**[vérifié]**. Extrait pour `EXEC CICS WRITEQ TS QUEUE(QNAME) FROM(MSG)` :

```cobol
       ENVIRONMENT DIVISION.
       SPECIAL-NAMES.
          call-convention 8 is litlink.
       ...
       WORKING-STORAGE SECTION.
       01  CICS-API-WS-START        PIC X.
       ...                                  *> données de l'utilisateur
       COPY 'CICS-API'.
       01  CICS-API-TEMP-STORAGE. ...
       01  CICS-API-WS-END          PIC X.
       LINKAGE SECTION.
       COPY 'CICS-EIB'.
       01 DFHCOMMAREA PIC X(10).
       PROCEDURE DIVISION USING DFHEIBLK DFHCOMMAREA.
       CICS-API SECTION.
       CICS-API-TRIGGER.
           SET CICS-EIB-PTR TO ADDRESS OF DFHEIBLK.
           CALL litlink 'CICSAPIWSADDRE' USING CICS-ARGS
                CICS-API-WS-START CICS-API-WS-END.
           IF EIBLABEL NOT = 0 GO TO CICS-API-ERROR.
           PERFORM CICS-API-EDF-INIT.
      *     EXEC CICS WRITEQ TS QUEUE(QNAME) FROM(MSG) END-EXEC
           MOVE QNAME TO CICS-DATA-VALUE(10)
           SET CICS-DATA-AREA(5) TO ADDRESS OF MSG
           MOVE LENGTH OF MSG TO CICS-SHORT-VALUE(3)
           MOVE 1556 TO CICS-ARG-MASK
           MOVE 107 TO CICS-FN-CODE
           MOVE 10 TO CICS-DEBUG-LINE
           CALL litlink 'CICSAPIE' USING CICS-ARGS
           IF EIBLABEL NOT = 0 GO TO CICS-API-ERROR END-IF
       ...
       CICS-API-EDF-INIT SECTION.
           CALL litlink 'CICSAPIEDFINIT' USING DFHEIBLK BY VALUE 1.
       CICS-API-ERROR SECTION.
           IF EIBLABEL = -1 GO TO CICS-API-RETURN-OR-ABEND.
           GO TO CICS-API-RETURN-OR-ABEND DEPENDING ON EIBLABEL.
       CICS-API-RETURN-OR-ABEND.
           GOBACK.
```

Codes de fonction observés : `WRITEQ TS` = 107, `SEND TEXT` = 109,
`LINK` = 56, `RETURN` = 72 ; le masque `CICS-ARG-MASK` indique les
arguments présents (positions dans `CICS-ARG-DATA`).

- Interface : un seul bloc `CICS-ARGS` par référence (copybook
  `$CICSPATH/include/CICS-API` : code fonction, ligne, masque, 96
  arguments de 8 octets en union, pointeur sur l'EIB, 4 chaînes longues).
- `CALL litlink 'X'` = appel **statique** : le `.so` du programme a des
  références indéfinies vers `CICSAPIE`, `CICSAPIEDFINIT`,
  `CICSAPIWSADDRE` **[vérifié avec notre cobc]**, que fournit
  `cicsprCOBCLD`.
- Points d'entrée exportés par l'objet IBM : `CICSAPI`, `CICSAPIE`,
  `CICSAPIWS`, `CICSAPIWSADDR`, `CICSAPIWSADDRE`, `CICSAPIPUSH`,
  `CICSAPIPOP`, `CICSAPIEDFINIT`, et leurs équivalents C
  `cics_api_exec_cobol`, `cics_api_push`, `cics_api_pop`,
  `cics_api_ws_addr`, `cics_api_edf_init_cobol` **[vérifié]**.
- `CICSAPIWSADDRE` reçoit les bornes de la WORKING-STORAGE
  (`CICS-API-WS-START` … `CICS-API-WS-END`) : **[déduit]** pour CEDF et
  les dumps ; elle suppose que la WORKING-STORAGE est **contiguë et dans
  l'ordre de déclaration**. À vérifier avec les instances par contexte
  de T1 (allocation d'un bloc unique ?).
- Copybook `CICS-EIB` : `DFHEIBLK` au format TXSeries (COMP-3 pour
  EIBTIME/EIBDATE/EIBTASKN, COMP-5 pour les binaires, `EIBLABEL`
  `S9(4) COMP-5`, `EIBGLOBALVARS POINTER`).

### 6.2 Compilation : `cicstcl -lCOBCLD`
Ligne de commande réelle (capturée avec un faux `cobc`) **[vérifié]** :

```
cicstran -e -d -lCOBCLD hello.ccp
cobc -o hello.cld -fthread-safe -fnotrunc -I $CICSPATH/include -m hello.cbl
```
(`-lCOBOLIT` : même chose sans `-o`, donc `hello.so`).
La variable `CICS_COBCLD_CCFLAGS` (resp. `CICS_COBOLIT_CCFLAGS`) est
ajoutée après `-I …` **[vérifié]**.

État avec notre `cobc` (2026-11-07) :
- `-fthread-safe` : **refusé** (« unrecognized option ») ;
- `SPECIAL-NAMES` sans `CONFIGURATION SECTION` : erreur avec le
  dialecte par défaut, accepté avec `-frelax-syntax-checks` ou
  `-std=mf` ;
- `call-convention 8 is litlink` et `CALL litlink` : acceptés ;
- avec `-std=mf` ou `-frelax-syntax-checks`, le source traduit compile
  et le `.so` exporte `HELLO` **[vérifié]**.

---

## 7. Conséquences pour GnuCOBOL (pistes pour T5)

1. **Bibliothèque `libcobcld`** fournissant les 12 symboles du § 3 sur
   libcob : `cob_get_rtd` = contexte du thread (un `cob_context` par
   tâche CICS, créé à la demande), `cob_init (rtd, …)` =
   `cob_set_hosted (1)` + `cob_init`, régions = pile de contextes ou
   d'instances par niveau de LINK, `cob_resolve (rtd, name)` =
   résolution de libcob dans le contexte de la région, CANCEL de région =
   CANCEL des programmes chargés dans ce contexte.
2. **Conflit de noms** `cob_init` / `cob_resolve` entre l'API COBOL-IT et
   libcob. Solution envisagée : `libcobcld.a` statique, symboles de
   visibilité cachée, lié dans `cicsprCOBCLD` seulement ; elle appelle
   libcob par d'autres noms (`cob_init_ctx`…, à exporter si besoin). Ne
   pas fournir de `libcobcld.so` exportant `cob_init`, sous peine
   d'interposition sur les appels internes de libcob.
3. **rtd binaire** : un bloc d'au moins `0x10c` octets avec `int` en 0,
   `jmp_buf` en `0x40`, `int` en `0x108`, en tête de la structure (le
   reste peut pointer vers le `cob_context`). STOP RUN / erreur fatale
   dans un contexte hébergé : `longjmp (rtd + 0x40, code)` si
   `rtd[0x108]` est armé ; le gestionnaire de fin de T2 peut le faire.
4. **`CBL_ERROR_PROC` / `CBL_EXIT_PROC` avec `'0'`** : libcob traite
   « non nul » comme « retirer » ; il faut accepter `'0'` comme
   « installer » (dans la couche `libcobcld`, pas dans libcob).
5. **Nom résolu** : IBM passe le nom de fichier (`dfhcall`, minuscules),
   alors que le point d'entrée est le PROGRAM-ID (`DFHCALL`). COBOL-IT
   résout sans tenir compte de la casse **[déduit]** ; notre
   `cob_resolve` devra essayer le nom tel quel, puis en majuscules, et
   charger `name.cld` (pas seulement `.so`) depuis `COB_LIBRARY_PATH`.
6. **Symboles `CICSAPI*`** : le programme les importe ; ils doivent être
   visibles au moment du `dlopen` du `.cld` (méthode chargée avec
   `RTLD_GLOBAL` ?) **[à vérifier en région]**.
7. **`cobc`** : accepter `-fthread-safe` (sans effet : runtime
   réentrant), `-preprocess=` éventuellement, et une configuration
   `txseries.conf` (via `CICS_COBCLD_CCFLAGS=-conf=…`) qui accepte
   `SPECIAL-NAMES` sans `CONFIGURATION SECTION` (T4).
8. **Erreurs** : une erreur d'exécution COBOL termine l'application
   server (`SupOS_ServerExit`) via le gestionnaire d'erreur ; pour être
   plus robuste que COBOL-IT, préférer le `longjmp` vers `rtd + 0x40`.

---

## 8. Reproduire l'analyse

```sh
# archives d'évaluation (essai 90 jours, IBM ID) dans ~/Downloads
mkdir -p ~/txseries-11.1/container && cd ~/txseries-11.1/container
tar xf ~/Downloads/TXSeries111-Evaluation-Linux-x86_64_Container-Image.tar
openssl dgst -sha256 -verify txserieskey.pem.pub.key \
        -signature signature.sig TXSeries111-Evaluation-Linux-x86_64_Container.tar
tar xf TXSeries111-Evaluation-Linux-x86_64_Container.tar
cd TXSeries111-Evaluation-Linux-x86_64_Container
docker load -i ibm-txseries-trial-11.1.0.0.tar.gz   # localhost/ibm-txseries-trial:11.1.0.0

# système de fichiers de TXSeries sans lancer le conteneur
mkdir img && tar xzf ibm-txseries-trial-11.1.0.0.tar.gz -C img
mkdir -p ~/txseries-11.1/rootfs
tar xf img/fae96818fa0c7c52a0d8175def5cb5ace507cf4ba0b37e3b6ad5100e83368ba8.tar \
    -C ~/txseries-11.1/rootfs --no-same-owner        # couche /opt/ibm/cics64
C=~/txseries-11.1/rootfs/opt/ibm/cics64/11.1
nm -u $C/lib/pinca_cobcld.o
objdump -dr --no-show-raw-insn -M intel $C/lib/pinca_cobcld.o

# traduire / compiler dans le conteneur, sans réseau
docker run --rm --network none --entrypoint /bin/bash -v $PWD:/t \
    localhost/ibm-txseries-trial:11.1.0.0 \
    -c 'cd /tmp && cp /t/prog.ccp . && cicstran -e -d -lCOBCLD prog.ccp && cp prog.cbl /t/'
```

Image : utilisateur `cics`, `CICSPATH=/opt/ibm/cics64/11.1`,
`CICS_PROGRAM_PATH=/work/autoinstall-dropin/`, point d'entrée
`/work/create_and_start` (région `TXREGION`, serveur SFS `TXSFS`,
ports 3270, 9443, 1435), `HEALTHCHECK cicshealth`.
