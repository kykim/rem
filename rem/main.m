//
//  main.m
//  rem
//
//  Created by Kevin Y. Kim on 10/15/12.
//  Copyright (c) 2012 kykim, inc. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <EventKit/EventKit.h>

#define COMMANDS @[ @"ls", @"add", @"rm", @"cat", @"done", @"help", @"version", @"orgmode", @"parseorg"]
typedef enum _CommandType {
    CMD_UNKNOWN = -1,
    CMD_LS = 0,
    CMD_ADD,
    CMD_RM,
    CMD_CAT,
    CMD_DONE,
    CMD_HELP,
    CMD_VERSION,
    CMD_ORGMODE,
    CMD_PARSEORG
} CommandType;

static CommandType command;
static NSString *calendar;
static NSString *reminder_id;

static EKEventStore *store;
static NSDictionary *calendars;
static EKReminder *reminder;

#define TACKER @"├──"
#define CORNER @"└──"
#define PIPER  @"│  "
#define SPACER @"   "

// For OrgMode
static bool scheduleWithTime = false; // show time in scheduled alarm
static bool showCompleted = false; // show completed tasks
static NSString *orgFile; // output file, if nil -> stdout

/*!
    @function _print
    @abstract Wrapper for fprintf with NSString format
    @param stream
        Output stream to write to
    @param format
        (f)printf style format string
    @param ...
        optional arguments as defined by format string
    @discussion Wraps call to fprintf with an NSString format argument, permitting use of the
        object formatter '%@'
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
    _print(stdout, @"rem Version 0.02\n");
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
    _print(stdout, @"\trem add [reminder]\n");
    _print(stdout, @"\t\tAdd reminder to your default list\n");
    _print(stdout, @"\trem cat [list] [item]\n");
    _print(stdout, @"\t\tShow reminder detail\n");
    _print(stdout, @"\trem done [list] [item]\n");
    _print(stdout, @"\t\tMark reminder as complete\n");
    _print(stdout, @"\trem help\n");
    _print(stdout, @"\t\tShow this text\n");
    _print(stdout, @"\trem version\n");
    _print(stdout, @"\t\tShow version information\n");

    _print(stdout, @"Org-mode features:\n");
    _print(stdout, @"\trem orgmode\n");
    _print(stdout, @"\t\tPrints org-mode files\n");
    _print(stdout, @"\trem parseorg\n");
    _print(stdout, @"\t\tParses a JSON file exported from org-export-json and makes changes to calendars.\n");
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

    // if we're adding a reminder, overload reminder_id to hold the reminder text (title)
    if (command == CMD_ADD) {
        reminder_id = [[args subarrayWithRange:NSMakeRange(1, [args count]-1)] componentsJoinedByString:@" "];
        return;
    }

    // OrgMode settings
    if (command == CMD_ORGMODE || command == CMD_PARSEORG) {
        showCompleted = true;

        if(args.count >= 2)
            orgFile = [args objectAtIndex:1];
        
        return;
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
    @abstract Sort an array of reminders into a dictionary.
    @returns NSDictionary
    @param reminders
        NSArray of EKReminder instances
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
            if (!showCompleted && r.completed)
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
    @function validateArguments
    @abstract Verfy the (reminder) list and reminder_id command-line arguments
    @description If provided, verify that the (reminder) list and reminder_id
        command-line arguments are valid. Compare the (reminder) list to the keys
        of the calendars dictionary. Verify the integer value of the reminder_id
        is within the index range of the appropriate calendar array.
 */
