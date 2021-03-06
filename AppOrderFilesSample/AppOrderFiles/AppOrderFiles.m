//
//  AppOrderFiles.m
//  AppOrderFiles
//
//  Created by 杨萧玉 on 2019/8/31.
//  Copyright © 2019 杨萧玉. All rights reserved.
//

#import "AppOrderFiles.h"
#import <dlfcn.h>
#import <libkern/OSAtomicQueue.h>
#import <pthread.h>

static OSQueueHead queue = OS_ATOMIC_QUEUE_INIT;

static BOOL collectBegan = NO;
static BOOL collectFinished = NO;

typedef struct {
    void *pc;
    void *next;
} PCNode;

// The guards are [start, stop).
// This function will be called at least once per DSO and may be called
// more than once with the same values of start/stop.
void __sanitizer_cov_trace_pc_guard_init(uint32_t *start,
                                         uint32_t *stop) {
    static uint32_t N;  // Counter for the guards.
    if (start == stop || *start) return;  // Initialize only once.
    printf("INIT: %p %p\n", start, stop);
    for (uint32_t *x = start; x < stop; x++)
        *x = ++N;  // Guards should start from 1.
}

// This callback is inserted by the compiler on every edge in the
// control flow (some optimizations apply).
// Typically, the compiler will emit the code like this:
//    if(*guard)
//      __sanitizer_cov_trace_pc_guard(guard);
// But for large functions it will emit a simple call:
//    __sanitizer_cov_trace_pc_guard(guard);
void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
    if (collectFinished || (!*guard && collectBegan)) {
        return;
    }
    // If you set *guard to 0 this code will not be called again for this edge.
    // Now you can get the PC and do whatever you want:
    //   store it somewhere or symbolize it and print right away.
    // The values of `*guard` are as you set them in
    // __sanitizer_cov_trace_pc_guard_init and so you can make them consecutive
    // and use them to dereference an array or a bit vector.
    *guard = 0;
    void *PC = __builtin_return_address(0);
    PCNode *node = malloc(sizeof(PCNode));
    *node = (PCNode){PC, NULL};
    // PC里面保存的是__sanitizer_cov_trace_pc_guard调用完返回的地方，也就是：
    //
    // 000000010057a064         bl         ___sanitizer_cov_trace_pc_guard
    // 000000010057a068         ldr        x8, [sp, #0x30]
    // PC保存的就是"000000010057a068"
    OSAtomicEnqueue(&queue, node, offsetof(PCNode, next));
}

extern void AppOrderFiles(void(^completion)(NSString *orderFilePath)) {
    collectFinished = YES;
    __sync_synchronize();
    NSString *functionExclude = [NSString stringWithFormat:@"_%s", __FUNCTION__];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray <NSString *> *functions = [NSMutableArray array];
        while (YES) {
            PCNode *node = OSAtomicDequeue(&queue, offsetof(PCNode, next));
            if (node == NULL) {
                break;
            }
            // int dladdr(void *addr, Dl_info *info)
            // dladdr函数检测addr地址描述的代码是否位于由当前可执行文件调用的共享模块中。
            // 如果存在，则返回共享模块和addr出的符号，并存储于info中。
            // typedef struct {
            //    const char *dli_fname;  /* Pathname of shared object that contains address */
            //    void       *dli_fbase;  /* Base address at which shared object is loaded */
            //    const char *dli_sname;  /* Name of symbol whose definition overlaps addr */
            //    void       *dli_saddr;  /* Exact address of symbol named in dli_sname */
            // } Dl_info;
            Dl_info info = {0};
            dladdr(node->pc, &info);
            if (info.dli_sname) {
                // 从注释和实验结果来看info.dli_sname返回的是node->pc所在的函数的函数名字。
                NSString *name = @(info.dli_sname);
                BOOL isObjc = [name hasPrefix:@"+["] || [name hasPrefix:@"-["];
                NSString *symbolName = isObjc ? name : [@"_" stringByAppendingString:name];
                [functions addObject:symbolName];
            }
        }
        if (functions.count == 0) {
            if (completion) {
                completion(nil);
            }
            return;
        }
        NSMutableArray<NSString *> *calls = [NSMutableArray arrayWithCapacity:functions.count];
        NSEnumerator *enumerator = [functions reverseObjectEnumerator];
        NSString *obj;
        while (obj = [enumerator nextObject]) {
            if (![calls containsObject:obj]) {
                [calls addObject:obj];
            }
        }
        [calls removeObject:functionExclude];
        NSString *result = [calls componentsJoinedByString:@"\n"];
        NSLog(@"Order:\n%@", result);
        NSString *filePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"app.order"];
        NSData *fileContents = [result dataUsingEncoding:NSUTF8StringEncoding];
        BOOL success = [[NSFileManager defaultManager] createFileAtPath:filePath
                                                               contents:fileContents
                                                             attributes:nil];
        if (completion) {
            completion(success ? filePath : nil);
        }
    });
}
