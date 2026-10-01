#ifndef TONER_UI_H
#define TONER_UI_H

#ifdef _WIN32
#include <windows.h>
#endif

/* Source and redirected output are UTF-8. On an attached Windows console,
 * request UTF-8 decoding for narrow C runtime output. */
static void toner_ui_init(void)
{
#ifdef _WIN32
    (void)SetConsoleOutputCP(CP_UTF8);
#endif
}

#endif