static void validateArguments()
{ 
    if (command == CMD_LS && calendar == nil)
        return;
    
    if (command == CMD_ORGMODE && calendar == nil)
        return;

    if (command == CMD_PARSEORG && calendar == nil && orgFile != nil)
        return;

    if (command == CMD_PARSEORG && orgFile == nil)
    {
        _print(stderr, @"rem: Error - did not specify org file.\n");
        exit(-1);
    }

    if (command == CMD_ADD)
        return;

    NSUInteger calendar_id = [[calendars allKeys] indexOfObject:calendar];
    if (calendar_id == NSNotFound) {
        _print(stderr, @"rem: Error - Unknown Reminder List: \"%@\"\n", calendar);
        exit(-1);
    }

    if (command == CMD_LS && reminder_id == nil)
        return;

    NSInteger r_id = [reminder_id integerValue] - 1;
    NSArray *reminders = [calendars objectForKey:calendar];
    if (r_id < 0 || r_id > reminders.count-1) {
        _print(stderr, @"rem: Error - ID Out of Range for Reminder List: %@\n", calendar);
        exit(-1);
    }
    reminder = [reminders objectAtIndex:r_id];
}

/*!
    @function _printCalendarLine
    @abstract format and output line containing calendar (reminder list) name
    @param line
        line to output
    @param last
        is this the last calendar being diplayed?
    @description format and output line containing calendar (reminder list) name.
        If it is the last calendar being displayed, prefix the name with a corner
        unicode character. If it is not the last calendar, prefix the name with a
        right-tack unicode character. Both prefix unicode characters are followed
        by two horizontal lines, also unicode.
 */
static void _printCalendarLine(NSString *line, BOOL last)
{
    NSString *prefix = (last) ? CORNER : TACKER;
    _print(stdout, @"%@ %@\n", prefix, line);
}

/*!
    @function _printReminderLine
    @abstract format and output line containing reminder information
    @param line
        line to output
    @param last
        is this the last reminder being diplayed?
    @param lastCalendar
        does this reminder belong to last calendar being displayed?
    @description format and output line containing reminder information.
        If it is the last reminder being displayed, prefix the name with a corner
        unicode character. If it is not the last reminder, prefix the name with a
        right-tack unicode character. Both prefix unicode characters are followed
        by two horizontal lines, also unicode. Also, indent the reminder with either
        blank space, if part of last calendar; or vertical bar followed by blank space.
 */
static void _printReminderLine(NSUInteger id, NSString *line, BOOL last, BOOL lastCalendar)
{
    NSString *indent = (lastCalendar) ? SPACER : PIPER;
    NSString *prefix = (last) ? CORNER : TACKER;
    _print(stdout, @"%@%@ %ld. %@\n", indent, prefix, id, line);
}

/*!
    @function _listCalendar
    @abstract output a calaendar and its reminders
    @param cal
        name of calendar (reminder list)
    @param last
        is this the last calendar being displayed?
    @description given a calendar (reminder list) name, output the calendar via
        _printCalendarLine. Retrieve the calendars reminders and display via _printReminderLine.
        Each reminder is prepended with an index/id for other commands
 */
static void _listCalendar(NSString *cal, BOOL last)
{
    _printCalendarLine(cal, last);
    NSArray *reminders = [calendars valueForKey:cal];
    for (NSUInteger i = 0; i < reminders.count; i++) {
        EKReminder *r = [reminders objectAtIndex:i];
        _printReminderLine(i+1, r.title, (r == [reminders lastObject]), last);
    }
}

/*!
    @function listReminders
    @abstract list reminders
    @description list all reminders if no calendar (reminder list) specified,
        or list reminders in specified calendar
 */
static void listReminders()
{
    _print(stdout, @"Reminders\n");
    if (calendar) {
        _listCalendar(calendar, YES);
    }
    else {
        for (NSString *cal in calendars) {
            _listCalendar(cal, (cal == [[calendars allKeys] lastObject]));
        }
    }
}

/*!
    @function addReminder
    @abstract add a reminder
    @description add a reminder to the default calendar
 */
static void addReminder()
{
    reminder = [EKReminder reminderWithEventStore:store];
    reminder.calendar = [store defaultCalendarForNewReminders];
    reminder.title = reminder_id;

    NSError *error;
    BOOL success = [store saveReminder:reminder commit:YES error:&error];
    if (!success) {
        _print(stderr, @"rem: Error adding Reminder (%@)\n\t%@", reminder_id, [error localizedDescription]);
    }
}

