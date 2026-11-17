#include "BundleInventory.h"
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <sys/wait.h>

static const char *scenario, *ancestor, *app;
static int armed = 1, failed;

/* Called only by a test-instrumented copy of BundleInventory.c. */
void bb_test_open_root_checkpoint(void) {
    if (!armed) return;
    armed = 0;
    char path[PATH_MAX], renamed[PATH_MAX];
    if (!strcmp(scenario, "sibling")) {
        snprintf(path, sizeof path, "%s/unrelated", ancestor);
        failed = mkdir(path, 0700);
    } else if (!strcmp(scenario, "permissions")) {
        failed = chmod(ancestor, 0777);
    } else if (!strcmp(scenario, "acl")) {
        pid_t p = fork();
        if (p == 0) { execl("/bin/chmod", "chmod", "+a", "everyone allow list", ancestor, (char *)NULL); _exit(127); }
        int status = 0; failed = p < 0 || waitpid(p, &status, 0) != p || !WIFEXITED(status) || WEXITSTATUS(status);
    } else if (!strcmp(scenario, "replacement")) {
        snprintf(renamed, sizeof renamed, "%s-moved", ancestor);
        failed = rename(ancestor, renamed) || symlink(renamed, ancestor);
    } else if (!strcmp(scenario, "root")) {
        snprintf(path, sizeof path, "%s/new-entry", app);
        failed = mkdir(path, 0700);
    }
}

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    scenario = argv[1]; ancestor = argv[2]; app = argv[3];
    BBInventory *v = NULL;
    BBError result = bb_inventory(app, bi_deadline_after_ms(2999), &v);
    bb_free(v);
    printf("scenario=%s result=%d checkpoint=%d failed=%d\n", scenario, result, !armed, failed);
    if (armed || failed) return 3;
    return result == (!strcmp(scenario, "sibling") ? BB_OK : BB_CHANGED) ? 0 : 1;
}
