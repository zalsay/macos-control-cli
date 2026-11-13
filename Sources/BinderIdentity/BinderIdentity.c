#include "BinderIdentity.h"
#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <stdbool.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <limits.h>
#define MAX_PARTS 128
#define MAX_SIZE (64ULL * 1024 * 1024)
static uint64_t now_ns(void) { struct timespec t; if (clock_gettime(CLOCK_MONOTONIC, &t)) return 0; return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec; }
uint64_t bi_deadline_after_ms(uint32_t ms) { uint64_t n = now_ns(); return n && ms && ms <= 5000 ? n + (uint64_t)ms * 1000000ULL : 0; }
static bool valid_deadline(uint64_t d) { uint64_t n = now_ns(); return n && d > n && d - n <= 5000000000ULL; }
static bool same(const struct stat *a, const struct stat *b) { return a->st_dev==b->st_dev && a->st_ino==b->st_ino && a->st_mode==b->st_mode && a->st_uid==b->st_uid && a->st_gid==b->st_gid && a->st_nlink==b->st_nlink && a->st_size==b->st_size && a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec && a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec; }
static void diag_reset(BIDiagnostic *d) { if(d) { d->stage=BI_STAGE_NONE; d->fields=0; d->depth=0; } }
static void diag_set(BIDiagnostic *d, BIStage stage, uint64_t fields, uint32_t depth) { if(d && d->stage==BI_STAGE_NONE) { d->stage=stage; d->fields=fields; d->depth=depth; } }
static uint64_t stat_fields(const struct stat *a,const struct stat *b) {
 uint64_t m=0;
 if(a->st_dev!=b->st_dev)m|=BI_F_DEV; if(a->st_ino!=b->st_ino)m|=BI_F_INO;
 if(a->st_mode!=b->st_mode)m|=BI_F_MODE; if(a->st_uid!=b->st_uid)m|=BI_F_UID;
 if(a->st_gid!=b->st_gid)m|=BI_F_GID; if(a->st_nlink!=b->st_nlink)m|=BI_F_NLINK;
 if(a->st_size!=b->st_size)m|=BI_F_SIZE;
 if(a->st_mtimespec.tv_sec!=b->st_mtimespec.tv_sec || a->st_mtimespec.tv_nsec!=b->st_mtimespec.tv_nsec)m|=BI_F_MTIME;
 if(a->st_ctimespec.tv_sec!=b->st_ctimespec.tv_sec || a->st_ctimespec.tv_nsec!=b->st_ctimespec.tv_nsec)m|=BI_F_CTIME;
 return m;
}
typedef BIError (*snapshot_callback)(const char *, uint64_t, void *);
static BIError snapshot_impl(const char *path, uint64_t deadline, BIFileSnapshot *out, snapshot_callback callback, void *context, BIDiagnostic *diag, uint64_t size_limit) {
    int fds[MAX_PARTS]; struct stat before[MAX_PARTS], after; char copy[PATH_MAX]; char *parts[MAX_PARTS]; unsigned count=0, opened=0; BIError err=BI_INVALID; BIFileSnapshot result={0};
    if (!out || !path || path[0]!='/' || !size_limit || size_limit>MAX_SIZE) return BI_INVALID;
    if (!valid_deadline(deadline)) return BI_EXPIRED;
    size_t len=strnlen(path,sizeof copy); if (len<2 || len>=sizeof copy || path[len-1]=='/') return BI_INVALID;
    memcpy(copy,path,len+1); char *p=copy+1;
    while (*p) { if (count>=MAX_PARTS-1 || *p=='/') return BI_INVALID; parts[count++]=p; char *slash=strchr(p,'/'); if (!slash) break; *slash=0; p=slash+1; if (!*p) return BI_INVALID; }
    for (unsigned i=0;i<count;i++) if (!strcmp(parts[i],".") || !strcmp(parts[i],"..")) return BI_INVALID;
    fds[0]=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC); if (fds[0]<0) return valid_deadline(deadline)?BI_IO:BI_EXPIRED; opened=1;
    if (!valid_deadline(deadline)) {err=BI_EXPIRED;goto done;}
    int statrc=fstat(fds[0],&before[0]); if (!valid_deadline(deadline)) {err=BI_EXPIRED;goto done;} if (statrc) {err=BI_IO;goto done;}
    for (unsigned i=0;i<count;i++) {
        if (!valid_deadline(deadline)) {err=BI_EXPIRED; goto done;}
        if (!S_ISDIR(before[i].st_mode) || (before[i].st_uid!=0 && before[i].st_uid!=geteuid()) || (before[i].st_mode & 0022)) goto done;
        int flags=O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK; if (i+1<count) flags|=O_DIRECTORY;
        int fd=openat(fds[i],parts[i],flags); if(fd>=0) fds[opened++]=fd;
        if(!valid_deadline(deadline)){err=BI_EXPIRED;goto done;} if(fd<0){err=BI_IO;goto done;}
        statrc=fstat(fd,&before[i+1]); if(!valid_deadline(deadline)){err=BI_EXPIRED;goto done;} if(statrc){err=BI_IO;goto done;}
    }
    struct stat *file=&before[count]; if (!S_ISREG(file->st_mode) || file->st_nlink!=1 || file->st_uid!=geteuid() || (file->st_mode&0022) || file->st_size<0 || (uint64_t)file->st_size>size_limit) goto done;
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx); uint8_t buf[16384]; uint64_t n=0; ssize_t r;
    for (;;) { if (!valid_deadline(deadline)){err=BI_EXPIRED;goto done;} if(size_limit<MAX_SIZE && n==size_limit){r=0;break;} size_t request=size_limit<MAX_SIZE && (size_limit-n)<sizeof buf ? (size_t)(size_limit-n) : sizeof buf; r=read(fds[count],buf,request); if (!valid_deadline(deadline)){err=BI_EXPIRED;goto done;} if(r<=0)break; n+=(uint64_t)r; if(n>size_limit){if(diag)diag_set(diag,BI_STAGE_READ_LIMIT,BI_F_SIZE,BI_DEPTH_NA);err=BI_CHANGED;goto done;} CC_SHA256_Update(&ctx,buf,(CC_LONG)r); }
    if(r<0){err=BI_IO;goto done;} if(n!=(uint64_t)file->st_size){if(diag)diag_set(diag,BI_STAGE_READ_SIZE,BI_F_SIZE,BI_DEPTH_NA);err=BI_CHANGED;goto done;} result.size=n; result.dev=(uint64_t)file->st_dev; result.ino=(uint64_t)file->st_ino; result.nlink=(uint64_t)file->st_nlink; result.uid=file->st_uid; result.gid=file->st_gid; result.mode=file->st_mode; result.mtime_sec=file->st_mtimespec.tv_sec; result.mtime_nsec=file->st_mtimespec.tv_nsec; result.ctime_sec=file->st_ctimespec.tv_sec; result.ctime_nsec=file->st_ctimespec.tv_nsec; CC_SHA256_Final(result.sha256,&ctx);
    if (callback) { err=callback(path,deadline,context); if(err!=BI_OK) goto done; }
    for (unsigned i=0;i<=count;i++) {
        if(!valid_deadline(deadline)){err=BI_EXPIRED;goto done;}
        statrc=fstat(fds[i],&after); if(!valid_deadline(deadline)){err=BI_EXPIRED;goto done;} if(statrc || !same(&before[i],&after)){if(diag)diag_set(diag,BI_STAGE_FSTAT,statrc?BI_F_UNAVAILABLE:stat_fields(&before[i],&after),i);err=BI_CHANGED;goto done;}
        if(i) { statrc=fstatat(fds[i-1],parts[i-1],&after,AT_SYMLINK_NOFOLLOW); if(!valid_deadline(deadline)){err=BI_EXPIRED;goto done;} if(statrc || !same(&before[i],&after)){if(diag)diag_set(diag,BI_STAGE_FSTATAT,statrc?BI_F_UNAVAILABLE:stat_fields(&before[i],&after),i);err=BI_CHANGED;goto done;} }
    }
    /* Reopen the full ancestor chain from the root; held directory descriptors alone are insufficient. */
    for(unsigned i=0;i<count;i++){
        if(!valid_deadline(deadline)){err=BI_EXPIRED;goto done;}
        int x=openat(fds[i],parts[i],O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK|(i+1<count?O_DIRECTORY:0));
        if(!valid_deadline(deadline)){if(x>=0)close(x);err=BI_EXPIRED;goto done;} if(x<0){if(diag)diag_set(diag,BI_STAGE_REOPEN,BI_F_UNAVAILABLE,i+1);err=BI_CHANGED;goto done;}
        statrc=fstat(x,&after); bool timely=valid_deadline(deadline); close(x);
        if(!timely){err=BI_EXPIRED;goto done;} if(statrc || !same(&before[i+1],&after)){if(diag)diag_set(diag,BI_STAGE_REOPEN_FSTAT,statrc?BI_F_UNAVAILABLE:stat_fields(&before[i+1],&after),i+1);err=BI_CHANGED;goto done;}
    }
    if(!valid_deadline(deadline)){err=BI_EXPIRED;goto done;} *out=result; err=BI_OK;
