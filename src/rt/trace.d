
/* Trace dynamic profiler.
 * For use with the Digital Mars DMD compiler.
 * Copyright (C) 1995-2006 by Digital Mars
 * All Rights Reserved
 * Written by Walter Bright
 * www.digitalmars.com
 */

/*
 *  Modified by Sean Kelly <sean@f4.ca> for use with Tango.
 */

module rt.trace;

private
{
    import rt.util.string;
    import core.stdc.string : memset, memcpy, strlen;
    import core.stdc.stdlib : malloc, free, exit, strtoul, strtoull, qsort,
                                EXIT_FAILURE;
    import core.stdc.ctype : isspace, isalpha, isgraph;
    import core.stdc.stdio : fopen, fclose, fprintf, fgetc, FILE, EOF;
}

extern (C):

char* unmangle_ident(char*);    // from DMC++ runtime library

alias long timer_t;

/////////////////////////////////////
//

struct SymPair
{
    SymPair* next;
    Symbol* sym;        // function that is called
    uint count;         // number of times sym is called
}

/////////////////////////////////////
// A Symbol for each function name.

struct Symbol
{
        Symbol* Sl, Sr;         // left, right children
        SymPair* Sfanin;        // list of calling functions
        SymPair* Sfanout;       // list of called functions
        timer_t totaltime;      // aggregate time
        timer_t functime;       // time excluding subfunction calls
        ubyte Sflags;
        char[] Sident;          // name of symbol
}

const ubyte SFvisited = 1;      // visited

static Symbol* root;            // root of symbol table

//////////////////////////////////
// Build a linked list of these.

struct Stack
{
    Stack* prev;
    Symbol* sym;
    timer_t starttime;          // time when function was entered
    timer_t ohd;                // overhead of all the bookkeeping code
    timer_t subtime;            // time used by all subfunctions
}

static Stack* stack_freelist;
static Stack* trace_tos;                // top of stack
static int trace_inited;                // !=0 if initialized
static timer_t trace_ohd;

static Symbol** psymbols;
static uint nsymbols;           // number of symbols

static char[] trace_logfilename = "trace.log";
static FILE* fplog;

static char[] trace_deffilename = "trace.def";
static FILE* fpdef;


////////////////////////////////////////
// Set file name for output.
// A file name of "" means write results to stdout.
// Returns:
//      0       success
//      !=0     failure

int trace_setlogfilename(char[] name)
{
    trace_logfilename = name;
    return 0;
}

////////////////////////////////////////
// Set file name for output.
// A file name of "" means write results to stdout.
// Returns:
//      0       success
//      !=0     failure

int trace_setdeffilename(char[] name)
{
    trace_deffilename = name;
    return 0;
}

////////////////////////////////////////
// Output optimal function link order.

static void trace_order(Symbol *s)
{
    while (s)
    {
        trace_place(s,0);
        if (s.Sl)
            trace_order(s.Sl);
        s = s.Sr;
    }
}

//////////////////////////////////////////////
//

static Stack* stack_malloc()
{   Stack *s;

    if (stack_freelist)
    {   s = stack_freelist;
        stack_freelist = s.prev;
    }
    else
        s = cast(Stack *)trace_malloc(Stack.sizeof);
    return s;
}

//////////////////////////////////////////////
//

static void stack_free(Stack *s)
{
    s.prev = stack_freelist;
    stack_freelist = s;
}

//////////////////////////////////////
// Qsort() comparison routine for array of pointers to SymPair's.

static int sympair_cmp(in void* e1, in void* e2)
{   SymPair** psp1;
    SymPair** psp2;

    psp1 = cast(SymPair**)e1;
    psp2 = cast(SymPair**)e2;

    return (*psp2).count - (*psp1).count;
}

//////////////////////////////////////
// Place symbol s, and then place any fan ins or fan outs with
// counts greater than count.

