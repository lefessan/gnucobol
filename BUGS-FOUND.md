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
- Statut : **vérifié** dans le source.
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
- Statut : signalé par une analyse, **non vérifié**.
- La valeur `ns_time` mémorisée n'est jamais mise à jour hors mode test,
  donc la vérification censée garantir un temps croissant ne sert à rien.

### `libcob/common.c:1016` — `cob_get_strerror` non réentrant
- Statut : signalé par deux analyses, **non vérifié**.
- Le commentaire le dit réentrant, mais il appelle `strerror` (non
  réentrant) au lieu de `strerror_r`.

### `libcob/common.c` — `cob_module_err` mort
- Statut : signalé par une analyse, **non vérifié**.
- Variable lue seulement dans du code `#if 0` : à supprimer.