done: while(opened) close(fds[--opened]); return err;
}

BIError bi_snapshot(const char *path, uint64_t deadline, BIFileSnapshot *out) { return snapshot_impl(path,deadline,out,NULL,NULL,NULL,MAX_SIZE); }
BIError bi_snapshot_diagnostic(const char *path,uint64_t deadline,BIFileSnapshot *out,BIDiagnostic *d) { diag_reset(d); return snapshot_impl(path,deadline,out,NULL,NULL,d,MAX_SIZE); }

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
static BIError static_code(const char *path, uint64_t deadline, void *context) {
    BIImagePin *pin=context; BIError result=BI_IO; SecStaticCodeRef code=NULL; CFDictionaryRef info=NULL;
    CFStringRef string=NULL; CFURLRef url=NULL;
    if (!valid_deadline(deadline)) return BI_EXPIRED;
    string=CFStringCreateWithFileSystemRepresentation(NULL,path); if(!string) goto done;
    if (!valid_deadline(deadline)) {result=BI_EXPIRED;goto done;}
    url=CFURLCreateWithFileSystemPath(NULL,string,kCFURLPOSIXPathStyle,false); if(!url) goto done;
    if (!valid_deadline(deadline)) {result=BI_EXPIRED;goto done;}
    OSStatus status=SecStaticCodeCreateWithPath(url,kSecCSDefaultFlags,&code);
    if (!valid_deadline(deadline)) {result=BI_EXPIRED;goto done;}
    if(status!=errSecSuccess || !code) goto done;
    status=SecStaticCodeCheckValidity(code,kSecCSDefaultFlags,NULL);
    if (!valid_deadline(deadline)) {result=BI_EXPIRED;goto done;}
    if(status!=errSecSuccess) goto done;
    status=SecCodeCopySigningInformation(code,kSecCSSigningInformation,&info);
    if (!valid_deadline(deadline)) {result=BI_EXPIRED;goto done;}
    if(status!=errSecSuccess || !info) goto done;
    CFTypeRef v=CFDictionaryGetValue(info,kSecCodeInfoUnique);
    if(!v || CFGetTypeID(v)!=CFDataGetTypeID()) goto done;
    CFIndex length=CFDataGetLength((CFDataRef)v); if(length<1 || length>64) goto done;
    CFDataGetBytes((CFDataRef)v,CFRangeMake(0,length),pin->code_hash); pin->code_hash_len=(uint32_t)length;
    if (!valid_deadline(deadline)) {result=BI_EXPIRED;goto done;}
    result=BI_OK;
done:
    if(info)CFRelease(info); if(code)CFRelease(code); if(url)CFRelease(url); if(string)CFRelease(string); return result;
}
static BIError static_pin_impl(const char *path, uint64_t deadline, BIImagePin *out,BIDiagnostic *diag) {
    if (!path || !out || strnlen(path,sizeof out->path)>=sizeof out->path) return BI_INVALID;
    BIImagePin pin={0}; BIError e=snapshot_impl(path,deadline,&pin.file,static_code,&pin,diag,MAX_SIZE);
    if(e!=BI_OK)return e;
    memcpy(pin.path,path,strlen(path)+1); *out=pin; return BI_OK;
}

