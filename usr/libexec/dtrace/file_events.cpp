//
//  file_events.cpp
//  smbd
//
//  Created by William Conway on 5/30/17.
//  Copyright © 2017 Apple Inc. All rights reserved.
//

#include "file_events.hpp"
#include <platform/logging.hpp>

// FSEvent Monitor
FSEventMonitor::FSEventMonitor()
: _init_done(false),
_started(false),
_streamRef(NULL),
_streamQueue(NULL),
_lock(),
_callback_handler(NULL)
{
    _devino.first = -1;
    _devino.second = -1;
    _path[0] = 0;
}

FSEventMonitor::~FSEventMonitor()
{
    if (_init_done == true) {
        if (_started == true) {
            stop_monitor();
        }
        
        FSEventStreamInvalidate(_streamRef);
        FSEventStreamRelease(_streamRef);
        dispatch_release(_streamQueue);
        
        _streamRef = NULL;
        _streamQueue = NULL;
        _init_done = 0;
    }
}

int
FSEventMonitor::init_monitor(ntvfs::file_device_inode dev_ino, const char *tree_path, CallbackHandler *cb_hand)
{
    int err;
    CFStringRef cfStr;
    CFMutableArrayRef cfArray;
    FSEventStreamContext context = {0, this, NULL, NULL, NULL};
    FSEventStreamCallback callback = (FSEventStreamCallback)&fsevents_callback;
    
    err = 0;
    
    _lock.lock_exclusive();
    if (_init_done == true) {
        log_debug("FSEventMonitor::init_monitor: already initialized, dev: %u, ino: %llu, path: %s",
                  dev_ino.first, dev_ino.second, tree_path);
        err = -1;
        _lock.unlock();
        goto out;
    }
    
    _streamQueue = dispatch_queue_create("FSEventMonitorQueue", DISPATCH_QUEUE_SERIAL);
    if (_streamQueue == NULL) {
        log_error("FSEventMonitor::init_monitor: failed to alloc streamQueue, dev: %u, ino: %llu, path: %s",
                  dev_ino.first, dev_ino.second, tree_path);
        err = -1;
        _lock.unlock();
        goto out;
    }
    
    cfArray = CFArrayCreateMutable(kCFAllocatorDefault, 1, &kCFTypeArrayCallBacks);
    if (cfArray == NULL) {
        log_error("FSEventMonitor::init_monitor: Failed to alloc cfArray, dev: %u, ino: %llu, path: %s",
                  dev_ino.first, dev_ino.second, tree_path);
        
        dispatch_release(_streamQueue);
        err = -1;
        _lock.unlock();
        goto out;
    }
    
    cfStr = CFStringCreateWithFileSystemRepresentation(kCFAllocatorDefault, tree_path);
    if (cfStr == NULL) {
        log_error("FSEventMonitor::init_monitor: Failed to create cfStr from tree_path, dev: %u, ino: %llu, path: %s",
                  dev_ino.first, dev_ino.second, tree_path);
        dispatch_release(_streamQueue);
        CFRelease(cfArray);
        err = -1;
        _lock.unlock();
        goto out;
    }
    
    CFArraySetValueAtIndex(cfArray, 0, cfStr);
    CFRelease(cfStr);
    
    // We might want to specify kFSEventStreamCreateFlagWatchRoot, just so we
    // could log an error if someone tried to rename a share with active connections.
    // But renaming a share root outside of smb would be really bad practice.
    _streamRef = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, cfArray,
                                     kFSEventStreamEventIdSinceNow, 1,
                                     kFSEventStreamCreateFlagIgnoreSelf |
                                     kFSEventStreamCreateFlagNoDefer |
                                     kFSEventStreamCreateFlagFileEvents |
                                     kFSEventStreamCreateFlagUseCFTypes |
                                     kFSEventStreamCreateFlagUseExtendedData);
    
    CFRelease(cfArray);
    
    if (_streamRef == NULL) {
        log_error("FSEventMonitor::init_monitor: Failed to create FSEventStream, dev: %u, ino: %llu, path: %s",
                  dev_ino.first, dev_ino.second, tree_path);
        dispatch_release(_streamQueue);
        err = -1;
        _lock.unlock();
        goto out;
    }
    
    FSEventStreamSetDispatchQueue(_streamRef, _streamQueue);
    
    _devino.first = dev_ino.first;
    _devino.second = dev_ino.second;
    _callback_handler = cb_hand;
    strlcpy(_path, tree_path, sizeof(_path));
    _init_done = true;
    _lock.unlock();
    
out:
    return (err);
}