static void trace_place(Symbol *s, uint count)
{   SymPair* sp;
    SymPair** base;

    if (!(s.Sflags & SFvisited))
    {   size_t num;
        uint u;

        //printf("\t%.*s\t%u\n", s.Sident, count);
        fprintf(fpdef,"\t%.*s\n".ptr, s.Sident);
        s.Sflags |= SFvisited;

        // Compute number of items in array
        num = 0;
        for (sp = s.Sfanin; sp; sp = sp.next)
            num++;
        for (sp = s.Sfanout; sp; sp = sp.next)
            num++;
        if (!num)
            return;

        // Allocate and fill array
        base = cast(SymPair**)trace_malloc(SymPair.sizeof * num);
        u = 0;
        for (sp = s.Sfanin; sp; sp = sp.next)
            base[u++] = sp;
        for (sp = s.Sfanout; sp; sp = sp.next)
            base[u++] = sp;

        // Sort array
        qsort(base, num, (SymPair *).sizeof, &sympair_cmp);

        //for (u = 0; u < num; u++)
            //printf("\t\t%.*s\t%u\n", base[u].sym.Sident, base[u].count);

        // Place symbols
        for (u = 0; u < num; u++)
        {
            if (base[u].count >= count)
            {   uint u2;
                uint c2;

                u2 = (u + 1 < num) ? u + 1 : u;
                c2 = base[u2].count;
                if (c2 < count)
                    c2 = count;
                trace_place(base[u].sym,c2);
            }
            else
                break;
        }

        // Clean up
        trace_free(base);
    }
}

/////////////////////////////////////
// Initialize and terminate.

static this()
{
    trace_init();
}

static ~this()
{
    trace_term();
}

///////////////////////////////////
// Report results.
// Also compute nsymbols.

static void trace_report(Symbol* s)
{   SymPair* sp;
    uint count;

    //printf("trace_report()\n");
    while (s)
    {   nsymbols++;
        if (s.Sl)
            trace_report(s.Sl);
        fprintf(fplog,"------------------\n".ptr);
        count = 0;
        for (sp = s.Sfanin; sp; sp = sp.next)
        {
            fprintf(fplog,"\t%5d\t%.*s\n".ptr, sp.count, sp.sym.Sident);
            count += sp.count;
        }
        fprintf(fplog,"%.*s\t%u\t%lld\t%lld\n".ptr,s.Sident,count,s.totaltime,s.functime);
        for (sp = s.Sfanout; sp; sp = sp.next)
        {
            fprintf(fplog,"\t%5d\t%.*s\n".ptr,sp.count,sp.sym.Sident);
        }
        s = s.Sr;
    }
}

////////////////////////////////////
// Allocate and fill array of symbols.

static void trace_array(Symbol *s)
{   static uint u;

    if (!psymbols)
    {   u = 0;
        psymbols = cast(Symbol **)trace_malloc((Symbol *).sizeof * nsymbols);
    }
    while (s)
    {
        psymbols[u++] = s;
        trace_array(s.Sl);
        s = s.Sr;
    }
}


//////////////////////////////////////
// Qsort() comparison routine for array of pointers to Symbol's.

static int symbol_cmp(in void* e1, in void* e2)
{   Symbol** ps1;
    Symbol** ps2;
    timer_t diff;

    ps1 = cast(Symbol **)e1;
    ps2 = cast(Symbol **)e2;

    diff = (*ps2).functime - (*ps1).functime;
    return (diff == 0) ? 0 : ((diff > 0) ? 1 : -1);
}


///////////////////////////////////
// Report function timings

static void trace_times(Symbol* root)
{   uint u;
    timer_t freq;

    // Sort array
    qsort(psymbols, nsymbols, (Symbol *).sizeof, &symbol_cmp);

    // Print array
    QueryPerformanceFrequency(&freq);
    fprintf(fplog,"\n======== Timer Is %lld Ticks/Sec, Times are in Microsecs ========\n\n".ptr,freq);
    fprintf(fplog,"  Num          Tree        Func        Per\n".ptr);
    fprintf(fplog,"  Calls        Time        Time        Call\n\n".ptr);
    for (u = 0; u < nsymbols; u++)
    {   Symbol* s = psymbols[u];
        timer_t tl,tr;
        timer_t fl,fr;
        timer_t pl,pr;
        timer_t percall;
        SymPair* sp;
        uint calls;
        char[] id;

        version (Win32)
        {
            char* p = (s.Sident ~ '\0').ptr;
            p = unmangle_ident(p);
            if (p)
                id = p[0 .. strlen(p)];
        }
        if (!id)
            id = s.Sident;
        calls = 0;
        for (sp = s.Sfanin; sp; sp = sp.next)
            calls += sp.count;
        if (calls == 0)
            calls = 1;

version (all)
{
        tl = (s.totaltime * 1000000) / freq;
        fl = (s.functime  * 1000000) / freq;
        percall = s.functime / calls;
        pl = (s.functime * 1000000) / calls / freq;

        fprintf(fplog,"%7d%12lld%12lld%12lld     %.*s\n".ptr,
            calls,tl,fl,pl,id);
}
else
{
        tl = s.totaltime / freq;
        tr = ((s.totaltime - tl * freq) * 10000000) / freq;

        fl = s.functime  / freq;
        fr = ((s.functime  - fl * freq) * 10000000) / freq;

        percall = s.functime / calls;
        pl = percall  / freq;
        pr = ((percall  - pl * freq) * 10000000) / freq;

        fprintf(fplog,"%7d\t%3lld.%07lld\t%3lld.%07lld\t%3lld.%07lld\t%.*s\n",
            calls,tl,tr,fl,fr,pl,pr,id);
}
        if (id !is s.Sident)
            free(id.ptr);
    }
}


