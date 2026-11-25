#include "SafarierControlSupport.h"
#include <assert.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
int main(void) {
    pid_t child = fork(); assert(child >= 0);
    if (!child) { for (;;) pause(); }
    unsigned version = cs_exit_pidversion(child); assert(version != 0);
    assert(!cs_exit_signal(child,version+1,SIGTERM));
    assert(!cs_exit_signal(getpid(),cs_exit_pidversion(getpid()),SIGTERM));
    assert(cs_exit_signal(child,version,SIGTERM));
    int status; assert(waitpid(child,&status,0)==child && WIFSIGNALED(status));
    assert(!cs_exit_signal(child,version,SIGKILL));
    int ready[2]; assert(pipe(ready)==0);
    child = fork(); assert(child >= 0);
    if (!child) { signal(SIGTERM,SIG_IGN); close(ready[0]); assert(write(ready[1],"1",1)==1); for (;;) pause(); }
    close(ready[1]); char byte; assert(read(ready[0],&byte,1)==1); close(ready[0]);
    version = cs_exit_pidversion(child); assert(cs_exit_signal(child,version,SIGTERM));
    assert(waitpid(child,&status,WNOHANG)==0);
    assert(cs_exit_signal(child,version,SIGKILL)); assert(waitpid(child,&status,0)==child && WTERMSIG(status)==SIGKILL);
}
