#include "BundleInventory.h"
#include <CommonCrypto/CommonDigest.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <sys/acl.h>
#include <dirent.h>
#include <fcntl.h>
#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <stdio.h>
#define BB_MAX_ENTRIES 256
#define BB_MAX_DEPTH 16
#define BB_FILE_MAX (64ULL*1024*1024)
#define BB_TOTAL_MAX (128ULL*1024*1024)
#define BB_METADATA_MAX (4ULL*1024*1024)
typedef struct { char path[PATH_MAX]; struct stat st; BIFileSnapshot file; uint8_t metadata[32]; bool dir; } Record;
struct BBInventory { char path[PATH_MAX]; int rootfd; struct stat root; uint8_t root_metadata[32]; size_t count; uint64_t total, metadata_total; Record entries[BB_MAX_ENTRIES]; uint8_t digest[32]; };
static bool timely(uint64_t d) { struct timespec t; if(clock_gettime(CLOCK_MONOTONIC,&t)) return false; uint64_t n=(uint64_t)t.tv_sec*1000000000ULL+(uint64_t)t.tv_nsec; return d>n && d-n<=5000000000ULL; }
static bool same_stat(const struct stat *a,const struct stat *b) { return a->st_dev==b->st_dev && a->st_ino==b->st_ino && a->st_mode==b->st_mode && a->st_uid==b->st_uid && a->st_gid==b->st_gid && a->st_nlink==b->st_nlink && a->st_size==b->st_size && a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec && a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec && a->st_birthtimespec.tv_sec==b->st_birthtimespec.tv_sec && a->st_birthtimespec.tv_nsec==b->st_birthtimespec.tv_nsec && a->st_flags==b->st_flags; }
static bool matches_file(const struct stat *s,const BIFileSnapshot *f) { return (uint64_t)s->st_dev==f->dev && (uint64_t)s->st_ino==f->ino && (uint64_t)s->st_nlink==f->nlink && (uint32_t)s->st_uid==f->uid && (uint32_t)s->st_gid==f->gid && (uint32_t)s->st_mode==f->mode && (uint64_t)s->st_size==f->size && s->st_mtimespec.tv_sec==f->mtime_sec && s->st_mtimespec.tv_nsec==f->mtime_nsec && s->st_ctimespec.tv_sec==f->ctime_sec && s->st_ctimespec.tv_nsec==f->ctime_nsec; }
static bool same_file(const BIFileSnapshot *a,const BIFileSnapshot *b) { return a->size==b->size && a->dev==b->dev && a->ino==b->ino && a->nlink==b->nlink && a->uid==b->uid && a->gid==b->gid && a->mode==b->mode && a->mtime_sec==b->mtime_sec && a->mtime_nsec==b->mtime_nsec && a->ctime_sec==b->ctime_sec && a->ctime_nsec==b->ctime_nsec && !memcmp(a->sha256,b->sha256,32); }
static BBError from_bi(BIError e) { switch(e) { case BI_OK:return BB_OK; case BI_EXPIRED:return BB_EXPIRED; case BI_CHANGED:return BB_CHANGED; case BI_IO:return BB_IO; default:return BB_INVALID; } }
/* ASCII-only names are an intentionally conservative supported layout. */
static bool name_ok(const char *s) {
 if(!s)return false;size_t n=strnlen(s,NAME_MAX+1);if(!n||n>NAME_MAX||(n==1&&s[0]=='.')||(n==2&&s[0]=='.'&&s[1]=='.'))return false;
 for(size_t i=0;i<n;i++){unsigned char c=(unsigned char)s[i];if(c<32||c>=127||c=='/')return false;}return true;
}
static bool copy_component(char out[NAME_MAX+1],const char *s){
 if(!s)return false;size_t n=strnlen(s,NAME_MAX+1);if(!n||n>NAME_MAX)return false;memcpy(out,s,n);out[n]='\0';return name_ok(out);
}
/* Include xattr names/values and extended ACL in the instance pin. Bounds
 * reject unsupported large metadata; never silently omit metadata. */
