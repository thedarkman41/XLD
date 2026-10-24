//
//  XLDQueue.m
//  XLD
//
//  Created by tmkk on 07/11/17.
//  Copyright 2007 tmkk. All rights reserved.
//

#import "XLDQueue.h"
#import "XLDConverterTask.h"
#import "XLDCDDAResult.h"

extern int XLDDarkModeSupportEnabled;

@implementation XLDQueue

- (id)init
{
	[super init];
	[NSBundle loadNibNamed:@"Queue" owner:self];
	taskArr = [[NSMutableArray alloc] init];
	progressViewArr = [[NSMutableArray alloc] init];
	lock = [[NSLock alloc] init];
	busyDevices = [[NSCountedSet alloc] init];

	toolbarItems = [[NSMutableDictionary alloc] init];
	NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:@"CancelAllTasks"];
	[item setLabel:LS(@"Cancel All Tasks")];
	[item setImage:[NSImage imageNamed:@"cancel"]];
	[item setTarget:self];
	[item setAction:@selector(cancelAllTasks:)];
	[toolbarItems setObject:item forKey:@"CancelAllTasks"];
	[item release];
	
	NSToolbar *theBar = [[NSToolbar alloc] initWithIdentifier:@"XLDProgressToolbar"];
	[theBar setDelegate:self];
	[o_mainPanel setToolbar:theBar];
	[theBar release];
	selectedRow = -1;
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5
	if(XLDDarkModeSupportEnabled) {
		[[o_tableView superview] setWantsLayer:YES];
	}
#endif
	return self;
}

- (id)initWithDelegate:(id)del
{
	[self init];
	delegate = [del retain];
	return self;
}

- (void)dealloc
{
	[taskArr release];
	[progressViewArr release];
	if(delegate) [delegate release];
	[lock release];
	[busyDevices release];
	[toolbarItems release];
	[super dealloc];
}

/* A task may start when a thread is free and, if it reads a drive, when no
   other running task is already reading that drive. (SourceForge ticket #631) */
- (BOOL)canStartTask:(id)task
{
	if(threadsOccupied >= [delegate maxThreads]) return NO;
	NSString *key = [task atomicKey];
	if(!key) return YES;
	return ![busyDevices containsObject:key];
}

- (void)startTask:(id)task
{
	NSString *key = [task atomicKey];
	if(key) [busyDevices addObject:key];
	[task beginConvert];
	if(lowestActivePosition < [task position]) lowestActivePosition = [task position];
	threadsOccupied += [task threadsOccupied];
}

- (IBAction)test:(id)sender
{
	XLDConverterTask *task = [[XLDConverterTask alloc] initWithQueue:self];
	[taskArr addObject:task];
	[o_tableView reloadData];
	[task showProgressInView:o_tableView row:[taskArr count]-1];
	[task release];
}

- (void)convertFinished:(id)task
{
	[lock lock];
	int idx = [taskArr indexOfObject:task];
	XLDCDDARippingSession *rippingSession = [task rippingSession];
	cddaRipResult *result = [task cddaRipResult];
	int i;
	/*for(i=idx+1;i<[taskArr count];i++) {
		[[taskArr objectAtIndex:i] hideProgress];
		[[taskArr objectAtIndex:i] showProgressInView:o_tableView row:i-1];
	}*/
	if([task isActive]) threadsOccupied -= [task threadsOccupied];
	if([task isActive]) { NSString *k = [task atomicKey]; if(k) [busyDevices removeObject:k]; }
	[taskArr removeObjectAtIndex:idx];
	[o_tableView reloadData];
	
	for(i=0;(i<[taskArr count]) && (threadsOccupied < [delegate maxThreads]);i++) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		XLDConverterTask *nextTask = [taskArr objectAtIndex:i];
		if(![nextTask isActive] && [self canStartTask:nextTask]) {
			[self startTask:nextTask];
		}
		[pool release];
	}
	[o_tableView scrollRowToVisible:lowestActivePosition];
	[lock unlock];
	if(threadsOccupied == 0) {
		int errorCount = 0;
		for(i=[progressViewArr count]-1;i>=0;i--) {
			if([[progressViewArr objectAtIndex:i] tag]) {
				if(i != errorCount) {
					[[progressViewArr objectAtIndex:i] removeFromSuperview];
					[[progressViewArr objectAtIndex:i] setFrame:[o_tableView frameOfCellAtColumn:0 row:errorCount]];
					[o_tableView addSubview:[progressViewArr objectAtIndex:i]];
				}
				errorCount++;
			}
			else {
				[[progressViewArr objectAtIndex:i] removeFromSuperview];
				[progressViewArr removeObjectAtIndex:i];
			}
		}
		[o_tableView reloadData];
		if(!errorCount) {
			[o_mainPanel close];
			selectedRow = -1;
		}
		lowestActivePosition = errorCount;
		if(checkUpdateStatus) [delegate setCheckUpdateStatus:YES];
	}
	if(rippingSession) {
		if(result && result->pending) result->pending = NO;
		/* Only finalise/destroy this disc's ripping session once NO other queued
		   task still references it. Several tracks of one disc share one session;
		   "Cancel All Tasks" runs convertFinished: for all of them in a tight loop,
		   and without this guard the first one to see allTasksFinished would destroy
		   the session while the others still hold it, so their convertFinished:
		   messaged freed memory and crashed. */
		BOOL othersUseSession = NO;
		for(i=0;i<[taskArr count];i++) {
			if([[taskArr objectAtIndex:i] rippingSession] == rippingSession) { othersUseSession = YES; break; }
		}
		if(!othersUseSession && [rippingSession allTasksFinished]) {
			XLDCDDAResult *resultObj = [[rippingSession result] retain];
			[rippingSession destroy];
			[delegate discRippedWithResult:resultObj];
			[resultObj release];
		}
	}
}

