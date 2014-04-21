/*
 *
 * HRTest2 - A short skeleton to demonstrate the use of the second
 * simplified read mode of HRTimer 1.1
 * 3/99 by Heinz Repp
 * parts from HRTest.C by Rick Fishman
 *
 */

#define DEFAULT_TIME_PERIOD 5000

#include <stdio.h>         /* for printf */
#include <stdlib.h>        /* for atoi */
#include <io.h>            /* for timer i/o */
#include <fcntl.h>
#include <conio.h>         /* for kbhit/getch */
#define INCL_DOSPROCESS    /* for DosSleep */
#include <os2.h>


int main (int argc, char *argv[])
{
  ULONG ulTimePeriod, ulStart, ulStop, ulOverhead;
  int timer, running;

  /* check for commandline args */
  if (argc < 2)
    ulTimePeriod = DEFAULT_TIME_PERIOD;
  else
    ulTimePeriod = atoi (argv[1]);

  printf ("\nMeasuring a DosSleep of %lu milliseconds\n\n", ulTimePeriod);


  /* Open the timer */
  timer = open ("TIMER$", O_RDONLY|O_BINARY);
  if (timer == -1)
  {
    printf ("opening the timer device failed.\n");
    return -1;
  }
  else
  {

    /* Determine the overhead for two successive reads          *
     * always do first a dummy timer read to fill the 2nd level *
     * processor cache - the first time needs always more!      */

    read (timer, &ulStop, sizeof (ULONG));   /* dummy */
    read (timer, &ulStart, sizeof (ULONG));
    read (timer, &ulStop, sizeof (ULONG));

    ulOverhead = ulStop - ulStart;
    printf ("Overhead = %10lu æs\n\n", ulOverhead);

    printf ("Hit any key to end this test program after waking again\n"
            "    or Ctrl-C to stop immediately ...\n\n");


    /* Main loop: running until user aborts */

    running = TRUE;
    while (running)
    {
      printf ("Sleeping for %lu milliseconds ...", ulTimePeriod);
      fflush (stdout);

      read (timer, &ulStart, sizeof (ULONG));

      DosSleep (ulTimePeriod);

      read (timer, &ulStop, sizeof (ULONG));

      printf (" elapsed time = %10lu æs\n",
              ulStop - ulStart - ulOverhead);

      /* check for key pressed */
      while (kbhit())
      {
        getch();         /* dummy read to empty keyboard buffer */
        running = FALSE;
      }

    } /* Main loop ends */

    close (timer);
  }

  return 0;
}
