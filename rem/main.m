//
//  main.m
//  rem
//
//  Created by Kevin Y. Kim on 10/15/12.
//  Copyright (c) 2012 kykim, inc. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <EventKit/EventKit.h>

#define COMMANDS @[ @"ls", @"rm", @"cat", @"done", @"help", @"version" ]
typedef enum _CommandType {
    CMD_UNKNOWN = -1,
    CMD_LS = 0,
    CMD_RM,
    CMD_CAT,
    CMD_DONE,
    CMD_HELP,
    CMD_VERSION
} CommandType;

static CommandType command;
static NSString *calendar;
static NSString *reminder_id;

static NSDictionary *calendars;

static EKEventStore *store;


/*!
    @function _print
    @abstract Wrapper for fprintf with NSString format
    @discussion Wraps call to fprintf with an NSString format argument, permitting use of the
        object formatter '%@'
    @param stream
        Output stream to write to
    @param format
        (f)printf style format string
    @param ...
        optional arguments as defined by format string
 */
static void _print(FILE *file, NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *string = [[NSString alloc] initWithFormat:format arguments:args];
    fprintf(file, "%s", [string UTF8String]);
    va_end(args);
}

/*!
    @function _version
    @abstract Output version information
 */
static void _version()
{
    _print(stdout, @"rem Version 0.01\n");
}

/*!
    @function _usage
    @abstract Output command usage
 */
static void _usage()
{
    _print(stdout, @"Usage:\n");
    _print(stdout, @"\trem <ls> [list]\n");
    _print(stdout, @"\t\tList reminders\n");
    _print(stdout, @"\trem rm [list] [reminder]\n");
    _print(stdout, @"\t\tRemove reminder from list\n");
    _print(stdout, @"\trem cat [list] [item]\n");
    _print(stdout, @"\t\tShow reminder detail\n");
    _print(stdout, @"\trem done [list] [item]\n");
    _print(stdout, @"\t\tMark reminder as complete\n");
    _print(stdout, @"\trem help\n");
    _print(stdout, @"\t\tShow this text\n");
    _print(stdout, @"\trem verison\n");
    _print(stdout, @"\t\tShow version information\n");
}

/*!
    @function parseArguments
    @abstract Command arguement parser
    @description Parse command-line arguments and populate appropriate variables
 */
static void parseArguments()
{
    command = CMD_LS;
    
    NSMutableArray *args = [NSMutableArray arrayWithArray:[[NSProcessInfo processInfo] arguments]];
    [args removeObjectAtIndex:0];    // pop off application argument
    
    // args array is empty, command was excuted without arguments
    if (args.count == 0)
        return;
    
    NSString *cmd = [args objectAtIndex:0];
    command = (CommandType)[COMMANDS indexOfObject:cmd];
    if (command == CMD_UNKNOWN) {
        _print(stderr, @"rem: Error unknown command %@", cmd);
        _usage();
        exit(-1);
    }
    
    // handle help and version requests
    if (command == CMD_HELP) {
        _usage();
        exit(0);
    }
    else if (command == CMD_VERSION) {
        _version();
        exit(0);
    }

    // get the reminder list (calendar) if exists
    if (args.count >= 2) {
        calendar = [args objectAtIndex:1];
    }

    // get the reminder id if exists
    if (args.count >= 3) {
        reminder_id = [args objectAtIndex:2];
    }
    
    return;
}

/*!
    @function fetchReminders
    @returns NSArray of EKReminders
    @abstract Fetch all reminders from Event Store
    @description use EventKit API to define a predicate to fetch all reminders from the 
        Event Store. Loop over current Run Loop until asynchronous reminder fetch is 
        completed.
 */
static NSArray* fetchReminders()
{
    __block NSArray *reminders = nil;
    __block BOOL fetching = YES;
    NSPredicate *predicate = [store predicateForRemindersInCalendars:nil];
    [store fetchRemindersMatchingPredicate:predicate completion:^(NSArray *ekReminders) {
        reminders = ekReminders;
        fetching = NO;
    }];

    while (fetching) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    
    return reminders;
}

/*!
    @function sortReminders
    @returns NSDictionary
    @param reminders
        NSArray of EKReminder instances
    @abstract Sort an array of reminders into a dictionary.
    @description Sort an array of EKReminder instances into a dictionary.
        The keys of the dictionary are reminder list (calendar) names, which is a property of each
        EKReminder. The values are arrays containing EKReminders that share a common calendar.
 */
static NSDictionary* sortReminders(NSArray *reminders)
{
    NSMutableDictionary *results = nil;
    if (reminders != nil && reminders.count > 0) {
        results = [NSMutableDictionary dictionary];
        for (EKReminder *r in reminders) {
            if (r.completed)
                continue;
            
            EKCalendar *calendar = [r calendar];
            if ([results objectForKey:calendar.title] == nil) {
                [results setObject:[NSMutableArray array] forKey:calendar.title];
            }
            NSMutableArray *calendarReminders = [results objectForKey:calendar.title];
            [calendarReminders addObject:r];
        }
    }
    return results;
}

/*!
 */
static void listReminders()
{
    NSLog(@"List Reminders");
}

/*!
 */
static void removeReminder()
{
    NSLog(@"Remove Reminders %@/%@", calendar, reminder_id);
}

/*!
 */
static void showReminder()
{
    NSLog(@"Show Reminders %@/%@", calendar, reminder_id);
}

/*!
 */
static void completeReminder()
{
    NSLog(@"Complete Reminders %@/%@", calendar, reminder_id);
}

/*!
 */
static void handleCommand()
{
    switch (command) {
        case CMD_LS:
            listReminders();
            break;
        case CMD_RM:
            removeReminder();
            break;
        case CMD_CAT:
            showReminder();
            break;
        case CMD_DONE:
            completeReminder();
            break;
        case CMD_HELP:
        case CMD_VERSION:
        case CMD_UNKNOWN:
            break;
    }

}

int main(int argc, const char * argv[])
{

    @autoreleasepool {
        parseArguments();

        store = [[EKEventStore alloc] initWithAccessToEntityTypes:EKEntityMaskReminder];
        
        NSArray *reminders = fetchReminders();
        calendars = sortReminders(reminders);
        
        handleCommand();
    }
    return 0;
}

