/*
 * sel.c
 * 
 * util routines for do the various select activities
 * 
 * Copyright 1996 (c) D-J Koopman
 * 
 * $Header$
 */
 

static char rcsid[] = "$Id$";

#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>
#include <stdlib.h>
#include <time.h>
#include <string.h>
#include <errno.h>

#include "chain.h"
#include "sel.h"

sel_t *sel;							   /* the array of selectors */
int sel_max;						   /* the maximum no of selectors */
int sel_top;						   /* the last selector in use */
int sel_inuse;						   /* the no of selectors in use */
time_t sel_systime;					   /* the unix time now */
struct timeval sel_tv;				   /* the current timeout for select */

/*
 * initialise the selector system, no is the no of slots to reserve
 */

void sel_init(int no, long sec, long usec)
{
	sel = malloc(sizeof(sel_t) * no);
	if (!sel)
		die("no room in sel_init");
	memset(sel, 0, sizeof(sel_t) * no);
	sel_max = no;
	sel_inuse = sel_top = 0;
	if (sec == 0 && usec == 0) 
		usec = 10000;
	sel_tv.tv_sec = sec;
	sel_tv.tv_usec = usec;
}

/*
 * open and initialise a selector slot, you are expected to deal with the
 * actual opening and setting up of the device itself
 */

sel_t *sel_open(int cnum, void *fcb, char *name, int (*handler)(), int sort, int flags)
{
	int i;
	sel_t *sp;
	
	/* get a free slot */
	for (i = 0; i < sel_max; ++i) {
		sp = &sel[i];
		if (sp->sort == 0)
			break;
	}
	if (i >= sel_max)
		die("there are no more sel slots available (max %d)", sel_max);
	
	/* fill in the blanks */
	sp->cnum = cnum;
	sp->fcb = fcb;
	sp->name = strdup(name);
	sp->handler = handler;
	sp->sort = sort;
	sp->flags = flags;
	sp->msgbase = chain_new();
	sp->err = 0;
	++sel_inuse;
	if (sel_top < (sp - sel) + 1)
		sel_top = (sp - sel) + 1;
	return sp;
}

/*
 * close (and thus clear down) a slot, it is assumed that you have done whatever
 * you need to do to close the actual device already
 */

void sel_close(sel_t *sp)
{
	if (sp->sort) {
		chain_flush(sp->msgbase);
		free(sp->msgbase);
		free(sp->name);
		memset(sp, 0, sizeof(sel_t));
		if (sel_top == (sp - sel) + 1)
			--sel_top;
		--sel_inuse;
	}
}

/*
 * this actually runs the (de)multiplexor, it simply listens to the various cnums 
 * presents the events to the handler which has to deal with them
 */

void sel_run()
{
	int i, r, max = 0;
	struct timeval tv;
	fd_set infd;
	fd_set outfd;
	fd_set errfd;
	sel_t *sp;
	
	/* first set up the parameters for the select according to the slots registered */
	FD_ZERO(&infd);
	FD_ZERO(&outfd);
	FD_ZERO(&errfd);
	tv = sel_tv;
	
	for (i = 0; i < sel_top; ++i) {
		sp = &sel[i];
		if (sp->sort && !sp->err) {
			if (sp->flags & SEL_INPUT)
				FD_SET(sp->cnum, &infd);
			if (sp->flags & SEL_OUTPUT)
				FD_SET(sp->cnum, &outfd);
			if (sp->flags & SEL_ERROR)
				FD_SET(sp->cnum, &errfd);
			if (sp->cnum > max)
				max = sp->cnum;
		}
	}
	
	/* now do the select */
	r = select(max + 1, &infd, &outfd, &errfd, &tv);

	if (r < 0) {
		if (errno != EINTR)
			die("Error during select (%d)", errno);
		return;
	}

	/* if there is anything to do, pass it on to the appropriate handler */
	if (r > 0) {
		int in, out, err;
		int hr;
		
		for (i = 0; i < sel_top; ++i) {
			sp = &sel[i];
			if (sp->sort) {
				in = FD_ISSET(sp->cnum, &infd);
				out = FD_ISSET(sp->cnum, &outfd);
				err = FD_ISSET(sp->cnum, &errfd);
				if (in || out || err) {
					hr = (sp->handler)(sp, in, out, err);
					
					/* if this is positive, close this selector */
					if (hr)
						sel_close(sp);
					else {
						FD_CLR(sp->cnum, &infd);
						FD_CLR(sp->cnum, &outfd);
						FD_CLR(sp->cnum, &errfd);
					}
				}
			}
		}
	}
	
	time(&sel_systime);				   /* note the time, for general purpuse use */
}

/*
 * get/set error flag - -1 simply gets the flag, 0 or 1 sets the flag
 * 
 * in all cases the old setting of the flag is returned
 */

int sel_error(sel_t *sp, int err)
{
	int r = sp->err;
	if (err >= 0)
		sp->err = err;
	return err;
}

/*
 * $Log$
 * Revision 1.1  2000-03-26 00:03:30  djk
 * first cut of client
 *
 * Revision 1.3  1998/01/02 19:39:59  djk
 * made various changes to cope with glibc
 * fixed problem with extended status in etsi_router
 *
 * Revision 1.2  1997/06/18 18:44:31  djk
 * A working hayes implementation!
 *
 * Revision 1.1  1997/01/28 16:14:38  djk
 * moved these into lib as general routines to use with sel
 *
 * Revision 1.3  1997/01/15 21:23:26  djk
 * fixed a few minor svlp problems and added the router logging system
 *
 * Revision 1.2  1997/01/13 23:34:56  djk
 * The first working test version of smsd
 *
 * Revision 1.1  1997/01/03 23:44:31  djk
 * initial workings
 *
 *
 */
