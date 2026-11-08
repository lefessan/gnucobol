#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <libcob.h>

#define NCALLS 300000
static int nthreads;

static void *
task (void *arg)
{
   cob_context *ctx = cob_context_create ();
   cob_context *prev = cob_context_enter (ctx);
   char res[9];
   void *argv[2];
   int i;
   argv[0] = res; argv[1] = "00";
   for (i = 0; i < NCALLS; i++) {
      (void)cob_call ("work", 2, argv);
   }
   cob_context_leave (prev);
   cob_context_destroy (ctx);
   return arg;
}

int
main (int argc, char **argv)
{
   pthread_t th[64];
   int i;
   nthreads = atoi (argv[1]);
   cob_init (0, NULL);
   for (i = 0; i < nthreads; i++) pthread_create (&th[i], NULL, task, NULL);
   for (i = 0; i < nthreads; i++) pthread_join (th[i], NULL);
   cob_stop_run (0);
}