BIError bi_static_pin(const char *p,uint64_t t,BIImagePin *o) { return static_pin_impl(p,t,o,NULL); }
BIError bi_static_pin_diagnostic(const char *p,uint64_t t,BIImagePin *o,BIDiagnostic *d) { diag_reset(d); return static_pin_impl(p,t,o,d); }
#include <libproc.h>
#include <sys/proc_info.h>
/* owned_pid is a historical parameter name: caller must enforce the approved
 * self/actual-parent/original-retained-child observation scope described in the
 * header. Metadata observation itself never confers ownership or cleanup rights. */
static BIError process_impl(int32_t owned_pid, uint64_t deadline, BIProcess *out,BIDiagnostic *diag) {
    if (!out || owned_pid <= 0) return BI_INVALID;
    if (!valid_deadline(deadline)) return BI_EXPIRED;
    struct proc_bsdinfo a = {0}, b = {0}; BIProcess p = {0};
    if (proc_pidinfo(owned_pid, PROC_PIDTBSDINFO, 0, &a, sizeof a) != sizeof a) return BI_IO;
    if (!valid_deadline(deadline)) return BI_EXPIRED;
    if (a.pbi_pid != (uint32_t)owned_pid || (a.pbi_status != 2 && a.pbi_status != 3) || (a.pbi_flags & (2U | 4U | 0x2000U)) || a.pbi_start_tvusec >= 1000000) return BI_INVALID;
    int n = proc_pidpath(owned_pid, p.path, sizeof p.path);
    if (!valid_deadline(deadline)) return BI_EXPIRED;
    if (n <= 0 || (size_t)n >= sizeof p.path || p.path[0] != '/' || !memchr(p.path, '\0', sizeof p.path)) return BI_IO;
    if (proc_pidinfo(owned_pid, PROC_PIDTBSDINFO, 0, &b, sizeof b) != sizeof b) return BI_IO;
    if (!valid_deadline(deadline)) return BI_EXPIRED;
    if (a.pbi_pid != b.pbi_pid || a.pbi_ppid != b.pbi_ppid || a.pbi_ruid != b.pbi_ruid || a.pbi_uid != b.pbi_uid || a.pbi_start_tvsec != b.pbi_start_tvsec || a.pbi_start_tvusec != b.pbi_start_tvusec || (b.pbi_status != 2 && b.pbi_status != 3) || (b.pbi_flags & (2U | 4U | 0x2000U))) { if(diag) { uint64_t m=0;
 if(a.pbi_pid!=b.pbi_pid)m|=BI_F_PID; if(a.pbi_ppid!=b.pbi_ppid)m|=BI_F_PPID;
 if(a.pbi_ruid!=b.pbi_ruid)m|=BI_F_RUID; if(a.pbi_uid!=b.pbi_uid)m|=BI_F_EUID;
 if(a.pbi_start_tvsec!=b.pbi_start_tvsec || a.pbi_start_tvusec!=b.pbi_start_tvusec)m|=BI_F_BIRTH;
 if(b.pbi_status!=2 && b.pbi_status!=3)m|=BI_F_STATUS;
 if(b.pbi_flags & (2U|4U|0x2000U))m|=BI_F_FLAGS;
 diag_set(diag,BI_STAGE_PROCESS,m,BI_DEPTH_NA); } return BI_CHANGED; }
    p.pid=(int32_t)b.pbi_pid; p.ppid=(int32_t)b.pbi_ppid; p.ruid=b.pbi_ruid; p.euid=b.pbi_uid;
    p.status=b.pbi_status; p.flags=b.pbi_flags; p.birth_sec=b.pbi_start_tvsec; p.birth_usec=b.pbi_start_tvusec;
    *out=p; return BI_OK;
}