static int strptr_cmp(const void *a,const void *b){return strcmp(*(char *const *)a,*(char *const *)b);}
static BBError metadata_update(CC_SHA256_CTX *ctx,const void *data,size_t size,uint64_t deadline) {
 const unsigned char *p=data;
 do { if(!timely(deadline))return BB_EXPIRED;size_t n=size>16384?16384:size;
  if(n && CC_SHA256_Update(ctx,p,(CC_LONG)n)!=1)return BB_IO;
  if(!timely(deadline))return BB_EXPIRED;p+=n;size-=n;
 } while(size);return BB_OK;
}
static BBError metadata_hash(int fd,uint64_t deadline,uint8_t out[32],uint64_t *out_size,uint64_t cap) {
 if(cap>BB_METADATA_MAX)return BB_INVALID;
 char names[65536];char *items[128];size_t count=0;uint64_t total=0;unsigned char *value=NULL;
 acl_t acl=NULL;char *text=NULL;BBError e=BB_IO;CC_SHA256_CTX ctx;
 #define CHECK_TIME() do { if(!timely(deadline)){e=BB_EXPIRED;goto done;} } while(0)
 #define CHARGE(n) do { uint64_t amount=(uint64_t)(n);if(amount>cap-total){e=BB_INVALID;goto done;}total+=amount; } while(0)
 #define UPDATE(p,n) do { e=metadata_update(&ctx,(p),(n),deadline);if(e!=BB_OK)goto done; } while(0)
 CHECK_TIME();ssize_t n=flistxattr(fd,names,sizeof names,0);CHECK_TIME();
 if(n<0){e=BB_IO;goto done;}if(n==(ssize_t)sizeof names){e=BB_INVALID;goto done;}CHARGE(n);
 for(ssize_t i=0;i<n;){CHECK_TIME();size_t z=strnlen(names+i,(size_t)(n-i));if(!z||z==(size_t)(n-i)||count==128){e=BB_INVALID;goto done;}items[count++]=names+i;i+=(ssize_t)z+1;}
 CHECK_TIME();qsort(items,count,sizeof items[0],strptr_cmp);CHECK_TIME();
 if(CC_SHA256_Init(&ctx)!=1){e=BB_IO;goto done;}CHECK_TIME();
 for(size_t i=0;i<count;i++){
  CHECK_TIME();if(i&&!strcmp(items[i-1],items[i])){e=BB_INVALID;goto done;}
  size_t len=strnlen(items[i],sizeof names);if(len==sizeof names){e=BB_INVALID;goto done;}
  CHECK_TIME();ssize_t sz=fgetxattr(fd,items[i],NULL,0,0,0);CHECK_TIME();if(sz<0){e=BB_IO;goto done;}CHARGE(sz);
  value=malloc(sz?(size_t)sz:1);if(!value){e=BB_IO;goto done;}
  CHECK_TIME();ssize_t got=fgetxattr(fd,items[i],value,(size_t)sz,0,0);CHECK_TIME();if(got!=sz){e=BB_CHANGED;goto done;}
  uint64_t l=(uint64_t)len,z=(uint64_t)sz;UPDATE(&l,sizeof l);UPDATE(items[i],len);UPDATE(&z,sizeof z);UPDATE(value,(size_t)sz);free(value);value=NULL;
 }
 CHECK_TIME();errno=0;acl=acl_get_fd_np(fd,ACL_TYPE_EXTENDED);int acl_errno=errno;CHECK_TIME();if(!acl&&acl_errno!=ENOENT){e=BB_IO;goto done;}
 uint8_t present=acl?1:0;UPDATE(&present,1);
 if(acl){ssize_t len=0;CHECK_TIME();text=acl_to_text(acl,&len);CHECK_TIME();if(!text||len<0){e=BB_IO;goto done;}CHARGE(len);UPDATE(text,(size_t)len);}
 CHECK_TIME();if(CC_SHA256_Final(out,&ctx)!=1){e=BB_IO;goto done;}CHECK_TIME();*out_size=total;e=BB_OK;
 done:free(value);if(text)acl_free(text);if(acl)acl_free(acl);
 #undef CHECK_TIME
 #undef CHARGE
 #undef UPDATE
 return timely(deadline)?e:BB_EXPIRED;
}
static bool good_dir(const struct stat *s) { return S_ISDIR(s->st_mode) && s->st_uid==geteuid() && !(s->st_mode&0022); }
/* Open and recheck every absolute mapping; no symlink and no writable ancestor. */
static BBError open_root(const char *path,uint64_t d,int *out,struct stat *root) {
 char buf[PATH_MAX]; int fds[128]; struct stat st[128], after; char *parts[127]; size_t n=0, opened=0; BBError e=BB_INVALID;
 if(!path)return BB_INVALID;size_t path_len=strnlen(path,sizeof buf);if(path_len<2||path_len==sizeof buf||path[0]!='/'||path[path_len-1]=='/')return BB_INVALID;
 memcpy(buf,path+1,path_len); char *p=buf; while(*p){ if(n==127)return BB_INVALID; parts[n++]=p; char *slash=strchr(p,'/'); if(!slash)break; *slash=0;p=slash+1; if(!*p)return BB_INVALID; }
 for(size_t i=0;i<n;i++)if(!name_ok(parts[i]))return BB_INVALID;
 if(!timely(d))return BB_EXPIRED;
 fds[0]=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC); if(fds[0]<0)return BB_IO; opened=1;
 if(fstat(fds[0],&st[0])){e=BB_IO;goto done;}
 for(size_t i=0;i<n;i++) {
  if(!timely(d)){e=BB_EXPIRED;goto done;}
  if(!S_ISDIR(st[i].st_mode) || (st[i].st_uid!=0 && st[i].st_uid!=geteuid()) || (st[i].st_mode&0022))goto done;
  int fd=openat(fds[i],parts[i],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC); if(fd<0){e=BB_IO;goto done;} fds[opened++]=fd;
  if(fstat(fd,&st[i+1])){e=BB_IO;goto done;}
 }
 if(!good_dir(&st[n]))goto done;
 for(size_t i=0;i<=n;i++) { if(!timely(d)){e=BB_EXPIRED;goto done;} if(fstat(fds[i],&after)||!same_stat(&after,&st[i])){e=BB_CHANGED;goto done;} if(i && (fstatat(fds[i-1],parts[i-1],&after,AT_SYMLINK_NOFOLLOW)||!same_stat(&after,&st[i]))){e=BB_CHANGED;goto done;} }
 *root=st[n]; *out=fds[n]; opened--; e=BB_OK;
 done: while(opened)close(fds[--opened]); return e;
}
static int record_cmp(const void *a,const void *b) { return strcmp(((const Record *)a)->path,((const Record *)b)->path); }
static BBError walk(BBInventory *v,int fd,const char *prefix,unsigned depth,uint64_t d) {
 struct stat before,after,at; uint8_t before_meta[32],after_meta[32];uint64_t before_size=0,after_size=0; if(!timely(d))return BB_EXPIRED;
 if(fstat(fd,&before)||!good_dir(&before))return BB_INVALID;BBError me=metadata_hash(fd,d,before_meta,&before_size,BB_METADATA_MAX);if(me!=BB_OK)return me;
 int streamfd=openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC); if(streamfd<0)return BB_IO;
 DIR *dir=fdopendir(streamfd); if(!dir){close(streamfd);return BB_IO;} BBError e=BB_OK;
 for(;;) {
  if(!timely(d)){e=BB_EXPIRED;break;} errno=0; struct dirent *de=readdir(dir); int saved=errno;
  if(!de){if(saved)e=BB_IO;break;} if(!strcmp(de->d_name,".")||!strcmp(de->d_name,".."))continue;
  if(!name_ok(de->d_name)||depth>BB_MAX_DEPTH || v->count>=BB_MAX_ENTRIES){e=BB_INVALID;break;}
  char rel[PATH_MAX], absolute[PATH_MAX]; int len=snprintf(rel,sizeof rel,"%s%s%s",prefix,*prefix?"/":"",de->d_name);
  if(len<0||len>=(int)sizeof rel || snprintf(absolute,sizeof absolute,"%s/%s",v->path,rel)>=(int)sizeof absolute){e=BB_INVALID;break;}
  if(fstatat(fd,de->d_name,&at,AT_SYMLINK_NOFOLLOW)){e=BB_IO;break;}
  if(!S_ISDIR(at.st_mode)&&!S_ISREG(at.st_mode)){e=BB_INVALID;break;}
  int child=openat(fd,de->d_name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK|(S_ISDIR(at.st_mode)?O_DIRECTORY:0));
  if(child<0){e=BB_IO;break;} struct stat st;
  uint8_t meta[32],later_meta[32];uint64_t meta_size=0,later_size=0; if(fstat(child,&st)||!same_stat(&at,&st)){close(child);e=BB_CHANGED;break;}
  e=metadata_hash(child,d,meta,&meta_size,BB_METADATA_MAX-v->metadata_total);if(e!=BB_OK){close(child);break;}if(meta_size>BB_METADATA_MAX-v->metadata_total){close(child);e=BB_INVALID;break;}v->metadata_total+=meta_size;
  if(st.st_uid!=geteuid() || (st.st_mode&0022)){close(child);e=BB_INVALID;break;}
  Record *r=&v->entries[v->count++]; strcpy(r->path,rel); r->st=st; memcpy(r->metadata,meta,32); r->dir=S_ISDIR(st.st_mode);
  if(r->dir) e=walk(v,child,rel,depth+1,d);
  else {
   if(st.st_nlink!=1||st.st_size<0||(uint64_t)st.st_size>BB_FILE_MAX || (uint64_t)st.st_size>BB_TOTAL_MAX-v->total) e=BB_INVALID;
   else { v->total+=(uint64_t)st.st_size; e=from_bi(bi_snapshot(absolute,d,&r->file)); if(e==BB_OK && !matches_file(&st,&r->file))e=BB_CHANGED; }
  }
  if(e==BB_OK){e=metadata_hash(child,d,later_meta,&later_size,meta_size);if(e==BB_OK&&(meta_size!=later_size||memcmp(meta,later_meta,32)))e=BB_CHANGED;}
  if(e==BB_OK && (fstat(child,&after)||!same_stat(&st,&after)||fstatat(fd,de->d_name,&after,AT_SYMLINK_NOFOLLOW)||!same_stat(&st,&after)))e=BB_CHANGED;
  close(child); if(e!=BB_OK)break;
 }
 if(closedir(dir)&&e==BB_OK)e=BB_IO;
 if(e==BB_OK){e=metadata_hash(fd,d,after_meta,&after_size,before_size);if(e==BB_OK&&(before_size!=after_size||memcmp(before_meta,after_meta,32)||fstat(fd,&after)||!same_stat(&before,&after)))e=BB_CHANGED;}
 return timely(d)?e:BB_EXPIRED;
}
static void hash_u64(CC_SHA256_CTX *c,uint64_t n){uint8_t b[8];for(int i=7;i>=0;i--){b[i]=(uint8_t)n;n>>=8;}CC_SHA256_Update(c,b,8);}
static void digest(BBInventory *v){ CC_SHA256_CTX c;CC_SHA256_Init(&c);static const char domain[]="BB-content-v1";CC_SHA256_Update(&c,domain,sizeof domain);hash_u64(&c,v->count);for(size_t i=0;i<v->count;i++){Record *r=&v->entries[i];size_t n=strlen(r->path);hash_u64(&c,n);CC_SHA256_Update(&c,r->path,(CC_LONG)n);uint8_t type=r->dir?1:2;CC_SHA256_Update(&c,&type,1);if(!r->dir){hash_u64(&c,r->file.size);CC_SHA256_Update(&c,r->file.sha256,32);}}CC_SHA256_Final(v->digest,&c);}
void bb_free(BBInventory *v){if(v){if(v->rootfd>=0)close(v->rootfd);free(v);}}
BBError bb_inventory(const char *path,uint64_t d,BBInventory **out){
 if(!out)return BB_INVALID; *out=NULL; if(!timely(d))return BB_EXPIRED;
 BBInventory *v=calloc(1,sizeof *v); if(!v)return BB_IO;v->rootfd=-1;
 if(!path){bb_free(v);return BB_INVALID;}size_t path_len=strnlen(path,sizeof v->path);if(path_len==sizeof v->path){bb_free(v);return BB_INVALID;}memcpy(v->path,path,path_len+1);
 BBError e=open_root(path,d,&v->rootfd,&v->root); if(e!=BB_OK){bb_free(v);return e;}
 e=metadata_hash(v->rootfd,d,v->root_metadata,&v->metadata_total,BB_METADATA_MAX);if(e!=BB_OK){bb_free(v);return e;}uint64_t root_meta_size=v->metadata_total;
 e=walk(v,v->rootfd,"",1,d); if(e==BB_OK){uint8_t after_meta[32];uint64_t after_size=0;e=metadata_hash(v->rootfd,d,after_meta,&after_size,root_meta_size);if(e==BB_OK&&(root_meta_size!=after_size||memcmp(v->root_metadata,after_meta,32)))e=BB_CHANGED;} if(e==BB_OK){int x=-1;struct stat st; e=open_root(path,d,&x,&st);if(e==BB_OK&&!same_stat(&v->root,&st))e=BB_CHANGED;if(x>=0)close(x);}
 if(e!=BB_OK){bb_free(v);return e;}qsort(v->entries,v->count,sizeof v->entries[0],record_cmp);digest(v);if(!timely(d)){bb_free(v);return BB_EXPIRED;}*out=v;return BB_OK;
}
size_t bb_count(const BBInventory *v){return v?v->count:0;}
int bb_entry(const BBInventory *v,size_t i,BBEntry *out){if(!v||!out||i>=v->count)return 0;const Record *r=&v->entries[i];out->path=r->path;out->is_directory=r->dir;out->size=r->dir?0:r->file.size;out->sha256=r->dir?NULL:r->file.sha256;return 1;}
int bb_content_digest(const BBInventory *v,uint8_t out[32]){if(!v||!out)return 0;memcpy(out,v->digest,32);return 1;}
BBError bb_validate_signature(const char *path,const char *bid,uint64_t d,BBCodeIdentity *out){
 if(!path||!out)return BB_INVALID;char safe_path[PATH_MAX],safe_bid[NAME_MAX+1];size_t path_len=strnlen(path,sizeof safe_path);
 if(!path_len||path_len==sizeof safe_path||!copy_component(safe_bid,bid))return BB_INVALID;memcpy(safe_path,path,path_len+1);path=safe_path;bid=safe_bid;if(!timely(d))return BB_EXPIRED;
 BBError e=BB_IO; int held=-1,afterfd=-1;struct stat before,after; e=open_root(path,d,&held,&before);if(e!=BB_OK)return e; e=BB_IO; CFStringRef s=NULL, expected=NULL;CFURLRef url=NULL;SecStaticCodeRef code=NULL;CFDictionaryRef info=NULL;BBCodeIdentity result={0};
 s=CFStringCreateWithFileSystemRepresentation(NULL,path);expected=CFStringCreateWithCString(NULL,bid,kCFStringEncodingUTF8);if(!s||!expected)goto done;
 url=CFURLCreateWithFileSystemPath(NULL,s,kCFURLPOSIXPathStyle,true);if(!url)goto done;
 OSStatus rc=SecStaticCodeCreateWithPath(url,kSecCSDefaultFlags,&code);if(!timely(d)){e=BB_EXPIRED;goto done;}if(rc!=errSecSuccess||!code)goto done;
 rc=SecStaticCodeCheckValidity(code,kSecCSCheckAllArchitectures|kSecCSCheckNestedCode|kSecCSStrictValidate,NULL);if(!timely(d)){e=BB_EXPIRED;goto done;}if(rc!=errSecSuccess){fprintf(stderr,"phase=bundle-security status=%d\n",(int)rc);goto done;}
 rc=SecCodeCopySigningInformation(code,kSecCSSigningInformation,&info);if(!timely(d)){e=BB_EXPIRED;goto done;}if(rc!=errSecSuccess||!info)goto done;
 CFTypeRef ident=CFDictionaryGetValue(info,kSecCodeInfoIdentifier), hash=CFDictionaryGetValue(info,kSecCodeInfoUnique);
 if(!ident||CFGetTypeID(ident)!=CFStringGetTypeID()||CFStringCompare(ident,expected,0)!=kCFCompareEqualTo||!hash||CFGetTypeID(hash)!=CFDataGetTypeID()){e=BB_INVALID;goto done;}
 CFIndex len=CFDataGetLength(hash);if(len<=0||len>64){e=BB_INVALID;goto done;}result.code_hash_len=(uint32_t)len;CFDataGetBytes(hash,CFRangeMake(0,len),result.code_hash);
 if(!timely(d)){e=BB_EXPIRED;goto done;}e=open_root(path,d,&afterfd,&after);if(e!=BB_OK)goto done;if(!same_stat(&before,&after)){e=BB_CHANGED;goto done;}*out=result;e=BB_OK;
 done:if(afterfd>=0)close(afterfd);if(held>=0)close(held);if(info)CFRelease(info);if(code)CFRelease(code);if(url)CFRelease(url);if(expected)CFRelease(expected);if(s)CFRelease(s);return e;
}
static bool equal_inventory(const BBInventory *a,const BBInventory *b){
 if(!same_stat(&a->root,&b->root)||memcmp(a->root_metadata,b->root_metadata,32)||a->count!=b->count||a->total!=b->total||memcmp(a->digest,b->digest,32))return false;
 for(size_t i=0;i<a->count;i++){const Record *x=&a->entries[i],*y=&b->entries[i];if(strcmp(x->path,y->path)||x->dir!=y->dir||!same_stat(&x->st,&y->st)||memcmp(x->metadata,y->metadata,32)||(!x->dir&&!same_file(&x->file,&y->file)))return false;}return true;
}
static const Record *find_record(const BBInventory *v,const char *path){for(size_t i=0;i<v->count;i++)if(!strcmp(v->entries[i].path,path))return &v->entries[i];return NULL;}
static BBError validate_plist(const BBInventory *v,const char *bid,const char *leaf,uint64_t d){
 const Record *r=find_record(v,"Contents/Info.plist");if(!r||r->dir||r->file.size>1024*1024)return BB_INVALID;
 int contents=openat(v->rootfd,"Contents",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(contents<0)return BB_IO;
 int fd=openat(contents,"Info.plist",O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);if(fd<0){close(contents);return BB_IO;}
 BBError e=BB_IO;struct stat before,after;uint8_t *bytes=NULL;CFDataRef data=NULL;CFPropertyListRef plist=NULL;
 if(fstat(fd,&before)||!matches_file(&before,&r->file))goto done;
 size_t size=(size_t)r->file.size;bytes=malloc(size?size:1);if(!bytes)goto done;size_t used=0;
 while(used<size){if(!timely(d)){e=BB_EXPIRED;goto done;}ssize_t n=read(fd,bytes+used,size-used);if(n<=0)goto done;used+=(size_t)n;}
 uint8_t hash[32];CC_SHA256(bytes,(CC_LONG)size,hash);
 if(memcmp(hash,r->file.sha256,32)||fstat(fd,&after)||!same_stat(&before,&after)||fstatat(contents,"Info.plist",&after,AT_SYMLINK_NOFOLLOW)||!same_stat(&before,&after)){e=BB_CHANGED;goto done;}
 data=CFDataCreate(NULL,bytes,(CFIndex)size);if(!data)goto done;plist=CFPropertyListCreateWithData(NULL,data,kCFPropertyListImmutable,NULL,NULL);if(!plist||CFGetTypeID(plist)!=CFDictionaryGetTypeID()){e=BB_INVALID;goto done;}
 CFDictionaryRef dict=(CFDictionaryRef)plist;CFTypeRef kind=CFDictionaryGetValue(dict,CFSTR("CFBundlePackageType")), id=CFDictionaryGetValue(dict,CFSTR("CFBundleIdentifier")), exe=CFDictionaryGetValue(dict,CFSTR("CFBundleExecutable"));
 CFStringRef expectedID=CFStringCreateWithCString(NULL,bid,kCFStringEncodingUTF8), expectedExe=CFStringCreateWithCString(NULL,leaf,kCFStringEncodingUTF8);
 if(!expectedID||!expectedExe){if(expectedID)CFRelease(expectedID);if(expectedExe)CFRelease(expectedExe);goto done;}
 bool good=kind&&id&&exe&&CFGetTypeID(kind)==CFStringGetTypeID()&&CFGetTypeID(id)==CFStringGetTypeID()&&CFGetTypeID(exe)==CFStringGetTypeID()&&CFEqual(kind,CFSTR("APPL"))&&CFEqual(id,expectedID)&&CFEqual(exe,expectedExe);CFRelease(expectedID);CFRelease(expectedExe);e=good?BB_OK:BB_INVALID;
 done:if(plist)CFRelease(plist);if(data)CFRelease(data);free(bytes);close(fd);close(contents);return timely(d)?e:BB_EXPIRED;
}
BBError bb_revalidate(BBInventory *pin,const char *bid,const char *leaf,uint64_t d){
 if(!pin)return BB_INVALID;char safe_bid[NAME_MAX+1],safe_leaf[NAME_MAX+1];if(!copy_component(safe_bid,bid)||!copy_component(safe_leaf,leaf))return BB_INVALID;bid=safe_bid;leaf=safe_leaf;BBInventory *first=NULL,*last=NULL;BBCodeIdentity code={0};BIImagePin mainpin={0};
 BBError e=bb_inventory(pin->path,d,&first);if(e!=BB_OK)goto done;if(!equal_inventory(pin,first)){e=BB_CHANGED;goto done;}
 e=validate_plist(first,bid,leaf,d);if(e!=BB_OK)goto done;
 char mainrel[PATH_MAX],mainpath[PATH_MAX];if(snprintf(mainrel,sizeof mainrel,"Contents/MacOS/%s",leaf)>=(int)sizeof mainrel||snprintf(mainpath,sizeof mainpath,"%s/%s",pin->path,mainrel)>=(int)sizeof mainpath){e=BB_INVALID;goto done;}
 const Record *main=find_record(first,mainrel);if(!main||main->dir){e=BB_INVALID;goto done;}
 e=bb_validate_signature(pin->path,bid,d,&code);if(e!=BB_OK)goto done;
 e=from_bi(bi_static_pin(mainpath,d,&mainpin));if(e!=BB_OK)goto done;
 if(!same_file(&mainpin.file,&main->file)||code.code_hash_len!=mainpin.code_hash_len||memcmp(code.code_hash,mainpin.code_hash,code.code_hash_len)){e=BB_INVALID;goto done;}
 e=bb_inventory(pin->path,d,&last);if(e==BB_OK&&!equal_inventory(pin,last))e=BB_CHANGED;
 done:bb_free(first);bb_free(last);return timely(d)?e:BB_EXPIRED;
}

BBError bb_expect_exact(const BBInventory *v,const BBExpected *expected,size_t count){
 if(!v||!expected||count!=v->count||count>BB_MAX_ENTRIES)return BB_INVALID;
 for(size_t i=0;i<count;i++){
  if(!expected[i].path||strnlen(expected[i].path,PATH_MAX)==PATH_MAX||(expected[i].is_directory!=0&&expected[i].is_directory!=1))return BB_INVALID;
  for(size_t j=0;j<i;j++)if(!strcmp(expected[i].path,expected[j].path))return BB_INVALID;
  const Record *r=find_record(v,expected[i].path);if(!r||r->dir!=(bool)expected[i].is_directory)return BB_INVALID;
  if(expected[i].sha256&&(r->dir||memcmp(expected[i].sha256,r->file.sha256,32)))return BB_INVALID;
 }
 return BB_OK;
}
