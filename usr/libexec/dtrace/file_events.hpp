//
//  file_events.hpp
//  smbd
//
//  Created by William Conway on 5/30/17.
//  Copyright © 2017 Apple Inc. All rights reserved.
//

#ifndef file_events_hpp
#define file_events_hpp

#include <CoreServices/CoreServices.h>
#include <sys/param.h>
#include "ntvfs/ntvfs.hpp"

// This is how file events are passed to clients.
// Derive a class from CallbackHandler and implement the
// virtual function handle_callback().  Pass an instance
// of this object to init_monitor().
struct CallbackHandler
{
    CallbackHandler() {};
    virtual ~CallbackHandler() {};
    
    // This callback handler should not block, instead it should behave like
    // a signal handler. That is, set state and then schedule the
    // event to be processed by a worker thread.
    virtual void handle_callback(uint64_t event_id,
                                 ntvfs::file_device_inode tree_devino,
                                 ino_t event_ino,
                                 FSEventStreamEventFlags event_flags,
                                 const char *event_path) = 0;
};

struct FSEventMonitor
{
    FSEventMonitor();
    ~FSEventMonitor();

    // Initialization can only be done once. While start + stop pairs
    // can be called multiple times.
    int init_monitor(ntvfs::file_device_inode dev_ino, const char *tree_path, CallbackHandler *cb_hand);
    
    // Once initialized, you can stop and start at will.
    int start_monitor(void);
    int stop_monitor(void);
    
    bool is_started(void) {return _started == true;}
    
    // Internal fsevents callback
    static void fsevents_callback(FSEventStreamRef streamRef, void *clientCallBackInfo,
                                  int numEvents, void *eventPaths, const FSEventStreamEventFlags
                                  *eventMasks, const   uint64_t *eventIds);
protected:
    bool _init_done;
    bool _started;
    ntvfs::file_device_inode _devino;
    FSEventStreamRef _streamRef;
    dispatch_queue_t _streamQueue;
    
    // simple lock to protect internal state (_init_done, _started)
    platform::mutex  _lock;
    
    // Registered callback
    CallbackHandler *_callback_handler;
    
    // for debugging, don't really need
    char _path[MAXPATHLEN];
    
    // Called by fsevents_callback
    void notify_fsevent(uint64_t event_id, ino_t event_ino, FSEventStreamEventFlags event_flags, const char *event_path);
};

// Simple node for implementing
// FSEventMonitor containers.
struct fsmonitor_node
{
    fsmonitor_node()
    : monitor(NULL),
    ref_count(0)
    { }
    
    FSEventMonitor  *monitor;
    uint32_t        ref_count;
};

#endif /* file_events_hpp */