- (void)addTask:(id)task
{
	if(!threadsOccupied) {
		checkUpdateStatus = [delegate checkUpdateStatus];
		if(checkUpdateStatus) [delegate setCheckUpdateStatus:NO];
	}
	[o_mainPanel makeKeyAndOrderFront:self];
	[lock lock];
	[taskArr addObject:task];
	[progressViewArr addObject:[task progressView]];
	[o_tableView reloadData];
	[task showProgressInView:o_tableView row:[progressViewArr count]-1];
	if([self canStartTask:task]) {
		[self startTask:task];
	}
	[lock unlock];
}

- (void)addTasks:(NSArray *)tasks
{
	if(!threadsOccupied) {
		checkUpdateStatus = [delegate checkUpdateStatus];
		if(checkUpdateStatus) [delegate setCheckUpdateStatus:NO];
	}
	[o_mainPanel makeKeyAndOrderFront:self];
	int i;
	[lock lock];
	for(i=0;i<[tasks count];i++) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		id task = [tasks objectAtIndex:i];
		[taskArr addObject:task];
		[progressViewArr addObject:[task progressView]];
		[o_tableView reloadData];
		[task showProgressInView:o_tableView row:[progressViewArr count]-1];
		if([self canStartTask:task]) {
			[self startTask:task];
		}
		[pool release];
	}
	[lock unlock];
}

- (void)showProgress
{
	[o_mainPanel makeKeyAndOrderFront:self];
}

- (int)numberOfRowsInTableView:(NSTableView *)tableView
{
	return [progressViewArr count];
}

- (id)tableView:(NSTableView *)tableView
		objectValueForTableColumn:(NSTableColumn *)tableColumn
			row:(int)row
{
	return nil;
}

- (void)tableViewSelectionDidChange:(NSNotification *)aNotification
{
	if([aNotification object] == o_tableView) {
		if([o_tableView numberOfSelectedRows] != 0) {
			int idx = [o_tableView selectedRow];
			if(selectedRow >= 0 && selectedRow < [taskArr count]) {
				[[taskArr objectAtIndex:selectedRow] taskDeselected];
			}
			if(idx < [taskArr count]) {
				[[taskArr objectAtIndex:idx] taskSelected];
			}
			selectedRow = idx;
		}
		else {
			if(selectedRow >= 0 && selectedRow <  [taskArr count]) {
				[[taskArr objectAtIndex:selectedRow] taskDeselected];
			}
			selectedRow = -1;
		}
	}
}

- (IBAction)cancelAllTasks:(id)sender
{
	int i;
	//[lock lock];
	for(i=[taskArr count]-1;i>=0;i--) {
		id task = [taskArr objectAtIndex:i];
		[task stopConvert:nil];
	}
	[o_tableView reloadData];
	//[lock unlock];
}

- (void)setMenuForItem:(id)item
{
	[item setMenu:o_menu];
}

- (void)windowWillClose:(NSNotification *)notification
{
	if(threadsOccupied) return;
	int i;
	for(i=[progressViewArr count]-1;i>=0;i--) {
		[[progressViewArr objectAtIndex:i] removeFromSuperview];
	}
	[progressViewArr removeAllObjects];
	[o_tableView reloadData];
	lowestActivePosition = 0;
	selectedRow = -1;
}

- (BOOL)hasActiveTask
{
	return (threadsOccupied > 0);
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSString *)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag
{
	return [toolbarItems objectForKey:itemIdentifier];
}

-(NSArray *) toolbarDefaultItemIdentifiers:(NSToolbar*)toolbar
{
	return [NSArray arrayWithObjects:NSToolbarFlexibleSpaceItemIdentifier,@"CancelAllTasks",nil];
}

-(NSArray *) toolbarAllowedItemIdentifiers:(NSToolbar*)toolbar
{
	return [NSArray arrayWithObjects:NSToolbarFlexibleSpaceItemIdentifier,@"CancelAllTasks",nil];
}

- (BOOL)validateToolbarItem:(NSToolbarItem *)theItem
{
	if([[theItem itemIdentifier] isEqualToString:@"CancelAllTasks"]) return (threadsOccupied > 0);
	return YES;
}

@end