/*!
    @function removeReminder
    @abstract remove a specified reminder
    @description remove a specified reminder
 */
static void removeReminder()
{
    NSError *error;
    BOOL success = [store removeReminder:reminder commit:YES error:&error];
    if (!success) {
        _print(stderr, @"rem: Error removing Reminder (%@) from list %@\n\t%@", reminder_id, calendar, [error localizedDescription]);
    }
}

/*!
    @function showReminder
    @abstract show reminder details
    @description show reminder details: creation date, last modified date (if different than
        creation date), start date (if defined), due date (if defined), notes (if defined)
 */
static void showReminder()
{
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateStyle:NSDateFormatterShortStyle];

    _print(stdout, @"Reminder: %@\n", reminder.title);
    _print(stdout, @"\tList: %@\n", calendar);

    _print(stdout, @"\tCreated On: %@\n", [dateFormatter stringFromDate:reminder.creationDate]);

    if (reminder.lastModifiedDate != reminder.creationDate) {
        _print(stdout, @"\tLast Modified On: %@\n", [dateFormatter stringFromDate:reminder.lastModifiedDate]);
    }

    NSDate *startDate = [reminder.startDateComponents date];
    if (startDate) {
        _print(stdout, @"\tStarted On: %@\n", [dateFormatter stringFromDate:startDate]);
    }

    NSDate *dueDate = [reminder.dueDateComponents date];
    if (dueDate) {
        _print(stdout, @"\tDue On: %@\n", [dateFormatter stringFromDate:dueDate]);
    }

    if (reminder.hasNotes) {
        _print(stdout, @"\tNotes: %@\n", reminder.notes);
    }
}

/*!
    @function completeReminder
    @abstract mark specified reminder as complete
    @description mark specified reminder as complete
 */
static void completeReminder()
{
    reminder.completed = YES;
    NSError *error;
    BOOL success = [store saveReminder:reminder commit:YES error:&error];
    if (!success) {
        _print(stderr, @"rem: Error marking Reminder (%@) from list %@\n\t%@", reminder_id, calendar, [error localizedDescription]);
    }
}

/*!
    @function printOrgMode
    @abstract print reminder lists as org-mode syntax
    @description print reminder lists as org-mode syntax
 */