///////////////////////////////////
// Initialize.

static void trace_init()
{
    if (!trace_inited)
    {
        trace_inited = 1;

        {   // See if we can determine the overhead.
            uint u;
            timer_t starttime;
            timer_t endtime;
            Stack *st;

            st = trace_tos;
            trace_tos = null;
            QueryPerformanceCounter(&starttime);
            for (u = 0; u < 100; u++)
            {
                _c_trace_pro(0,null);
                _c_trace_epi();
            }
            QueryPerformanceCounter(&endtime);
            trace_ohd = (endtime - starttime) / u;
            //printf("trace_ohd = %lld\n",trace_ohd);
            if (trace_ohd > 0)
                trace_ohd--;            // round down
            trace_tos = st;
        }
    }
}

/////////////////////////////////
// Terminate.

void trace_term()
{
    //printf("trace_term()\n");
    if (trace_inited == 1)
    {   Stack *n;

        trace_inited = 2;

        // Free remainder of the stack
        while (trace_tos)
        {
            n = trace_tos.prev;
            stack_free(trace_tos);
            trace_tos = n;
        }

        while (stack_freelist)
        {
            n = stack_freelist.prev;
            stack_free(stack_freelist);
            stack_freelist = n;
        }

        // Merge in data from any existing file
        trace_merge();

        // Report results
        fplog = fopen(trace_logfilename.ptr, "w".ptr);
        //fplog = tango.stdc.stdio.stdout;
        if (fplog)
        {   nsymbols = 0;
            trace_report(root);
            trace_array(root);
            trace_times(root);
            fclose(fplog);
        }

        // Output function link order
        fpdef = fopen(trace_deffilename.ptr,"w".ptr);
        if (fpdef)
        {   fprintf(fpdef,"\nFUNCTIONS\n".ptr);
            trace_order(root);
            fclose(fpdef);
        }

        trace_free(psymbols);
        psymbols = null;
    }
}

/////////////////////////////////
// Our storage allocator.

static void *trace_malloc(size_t nbytes)
{   void *p;

    p = malloc(nbytes);
    if (!p)
        exit(EXIT_FAILURE);
    return p;
}

static void trace_free(void *p)
{
    free(p);
}

//////////////////////////////////////////////
//

static Symbol* trace_addsym(char[] id)
{
    Symbol** parent;
    Symbol* rover;
    Symbol* s;
    int cmp;
    char c;

    //printf("trace_addsym('%s',%d)\n",p,len);
    parent = &root;
    rover = *parent;
    while (rover !is null)               // while we haven't run out of tree
    {
        cmp = stringCompare (id, rover.Sident);
        if (cmp == 0)
        {
            return rover;
        }
        parent = (cmp < 0) ?            /* if we go down left side      */
            &(rover.Sl) :               /* then get left child          */
            &(rover.Sr);                /* else get right child         */
        rover = *parent;                /* get child                    */
    }
    /* not in table, so insert into table       */
    s = cast(Symbol *)trace_malloc(Symbol.sizeof);
    memset(s,0,Symbol.sizeof);
    s.Sident = id;
    *parent = s;                        // link new symbol into tree
    return s;
}

/***********************************
 * Add symbol s with count to SymPair list.
 */

static void trace_sympair_add(SymPair** psp, Symbol* s, uint count)
{   SymPair* sp;

    for (; 1; psp = &sp.next)
    {
        sp = *psp;
        if (!sp)
        {
            sp = cast(SymPair *)trace_malloc(SymPair.sizeof);
            sp.sym = s;
            sp.count = 0;
            sp.next = null;
            *psp = sp;
            break;
        }
        else if (sp.sym == s)
        {
            break;
        }
    }
    sp.count += count;
}

//////////////////////////////////////////////
//

