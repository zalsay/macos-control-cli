#include "BinderIdentity.h"
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <sys/wait.h>

static const char *scenario, *ancestor, *file;
static int armed = 1, failed;

void bi_test_snapshot_checkpoint(void) {
    if (!armed) return;
    armed = 0;
    char path[PATH_MAX], moved[PATH_MAX];
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
        snprintf(moved, sizeof moved, "%s-moved", ancestor);
        failed = rename(ancestor, moved) || symlink(moved, ancestor);
    } else if (!strcmp(scenario, "file")) {
        FILE *f = fopen(file, "a");
        if (!f) { failed = 1; return; }
        failed = fputs("changed", f) < 0 || fclose(f);
    }
}

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    scenario = argv[1]; ancestor = argv[2]; file = argv[3];
    BIFileSnapshot snapshot;
    BIDiagnostic diag = {0};
    BIError result = bi_snapshot_diagnostic(file, bi_deadline_after_ms(2999), &snapshot, &diag);
    printf("scenario=%s result=%d checkpoint=%d failed=%d\n", scenario, result, !armed, failed);
    if (armed || failed || (!strcmp(scenario, "acl") && !(diag.fields & BI_F_ACL))) return 3;
    return result == (!strcmp(scenario, "sibling") ? BI_OK : BI_CHANGED) ? 0 : 1;
}
