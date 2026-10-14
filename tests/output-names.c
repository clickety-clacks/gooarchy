// Copied unchanged from Scottland's tests/output-names.c (clickety-clacks/scottland commit
// 994b456f3250f19ef03dc2cda27cee8750b2dabf), which Scottland's v0.3.0 tag does not carry.
//
// Test setup only: give virtual (headless) outputs the connector names real hardware has, so stock
// scripts that tell a laptop panel by its name (eDP-*) see one.
//
//   LD_PRELOAD=output-names.so SCOTTLAND_TEST_OUTPUT_NAMES=HEADLESS-1=eDP-1,HEADLESS-2=DP-1 wayfire …
//
// wlroots names each output once, as it creates it (wlr_output_set_name), before the compositor
// sees it; this renames it there. It drops LD_PRELOAD from the environment as it loads, so the
// compositor's own children don't inherit it.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

struct wlr_output;

__attribute__((constructor)) static void forget_preload(void)
{
    unsetenv("LD_PRELOAD");
}

void wlr_output_set_name(struct wlr_output *output, const char *name)
{
    static void (*real)(struct wlr_output*, const char*);
    if (!real)
    {
        real = (void (*)(struct wlr_output*, const char*))dlsym(RTLD_NEXT, "wlr_output_set_name");
    }

    const char *map = getenv("SCOTTLAND_TEST_OUTPUT_NAMES");
    size_t length   = strlen(name);
    while (map && *map)
    {
        const char *end = strchr(map, ',');
        size_t entry    = end ? (size_t)(end - map) : strlen(map);
        if ((entry > length + 1) && (strncmp(map, name, length) == 0) && (map[length] == '='))
        {
            char renamed[64] = {0};
            size_t size = entry - length - 1;
            memcpy(renamed, map + length + 1, size < sizeof(renamed) - 1 ? size : sizeof(renamed) - 1);
            real(output, renamed);
            return;
        }

        map = end ? end + 1 : NULL;
    }

    real(output, name);
}