int
FSEventMonitor::start_monitor(void)
{
    Boolean result;
    int err = 0;
    
    _lock.lock_exclusive();
    if (_init_done == false) {
        log_debug("FSEventMonitor::start_monitor: Can't start, need to initialize first");
        err = -1;
        _lock.unlock();
        goto out;
    }
    
    if (_started == true) {
        log_debug("FSEventMonitor::start_monitor: already started, dev: %u, ino: %llu, path: %s",
                  _devino.first, _devino.second, _path);
        
        // Don't really need to return an error here,
        // caller wants this monitor started, and it is started.
        _lock.unlock();
        goto out;
    }
    
    result = FSEventStreamStart(_streamRef);
    
    if (result != true) {
        log_error("FSEventMonitor::start_monitor problem, FSEventStreamStart returned false");
    } else {
        _started = true;
    }
    
    _lock.unlock();
out:
    return (err);
}

int
FSEventMonitor::stop_monitor(void)
{
    int err = 0;
    
    _lock.lock_exclusive();
    if (_init_done == false) {
        log_debug("FSEventMonitor::stop_monitor: need to initialize first");
        err = -1;
        _lock.unlock();
        goto out;
    }
    
    if (_started == false) {
        log_debug("FSEventMonitor::stop_monitor: already stopped");
        
        // Don't really need to return an error here,
        // caller wants this monitor stopped, and it is stopped.
        _lock.unlock();
        goto out;
    }
    
    FSEventStreamStop(_streamRef);
    
    _started = false;
    
    _lock.unlock();
    
    // Make sure all fsevents were dispatched,
    // before we return.
    dispatch_sync(_streamQueue, ^{});
    
out:
    
    return (err);
    
}

void
FSEventMonitor::notify_fsevent(uint64_t event_id, ino_t event_ino, FSEventStreamEventFlags event_flags, const char *event_path)
{
    _lock.lock_exclusive();
    if (_started == false) {
        // Monitor not running, just return
        _lock.unlock();
        goto out;
    }
    
    _lock.unlock();
    
    if (_callback_handler != NULL) {
        _callback_handler->handle_callback(event_id, _devino, event_ino, event_flags, event_path);
    }
    
out:
    return;
}

// FSEvents calls this static callback when file events occur
void
FSEventMonitor::fsevents_callback(FSEventStreamRef streamRef, void *clientCallBackInfo, int numEvents, void *eventPaths, const FSEventStreamEventFlags *eventMasks, const   uint64_t *eventIds)
{
    FSEventStreamEventFlags eflags;
    Boolean result;
    bool    good_event;
    uint64_t fileid;
    char pathb[PATH_MAX];
    char *eventPath;
    long i;
    
    FSEventMonitor *mon = (FSEventMonitor *)clientCallBackInfo;
    if (mon == NULL || streamRef == NULL || eventIds == NULL) {
        log_debug("fsevents_cb: we got a null monitor or streamRef or eventIDs");
        return;
    }
    
    if (eventPaths == NULL) {
        return;
    }
    
    for (i = 0; i < numEvents; i++) {
        eventPath = NULL;
        
        eflags = eventMasks[i];
        good_event = true;
        fileid = 0;
        
        CFArrayRef cfArrayRef_of_cfDictionariesRef = (CFArrayRef)eventPaths;
        CFDictionaryRef entryRef = (CFDictionaryRef)CFArrayGetValueAtIndex(cfArrayRef_of_cfDictionariesRef, i);
        
        if (CFDictionaryGetTypeID() != CFGetTypeID(entryRef)) {
            log_debug("fsevents_cb: CFDictionaryGetTypeID() != CFGetTypeID(entryRef) (i = %ld)", i);
            good_event = false;
        } else {
            CFStringRef cfStringRef = (CFStringRef)CFDictionaryGetValue(entryRef, CFSTR("path"));
            
            if (!CFStringGetFileSystemRepresentation(cfStringRef, pathb, PATH_MAX))
            {
                log_debug("fsevents_cb: CFStringGetFileSystemRepresentation() failed (i = %ld)", i);
                good_event = false;
            }
            eventPath = pathb;
            
            CFNumberRef fileIDRef = (CFNumberRef)CFDictionaryGetValue(entryRef, kFSEventStreamEventExtendedFileIDKey);
            if (fileIDRef == NULL)
            {
                log_debug("fsevents_cb: file ID not available for event (i = %ld)\n", i);
                good_event = false;
            }
            else
            {
                result = CFNumberGetValue(fileIDRef, kCFNumberSInt64Type, &fileid);
                if (result == false) {
                    // Couldn't get fileid (inode)
                    log_debug("fsevents_cb: CFNumberGetValue failed for fileid");
                    good_event = false;
                }
            }
        }
        
        if (good_event == true) {
            mon->notify_fsevent(eventIds[i], fileid, eflags, eventPath);
        }
    }
}
