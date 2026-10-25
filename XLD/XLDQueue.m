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

	NSToolbarItem *clearItem = [[NSToolbarItem alloc] initWithItemIdentifier:@"ClearCompleted"];
	[clearItem setLabel:LS(@"Clear Completed")];
	NSImage *clearImg = nil;
	if([NSImage respondsToSelector:@selector(imageWithSystemSymbolName:accessibilityDescription:)])
		clearImg = [NSImage imageWithSystemSymbolName:@"trash" accessibilityDescription:LS(@"Clear Completed")];
	[clearItem setImage:clearImg ? clearImg : [NSImage imageNamed:@"cancel"]];
	[clearItem setTarget:self];
	[clearItem setAction:@selector(clearCompletedTasks:)];
	[toolbarItems setObject:clearItem forKey:@"ClearCompleted"];
	[clearItem release];

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
	NSString *key = [task atomicKey];
	if(key) {
		/* A drive-reading (rip) task starts whenever its own drive is free, so
		   discs in different drives rip in parallel regardless of the encoder
		   "Maximum #Threads" limit (that limit is about CPU encode threads, not
		   independent optical drives). One rip per drive still holds via
		   busyDevices (SourceForge ticket #631). */
		return ![busyDevices containsObject:key];
	}
	/* Non-drive tasks (transcode/encode of files) honour Maximum #Threads. */
	if(threadsOccupied >= [delegate maxThreads]) return NO;
	return YES;
}

- (void)startTask:(id)task
{
	NSString *key = [task atomicKey];
	if(key) {
		[busyDevices addObject:key];
		/* Let the disc view start its busy-drive Cylon sweep. */
		if([delegate respondsToSelector:@selector(queueBusyDevicesChanged)])
			[delegate queueBusyDevicesChanged];
	}
	[task beginConvert];
	if(lowestActivePosition < [task position]) lowestActivePosition = [task position];
	threadsOccupied += [task threadsOccupied];
}

- (BOOL)isDeviceBusy:(NSString *)dev
{
	return (dev && [busyDevices containsObject:dev]);
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
	/* Grey the track only on a genuine success. A cancelled or errored task
	   returns its track to the normal (un-greyed) state. */
	{
		BOOL errored = ([task progressView] && [[task progressView] tag] != 0);
		/* Grey only a task that actually ran to a successful finish. A task that
		   never started (cancelled while waiting), was cancelled mid-rip, or
		   errored returns its track to the normal state. */
		[[task track] setRipState:(![task isActive] || [task wasCancelled] || errored) ? 0 : 3];
	}
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

	/* A task the user removed (the row's × button, or Cancel All Tasks) drops its
	   row entirely and the rows below slide up to fill the gap. A task that
	   finished on its own keeps its row (it shows "Completed"/error until the
	   queue goes idle or the user hits Clear Completed). */
	if([task wasCancelled]) {
		NSView *pv = [task progressView];
		int vIdx = pv ? [progressViewArr indexOfObject:pv] : NSNotFound;
		if(vIdx != NSNotFound) {
			[pv removeFromSuperview];
			[progressViewArr removeObjectAtIndex:vIdx];
			[o_tableView reloadData];
			[self relayoutProgressViewsAnimated:YES];
		}
	}
	
	/* Consider every queued task; canStartTask: applies the right gate per task
	   (drive-free for rips, Maximum #Threads for file transcodes), so rips in
	   other drives resume in parallel rather than one-at-a-time. */
	for(i=0;i<[taskArr count];i++) {
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

/* Reposition every progress row to its slot. Animated gives the slide-up when a
   row above it is removed; the rows are manual subviews over an empty cell-based
   table, so they are moved by frame rather than by the table itself. */
- (void)relayoutProgressViewsAnimated:(BOOL)animated
{
	int i;
	if(animated) {
		[NSAnimationContext beginGrouping];
		[[NSAnimationContext currentContext] setDuration:0.22];
	}
	for(i=0;i<[progressViewArr count];i++) {
		NSView *v = [progressViewArr objectAtIndex:i];
		NSRect f = [o_tableView frameOfCellAtColumn:0 row:i];
		if(animated) [[v animator] setFrame:f];
		else [v setFrame:f];
	}
	if(animated) [NSAnimationContext endGrouping];
	/* Keep each live task's row index in sync with its new slot. */
	for(i=0;i<[taskArr count];i++) {
		id t = [taskArr objectAtIndex:i];
		int vIdx = [progressViewArr indexOfObject:[t progressView]];
		if(vIdx != NSNotFound) [t setPosition:vIdx];
	}
}

/* Drop every finished row (completed or errored — anything no longer among the
   active/waiting tasks) and slide the rest up. */
- (IBAction)clearCompletedTasks:(id)sender
{
	[lock lock];
	int i,j;
	for(i=[progressViewArr count]-1;i>=0;i--) {
		NSView *v = [progressViewArr objectAtIndex:i];
		BOOL active = NO;
		for(j=0;j<[taskArr count];j++) {
			if([[taskArr objectAtIndex:j] progressView] == v) { active = YES; break; }
		}
		if(!active) {
			[v removeFromSuperview];
			[progressViewArr removeObjectAtIndex:i];
		}
	}
	[o_tableView reloadData];
	[self relayoutProgressViewsAnimated:YES];
	if(![progressViewArr count]) {
		[o_mainPanel close];
		selectedRow = -1;
		lowestActivePosition = 0;
	}
	[lock unlock];
}

- (void)setMenuForItem:(id)item
{
	[item setMenu:o_menu];
}

/* Context menu for one task's progress rows: a copy of the shared menu plus a
   "Locate in Finder" item that reveals that task's output (targeted at the task
   so the right-clicked row resolves correctly). */
- (NSMenu *)contextMenuForTask:(id)task
{
	NSMenu *m = o_menu ? [[o_menu copy] autorelease] : [[[NSMenu alloc] initWithTitle:@""] autorelease];
	if([m numberOfItems] > 0) [m addItem:[NSMenuItem separatorItem]];
	NSMenuItem *locate = [[[NSMenuItem alloc] initWithTitle:LS(@"Locate in Finder") action:@selector(locateInFinder:) keyEquivalent:@""] autorelease];
	[locate setTarget:task];
	[m addItem:locate];
	return m;
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
	return [NSArray arrayWithObjects:NSToolbarFlexibleSpaceItemIdentifier,@"ClearCompleted",@"CancelAllTasks",nil];
}

-(NSArray *) toolbarAllowedItemIdentifiers:(NSToolbar*)toolbar
{
	return [NSArray arrayWithObjects:NSToolbarFlexibleSpaceItemIdentifier,@"ClearCompleted",@"CancelAllTasks",nil];
}

- (BOOL)validateToolbarItem:(NSToolbarItem *)theItem
{
	if([[theItem itemIdentifier] isEqualToString:@"CancelAllTasks"]) return (threadsOccupied > 0);
	/* Enabled whenever there is at least one finished row (more rows shown than
	   active/waiting tasks) to clear. */
	if([[theItem itemIdentifier] isEqualToString:@"ClearCompleted"]) return ([progressViewArr count] > [taskArr count]);
	return YES;
}

@end
