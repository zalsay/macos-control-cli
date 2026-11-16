#include "BundleInventory.h"
#include <stdio.h>
#include <limits.h>

int main(int argc, char **argv) {
    if (argc != 2) return 10;
    BBInventory *pin = NULL;
    BBError result = bb_inventory(argv[1], bi_deadline_after_ms(2999), &pin);
    if (result != BB_OK) return 11;
    result = bb_revalidate(pin, "sh.safarier.tracefixture", "fixture", bi_deadline_after_ms(2999));
    printf("valid=%d\n", result);
    if (result != BB_OK) { bb_free(pin); return 12; }
    result = bb_revalidate(pin, "sh.safarier.wrong", "fixture", bi_deadline_after_ms(2999));
    printf("wrong_identifier=%d\n", result);
    if (result != BB_INVALID) { bb_free(pin); return 13; }
    result = bb_revalidate(pin, "sh.safarier.tracefixture", "fixture", 0);
    printf("expired=%d\n", result);
    if (result != BB_EXPIRED) { bb_free(pin); return 14; }
    char path[PATH_MAX];
    if (snprintf(path, sizeof path, "%s/Contents/Info.plist", argv[1]) >= sizeof path) return 15;
    FILE *file = fopen(path, "a");
    if (!file) return 16;
    fputs("\n", file);
    if (fclose(file)) return 17;
    result = bb_revalidate(pin, "sh.safarier.tracefixture", "fixture", bi_deadline_after_ms(2999));
    printf("mutated=%d\n", result);
    bb_free(pin);
    return result == BB_CHANGED ? 0 : 18;
}
