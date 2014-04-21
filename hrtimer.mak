BASE=hrtimer
AS=MASM2ALP

.SUFFIXES: .asm

$(BASE).sys: $*.obj $*.def
    link /MAP $*, $*.sys,, os2286, $*
    mapsym $*
