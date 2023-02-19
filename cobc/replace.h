/*
   Copyright (C) 2023-2023 Free Software Foundation, Inc.
   Written by Fabrice Le Fessant

   This file is part of GnuCOBOL.

   The GnuCOBOL compiler is free software: you can redistribute it
   and/or modify it under the terms of the GNU General Public License
   as published by the Free Software Foundation, either version 3 of the
   License, or (at your option) any later version.

   GnuCOBOL is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with GnuCOBOL.  If not, see <https://www.gnu.org/licenses/>.
*/

#ifndef CB_REPLACE_H
#define CB_REPLACE_H

// defined in pplex.l
extern void	ppecho_direct (const char *);
extern struct cb_text_list	*pp_text_list_add (struct cb_text_list *,
					 const char *, const size_t);

// defined in replace.c

extern void init_replace (void);
extern void reset_replace (void);
extern void free_replace (void);
extern void ppecho_copy (const char *);

/* For COPY-REPLACING */
extern void set_copy_replacing_list (struct cb_replace_list *list);
extern struct cb_replace_list * get_copy_replacing_list (void);

/* For REPLACE, called from yylex.l pp_set_replace_list */
extern void
set_replace_list (struct cb_replace_list *list, const int is_pushpop);

#endif // CB_REPLACE_H
