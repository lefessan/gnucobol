/*
   Copyright (C) 2026 Free Software Foundation, Inc.

   This file is part of GnuCOBOL.

   The GnuCOBOL runtime library is free software: you can redistribute it
   and/or modify it under the terms of the GNU Lesser General Public License
   as published by the Free Software Foundation, either version 3 of the
   License, or (at your option) any later version.

   GnuCOBOL is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public License
   along with GnuCOBOL.  If not, see <https://www.gnu.org/licenses/>.
*/

/* libcobcld: the runtime API that the COBOL language method of IBM
   TXSeries for CobolCloud (pinca_cobcld.o, linked into cicsprCOBCLD by
   cicsmkcobcld) expects, implemented on libcob.

   See TXSERIES-COBOLIT-API.md for the reverse engineering of that API.

   The functions are built into a static archive with hidden visibility:
   cob_init, cob_resolve and cob_resolve_error have other signatures in
   libcob, they must only be seen by cicsprCOBCLD.

   Model:
   - one "rtd" per thread of the application server (cicsas);
   - one GnuCOBOL context per "region" of the rtd, a region being a
     level of EXEC CICS LINK in the task (1 to 15); TXSeries cancels the
     region before each load of a program, so each LINK starts with
     programs in their initial state, as CICS requires;
   - STOP RUN and fatal errors end the run unit of the context and
     return to the jmp_buf of the rtd, armed by TXSeries before it calls
     the program (cob_context_set_return_point). */

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <setjmp.h>
#include <unistd.h>
#include <pthread.h>

/* hide the declarations of libcob for the names of the COBOL-IT API */
#define cob_init		libcob_cob_init
#define cob_resolve		libcob_cob_resolve
#define cob_resolve_error	libcob_cob_resolve_error
#include <libcob.h>
#undef cob_init
#undef cob_resolve
#undef cob_resolve_error

#define CLD_API		__attribute__ ((visibility ("hidden")))

#define CLD_MAX_REGION	15	/* COBIT_MAX_REGION of TXSeries */
#define CLD_NAME_MAX	256

/* runtime data: the first fields are read and written by TXSeries */
struct cob_rtd {
	int		embedded;	/* 0x000: set to 1 by TXSeries */
	char		reserved1[0x40 - sizeof (int)];
	jmp_buf		return_jmp;	/* 0x040: setjmp by TXSeries */
	int		return_jmp_set;	/* 0x108: set to 1 by TXSeries */

	/* ours */
	int		current;	/* current region, 0 = none */
	cob_context	*outer;		/* current context before region 1 */
	cob_context	*region[CLD_MAX_REGION + 1];
	char		error[4096 + CLD_NAME_MAX + 64];
};

_Static_assert (offsetof (struct cob_rtd, return_jmp) == 0x40,
		"TXSeries expects the jmp_buf at 0x40");
_Static_assert (offsetof (struct cob_rtd, return_jmp_set) == 0x108,
		"TXSeries expects the flag at 0x108");

/* procedures given by TXSeries (CBL_ERROR_PROC, CBL_EXIT_PROC) */
typedef int	(*cld_error_proc) (char *);
typedef void	(*cld_exit_proc) (void);

static __thread struct cob_rtd	*thread_rtd;
static pthread_once_t		init_once = PTHREAD_ONCE_INIT;
static int			init_argc;
static char			**init_argv;
static cld_error_proc		error_proc;
static cld_exit_proc		exit_proc;

CLD_API struct cob_rtd	*cob_get_rtd (void);
CLD_API void		cob_init (struct cob_rtd *, int, char **);
CLD_API struct cob_rtd	*cob_enterprise_set_current_region (struct cob_rtd *,
				int);
CLD_API int		cob_enterprise_get_current_region (struct cob_rtd *);
CLD_API void		cob_enterprise_cancel_region (struct cob_rtd *, int,
				int);
CLD_API void		*cob_resolve (struct cob_rtd *, const char *);
CLD_API const char	*cob_resolve_error (struct cob_rtd *);
CLD_API void		cob_runtime_debugger_init (void);
CLD_API void		cob_runtime_debugger_activate (struct cob_rtd *, int);
CLD_API void		cob_dump_debug_info (struct cob_rtd *);
CLD_API int		CBL_ERROR_PROC (unsigned char *, void *);
CLD_API int		CBL_EXIT_PROC (unsigned char *, void *);

/* the rtd of the thread */
struct cob_rtd *
cob_get_rtd (void)
{
	if (thread_rtd == NULL) {
		thread_rtd = calloc (1, sizeof (struct cob_rtd));
	}
	return thread_rtd;
}

static void
init_runtime (void)
{
	cob_set_hosted (1);
	cob_init_nomain (init_argc, init_argv);
}

/* initialization of the runtime, once per process */
void
cob_init (struct cob_rtd *rtd, int argc, char **argv)
{
	(void)rtd;
	init_argc = argc;
	init_argv = argv;
	(void)pthread_once (&init_once, init_runtime);
}

/* the context of a region, created when needed */
static cob_context *
region_context (struct cob_rtd *rtd, int region)
{
	cob_context	*ctx = rtd->region[region];
	if (ctx == NULL) {
		ctx = cob_context_create ();
		cob_context_set_return_point (ctx, &rtd->return_jmp);
		rtd->region[region] = ctx;
	}
	return ctx;
}

static int
valid_region (int region)
{
	if (region < 0) {
		return 0;
	}
	if (region > CLD_MAX_REGION) {
		return CLD_MAX_REGION;
	}
	return region;
}

/* make 'region' current: its context becomes the current context of
   the thread; region 0 restores the context of the thread before */