BIError bi_process_metadata(int32_t p,uint64_t t,BIProcess *o) { return process_impl(p,t,o,NULL); }
BIError bi_process_metadata_diagnostic(int32_t p,uint64_t t,BIProcess *o,BIDiagnostic *d) { diag_reset(d); return process_impl(p,t,o,d); }
#include <bsm/libbsm.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <poll.h>
#include <stddef.h>
static void wipe(void *p,size_t n) { volatile unsigned char *b=p; while(n--) *b++=0; }
static bool proc_equal(const BIProcess *a,const BIProcess *b) {
 return a->pid==b->pid && a->ppid==b->ppid && a->ruid==b->ruid && a->euid==b->euid && a->birth_sec==b->birth_sec && a->birth_usec==b->birth_usec && !strcmp(a->path,b->path);
}
static bool file_equal(const BIFileSnapshot *a,const BIFileSnapshot *b) {
 return a->size==b->size && a->dev==b->dev && a->ino==b->ino && a->nlink==b->nlink && a->uid==b->uid && a->gid==b->gid && a->mode==b->mode && a->mtime_sec==b->mtime_sec && a->mtime_nsec==b->mtime_nsec && a->ctime_sec==b->ctime_sec && a->ctime_nsec==b->ctime_nsec && !memcmp(a->sha256,b->sha256,32);
}
static bool pin_equal(const BIImagePin *a,const BIImagePin *b) {
 return a->code_hash_len>0 && a->code_hash_len<=64 && a->code_hash_len==b->code_hash_len && !memcmp(a->code_hash,b->code_hash,a->code_hash_len) && !strncmp(a->path,b->path,sizeof a->path) && file_equal(&a->file,&b->file);
}
static uint64_t proc_fields(const BIProcess *a,const BIProcess *b) {
 uint64_t m=0; if(a->pid!=b->pid)m|=BI_F_PID; if(a->ppid!=b->ppid)m|=BI_F_PPID;
 if(a->ruid!=b->ruid)m|=BI_F_RUID; if(a->euid!=b->euid)m|=BI_F_EUID;
 if(a->birth_sec!=b->birth_sec || a->birth_usec!=b->birth_usec)m|=BI_F_BIRTH;
 if(strcmp(a->path,b->path))m|=BI_F_PATH; return m;
}
static uint64_t file_fields(const BIFileSnapshot *a,const BIFileSnapshot *b) {
 uint64_t m=0; if(a->size!=b->size)m|=BI_F_SIZE; if(a->dev!=b->dev)m|=BI_F_DEV;
 if(a->ino!=b->ino)m|=BI_F_INO; if(a->nlink!=b->nlink)m|=BI_F_NLINK;
 if(a->uid!=b->uid)m|=BI_F_UID; if(a->gid!=b->gid)m|=BI_F_GID; if(a->mode!=b->mode)m|=BI_F_MODE;
 if(a->mtime_sec!=b->mtime_sec || a->mtime_nsec!=b->mtime_nsec)m|=BI_F_MTIME;
 if(a->ctime_sec!=b->ctime_sec || a->ctime_nsec!=b->ctime_nsec)m|=BI_F_CTIME;
 if(memcmp(a->sha256,b->sha256,32))m|=BI_F_CONTENT; return m;
}
static uint64_t pin_fields(const BIImagePin *a,const BIImagePin *b) {
 if(!a->code_hash_len || a->code_hash_len>64 || a->code_hash_len!=b->code_hash_len)return BI_F_HASH_LENGTH;
 if(memcmp(a->code_hash,b->code_hash,a->code_hash_len))return BI_F_HASH;
 if(strncmp(a->path,b->path,sizeof a->path))return BI_F_PATH;
 return file_fields(&a->file,&b->file);
}
int bi_match(const BIImagePin *pin,const BIProcess *expected,const BIEvidence *e) {
 if(!pin || !expected || !e || !memchr(pin->path,0,sizeof pin->path) || !memchr(expected->path,0,sizeof expected->path) || !memchr(e->process.path,0,sizeof e->process.path) || expected->pid<=0 || expected->birth_usec>=1000000 || (e->process.status!=2 && e->process.status!=3) || (e->process.flags & (2U|4U|0x2000U)) || pin->code_hash_len==0 || pin->code_hash_len>64 || pin->code_hash_len!=e->code_hash_len) return 0;
 return proc_equal(expected,&e->process) && !strcmp(pin->path,e->process.path) && file_equal(&pin->file,&e->file) && !memcmp(pin->code_hash,e->code_hash,pin->code_hash_len);
}
static BIError dynamic_code(const audit_token_t *token, bool self, uint64_t deadline, BIEvidence *out) {
 BIError e=BI_IO; SecCodeRef code=NULL; CFDictionaryRef info=NULL, attrs=NULL; CFDataRef data=NULL;
 if(!valid_deadline(deadline)) return BI_EXPIRED;
 OSStatus status;
 if(self) status=SecCodeCopySelf(kSecCSDefaultFlags,&code);
 else {
  data=CFDataCreate(NULL,(const UInt8 *)token,sizeof *token); if(!data)goto done;
  const void *keys[]={kSecGuestAttributeAudit}; const void *values[]={data};
  attrs=CFDictionaryCreate(NULL,keys,values,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks); if(!attrs)goto done;
  if(!valid_deadline(deadline)){e=BI_EXPIRED;goto done;}
  status=SecCodeCopyGuestWithAttributes(NULL,attrs,kSecCSDefaultFlags,&code);
 }
 if(!valid_deadline(deadline)){e=BI_EXPIRED;goto done;} if(status!=errSecSuccess || !code)goto done;
 status=SecCodeCheckValidity(code,kSecCSDefaultFlags,NULL);
 if(!valid_deadline(deadline)){e=BI_EXPIRED;goto done;} if(status!=errSecSuccess)goto done;
 status=SecCodeCopySigningInformation(code,kSecCSSigningInformation|kSecCSDynamicInformation,&info);
 if(!valid_deadline(deadline)){e=BI_EXPIRED;goto done;} if(status!=errSecSuccess || !info)goto done;
 CFTypeRef v=CFDictionaryGetValue(info,kSecCodeInfoUnique); if(!v||CFGetTypeID(v)!=CFDataGetTypeID())goto done;
 CFIndex n=CFDataGetLength((CFDataRef)v); if(n<1||n>64)goto done;
 CFDataGetBytes((CFDataRef)v,CFRangeMake(0,n),out->code_hash); out->code_hash_len=(uint32_t)n;
 e=valid_deadline(deadline)?BI_OK:BI_EXPIRED;
done:
 if(info)CFRelease(info); if(code)CFRelease(code); if(attrs)CFRelease(attrs); if(data)CFRelease(data); return e;
}
static BIError peer_sample(int fd,uint64_t deadline,pid_t *pid,audit_token_t *token,BIDiagnostic *diag) {
 if(fd<0){diag_set(diag,BI_STAGE_PEER_FD,BI_F_UNAVAILABLE,BI_DEPTH_NA);return BI_INVALID;} if(!valid_deadline(deadline))return BI_EXPIRED;
 int type=0; socklen_t n=sizeof type;
 if(getsockopt(fd,SOL_SOCKET,SO_TYPE,&type,&n) || n!=sizeof type || type!=SOCK_STREAM){diag_set(diag,BI_STAGE_PEER_SOCKET_TYPE,BI_F_UNAVAILABLE,BI_DEPTH_NA);return BI_INVALID;}
 if(!valid_deadline(deadline))return BI_EXPIRED;
 struct sockaddr_un a={0}; n=sizeof a;
 if(getsockname(fd,(struct sockaddr *)&a,&n) || a.sun_family!=AF_UNIX || n>sizeof a) {diag_set(diag,BI_STAGE_PEER_LOCAL_ADDRESS,BI_F_UNAVAILABLE,BI_DEPTH_NA);return BI_INVALID;}
 for(size_t i=offsetof(struct sockaddr_un,sun_path);i<n;i++) if(((unsigned char *)&a)[i]!=0){diag_set(diag,BI_STAGE_PEER_LOCAL_NAME,BI_F_PATH,BI_DEPTH_NA);return BI_INVALID;}
 if(!valid_deadline(deadline))return BI_EXPIRED;
 memset(&a,0,sizeof a); n=sizeof a;
 if(getpeername(fd,(struct sockaddr *)&a,&n) || a.sun_family!=AF_UNIX || n>sizeof a) {diag_set(diag,BI_STAGE_PEER_REMOTE_ADDRESS,BI_F_UNAVAILABLE,BI_DEPTH_NA);return BI_INVALID;}
 for(size_t i=offsetof(struct sockaddr_un,sun_path);i<n;i++) if(((unsigned char *)&a)[i]!=0){diag_set(diag,BI_STAGE_PEER_REMOTE_NAME,BI_F_PATH,BI_DEPTH_NA);return BI_INVALID;}
 if(!valid_deadline(deadline))return BI_EXPIRED;
 struct pollfd pollfd={fd,0,0}; if(poll(&pollfd,1,0)<0 || (pollfd.revents&(POLLHUP|POLLERR|POLLNVAL))){diag_set(diag,BI_STAGE_PEER_POLL,BI_F_UNAVAILABLE,BI_DEPTH_NA);return BI_INVALID;}
 if(!valid_deadline(deadline))return BI_EXPIRED;
 n=sizeof *pid; if(getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,pid,&n) || n!=sizeof *pid || *pid<=0){diag_set(diag,BI_STAGE_PEER_PID,BI_F_PID,BI_DEPTH_NA);return BI_INVALID;}
 if(!valid_deadline(deadline))return BI_EXPIRED;
 n=sizeof *token; if(getsockopt(fd,SOL_LOCAL,LOCAL_PEERTOKEN,token,&n) || n!=sizeof *token){diag_set(diag,BI_STAGE_PEER_TOKEN,BI_F_TOKEN,BI_DEPTH_NA);return BI_INVALID;}
 return valid_deadline(deadline)?BI_OK:BI_EXPIRED;
}
static BIError capture_peer_impl(int fd,const BIProcess *expected,const BIImagePin *pin,uint64_t deadline,BIEvidence *out,BIDiagnostic *diag) {
 if(!expected||!pin||!out||expected->pid<=0||expected->euid!=(uint32_t)geteuid()||!memchr(expected->path,0,sizeof expected->path)||!memchr(pin->path,0,sizeof pin->path)){diag_set(diag,BI_STAGE_PEER_INPUT,BI_F_UNAVAILABLE,BI_DEPTH_NA);return BI_INVALID;}
 audit_token_t a={0},b={0}; pid_t ap=0,bp=0; BIProcess p={0},q={0}; BIImagePin actual={0}; BIEvidence first={0},second={0}; BIError e;
 if((e=peer_sample(fd,deadline,&ap,&a,diag))!=BI_OK)goto done;
 if(ap!=expected->pid || audit_token_to_pid(a)!=ap || (uint32_t)audit_token_to_euid(a)!=expected->euid || (uint32_t)audit_token_to_ruid(a)!=expected->ruid) {diag_set(diag,BI_STAGE_PEER_CREDENTIALS,BI_F_TOKEN,BI_DEPTH_NA);e=BI_INVALID;goto done;}
 if((e=process_impl(ap,deadline,&p,diag))!=BI_OK){if(e==BI_INVALID)diag_set(diag,BI_STAGE_PEER_PROCESS_CAPTURE,BI_F_UNAVAILABLE,BI_DEPTH_NA);goto done;}
 if(!proc_equal(expected,&p)||strcmp(pin->path,p.path)){diag_set(diag,BI_STAGE_PEER_PROCESS_IDENTITY,BI_F_UNAVAILABLE,BI_DEPTH_NA);e=BI_INVALID;goto done;}
 if((e=dynamic_code(&a,false,deadline,&first))!=BI_OK)goto done;
 if((e=static_pin_impl(pin->path,deadline,&actual,diag))!=BI_OK)goto done;
 if(!pin_equal(pin,&actual)){if(diag)diag_set(diag,BI_STAGE_PIN,pin_fields(pin,&actual),BI_DEPTH_NA);e=BI_CHANGED;goto done;}
 if((e=dynamic_code(&a,false,deadline,&second))!=BI_OK)goto done;
 if((e=process_impl(ap,deadline,&q,diag))!=BI_OK){if(e==BI_INVALID)diag_set(diag,BI_STAGE_PEER_PROCESS_CAPTURE,BI_F_UNAVAILABLE,BI_DEPTH_NA);goto done;}
 if((e=peer_sample(fd,deadline,&bp,&b,diag))!=BI_OK)goto done;
 if(ap!=bp || memcmp(&a,&b,sizeof a) || !proc_equal(&p,&q) || first.code_hash_len!=second.code_hash_len || memcmp(first.code_hash,second.code_hash,first.code_hash_len)){ if(diag) { uint64_t m;
 if(ap!=bp)m=BI_F_PID; else if(memcmp(&a,&b,sizeof a))m=BI_F_TOKEN; else if(!proc_equal(&p,&q))m=proc_fields(&p,&q); else if(first.code_hash_len!=second.code_hash_len || !first.code_hash_len || first.code_hash_len>64)m=BI_F_HASH_LENGTH; else m=BI_F_HASH;
 diag_set(diag,BI_STAGE_PEER,m,BI_DEPTH_NA); } e=BI_CHANGED;goto done;}
 first.process=q; first.file=actual.file; first.pidversion=(uint32_t)audit_token_to_pidversion(a); if(!bi_match(pin,expected,&first)){diag_set(diag,BI_STAGE_PEER_MATCH,BI_F_UNAVAILABLE,BI_DEPTH_NA);e=BI_INVALID;goto done;}
 if(!valid_deadline(deadline)){e=BI_EXPIRED;goto done;} *out=first; e=BI_OK;
done: wipe(&a,sizeof a); wipe(&b,sizeof b); return e;
}
static BIError capture_self_impl(const BIImagePin *pin,uint64_t deadline,BIEvidence *out,BIDiagnostic *diag) {
 if(!pin||!out||!memchr(pin->path,0,sizeof pin->path))return BI_INVALID;
 BIProcess p={0},q={0}; BIImagePin actual={0}; BIEvidence a={0},b={0}; BIError e;
 if((e=process_impl(getpid(),deadline,&p,diag))!=BI_OK)return e;
 if(strcmp(pin->path,p.path))return BI_INVALID;
 if((e=dynamic_code(NULL,true,deadline,&a))!=BI_OK)return e;
 if((e=static_pin_impl(pin->path,deadline,&actual,diag))!=BI_OK)return e;
 if(!pin_equal(pin,&actual)){if(diag)diag_set(diag,BI_STAGE_PIN,pin_fields(pin,&actual),BI_DEPTH_NA);return BI_CHANGED;}
 if((e=dynamic_code(NULL,true,deadline,&b))!=BI_OK)return e;
 if((e=process_impl(getpid(),deadline,&q,diag))!=BI_OK)return e;
 if(!proc_equal(&p,&q)||a.code_hash_len!=b.code_hash_len||memcmp(a.code_hash,b.code_hash,a.code_hash_len)) { if(diag) { uint64_t m=!proc_equal(&p,&q)?proc_fields(&p,&q):(a.code_hash_len!=b.code_hash_len || !a.code_hash_len || a.code_hash_len>64?BI_F_HASH_LENGTH:BI_F_HASH); diag_set(diag,BI_STAGE_SELF,m,BI_DEPTH_NA); } return BI_CHANGED; }
 a.process=q; a.file=actual.file; if(!bi_match(pin,&q,&a))return BI_INVALID; if(!valid_deadline(deadline))return BI_EXPIRED; *out=a; return BI_OK;
}
BIError bi_capture_peer(int fd,const BIProcess *p,const BIImagePin *i,uint64_t t,BIEvidence *o) { return capture_peer_impl(fd,p,i,t,o,NULL); }
BIError bi_capture_peer_diagnostic(int fd,const BIProcess *p,const BIImagePin *i,uint64_t t,BIEvidence *o,BIDiagnostic *d) { diag_reset(d); return capture_peer_impl(fd,p,i,t,o,d); }
BIError bi_capture_self(const BIImagePin *p,uint64_t t,BIEvidence *o) { return capture_self_impl(p,t,o,NULL); }
BIError bi_capture_self_diagnostic(const BIImagePin *p,uint64_t t,BIEvidence *o,BIDiagnostic *d) { diag_reset(d); return capture_self_impl(p,t,o,d); }
/* Compare repeated captured observations, including kernel audit pidversion. */
int bi_evidence_same(const BIEvidence *a,const BIEvidence *b) {
 if(!a||!b || !memchr(a->process.path,0,sizeof a->process.path) || !memchr(b->process.path,0,sizeof b->process.path) || !a->code_hash_len || a->code_hash_len>64 || a->code_hash_len!=b->code_hash_len) return 0;
 return a->pidversion==b->pidversion && proc_equal(&a->process,&b->process) && file_equal(&a->file,&b->file) && !memcmp(a->code_hash,b->code_hash,a->code_hash_len);
}

int bi_fixture_file_equal(const BIFileSnapshot *a, const BIFileSnapshot *b) { return a && b && file_equal(a,b); }
BIError bi_snapshot_limited(const char *path, uint64_t deadline, uint64_t limit, BIFileSnapshot *out) { return snapshot_impl(path,deadline,out,NULL,NULL,NULL,limit); }
int bi_fixture_deadline_valid(uint64_t deadline) { return valid_deadline(deadline); }
