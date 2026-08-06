#ifndef SHATRANJ_SPRINTER_COLD_TEXT_H
#define SHATRANJ_SPRINTER_COLD_TEXT_H

/* Copy cold WIN1 text to permanent WIN2 before a far UI call remaps WIN1. */
char *sprinter_cold_text(const char *source) __z88dk_fastcall;

#endif