static void printOrgMode()
{
    NSFileHandle* fileHandle;

    if(orgFile)
    {
        [[NSFileManager defaultManager] createFileAtPath:orgFile contents:nil attributes:nil];
        fileHandle = [NSFileHandle fileHandleForWritingAtPath:orgFile];
    }
    else
    {
        fileHandle = [NSFileHandle fileHandleWithStandardOutput];
    }

    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm"];

    NSDateFormatter *dateFormatterSchedule = [[NSDateFormatter alloc] init];
    if(scheduleWithTime)
        [dateFormatterSchedule setDateFormat:@"yyyy-MM-dd HH:mm"];
    else
        [dateFormatterSchedule setDateFormat:@"yyyy-MM-dd"];

    for (NSString *cal in calendars) {
        bool last = (cal == [[calendars allKeys] lastObject]);

        [fileHandle writeData:[[NSString stringWithFormat:@"* %@\n", cal] dataUsingEncoding:NSUTF8StringEncoding]];
        NSArray *reminders = [calendars valueForKey:cal];
        for (NSUInteger i = 0; i < reminders.count; i++) {
            EKReminder *reminder = [reminders objectAtIndex:i];

            {
                // priority seems to be:
                // high = 1
                // medium = 5
                // low = 9
                NSString* priority = @"";
                switch(reminder.priority)
                {
                case 1:
                    priority = @"[#A] ";
                    break;
                case 5:
                    priority = @"[#B] ";
                    break;
                case 9:
                    priority = @"[#C] ";
                    break;
                default:
                    break;
                }

                NSString* flag = @"TODO";
                if(reminder.completed)
                    flag = @"DONE";
                
                [fileHandle writeData:[[NSString stringWithFormat:@"** %@ %@%@\n", flag, priority, reminder.title] dataUsingEncoding:NSUTF8StringEncoding]];

                if (reminder.completed) {
                    [fileHandle writeData:[[NSString stringWithFormat: @"CLOSED: [%@] ", [dateFormatter stringFromDate:reminder.completionDate]] dataUsingEncoding:NSUTF8StringEncoding]];
                }

                NSArray *alarms = reminder.alarms;

                for(NSUInteger j = 0; j < alarms.count; j++)
                {
                    EKAlarm *alarm = [alarms objectAtIndex:j];
                    NSDate *dueDate = alarm.absoluteDate;
                    
                    if (dueDate) {
                        [fileHandle writeData:[[NSString stringWithFormat: @"SCHEDULED: <%@>", [dateFormatterSchedule stringFromDate:dueDate]] dataUsingEncoding:NSUTF8StringEncoding]];
                    }
                }

                [fileHandle writeData:[[NSString stringWithFormat:@"\n:LOGBOOK:\nUNIQUEID: %@\n:END:\n", reminder.calendarItemIdentifier] dataUsingEncoding:NSUTF8StringEncoding]];

                [fileHandle writeData:[[NSString stringWithFormat:@"Created: [%@]\n", [dateFormatter stringFromDate:reminder.creationDate]] dataUsingEncoding:NSUTF8StringEncoding]];

                if (reminder.lastModifiedDate != reminder.creationDate) {
                    [fileHandle writeData:[[NSString stringWithFormat:@"Modified: [%@]\n", [dateFormatter stringFromDate:reminder.lastModifiedDate]] dataUsingEncoding:NSUTF8StringEncoding]];
                }

                NSDate *startDate = [reminder.startDateComponents date];
                if (startDate) {
                    [fileHandle writeData:[[NSString stringWithFormat: @"Started On: [%@]\n", [dateFormatter stringFromDate:startDate]] dataUsingEncoding:NSUTF8StringEncoding]];
                }

                if (reminder.hasNotes) {
                    [fileHandle writeData:[[NSString stringWithFormat:@"%@\n", reminder.notes] dataUsingEncoding:NSUTF8StringEncoding]];
                }

                
            }
        }
    }
}
/*!
    @function parseOrgMode
    @abstract parses JSON files in org-mode syntax and adds changes to reminder lists
    @description parses JSON files in org-mode syntax and adds changes to reminder lists
 */