struct cob_rtd *
cob_enterprise_set_current_region (struct cob_rtd *rtd, int region)
{
	region = valid_region (region);
	if (rtd->current == 0 && region != 0) {
		rtd->outer = cob_get_current_context ();
	}
	if (region == 0) {
		cob_context_leave (rtd->outer);
	} else {
		(void)cob_context_enter (region_context (rtd, region));
	}
	rtd->current = region;
	return rtd;
}

int
cob_enterprise_get_current_region (struct cob_rtd *rtd)
{
	return rtd->current;
}

/* cancel all the programs of a region: its context is destroyed, the
   next use creates a new one, with the programs in their initial state;
   mode 1 (NEWCOPY, or CICS_DISABLE_COBCLD_CACHE) should also reload the
   module files, which libcob does not do for preloaded modules */
void
cob_enterprise_cancel_region (struct cob_rtd *rtd, int region, int mode)
{
	cob_context	*ctx;

	(void)mode;
	region = valid_region (region);
	ctx = rtd->region[region];
	if (region == 0 || ctx == NULL) {
		return;
	}
	if (cob_get_current_context () == ctx) {
		cob_context_leave (rtd->outer);
		rtd->current = 0;
	}
	cob_context_set_return_point (ctx, NULL);
	cob_context_destroy (ctx);
	rtd->region[region] = NULL;
}

/* append the directories of a path list (':') to the candidates */
static int
find_in_path (const char *list, const char *name, char *found, size_t size)
{
	const char	*p = list;
	const char	*e;

	if (list == NULL) {
		return 0;
	}
	while (*p) {
		size_t	len;
		e = strchr (p, ':');
		len = e ? (size_t)(e - p) : strlen (p);
		if (len > 0) {
			if ((size_t)snprintf (found, size, "%.*s/%s.cld",
					      (int)len, p, name) < size
			 && access (found, R_OK) == 0) {
				return 1;
			}
		}
		if (e == NULL) {
			break;
		}
		p = e + 1;
	}
	return 0;
}

/* the module file NAME.cld of a program, searched in COB_LIBRARY_PATH,
   then CICS_PROGRAM_PATH, then the current directory */
static int
find_module (const char *name, char *found, size_t size)
{
	if (find_in_path (getenv ("COB_LIBRARY_PATH"), name, found, size)
	 || find_in_path (getenv ("CICS_PROGRAM_PATH"), name, found, size)
	 || find_in_path (".", name, found, size)) {
		return 1;
	}
	return 0;
}

static void
case_copy (char *to, const char *from, int upper)
{
	for (; *from; from++, to++) {
		*to = (char)(upper ? toupper ((unsigned char)*from)
				   : tolower ((unsigned char)*from));
	}
	*to = 0;
}

/* the entry point of the program 'name' (the base name of the PathName
   of the program definition, without extension) in the current region;
   the entry point is the PROGRAM-ID, which may differ in case */
void *
cob_resolve (struct cob_rtd *rtd, const char *name)
{
	cob_context	*ctx;
	char		path[4096];
	char		lower[CLD_NAME_MAX + 1];
	char		upper[CLD_NAME_MAX + 1];
	const char	*names[3];
	void		*entry;
	int		i;

	if (strlen (name) > CLD_NAME_MAX) {
		snprintf (rtd->error, sizeof (rtd->error),
			  "program name too long");
		return NULL;
	}
	ctx = rtd->current ? region_context (rtd, rtd->current)
			   : cob_get_current_context ();
	case_copy (lower, name, 0);
	case_copy (upper, name, 1);
	names[0] = name;
	names[1] = lower;
	names[2] = upper;

	/* load the module file */
	for (i = 0; i < 3; i++) {
		if (find_module (names[i], path, sizeof (path))) {
			break;
		}
	}
	if (i == 3) {
		snprintf (rtd->error, sizeof (rtd->error),
			  "module '%s.cld' not found", name);
		return NULL;
	}
	if (!cob_preload_module_ctx (ctx, path)) {
		snprintf (rtd->error, sizeof (rtd->error), "%s",
			  cob_resolve_error_ctx (ctx));
		return NULL;
	}

	/* its entry point */
	for (i = 0; i < 3; i++) {
		entry = cob_resolve_ctx (ctx, names[i]);
		if (entry != NULL) {
			rtd->error[0] = 0;
			return entry;
		}
	}
	snprintf (rtd->error, sizeof (rtd->error),
		  "entry point '%s' not found in '%s'", name, path);
	return NULL;
}

const char *
cob_resolve_error (struct cob_rtd *rtd)
{
	return rtd->error;
}

/* the debugger of COBOL-IT: not available */
void
cob_runtime_debugger_init (void)
{
}

void
cob_runtime_debugger_activate (struct cob_rtd *rtd, int flag)
{
	(void)rtd;
	(void)flag;
}

/* called by TXSeries after a STOP RUN or a fatal error */
void
cob_dump_debug_info (struct cob_rtd *rtd)
{
	(void)rtd;
}

/* the error and exit procedures of TXSeries: they abend the task and
   end the application server; they are kept but not called, the
   return point of the rtd brings STOP RUN and the fatal errors back to
   TXSeries instead; TXSeries installs them with the flag '0' (not the
   binary 0 of Micro Focus) */
static int
install_flag (const unsigned char *flag)
{
	return *flag == 0 || *flag == '0';
}

int
CBL_ERROR_PROC (unsigned char *flag, void *proc)
{
	error_proc = install_flag (flag) ? *(cld_error_proc *)proc : NULL;
	return 0;
}

int
CBL_EXIT_PROC (unsigned char *flag, void *proc)
{
	exit_proc = install_flag (flag) ? *(cld_exit_proc *)proc : NULL;
	return 0;
}