static void trace_pro(char[] id)
{
    Stack* n;
    Symbol* s;
    timer_t starttime;
    timer_t t;

    QueryPerformanceCounter(&starttime);
    if (id.length == 0)
        return;
    if (!trace_inited)
        trace_init();                   // initialize package
    n = stack_malloc();
    n.prev = trace_tos;
    trace_tos = n;
    s = trace_addsym(id);
    trace_tos.sym = s;
    if (trace_tos.prev)
    {
        Symbol* prev;
        int i;

        // Accumulate Sfanout and Sfanin
        prev = trace_tos.prev.sym;
        trace_sympair_add(&prev.Sfanout,s,1);
        trace_sympair_add(&s.Sfanin,prev,1);
    }
    QueryPerformanceCounter(&t);
    trace_tos.starttime = starttime;
    trace_tos.ohd = trace_ohd + t - starttime;
    trace_tos.subtime = 0;
    //printf("trace_tos.ohd=%lld, trace_ohd=%lld + t=%lld - starttime=%lld\n",
    //  trace_tos.ohd,trace_ohd,t,starttime);
}


void _c_trace_pro(size_t idlen, char* idptr)
{
    char[] id = idptr[0 .. idlen];
    trace_pro(id);
}

/////////////////////////////////////////
//

static void trace_epi()
{   Stack* n;
    timer_t endtime;
    timer_t t;
    timer_t ohd;

    //printf("trace_epi()\n");
    if (trace_tos)
    {
        timer_t starttime;
        timer_t totaltime;

        QueryPerformanceCounter(&endtime);
        starttime = trace_tos.starttime;
        totaltime = endtime - starttime - trace_tos.ohd;
        if (totaltime < 0)
        {   //printf("endtime=%lld - starttime=%lld - trace_tos.ohd=%lld < 0\n",
            //  endtime,starttime,trace_tos.ohd);
            totaltime = 0;              // round off error, just make it 0
        }

        // totaltime is time spent in this function + all time spent in
        // subfunctions - bookkeeping overhead.
        trace_tos.sym.totaltime += totaltime;

        //if (totaltime < trace_tos.subtime)
        //printf("totaltime=%lld < trace_tos.subtime=%lld\n",totaltime,trace_tos.subtime);
        trace_tos.sym.functime  += totaltime - trace_tos.subtime;
        ohd = trace_tos.ohd;
        n = trace_tos.prev;
        stack_free(trace_tos);
        trace_tos = n;
        if (n)
        {   QueryPerformanceCounter(&t);
            n.ohd += ohd + t - endtime;
            n.subtime += totaltime;
            //printf("n.ohd = %lld\n",n.ohd);
        }
    }
}

/////////////////////////////////////
// The compiler expects to find _c_trace_epi() function. On comparing the
// official druntime rt.trace.d code for _c_trace_epi() function it matched the
// trace_epi() function here.
static void _c_trace_epi()
{
    trace_epi();
}


////////////////////////// FILE INTERFACE /////////////////////////

/////////////////////////////////////
// Read line from file fp.
// Returns:
//      trace_malloc'd line buffer
//      null if end of file

static char* trace_readline(FILE* fp)
{   int c;
    int dim;
    int i;
    char *buf;

    //printf("trace_readline(%p)\n", fp);
    i = 0;
    dim = 0;
    buf = null;
    while (1)
    {
        if (i == dim)
        {   char *p;

            dim += 80;
            p = cast(char *)trace_malloc(dim);
            memcpy(p,buf,i);
            trace_free(buf);
            buf = p;
        }
        c = fgetc(fp);
        switch (c)
        {
            case EOF:
                if (i == 0)
                {   trace_free(buf);
                    return null;
                }
            case '\n':
                goto L1;
            default:
                break;
        }
        buf[i] = cast(char)c;
        i++;
    }
L1:
    buf[i] = 0;
    //printf("line '%s'\n",buf);
    return buf;
}

//////////////////////////////////////
// Skip space

static char *skipspace(char *p)
{
    while (isspace(*p))
        p++;
    return p;
}

////////////////////////////////////////////////////////
// Merge in profiling data from existing file.