static void parseOrgMode()
{
    NSFileHandle* fileHandle = [NSFileHandle fileHandleForReadingAtPath:orgFile];
    NSData *returnedData = [fileHandle readDataToEndOfFile];
    if(!returnedData)
    {
        _print(stderr, @"rem: Error - could not read .org.json file.\n");
        exit(-1);
    }

    if(NSClassFromString(@"NSJSONSerialization"))
    {
        NSError *error = nil;
        id object = [NSJSONSerialization
                      JSONObjectWithData:returnedData
                                 options:0
                                   error:&error];

        if(error)
        {
            _print(stderr, @"rem: Error - .org.json file seems not to be a valid JSON file.\n");
            exit(-1);
        }


        if([object isKindOfClass:[NSArray class]])
        {
            NSArray *results = object;
            // results[0] == "org-data"
            // results[1] == ""
            // results[2..n] == calendars 
            if([results[0] isEqualToString:@"org-data"])
            {
                // each for-loop runthrough is one calendar
                for (NSUInteger i = 2; i < results.count; i++) {
                    NSArray *calendar = results[i];
                    // calendar[0] == "headline"
                    // calendar[1] == NSDictionary with title of calendar
                    // calendar[2..n] == NSArray with reminders for this calendar
                    if([calendar[0] isEqualToString:@"headline"])
                    {
                        NSString* calendarName = calendar[1][@"title"][0];
                        for (NSUInteger j = 2; j < calendar.count; j++) {
                            NSArray *reminder = calendar[j];
                            // reminder[0] == "headline"
                            // reminder[1] == NSDictionary containing title of reminder as well as TODO/DONE status
                            // reminder[2..n] == NSArray of sections
                            NSString *reminderName = reminder[1][@"title"][0];

                            bool completed = false;
                            NSString* todo_keyword = reminder[1][@"todo-keyword"];
                            if([todo_keyword isEqualToString:@"DONE"])
                                completed = true;

                            id prio = reminder[1][@"priority"];
                            int priority = 0;
                            if([prio isKindOfClass:[NSNumber class]])
                            {
                                // ASCII
                                priority = [prio intValue];

                                if(priority == 65) // A
                                    priority = 1;
                                if(priority == 66) // B
                                    priority = 5;
                                if(priority == 67) // C
                                    priority = 9;
                            }


                            NSString* unique_id;
                            NSDate* createdDate;
                            NSDate* modifiedDate;
                            NSDate* scheduledDate;
                            NSDate* completedDate;
                            NSString* notes = @"";

                            for (NSUInteger k = 2; k < reminder.count; k++)
                            {
                                NSArray* sections = reminder[k];
                                // sections[0] == "section"
                                // sections[1] == uninteresting meta data
                                // sections[2..n] ==
                                // one element is called drawer -> search for apple id
                                // one element is called paragraph -> contains element like schedule etc
                                for (NSUInteger l = 2; l < sections.count; l++)
                                {
                                    NSArray* section = sections[l];
                                    
                                    //NSLog(@"%@", section);
                                    // section[0] == "drawer" or "paragraph" or "planning"
                                    // section[1] == NSDictionary with meta data about section, such as drawer-name
                                    // section[2..n] == NSArray with data in section
                                    if([section[0] isEqualToString:@"drawer"])
                                    {
                                        NSString* sectionName = section[1][@"drawer-name"];
                                        if([sectionName isEqualToString:@"LOGBOOK"])
                                        {
                                            NSArray* drawerContent = section[2];
                                            // data is kind of cryptic again
                                            // drawerContent[0] == "paragraph"
                                            // drawerContent[1..n] ==
                                            // elements where one element:
                                            //     x == "UNIQUEID: " + id + "\n"

                                            for (NSUInteger m = 1; m < drawerContent.count; m++)
                                            {
                                                if(![drawerContent[m] isKindOfClass:[NSString class]])
                                                    continue;

                                                if([drawerContent[m] hasPrefix:@"UNIQUEID: "])
                                                {
                                                    unique_id = drawerContent[m];
                                                    break;
                                                }
                                            }

                                            // format the string
                                            // assumes ": " in front and "\n" in end. removes exactly that.
                                            if(unique_id)
                                            {
                                                unique_id = [unique_id substringToIndex:[unique_id length]-1];
                                                unique_id = [unique_id substringFromIndex:10];
                                            }
                                        }
                                        else
                                        {
                                            // only interested in logbook
                                        }
                                    }
                                    else if([section[0] isEqualToString:@"planning"])
                                    {
                                        NSDictionary* plans = section[1];

                                        // does not support deadlines
                                        if(plans[@"scheduled"] &&
                                               [plans[@"scheduled"] isKindOfClass:[NSArray class]])
                                        {
                                            NSString* dateString;
                                            // only handle timestamps
                                            if([plans[@"scheduled"][0] isEqualToString:@"timestamp"])
                                            {
                                                dateString = plans[@"scheduled"][1][@"raw-value"];
                                                dateString = [dateString stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"[]<>"]];

                                                NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
                                                [dateFormatter setDateFormat:@"yyyy-MM-dd"];
                                                [dateFormatter setTimeZone:[NSTimeZone timeZoneWithName:@"GMT"]];

                                                NSDate* date = [dateFormatter dateFromString:dateString];
                                                if(date == nil)
                                                {
                                                    [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm"];
                                                    date = [dateFormatter dateFromString:dateString];
                                                }
                                                if(date == nil)
                                                {
                                                    [dateFormatter setDateFormat:@"yyyy-MM-dd EEE"];
                                                    date = [dateFormatter dateFromString:dateString];
                                                }
                                                if(date == nil)
                                                {
                                                    [dateFormatter setDateFormat:@"yyyy-MM-dd EEE HH:mm"];
                                                    date = [dateFormatter dateFromString:dateString];
                                                }
                                                scheduledDate = date;
                                            }
                                        }

                                        if(plans[@"closed"] &&
                                               [plans[@"closed"] isKindOfClass:[NSArray class]])
                                        {
                                            NSString* dateString;
                                            // only handle timestamps
                                            if([plans[@"closed"][0] isEqualToString:@"timestamp"])
                                            {

                                                dateString = plans[@"closed"][1][@"raw-value"];
                                                dateString = [dateString stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"[]<>"]];
                                                //NSLog(@"close date: %@", dateString);
                                                NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
                                                [dateFormatter setDateFormat:@"yyyy-MM-dd"];
                                                [dateFormatter setTimeZone:[NSTimeZone timeZoneWithName:@"GMT"]];

                                                NSDate* date = [dateFormatter dateFromString:dateString];
                                                if(date == nil)
                                                {
                                                    [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm"];
                                                    date = [dateFormatter dateFromString:dateString];
                                                }
                                                if(date == nil)
                                                {
                                                    [dateFormatter setDateFormat:@"yyyy-MM-dd EEE"];
                                                    date = [dateFormatter dateFromString:dateString];
                                                }
                                                if(date == nil)
                                                {
                                                    [dateFormatter setDateFormat:@"yyyy-MM-dd EEE HH:mm"];
                                                    date = [dateFormatter dateFromString:dateString];
                                                }
                                                completedDate = date;
                                            }
                                        }
                                    }
                                    else if([section[0] isEqualToString:@"paragraph"])
                                    {
                                        // metadata of paragraph uninteresting. jump to its array directly
                                        for (NSUInteger m = 2; m < section.count; m++)
                                        {
                                            // if an element has sub-metadata, it resides in m+1
                                            // this is a little bit inconvenient
                                            NSString* paragraphElementName = section[m];

                                            // if name != NSString, then this is metadata
                                            if(![paragraphElementName isKindOfClass:[NSString class]])
                                            {
                                                continue;
                                            }

                                            // format
                                            paragraphElementName = [paragraphElementName stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@": \n"]];

                                            // avoid out of border things
                                            if(m+1 < section.count)
                                            {
                                                // if next element is meta data
                                                if([section[m+1] isKindOfClass:[NSArray class]])
                                                {
                                                    NSString* dateString;
                                                    // only handle timestamps
                                                    if([section[m+1][0] isEqualToString:@"timestamp"])
                                                    {
                                                        dateString = section[m+1][1][@"raw-value"];
                                                        dateString = [dateString stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"[]<>"]];

                                                        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
                                                        [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm"];
                                                        [dateFormatter setTimeZone:[NSTimeZone timeZoneWithName:@"GMT"]];
                                            
                                                        NSDate* date = [dateFormatter dateFromString:dateString];


                                                        //NSLog(@"%@", dateString);
                                                        if(date == nil)
                                                        {
                                                            [dateFormatter setDateFormat:@"yyyy-MM-dd"];
                                                            date = [dateFormatter dateFromString:dateString];
                                                        }

                                                        if(date == nil)
                                                        {
                                                            [dateFormatter setDateFormat:@"yyyy-MM-dd EEE"];
                                                            date = [dateFormatter dateFromString:dateString];
                                                        }

                                                        if(date == nil)
                                                        {
                                                            [dateFormatter setDateFormat:@"yyyy-MM-dd EEE HH:mm"];
                                                            date = [dateFormatter dateFromString:dateString];
                                                        }
                                                       
                                            
                                                        //NSLog(@"%@", date);


                                                        if([paragraphElementName isEqualToString:@"Modified"])
                                                        {
                                                            modifiedDate = date;
                                                        }
                                                        if([paragraphElementName isEqualToString:@"Created"])
                                                        {
                                                            createdDate = date;
                                                        }

                                                        // We continue for loop here. Everything which wasn't a
                                                        // timestamp gets added to note.
                                                        continue;
                                                    }
                                                }
                                            }

                                            if(![paragraphElementName isEqualToString:@"\n"])
                                                notes = [NSString stringWithFormat:@"%@\n%@", notes, paragraphElementName];
                                        }
                                    }
                                    else
                                    {
                                        // ignore other sections
                                    }
                                }
                            }

                            // We collected all data about this reminder on the way.
                            // Update it!
                            
                            // NSLog(@"Calendar: %@", calendarName);
                            // NSLog(@"Reminder Name: %@", reminderName);
                            // NSLog(@"Completion status: %d", completed);
                            // NSLog(@"Priority: %d", priority);
                            // NSLog(@"Created: %@", createdDate);
                            // NSLog(@"Modified: %@", modifiedDate);
                            // NSLog(@"Scheduled: %@", scheduledDate);
                            // NSLog(@"Completed: %@", completedDate);
                            // NSLog(@"Notes: %@", notes);
                            // NSLog(@"Unique ID: %@\n\n", unique_id);

                            EKReminder* original = (EKReminder *)[store calendarItemWithIdentifier:unique_id];

                            if(original)
                            {
                                original.title = reminderName;
                                original.priority = priority;
                                original.notes = notes;

                                // Read only variables (logically)
                                // original.creationDate = createdDate;
                                // original.lastModifiedDate = modifiedDate;


                                original.completed = completed ? YES : NO;
                                if(original.completed)
                                {
                                    original.completionDate = completedDate;
                                }

                                if(scheduledDate != nil)
                                {
                                    for(EKAlarm *alarm in original.alarms)
                                    {
                                        [original removeAlarm:alarm];
                                    }

                                    EKAlarm *alarm = [EKAlarm alarmWithAbsoluteDate:scheduledDate];
                                    [original addAlarm:alarm];
                                }

                                BOOL success = [store saveReminder:original commit:YES error:&error];
                                if (!success) {
                                    _print(stderr, @"rem: Error updating Reminder (%@)\n\t%@", unique_id, [error localizedDescription]);
                                }
                                
                            }
                            else
                            {
                                _print(stderr, @"rem: Error - could not find unique ID in database\n");
                                // don't exit, just skip
                            }
    
                        }
                    }
                    else
                    {
                        _print(stderr, @"rem: Error - .org.json file seems not to be a valid JSON file.\n");
                        exit(-1);
                    }
                }
            }
            else
            {
                _print(stderr, @"rem: Error - .org.json file seems not to be a valid JSON file.\n");
                exit(-1);
            }
        }
        else
        {
            NSLog(@"test");
        }
    }
    
    /*

BOOL success = [store saveReminder:reminder commit:YES error:&error];
    if (!success) {
        _print(stderr, @"rem: Error marking Reminder (%@) from list %@\n\t%@", reminder_id, calendar, [error localizedDescription]);
    }

     */
}

/*!
    @function handleCommand
    @abstract dispatch to correct function based on command-line argument
    @description dispatch to correct function based on command-line argument
 */
static void handleCommand()
{
    switch (command) {
    case CMD_LS:
        listReminders();
        break;
    case CMD_ADD:
        addReminder();
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
    case CMD_ORGMODE:
        printOrgMode();
        break;
    case CMD_PARSEORG:
        parseOrgMode();
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

        if (command != CMD_ADD) {
            NSArray *reminders = fetchReminders();
            calendars = sortReminders(reminders);
        }

        validateArguments();
        handleCommand();
    }
    return 0;
}