static void trace_merge()
{   FILE* fp;
    char *buf;
    char *p;
    uint count;
    Symbol *s;
    SymPair *sfanin;
    SymPair **psp;

    if (trace_logfilename && (fp = fopen(trace_logfilename.ptr,"r".ptr)) !is null)
    {
        buf = null;
        sfanin = null;
        psp = &sfanin;
        while (1)
        {
            trace_free(buf);
            buf = trace_readline(fp);
            if (!buf)
                break;
            switch (*buf)
            {
                case '=':               // ignore rest of file
                    trace_free(buf);
                    goto L1;
                case ' ':
                case '\t':              // fan in or fan out line
                    count = cast(uint) strtoul(buf,&p,10);
                    if (p == buf)       // if invalid conversion
                        continue;
                    p = skipspace(p);
                    if (!*p)
                        continue;
                    s = trace_addsym(p[0 .. strlen(p)]);
                    trace_sympair_add(psp,s,count);
                    break;
                default:
                    if (!isalpha(*buf))
                    {
                        if (!sfanin)
                            psp = &sfanin;
                        continue;       // regard unrecognized line as separator
                    }
                case '?':
                case '_':
                case '$':
                case '@':
                    p = buf;
                    while (isgraph(*p))
                        p++;
                    *p = 0;
                    //printf("trace_addsym('%s')\n",buf);
                    s = trace_addsym(buf[0 .. strlen(buf)]);
                    if (s.Sfanin)
                    {   SymPair *sp;

                        for (; sfanin; sfanin = sp)
                        {
                            trace_sympair_add(&s.Sfanin,sfanin.sym,sfanin.count);
                            sp = sfanin.next;
                            trace_free(sfanin);
                        }
                    }
                    else
                    {   s.Sfanin = sfanin;
                    }
                    sfanin = null;
                    psp = &s.Sfanout;

                    {   timer_t t;

                        p++;
                        count = cast(uint) strtoul(p,&p,10);
                        t = cast(long)strtoull(p,&p,10);
                        s.totaltime += t;
                        t = cast(long)strtoull(p,&p,10);
                        s.functime += t;
                    }
                    break;
            }
        }
    L1:
        fclose(fp);
    }
}

////////////////////////// COMPILER INTERFACE /////////////////////

/////////////////////////////////////////////
// Function called by trace code in function prolog.

/////////////////////////////////////////////
// Function called by trace code in function epilog.


void _trace_epi_n()
{
    version (OSX) { // 16 byte align stack
        asm{
            naked   ;
            pushad  ;
            sub ESP,12  ;
        }
        trace_epi();
        asm {
            add ESP,12  ;
            popad   ;
            ret ;
        }
    }
    else {
        version (D_InlineAsm_X86_64)
        {
            asm
            {
                naked   ;
                push RAX ;
                push RBX ;
                push RCX ;
                push RDX ;
                push RSI ;
                push RDI ;
                push RBP ;
                push R8  ;
                push R9  ;
                push R10  ;
                push R11  ;
                push R12  ;
                push R13  ;
                push R14  ;
                push R15  ;
                push RAX ;
            }
        }
        else
        {
            asm
            {
                naked   ;
                pushad  ;
            }
        }

        trace_epi();
        version(D_InlineAsm_X86_64)
        {
            asm
            {
                pop RAX ;   // 16 byte align the stack
                pop R15 ;
                pop R14 ;
                pop R13 ;
                pop R12 ;
                pop R11 ;
                pop R10 ;
                pop R9  ;
                pop R8  ;
                pop RBP ;
                pop RDI ;
                pop RSI ;
                pop RDX ;
                pop RCX ;
                pop RBX ;
                pop RAX ;
                ret     ;
            }
        }
        else
        {
            asm
            {
                popad   ;
                ret     ;
            }
        }
    }
}


version (Win32)
{
    extern (Windows)
    {
        export int QueryPerformanceCounter(timer_t *);
        export int QueryPerformanceFrequency(timer_t *);
    }
}
else version (X86)
{
    extern (D)
    {
        void QueryPerformanceCounter(timer_t* ctr)
        {
            asm
            {   naked                   ;
                mov       ECX,EAX       ;
                rdtsc                   ;
                mov   [ECX],EAX         ;
                mov   4[ECX],EDX        ;
                ret                     ;
            }
        }

        void QueryPerformanceFrequency(timer_t* freq)
        {
            *freq = 3579545;
        }
    }
}
else version (D_InlineAsm_X86_64)
{
    extern (D)
    {
        void QueryPerformanceCounter(timer_t* ctr)
        {
            asm
            {
                naked                   ;
                rdtsc                   ;
                mov   [RDI],EAX         ;
                mov   4[RDI],EDX        ;
                ret                     ;
            }
        }

        void QueryPerformanceFrequency(timer_t* freq)
        {
            *freq = 3579545;
        }
    }
}
else
{
    static assert(0);
}
