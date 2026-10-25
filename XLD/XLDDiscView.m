//
//  XLDDiscView.m
//  XLD
//
//  Created by tmkk on 11/03/06.
//  Copyright 2011 tmkk. All rights reserved.
//

#import <DiscRecording/DiscRecording.h>
#import <DiscRecordingUI/DiscRecordingUI.h>
#import <objc/runtime.h>
#import "XLDDiscView.h"
#import "XLDShadowedImageView.h"
#import "XLDCustomClasses.h"
#import "XLDCueParser.h"
#import "XLDTrack.h"
#import "XLDController.h"
#import "XLDMetadataEditor.h"
#import "XLDPlayer.h"
#import "XLDDiscBurner.h"
#import "XLDMultipleFileWrappedDecoder.h"

#define NSAppKitVersionNumber10_4 824
extern int XLDDarkModeSupportEnabled;

static NSString *framesToMSFStr(xldoffset_t frames, int samplerate)
{
	int min = frames/samplerate/60;
	frames -= (xldoffset_t)min*samplerate*60;
	int sec = frames/samplerate;
	frames -= (xldoffset_t)sec*samplerate;
	int f = frames*75/samplerate;
	return [NSString stringWithFormat:@"%d:%02d:%02d",min,sec,f];
}

@implementation XLDDiscView

#pragma mark Normal Methods

- (id)initWithDelegate:(id)del
{
	[super init];
	[NSBundle loadNibNamed:@"DiscView" owner:self];
	
	[o_selectorTable registerForDraggedTypes:[NSArray arrayWithObjects:NSFilenamesPboardType,nil]];
	if(floor(NSAppKitVersionNumber) <= NSAppKitVersionNumber10_4) {
		[o_selectorTable setBackgroundColor:[NSColor colorWithCalibratedRed:0.9 green:0.93 blue:0.97 alpha:1.0]];
		[o_window setBackgroundColor:[NSColor colorWithCalibratedRed:0.93 green:0.93 blue:0.93 alpha:1.0]];
	}
	else {
		//[o_window setAutorecalculatesContentBorderThickness:YES forEdge:NSMinYEdge];
		[o_window setContentBorderThickness:21 forEdge:NSMinYEdge];
		//[o_verify setBezelStyle:NSTexturedRoundedBezelStyle];
		//[[o_verify cell] setControlSize:NSMiniControlSize];
		//[[o_totalTime cell] setBackgroundStyle:2]; // NSBackgroundStyleRaised
	}
	if([o_selectorTable respondsToSelector:@selector(setSelectionHighlightStyle:)]) {
		[o_selectorTable setSelectionHighlightStyle:1];
	}
	/* Shrink the selection pill on the right so it never sits under the eject glyph. */
	if([o_selectorTable isMemberOfClass:[NSTableView class]])
		object_setClass(o_selectorTable, [XLDSourceTableView class]);
	
	delegate = [del retain];
	[o_verify setHidden:YES]; /* Verify button removed */
	toolbarItems = [[NSMutableDictionary alloc] init];
	parserArray = [[NSMutableArray alloc] init];
	
	o_extractionMode = [[NSPopUpButton alloc] init];
	if(floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_4) {
		[o_extractionMode setBezelStyle:NSTexturedRoundedBezelStyle];
	}
	[[o_extractionMode cell] setArrowPosition:NSPopUpArrowAtBottom];
	//[[o_extractionMode cell] setControlSize:NSSmallControlSize];
	[[o_extractionMode cell] setFont:[NSFont systemFontOfSize:12]];
	[o_extractionMode setMenu:o_extractionModeMenu];
	
	NSToolbarItem* item;
	item = [[NSToolbarItem alloc] initWithItemIdentifier:@"ExtractionMode"];
	[item setView:o_extractionMode];
	[item setMinSize:NSMakeSize(200,25)];
	[item setMaxSize:NSMakeSize(350,25)];
	[item setLabel:LS(@"Extraction Mode")];
	[item setPaletteLabel:LS(@"Extraction Mode")];
	[item setTarget:self];
	[item setAction:@selector(extractionModeChanged:)];
	[toolbarItems setObject:item forKey:@"ExtractionMode"];
	[item release];

	/* Output-format pull-down (mirrors the format list in Preferences). */
	o_outputFormatPopUp = [[NSPopUpButton alloc] init];
	if(floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_4) {
		[o_outputFormatPopUp setBezelStyle:NSTexturedRoundedBezelStyle];
	}
	[[o_outputFormatPopUp cell] setArrowPosition:NSPopUpArrowAtBottom];
	[[o_outputFormatPopUp cell] setFont:[NSFont systemFontOfSize:12]];
	[o_outputFormatPopUp setTarget:self];
	[o_outputFormatPopUp setAction:@selector(outputFormatChangedFromToolbar:)];
	[[o_outputFormatPopUp menu] setDelegate:self]; /* repopulate just before it opens */
	/* The pull-down is placed inside the single titlebar "Group" view below. */

	/* Open: pick an inserted Audio CD or a folder/files to transcode. */
	o_openToolbarMenu = [[NSMenu alloc] initWithTitle:@"Open"];
	[o_openToolbarMenu setDelegate:self]; /* built on demand in menuNeedsUpdate: */
	if([NSMenuToolbarItem class]) {
		NSMenuToolbarItem *openItem = [[NSMenuToolbarItem alloc] initWithItemIdentifier:@"Open"];
		[openItem setLabel:LS(@"Open")];
		[openItem setPaletteLabel:LS(@"Open")];
		[openItem setImage:[NSImage imageNamed:NSImageNameFolder]];
		[openItem setMenu:o_openToolbarMenu];
		[openItem setShowsIndicator:YES];
		[toolbarItems setObject:openItem forKey:@"Open"];
		[openItem release];
	}

	/* All the controls (output-format pull-down + five monochrome SF Symbol action
	   glyphs with small labels beneath) live in ONE custom view hosted as a single
	   "Group" NSToolbar item. The toolbar renders a fixed-size custom view
	   reliably at full height (H below), so nothing is clipped; a leading flexible
	   space right-anchors the group and GROUP_RIGHT trailing padding inside the
	   view holds it off the right edge. (Two custom-titlebar routes were tried and
	   dropped: a FullSizeContentView + transparent-titlebar overlay crashed
	   intermittently in the NSScrollView titlebar-mirror path, and an
	   NSTitlebarAccessoryViewController strip clipped the controls at the top.) */
	{
		const CGFloat H=56.0, ICON=23.0, PDW=180.0, PDH=24.0, LABELH=13.0, GAP=2.0;
		const CGFloat COLW=52.0, PD_ICONS_GAP=20.0, GROUP_RIGHT=22.0, TOP_GAP=14.0;
		NSArray *syms   = [NSArray arrayWithObjects:@"gearshape",@"opticaldisc",@"globe",@"square.and.pencil",@"flame",nil];
		NSArray *labels = [NSArray arrayWithObjects:LS(@"Settings"),LS(@"Rip"),LS(@"Lookup"),LS(@"Edit"),LS(@"Burn"),nil];
		NSArray *fbacks = [NSArray arrayWithObjects:[NSImage imageNamed:NSImageNamePreferencesGeneral],[[NSWorkspace sharedWorkspace] iconForDisc],[[NSWorkspace sharedWorkspace] iconForNetwork],[NSImage imageNamed:@"metadata"],[[NSWorkspace sharedWorkspace] iconForBurn],nil];
		id targets[5]; SEL actions[5];
		targets[0]=delegate; actions[0]=@selector(showPreferences:);
		targets[1]=delegate; actions[1]=@selector(beginDecode:);
		targets[2]=delegate; actions[2]=@selector(cddbGetTracks:);
		targets[3]=self;     actions[3]=@selector(editMetadata:);
		targets[4]=self;     actions[4]=@selector(burn:);

		CGFloat groupW = PDW + PD_ICONS_GAP + 5.0*COLW;
		CGFloat viewW = groupW + GROUP_RIGHT;             /* trailing pad = right offset */
		/* Place the icon+label block toward the bottom of the item so TOP_GAP pixels
		   stay clear above the glyphs (the distance from the window top that reads
		   right against the pull-down). */
		CGFloat unitBottom = H - TOP_GAP - (ICON + GAP + LABELH);

		NSView *grp = [[[NSView alloc] initWithFrame:NSMakeRect(0,0,viewW,H)] autorelease];

		/* Pull-down vertically centred on the glyph row so the group reads as one
		   row; rounded to whole pixels for a crisp bezel. */
		CGFloat iconCenterY = unitBottom + LABELH + GAP + ICON/2.0;
		CGFloat pdY = round(iconCenterY - PDH/2.0);
		[o_outputFormatPopUp setFrame:NSMakeRect(0, pdY, PDW, PDH)];
		[grp addSubview:o_outputFormatPopUp];

		int gi;
		for(gi=0; gi<5; gi++) {
			CGFloat colX = PDW + PD_ICONS_GAP + gi*COLW;
			NSButton *b = [[[NSButton alloc] initWithFrame:NSMakeRect(colX + (COLW-ICON)/2.0, unitBottom + LABELH + GAP, ICON, ICON)] autorelease];
			[b setButtonType:NSMomentaryChangeButton];
			[b setBordered:NO];
			[b setImagePosition:NSImageOnly];
			NSImage *img = nil;
			if([NSImage respondsToSelector:@selector(imageWithSystemSymbolName:accessibilityDescription:)])
				img = [NSImage imageWithSystemSymbolName:[syms objectAtIndex:gi] accessibilityDescription:[labels objectAtIndex:gi]];
			if(img && [img respondsToSelector:@selector(imageWithSymbolConfiguration:)] && NSClassFromString(@"NSImageSymbolConfiguration"))
				img = [img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:18.0 weight:NSFontWeightRegular]];
			if(!img) img = [fbacks objectAtIndex:gi];
			[b setImage:img];
			[[b cell] setImageScaling:NSImageScaleProportionallyUpOrDown];
			[b setTarget:targets[gi]];
			[b setAction:actions[gi]];
			[b setToolTip:[labels objectAtIndex:gi]];
			[grp addSubview:b];

			NSTextField *lbl = [[[NSTextField alloc] initWithFrame:NSMakeRect(colX, unitBottom, COLW, LABELH)] autorelease];
			[lbl setStringValue:[labels objectAtIndex:gi]];
			[lbl setEditable:NO]; [lbl setSelectable:NO]; [lbl setBordered:NO]; [lbl setBezeled:NO]; [lbl setDrawsBackground:NO];
			[lbl setAlignment:NSCenterTextAlignment];
			[lbl setFont:[NSFont systemFontOfSize:9.0]];
			[lbl setTextColor:[NSColor secondaryLabelColor]];
			[[lbl cell] setLineBreakMode:NSLineBreakByClipping];
			[grp addSubview:lbl];
			if(gi==1) o_ripLabel = lbl; /* the Rip/Transcode label */
		}

		NSToolbarItem *groupItem = [[[NSToolbarItem alloc] initWithItemIdentifier:@"Group"] autorelease];
		[groupItem setLabel:@""];
		[groupItem setPaletteLabel:LS(@"Controls")];
		if([groupItem respondsToSelector:@selector(setBordered:)]) [groupItem setBordered:NO];
		[groupItem setView:grp];
		[groupItem setMinSize:NSMakeSize(viewW,H)];
		[groupItem setMaxSize:NSMakeSize(viewW,H)];
		[toolbarItems setObject:groupItem forKey:@"Group"];

		NSToolbar *theBar = [[NSToolbar alloc] initWithIdentifier:@"XLDDiscViewToolbar9"];
		[theBar setDelegate:self];
		[theBar setAllowsUserCustomization:NO];
		[theBar setDisplayMode:NSToolbarDisplayModeIconOnly];
		[o_window setToolbar:theBar];
		[theBar release];
	}

	NSRect frame = [o_trackTableScroll frame];
	frame.size.width = [[[o_splitView subviews] objectAtIndex:1] frame].size.width;
	[o_trackTableScroll setFrame:frame];
	
	[o_trackTable setTarget:self];
	[o_trackTable setDoubleAction:@selector(playTrack:)];
	/* Centre the Track column so the dashes line up (and nudge the content 2px
	   left via the cell's line-break/inset is not exposed, so centring is the
	   clean lever); the disc-prefix is only shown for multi-disc sets. */
	{
		NSTableColumn *tc = [o_trackTable tableColumnWithIdentifier:@"Track"];
		[[tc dataCell] setAlignment:NSCenterTextAlignment];
		[[tc headerCell] setAlignment:NSCenterTextAlignment];
	}

	[o_imageView setAcceptClick:YES];
	[o_imageView setTarget:delegate];
	[o_imageView setAction:@selector(searchCoverArt:)];
	
	if([NSCell instanceMethodForSelector:@selector(setLineBreakMode:)]) {
		[[o_titleText cell] setLineBreakMode:NSLineBreakByTruncatingTail];
		[[o_artistText cell] setLineBreakMode:NSLineBreakByTruncatingTail];
	}
	
	NSButton *hiddenButton = [[NSButton alloc] init];
	[hiddenButton setTarget:delegate];
	[hiddenButton setAction:@selector(beginDecode:)];
	[hiddenButton setFrame:NSMakeRect(-10, -10, 5, 5)];
	[hiddenButton setAutoresizingMask:NSViewMaxXMargin|NSViewMaxYMargin];
	[hiddenButton setKeyEquivalent:@"d"];
	[hiddenButton setKeyEquivalentModifierMask:NSCommandKeyMask];
	[[o_window contentView] addSubview:hiddenButton];
	[hiddenButton release];
	
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5
	if(XLDDarkModeSupportEnabled) {
		/* Make the whole content view layer-backed consistently. Previously only
		   the two scroll containers were layer-backed, leaving their siblings
		   (the cover-art / info header) non-layer-backed; mixing the two modes
		   produces redraw trails ("ghost rectangles") when the window is
		   resized in dark mode. A single layer-backed ancestor composites all
		   subviews uniformly and clears the artifact. */
		[[o_window contentView] setWantsLayer:YES];
		[[[o_trackTable superview] superview] setWantsLayer:YES];
		[[[o_selectorTable superview] superview] setWantsLayer:YES];
	}
	[o_splitView setDividerStyle:NSSplitViewDividerStyleThin];
#endif
	[self syncOutputFormatPopUp];

	/* Move the album title / artist labels to the TOP of the header area
	   (they were anchored near the bottom, beside the cover art). */
	if(o_titleText && o_artistText) {
		NSView *titleView = o_titleText;
		NSView *artistView = o_artistText;
		NSView *container = [titleView superview];
		CGFloat top = [container bounds].size.height;
		BOOL flipped = [container isFlipped];
		NSRect tf = [titleView frame];
		NSRect af = [artistView frame];
		CGFloat margin = 34.0; /* inset from the top so the text sits inside the field */
		if(flipped) {
			tf.origin.y = margin;
			af.origin.y = NSMaxY(tf) + 2.0;
		} else {
			tf.origin.y = top - margin - tf.size.height;
			af.origin.y = tf.origin.y - 2.0 - af.size.height;
		}
		[titleView setFrame:tf];
		[artistView setFrame:af];
		titleFrame0 = tf; /* remember normal title frame for the empty-state toggle */
	}

	/* Open wider by default so longer titles are visible. */
	{
		NSRect wf = [o_window frame];
		if(wf.size.width < 1180) {
			wf.size.width = 1180;
			[o_window setFrame:wf display:NO];
		}
	}

	/* Make the "AccurateRip:" status in the bottom-left clickable: clicking it
	   toggles the indicator between YES and NO. We overlay a transparent button
	   covering the status label and its caption. */
	if(o_accurateRipStatus) {
		NSView *statusSuper = [o_accurateRipStatus superview];
		NSRect sr = [o_accurateRipStatus frame];
		NSRect btnFrame = NSMakeRect(0, sr.origin.y - 2, NSMaxX(sr) + 4, sr.size.height + 4);
		NSButton *arButton = [[NSButton alloc] initWithFrame:btnFrame];
		[arButton setButtonType:NSMomentaryChangeButton];
		[arButton setBordered:NO];
		[arButton setTransparent:YES];
		[arButton setTitle:@""];
		[arButton setTarget:self];
		[arButton setAction:@selector(toggleAccurateRip:)];
		[arButton setAutoresizingMask:NSViewMaxXMargin|NSViewMaxYMargin];
		[statusSuper addSubview:arButton positioned:NSWindowAbove relativeTo:nil];
		[arButton release];
	}

	[o_window display];
	//[o_window makeKeyAndOrderFront:self];
	proposedRow = -1;
	return self;
}

- (void)dealloc
{
	if(scanAnimTimer) { [scanAnimTimer invalidate]; [scanAnimTimer release]; }
	[delegate release];
	[toolbarItems release];
	[o_openToolbarMenu release];
	[ejectButtons release];
	[o_emptyStateLabel release];
	[parserArray release];
	if(checkArray) [checkArray release];
	[super dealloc];
}

- (void)removeCheckboxes
{
	int i;
	if(!checkArray) return;
	for(i=0;i<[checkArray count];i++) {
		id button = [checkArray objectAtIndex:i];
		[button removeFromSuperview];
	}
	[checkArray release];
	checkArray = nil;
}

- (void)drawCheckboxes
{
	int i;
	if(!checkArray) return;
	for(i=0;i<[checkArray count];i++) {
		id button = [checkArray objectAtIndex:i];
		NSRect frame = [o_trackTable frameOfCellAtColumn:0 row:i];
		frame.origin.x += 11;
		[button setFrame:frame];
		[o_trackTable addSubview:button];
	}
}

- (void)showEmptyStatePrompt:(BOOL)show
{
	if(!o_titleText) return;
	NSView *container = [o_titleText superview];
	if(show) {
		if(!o_emptyStateLabel) {
			NSRect cf = [container bounds];
			o_emptyStateLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, (cf.size.height-24)/2.0, cf.size.width-20, 24)];
			[o_emptyStateLabel setEditable:NO];
			[o_emptyStateLabel setSelectable:NO];
			[o_emptyStateLabel setBordered:NO];
			[o_emptyStateLabel setDrawsBackground:NO];
			[o_emptyStateLabel setAlignment:NSTextAlignmentCenter];
			[o_emptyStateLabel setFont:[NSFont boldSystemFontOfSize:14]];
			[o_emptyStateLabel setTextColor:[NSColor secondaryLabelColor]];
			[o_emptyStateLabel setStringValue:LS(@"Insert Audio CD or select folder for conversion")];
			[o_emptyStateLabel setAutoresizingMask:NSViewWidthSizable|NSViewMinYMargin|NSViewMaxYMargin];
			[container addSubview:o_emptyStateLabel];
		}
		[o_emptyStateLabel setHidden:NO];
	}
	else [o_emptyStateLabel setHidden:YES];
}

- (void)removeEjectButtons
{
	int i;
	for(i=0;i<[ejectButtons count];i++) [[ejectButtons objectAtIndex:i] removeFromSuperview];
	[ejectButtons removeAllObjects];
}

- (void)layoutEjectButtons
{
	[self removeEjectButtons];
	if(!ejectButtons) ejectButtons = [[NSMutableArray alloc] init];
	int i;
	for(i=0;i<[parserArray count];i++) {
		NSString *dev = [[parserArray objectAtIndex:i] fileToDecode];
		if(!dev || ![dev hasPrefix:@"/dev/disk"]) continue; /* optical discs only */
		NSRect rowRect = [o_selectorTable rectOfRow:i];
		CGFloat tableW = [o_selectorTable bounds].size.width;
		/* Place the eject control at the far-right edge of the row, in its own
		   dark rounded chip, so it sits clear of the selection pill. */
		NSRect frame = NSMakeRect(tableW-22, rowRect.origin.y + (rowRect.size.height-18)/2.0, 20, 18);
		NSButton *btn = [[NSButton alloc] initWithFrame:frame];
		[btn setButtonType:NSMomentaryChangeButton];
		[btn setBordered:NO];
		[[btn cell] setImagePosition:NSNoImage];
		/* Visible eject glyph in the right-hand gutter (pill stops short of it);
		   device path carried in the identifier for the action. */
		NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys:
			[NSColor secondaryLabelColor], NSForegroundColorAttributeName,
			[NSFont systemFontOfSize:13], NSFontAttributeName, nil];
		[btn setAttributedTitle:[[[NSAttributedString alloc] initWithString:@"⏏" attributes:attrs] autorelease]];
		[btn setIdentifier:dev];
		[btn setToolTip:LS(@"Eject")];
		[btn setTarget:self];
		[btn setAction:@selector(ejectDiscClicked:)];
		[btn setAutoresizingMask:NSViewMinXMargin];
		[o_selectorTable addSubview:btn positioned:NSWindowAbove relativeTo:nil];
		[ejectButtons addObject:btn];
		[btn release];
	}
}

- (IBAction)ejectDiscClicked:(id)sender
{
	if([delegate respondsToSelector:@selector(ejectDiscByDevice:)])
		[delegate ejectDiscByDevice:[sender identifier]];
}

/* --- Async disc scanning: show the disc immediately, with scan progress in its
   source-list row, before/while the pregap is detected. --- */
- (id)entryForDevice:(NSString *)dev
{
	int i;
	for(i=0;i<[parserArray count];i++) {
		id p = [parserArray objectAtIndex:i];
		if([[p fileToDecode] isEqualToString:dev]) return p;
	}
	return nil;
}

- (void)addScanningDiscWithVolume:(NSString *)volume device:(NSString *)dev
{
	if([self entryForDevice:dev]) return; /* already shown (scanning or opened) */
	XLDScanningDisc *sd = [[XLDScanningDisc alloc] initWithVolume:volume device:dev];
	[parserArray addObject:sd];
	[sd release];
	[self reloadData];
	if([parserArray count] == 1)
		[o_selectorTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	[o_window makeKeyAndOrderFront:nil]; /* show the disc immediately, while it scans */
	/* Drive the Cylon sweep on the scanning rows. Common modes so it keeps
	   animating while a menu is open or the window is being resized. */
	if(!scanAnimTimer) {
		scanAnimTimer = [[NSTimer timerWithTimeInterval:1.0/30.0 target:self selector:@selector(scanAnimTick:) userInfo:nil repeats:YES] retain];
		[[NSRunLoop currentRunLoop] addTimer:scanAnimTimer forMode:NSRunLoopCommonModes];
	}
}

- (void)scanAnimTick:(NSTimer *)timer
{
	BOOL anyScanning = NO;
	int i;
	for(i=0;i<[parserArray count];i++) {
		if([[parserArray objectAtIndex:i] isKindOfClass:[XLDScanningDisc class]]) {
			anyScanning = YES;
			[o_selectorTable setNeedsDisplayInRect:[o_selectorTable rectOfRow:i]];
		}
	}
	if(!anyScanning) {
		[scanAnimTimer invalidate];
		[scanAnimTimer release];
		scanAnimTimer = nil;
	}
}

- (void)updateScanProgress:(double)frac forDevice:(NSString *)dev
{
	int i;
	for(i=0;i<[parserArray count];i++) {
		id p = [parserArray objectAtIndex:i];
		if([p isKindOfClass:[XLDScanningDisc class]] && [[p devicePath] isEqualToString:dev]) {
			[p setScanProgress:frac];
			[o_selectorTable setNeedsDisplayInRect:[o_selectorTable rectOfRow:i]];
			return;
		}
	}
}

- (double)scanProgressForRow:(NSInteger)row
{
	if(row < 0 || row >= [parserArray count]) return -1.0;
	id p = [parserArray objectAtIndex:row];
	if([p isKindOfClass:[XLDScanningDisc class]]) return [p scanProgress];
	return -1.0;
}

- (void)removeScanningDiscForDevice:(NSString *)dev
{
	int i;
	for(i=0;i<[parserArray count];i++) {
		id p = [parserArray objectAtIndex:i];
		if([p isKindOfClass:[XLDScanningDisc class]] && [[p devicePath] isEqualToString:dev]) {
			[parserArray removeObjectAtIndex:i];
			return;
		}
	}
}

- (void)reloadData
{
	[self syncOutputFormatPopUp];
	[o_selectorTable reloadData];
	[o_trackTable reloadData];
	if(![parserArray count]) {
		[self removeCheckboxes];
		[self removeEjectButtons];
		/* Empty state: prompt the user to pick a source. */
		[o_imageView setDefaultString:@""];
		[o_imageView clearImage];
		/* Centered prompt in its own label; leave the real title/artist fields
		   untouched so their layout never shifts. */
		[o_titleText setStringValue:@""];
		[o_titleText setToolTip:nil];
		[o_artistText setStringValue:@""];
		[self showEmptyStatePrompt:YES];
		if(o_accurateRipStatus) [o_accurateRipStatus setStringValue:LS(@"NO")];
		[o_totalTime setStringValue:[NSString stringWithFormat:LS(@"%@ Total"), @"--:--:--"]];
		[o_window setTitle:@""];
		return;
	}
	[self layoutEjectButtons];

	id cueParser = [parserArray objectAtIndex:[o_selectorTable selectedRow]];
	[o_imageView setDefaultString:@"No Image"]; /* restore normal placeholder */
	if(![cueParser coverData]) [o_imageView clearImage];
	else if([cueParser coverData] != [o_imageView imageData]) [o_imageView setImageData:[cueParser coverData]];
	[self showEmptyStatePrompt:NO];
	[o_titleText setStringValue:[cueParser title]];
	[o_titleText setToolTip:[cueParser title]];
	[o_artistText setStringValue:[cueParser artist]];
	[o_artistText setToolTip:[cueParser artist]];
	[o_window setTitle:[cueParser title]];
	if([cueParser representedFilename]) {
		if(![[NSFileManager defaultManager] fileExistsAtPath:[cueParser representedFilename]]) {
			[o_window setRepresentedFilename:@""];
			[o_window performSelector:@selector(setRepresentedFilename:) withObject:[cueParser representedFilename] afterDelay:2.0];
		}
		else [o_window setRepresentedFilename:[cueParser representedFilename]];
	}
	else [o_window setRepresentedFilename:@""];
	XLDAccurateRipDBState arState = [[cueParser accurateRipData] state];
	NSString *arStateString = LS(@"NO"); /* default to NO rather than ??? */
	if (arState == kXLDAccurateRipDBStateFound) arStateString = LS(@"YES");
	else if (arState == kXLDAccurateRipDBStateNotFound) arStateString = LS(@"NO");
	else if (arState == kXLDAccurateRipDBStateNetworkError) arStateString = @"ERR";
	[o_accurateRipStatus setStringValue:arStateString];
	[o_totalTime setStringValue:[NSString stringWithFormat:LS(@"%@ Total"), framesToMSFStr([cueParser totalFrames], [cueParser samplerate])]];
	[o_verify setHidden:YES]; /* Verify button removed */
	/* "Rip" for a disc, "Transcode" for a folder/file. */
	{
		BOOL isDisc = ([cueParser fileToDecode] && [[cueParser fileToDecode] hasPrefix:@"/dev/disk"]);
		[o_ripLabel setStringValue:(isDisc ? LS(@"Rip") : LS(@"Transcode"))];
	}

	[self removeCheckboxes];
	checkArray = [[cueParser checkList] retain];
	[self drawCheckboxes];
}

- (void)openCueParser:(id)parser
{
	int i;
	NSString *source = [parser fileToDecode];
	for(i=0;i<[parserArray count];i++) {
		if([[[parserArray objectAtIndex:i] fileToDecode] isEqualToString:source]) {
			[parserArray replaceObjectAtIndex:i withObject:parser];
			break;
		}
	}
	if(i==[parserArray count]) {
		if(proposedRow < 0) {
			[parserArray addObject:parser];
			[o_selectorTable reloadData];
			[o_selectorTable selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
		}
		else {
			[parserArray insertObject:parser atIndex:proposedRow];
			[o_selectorTable reloadData];
			[o_selectorTable selectRowIndexes:[NSIndexSet indexSetWithIndex:proposedRow] byExtendingSelection:NO];
			[self reloadData];
		}
	}
	else {
		if(i!=[o_selectorTable selectedRow]) [o_selectorTable selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
		else [self reloadData];
	}
	[o_window makeKeyAndOrderFront:self];
	if ([[parser accurateRipData] state] == kXLDAccurateRipDBStatePending) {
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(accurateRipDatabaseDidBecomeAvailable:) name:@"XLDARDBDidFinishLoadingNotification" object:[parser accurateRipData]];
	}
	/* this was needed in 11.0 beta - I guess no longer needed
	[[o_window toolbar] validateVisibleItems];
	*/
}

- (void)checkAtIndex:(int)idx
{
	if(!checkArray) return;
	if(![[checkArray objectAtIndex:idx] isEnabled]) return;
	[[checkArray objectAtIndex:idx] setState:NSOnState];
}

- (void)uncheckAtIndex:(int)idx
{
	if(!checkArray) return;
	if(![[checkArray objectAtIndex:idx] isEnabled]) return;
	[[checkArray objectAtIndex:idx] setState:NSOffState];
}

- (void)imageLoaded
{
	id cueParser = [self cueParser];
	if(!cueParser) return;
	[cueParser setCoverData:[o_imageView imageData]];
	[o_window makeKeyAndOrderFront:nil];
}

- (NSWindow *)window
{
	return o_window;
}

- (id)cueParser
{
	if(![parserArray count]) return nil;
	return [parserArray objectAtIndex:[o_selectorTable selectedRow]];
}

- (int)extractionMode
{
	return [[o_extractionMode selectedItem] tag];
}

- (void)setExtractionMode:(int)mode
{
	int idx = [o_extractionMode indexOfItemWithTag:mode];
	if(idx >= 0 && idx < [o_extractionMode numberOfItems]) [o_extractionMode selectItemAtIndex:idx];
	[self extractionModeChanged:o_extractionMode];
}

- (void)closeFile:(NSString *)path
{
	int i;
	for(i=0;i<[parserArray count];i++) {
		if([[[parserArray objectAtIndex:i] fileToDecode] isEqualToString:path]) {
			[parserArray removeObjectAtIndex:i];
			/* When the last source is removed, keep the window open showing the
			   empty-state prompt instead of closing it. Closing the now-empty
			   window again (red button / Cmd-W) dismisses it via
			   windowShouldClose:. */
			[self reloadData];
			break;
		}
	}
}

- (NSString *)splitViewPosition:(NSSplitView *)splitView
{
    NSArray *subViews = [splitView subviews];
    int     lenFirst, lenSecond;
	
    lenFirst = [[subViews objectAtIndex: 0] frame].size.width;
    lenSecond = [[subViews objectAtIndex: 1] frame].size.width;
	
	return [NSString stringWithFormat: @"%i %i", lenFirst, lenSecond];
}

- (void)setSplitViewPosition:(NSSplitView *)splitView position:(NSString *)s
{
	if(!s) return;
    NSArray *subViews = [splitView subviews];
    NSRect  newBounds;
    float   dividerWidth = [splitView dividerThickness];
    NSView  *viewZero = [subViews objectAtIndex: 0];
    NSView  *viewOne = [subViews objectAtIndex: 1];
    NSArray *stringComponents = [s componentsSeparatedByString: @" "];
    int     valueZero, valueOne;
	
    valueZero = [[stringComponents objectAtIndex: 0] intValue];
    valueOne = [[stringComponents objectAtIndex: 1] intValue];
	
    int leftSize = valueZero;
    int rightSize = valueOne;
	if (leftSize < 150) leftSize = 150;
	
    if ((leftSize + rightSize + dividerWidth) != [splitView frame].size.width)
        rightSize = [splitView frame].size.width - dividerWidth - leftSize;
	
    newBounds = [viewZero frame];
    newBounds.size.width = leftSize;
    newBounds.origin.x = 0;
    [viewZero setFrame: newBounds];
	
    newBounds = [viewOne frame];
    newBounds.size.width = rightSize;
    newBounds.origin.x = leftSize + dividerWidth;
    [viewOne setFrame: newBounds];
}

- (void)savePrefs
{
	NSUserDefaults *pref = [NSUserDefaults standardUserDefaults];
	[pref setObject:[self splitViewPosition:o_splitView] forKey:@"XLDDiscViewSplitPosition"];
	[pref synchronize];
}

- (void)loadPrefs
{
	NSUserDefaults *pref = [NSUserDefaults standardUserDefaults];
	id obj;
	if(obj=[pref objectForKey:@"XLDDiscViewSplitPosition"]) {
		[self setSplitViewPosition:o_splitView position:obj];
	}
}

- (BOOL)burning
{
	return burning;
}

- (id)imageView
{
	return o_imageView;
}

#pragma mark IBActions

- (IBAction)saveImage:(id)sender
{
	NSSavePanel *sv = [NSSavePanel savePanel];
	NSString *defaultLocation = nil;
	id cueParser = [self cueParser];
	if(!cueParser) return;
	if(![[cueParser fileToDecode] hasPrefix:@"/dev/disk"])
		defaultLocation = [[cueParser fileToDecode] stringByDeletingLastPathComponent];
	
	NSString *extensionStr;
	unsigned char *tmp = (unsigned char *)[[o_imageView imageData] bytes];
	if (tmp[0] == 0xFF && tmp[1] == 0xD8) {
        extensionStr = @"jpg";
    } else if (tmp[0] == 0x89 && strncmp((const char *)&tmp[1], "PNG", 3) == 0) {
        extensionStr = @"png";
    } else if (strncmp((const char *)tmp, "GIF8", 4) == 0) { 
        extensionStr = @"gif";
    } else {
        extensionStr = @"";
    }
	if(![extensionStr isEqualToString:@""]) [sv setAllowedFileTypes:[NSArray arrayWithObject:extensionStr]];
	
	NSString *filename = [o_titleText stringValue];
	if([[[filename pathExtension] lowercaseString] isEqualToString:@"cue"])
		filename = [[cueParser title] stringByDeletingPathExtension];
	int ret = [sv runModalForDirectory:defaultLocation file:[filename stringByAppendingPathExtension:extensionStr]];
	if(ret != NSOKButton) return;
	
	[[o_imageView imageData] writeToFile:[sv filename] atomically:YES];
}


- (IBAction)openImage:(id)sender
{
	NSOpenPanel *op = [NSOpenPanel openPanel];
	[op setCanChooseDirectories:NO];
	[op setCanChooseFiles:YES];
	[op setAllowsMultipleSelection:NO];
	
	int ret = [op runModal];
	if(ret != NSOKButton) return;
	if([o_imageView setImageFromPath:[op filename]]) { // succesfully loaded
		id cueParser = [self cueParser];
		if(!cueParser) return;
		[cueParser setCoverData:[o_imageView imageData]];
	}
}

- (IBAction)checkSelected:(id)sender
{
	int i;
	if([sender tag] == 0) {
		for(i=0;i<[checkArray count];i++) {
			if([o_trackTable isRowSelected:i]) [self checkAtIndex:i];
		}
	}
	else {
		for(i=0;i<[checkArray count];i++) {
			[self checkAtIndex:i];
		}
	}
}

- (IBAction)uncheckSelected:(id)sender
{
	int i;
	if([sender tag] == 0) {
		for(i=0;i<[checkArray count];i++) {
			if([o_trackTable isRowSelected:i]) [self uncheckAtIndex:i];
		}
	}
	else {
		for(i=0;i<[checkArray count];i++) {
			[self uncheckAtIndex:i];
		}
	}
}

- (IBAction)editMetadata:(id)sender
{
	int i;
	id cueParser = [self cueParser];
	if(!cueParser) return;
	id trackList = [cueParser trackList];
	if([o_trackTable numberOfSelectedRows] == 1) {
		[[delegate metadataEditor] editTracks:trackList atIndex:[o_trackTable selectedRow]];
	}
	else if([o_trackTable numberOfSelectedRows] > 1) {
		NSMutableArray *arr = [[NSMutableArray alloc] init];
		for(i=0;i<[trackList count];i++) {
			if([o_trackTable isRowSelected:i]) [arr addObject:[trackList objectAtIndex:i]];
		}
		[[delegate metadataEditor] editAllTracks:arr];
		[arr release];
	}
	else {
		[[delegate metadataEditor] editTracks:trackList atIndex:0];
	}
	
	[self reloadData];
}

- (IBAction)checkboxStatusChanged:(id)sender
{
	int i;
	if([sender state] == NSOnState) {
		if([sender shiftKeyPressed]) {
			for(i=0;i<[checkArray count];i++) {
				[self checkAtIndex:i];
			}
		}
		else if([sender commandKeyPressed]) {
			for(i=0;i<[checkArray count];i++) {
				if([o_trackTable isRowSelected:i]) [self checkAtIndex:i];
			}
		}
	}
	else {
		if([sender shiftKeyPressed]) {
			for(i=0;i<[checkArray count];i++) {
				[self uncheckAtIndex:i];
			}
		}
		else if([sender commandKeyPressed]) {
			for(i=0;i<[checkArray count];i++) {
				if([o_trackTable isRowSelected:i]) [self uncheckAtIndex:i];
			}
		}
	}
}

- (IBAction)extractionModeChanged:(id)sender
{
	int i;
	if([[sender selectedItem] tag] == 2) {
		for(i=0;i<[checkArray count];i++) {
			if(![[checkArray objectAtIndex:i] isEnabled]) continue;
			[[checkArray objectAtIndex:i] setState:NSOnState];
			[[checkArray objectAtIndex:i] setEnabled:NO];
		}
	}
	else {
		for(i=0;i<[checkArray count];i++) {
			if([[checkArray objectAtIndex:i] state] == NSOffState) continue;
			[[checkArray objectAtIndex:i] setEnabled:YES];
		}
	}
										  
}

- (IBAction)playTrack:(id)sender
{
	id cueParser = [self cueParser];
	if(!cueParser) return;
	if([o_trackTable clickedRow] >= [[cueParser trackList] count]) return;
	if([[cueParser fileToDecode] hasPrefix:@"/dev/disk"]) return;
	id player = [delegate player];
	if([cueParser cueMode] == XLDCueModeRaw)
		[player playRawFile:[cueParser fileToDecode]
				  withTrack:[cueParser trackList]
				  fromIndex:[o_trackTable clickedRow]
				 withFormat:[cueParser rawFormat]
					 endian:[cueParser rawEndian]
					 offset:[cueParser rawOffset]];
	else if([cueParser cueMode] == XLDCueModeMulti)
		[player playDiscLayout:[cueParser discLayout]
					  withFile:[cueParser fileToDecode]
					 withTrack:[cueParser trackList]
					 fromIndex:[o_trackTable clickedRow]];
	else
		[player playFile:[cueParser fileToDecode]
			   withTrack:[cueParser trackList]
			   fromIndex:[o_trackTable clickedRow]];
	[player showPlayer];
}

- (IBAction)clearImage:(id)sender
{
	[o_imageView clearImage];
	[[self cueParser] setCoverData:nil];
}

- (IBAction)burn:(id)sender
{
	DRBurnSetupPanel *bsp = [DRBurnSetupPanel setupPanel];
	[bsp setCanSelectAppendableMedia:NO];
	[bsp setCanSelectTestBurn:YES];
	[bsp beginSetupSheetForWindow:o_window modalDelegate:self didEndSelector:@selector(setupPanelDidEnd:returnCode:contextInfo:) contextInfo:NULL];
}

- (IBAction)verify:(id)sender
{
	[delegate checkAccurateRip:sender];
}

#pragma mark Delegate Methods

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSString *)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag
{
	return [toolbarItems objectForKey:itemIdentifier];
}

-(NSArray *) toolbarDefaultItemIdentifiers:(NSToolbar*)toolbar
{
	/* One custom group view, right-anchored by a leading flexible space; the view
	   itself carries the sandbox offset from the right edge. */
	return [NSArray arrayWithObjects:NSToolbarFlexibleSpaceItemIdentifier,@"Group",nil];
}

-(NSArray *) toolbarAllowedItemIdentifiers:(NSToolbar*)toolbar
{
	return [NSArray arrayWithObjects:@"Group",NSToolbarFlexibleSpaceItemIdentifier,NSToolbarSpaceItemIdentifier,nil];
}

/* Build a toolbar item whose view is an icon with a small centred label beneath,
   at a fixed size so every action item is the same width and the icons stay
   evenly spaced. The label text lives in the view (toolbar display mode is
   IconOnly), and a borderless button carries the action. */
- (NSToolbarItem *)labeledToolbarItem:(NSString *)ident label:(NSString *)label image:(NSImage *)img target:(id)t action:(SEL)a
{
	const CGFloat W = 56.0, H = 52.0, ICON = 23.0, LABELH = 13.0, GAP = 2.0, ICONS_DOWN = 7.0;
	/* The icon+label block is centred on the view, then nudged down by ICONS_DOWN
	   (the offset dialled in in the sandbox) so the icons sit where they look right
	   against the output-format pull-down. */
	CGFloat unitBottom = (H - (ICON + GAP + LABELH))/2.0 - ICONS_DOWN;
	NSToolbarItem *item = [[[NSToolbarItem alloc] initWithItemIdentifier:ident] autorelease];
	[item setLabel:label];
	[item setPaletteLabel:label];
	/* No rounded/pill background ring around the view (the plain-icon look). */
	if([item respondsToSelector:@selector(setBordered:)]) [item setBordered:NO];
	NSView *v = [[[NSView alloc] initWithFrame:NSMakeRect(0,0,W,H)] autorelease];
	NSButton *btn = [[[NSButton alloc] initWithFrame:NSMakeRect((W-ICON)/2.0, unitBottom + LABELH + GAP, ICON, ICON)] autorelease];
	[btn setButtonType:NSMomentaryChangeButton];
	[btn setBordered:NO];
	[btn setImage:img];
	[btn setImagePosition:NSImageOnly];
	[[btn cell] setImageScaling:NSImageScaleProportionallyUpOrDown];
	[btn setTarget:t];
	[btn setAction:a];
	[btn setToolTip:label];
	[btn setAutoresizingMask:NSViewMinXMargin|NSViewMaxXMargin];
	[v addSubview:btn];
	NSTextField *lbl = [[[NSTextField alloc] initWithFrame:NSMakeRect(0.0, unitBottom, W, LABELH)] autorelease];
	[lbl setStringValue:label];
	[lbl setEditable:NO];
	[lbl setSelectable:NO];
	[lbl setBordered:NO];
	[lbl setBezeled:NO];
	[lbl setDrawsBackground:NO];
	[lbl setAlignment:NSCenterTextAlignment];
	[lbl setFont:[NSFont systemFontOfSize:9.0]];
	[lbl setTextColor:[NSColor secondaryLabelColor]];
	[[lbl cell] setLineBreakMode:NSLineBreakByClipping];
	[v addSubview:lbl];
	[item setView:v];
	[item setMinSize:NSMakeSize(W,H)];
	[item setMaxSize:NSMakeSize(W,H)];
	return item;
}

/* Repopulate the output-format pull-down from Preferences just before it opens. */
- (void)menuNeedsUpdate:(NSMenu *)menu
{
	if(o_outputFormatPopUp && menu == [o_outputFormatPopUp menu]) [self syncOutputFormatPopUp];
	else if(menu == o_openToolbarMenu) [self buildOpenMenu:menu];
}

- (void)buildOpenMenu:(NSMenu *)menu
{
	[menu removeAllItems];
	/* Inserted audio CDs (each opens via the controller's readCDDA:). */
	NSArray *cds = [delegate respondsToSelector:@selector(insertedAudioCDTitles)] ? [delegate insertedAudioCDTitles] : nil;
	int i;
	for(i=0;i<[cds count];i++) {
		/* readCDDA: opens the disc named by the item's title, so use the bare
		   volume name as the title. */
		NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:[cds objectAtIndex:i] action:@selector(readCDDA:) keyEquivalent:@""];
		[it setTarget:delegate];
		[menu addItem:it];
		[it release];
	}
	if(![cds count]) {
		NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:LS(@"No Audio CD Inserted") action:nil keyEquivalent:@""];
		[none setEnabled:NO]; [menu addItem:none]; [none release];
	}
	if([cds count]) [menu addItem:[NSMenuItem separatorItem]];
	NSMenuItem *folder = [[NSMenuItem alloc] initWithTitle:LS(@"Open Folder As a Disc...") action:@selector(openFolderAsDisc:) keyEquivalent:@""];
	[folder setTarget:delegate]; [menu addItem:folder]; [folder release];
	NSMenuItem *file = [[NSMenuItem alloc] initWithTitle:LS(@"Open File(s)...") action:@selector(openFile:) keyEquivalent:@""];
	[file setTarget:delegate]; [menu addItem:file]; [file release];
}

- (void)syncOutputFormatPopUp
{
	if(!o_outputFormatPopUp || !delegate) return;
	NSArray *titles = [delegate outputFormatTitles];
	NSString *current = [delegate currentOutputFormatTitle];
	[o_outputFormatPopUp removeAllItems];
	if(titles) [o_outputFormatPopUp addItemsWithTitles:titles];
	if(current && [o_outputFormatPopUp itemWithTitle:current]) [o_outputFormatPopUp selectItemWithTitle:current];
}

- (IBAction)outputFormatChangedFromToolbar:(id)sender
{
	[delegate selectOutputFormatWithTitle:[o_outputFormatPopUp titleOfSelectedItem]];
}

- (IBAction)toggleAccurateRip:(id)sender
{
	/* Toggle the AccurateRip status indicator between YES and NO. */
	NSString *cur = [o_accurateRipStatus stringValue];
	[o_accurateRipStatus setStringValue:[cur isEqualToString:LS(@"YES")] ? LS(@"NO") : LS(@"YES")];
}

- (BOOL)validateToolbarItem:(NSToolbarItem *)theItem
{
	/* Settings and the output-format pull-down are always available. */
	if([[theItem itemIdentifier] isEqualToString:@"Settings"]) return YES;
	if([[theItem itemIdentifier] isEqualToString:@"OutputFormat"]) return YES;
	if([[theItem itemIdentifier] isEqualToString:@"Open"]) return YES;
	int selected = [o_selectorTable selectedRow];
	if(selected < 0) return NO;
	if([[theItem itemIdentifier] isEqualToString:@"EditMetadata"]) return ([self cueParser] != nil);
	else if([[theItem itemIdentifier] isEqualToString:@"Burn"]) 
		return [[parserArray objectAtIndex:selected] writable];
	return YES;
}

#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5
- (CGFloat)splitView:(NSSplitView *)sender constrainMinCoordinate:(CGFloat)proposedMin ofSubviewAt:(NSInteger)offset
#else
- (float)splitView:(NSSplitView *)sender constrainMinCoordinate:(float)proposedMin ofSubviewAt:(int)offset
#endif
{
	return proposedMin + 150;
}

#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5
- (CGFloat)splitView:(NSSplitView *)sender constrainMaxCoordinate:(CGFloat)proposedMax ofSubviewAt:(NSInteger)offset
#else
- (float)splitView:(NSSplitView *)sender constrainMaxCoordinate:(float)proposedMax ofSubviewAt:(int)offset
#endif
{
	return proposedMax - 490;
}

- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)proposedFrameSize
{
	if(splitPosition) [splitPosition release];
	splitPosition = [[self splitViewPosition: o_splitView] retain];
	return proposedFrameSize;
}

- (void)windowDidResize:(NSNotification *)aNotification
{
	[self setSplitViewPosition: o_splitView position: splitPosition];
	[splitPosition release];
	splitPosition = nil;
	/* Clear any stale pixels left by live resize when layer-backed in dark mode. */
	if(XLDDarkModeSupportEnabled) [[o_window contentView] setNeedsDisplay:YES];
}

- (int)numberOfRowsInTableView:(NSTableView *)aTableView
{
	if(aTableView == o_selectorTable) {
		return [parserArray count];
	}
	else {
		if(![parserArray count]) return 0;
		return [[[parserArray objectAtIndex:[o_selectorTable selectedRow]] trackList] count];
	}
	return 0;
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(int)rowIndex
{
	if(![parserArray count]) return nil;
	
	if(aTableView == o_selectorTable) {
		if([[aTableColumn identifier] isEqualToString:@"Icon"]) {
			if([[[[parserArray objectAtIndex:rowIndex] fileToDecode] lastPathComponent] isEqualToString:@"CDImage.folder"]) {
				NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFolder];
				[icon setSize:NSMakeSize(16, 16)];
				return icon;
			}
			else {
				NSString *path = [[parserArray objectAtIndex:rowIndex] fileToDecode];
				if(path && [path hasPrefix:@"/dev/disk"]) return [[NSWorkspace sharedWorkspace] iconForDisc];
			}
			return [NSImage imageNamed:@"cue"];
		}
		else {
			return [[parserArray objectAtIndex:rowIndex] title];
		}
	}
	else {
		NSString *identifier = [aTableColumn identifier];
		id cueParser = [parserArray objectAtIndex:[o_selectorTable selectedRow]];
		if([identifier isEqualToString:@"Check"]) {
			return nil;
		}
		else {
			if(rowIndex >= [[cueParser trackList] count]) return nil;
			if([identifier isEqualToString:@"Track"]) {
				id meta = [[[cueParser trackList] objectAtIndex:rowIndex] metadata];
				NSNumber *track = [meta objectForKey:XLD_METADATA_TRACK];
				NSNumber *disc = [meta objectForKey:XLD_METADATA_DISC];
				NSNumber *totalDiscs = [meta objectForKey:XLD_METADATA_TOTALDISCS];
				/* Only prefix the disc number for a multi-disc set; a lone disc shows
				   just the zero-padded track number. */
				BOOL multiDisc = (totalDiscs && [totalDiscs intValue] > 1) || (disc && [disc intValue] > 1);
				int tn = track ? [track intValue] : (rowIndex+1);
				if(multiDisc && disc) return [NSString stringWithFormat:@"%d-%02d",[disc intValue],tn];
				return [NSString stringWithFormat:@"%02d",tn];
			}
			else if([identifier isEqualToString:@"Title"]) {
				NSString *title = [[[[cueParser trackList] objectAtIndex:rowIndex] metadata] objectForKey:XLD_METADATA_TITLE];
				if(title) return title;
				else return [NSString stringWithFormat:@"Track %02d",rowIndex+1];
			}
			else if([identifier isEqualToString:@"Artist"]) {
				return [[[[cueParser trackList] objectAtIndex:rowIndex] metadata] objectForKey:XLD_METADATA_ARTIST];
			}
			else if([identifier isEqualToString:@"Length"]) {
				return [cueParser lengthOfTrack:rowIndex];
			}
			else if([identifier isEqualToString:@"Pregap"]) {
				return [cueParser gapOfTrack:rowIndex];
			}
			return nil;
		}
	}
	return nil;
}

- (void)tableViewSelectionDidChange:(NSNotification *)aNotification
{
	if([aNotification object] == o_selectorTable) {
		[self reloadData];
		[o_trackTable deselectAll:nil];
		[self extractionModeChanged:o_extractionMode];
	}
}

- (void)tableView:(NSTableView *)tableView mouseDownInHeaderOfTableColumn:(NSTableColumn *)tableColumn
{
	if(tableView == o_trackTable) {
		BOOL checkMode = NO;
		if([[tableColumn identifier] isEqualToString:@"Check"]) {
			int i;
			for(i=0;i<[checkArray count];i++) {
				if([[checkArray objectAtIndex:i] isEnabled] && [[checkArray objectAtIndex:i] state] == NSOffState) {
					checkMode = YES;
					break;
				}
			}
			for(i=0;i<[checkArray count];i++) {
				if(checkMode) [self checkAtIndex:i];
				else [self uncheckAtIndex:i];
			}
		}
	}
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	if([menuItem action] == @selector(saveImage:)) {
		if(![parserArray count]) return NO;
        return ([o_imageView imageData] != nil);
	}
	else if([menuItem action] == @selector(openImage:)) {
		if(![parserArray count]) return NO;
	}
	else if([menuItem action] == @selector(clearImage:)) {
		if(![parserArray count]) return NO;
		return ([o_imageView imageData] != nil);
	}
	else if([menuItem action] == @selector(checkSelected:))
	{
		if(!checkArray) return NO;
		if([[o_extractionMode selectedItem] tag] == 2) return NO;
		if([menuItem tag] == 0 && [o_trackTable selectedRow] == -1) return NO;
	}
	else if([menuItem action] == @selector(uncheckSelected:))
	{
		if(!checkArray) return NO;
		if([[o_extractionMode selectedItem] tag] == 2) return NO;
		if([menuItem tag] == 0 && [o_trackTable selectedRow] == -1) return NO;
	}
	else if([menuItem action] == @selector(editMetadata:))
	{
		if(![parserArray count]) return NO;
	}
	return YES;
}

- (BOOL)windowShouldClose:(id)sender
{
	if(sender != o_window) return YES;
	int idx = [o_selectorTable selectedRow];
	if(idx < 0) return YES;
	[self closeFile:[[self cueParser] fileToDecode]];
	return NO;
}

- (void)startBurn:(DRBurn *)burn withLayout:(NSArray *)layout
{
	if(!burn || !layout) {
		NSBeginAlertSheet(LS(@"Burn Failed"), @"OK", nil, nil, o_window, nil, nil, nil, NULL, LS(@"There is not enough space available on the disc."));
		return;
	}
	DRBurnProgressPanel *bpp = [DRBurnProgressPanel progressPanel];
	[bpp setDelegate:self];
	SEL selector = @selector(beginProgressSheetForBurn:layout:modalForWindow:);
	NSMethodSignature* signature = [bpp methodSignatureForSelector:selector];
	NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:signature];
	[invocation setTarget:bpp];
	[invocation setSelector:selector];
	[invocation setArgument:(void *)&burn atIndex:2];
	[invocation setArgument:(void *)&layout atIndex:3];
	[invocation setArgument:(void *)&o_window atIndex:4];
	[invocation retainArguments];
	[invocation performSelector:@selector(invoke) withObject:nil afterDelay:0.5];
	burning = YES;
	checkUpdateStatus = [delegate checkUpdateStatus];
	if(checkUpdateStatus) [delegate setCheckUpdateStatus:NO];
}

- (void)setupPanelDidEnd:(DRBurnSetupPanel*)bsp returnCode:(int)returnCode contextInfo:(void*)contextInfo
{
	if(returnCode != NSOKButton) return;
	
	XLDCueParser *parser = [parserArray objectAtIndex:[o_selectorTable selectedRow]];
	
	BOOL noEnoughSpace = NO;
	if([[[bsp burnObject] properties] objectForKey:DRBurnOverwriteDiscKey] && [[[[bsp burnObject] properties] objectForKey:DRBurnOverwriteDiscKey] boolValue]) {
		xldoffset_t available = 588*[[[[[[bsp burnObject] device] status] objectForKey:DRDeviceMediaInfoKey] objectForKey:DRDeviceMediaBlocksOverwritableKey] longLongValue];
		if(available < [parser totalFrames]) noEnoughSpace = YES;
	}
	else {
		xldoffset_t available = 588*[[[[[[bsp burnObject] device] status] objectForKey:DRDeviceMediaInfoKey] objectForKey:DRDeviceMediaBlocksFreeKey] longLongValue];
		if(available < [parser totalFrames]) noEnoughSpace = YES;
	}
	
	/*NSLog(@"%@",[[[bsp burnObject] properties] description]);
	NSLog(@"%@",[[[[bsp burnObject] device] status] description]);*/
	
	if(noEnoughSpace) {
		SEL selector = @selector(startBurn:withLayout:);
		NSMethodSignature* signature = [self methodSignatureForSelector:selector];
		NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:signature];
		[invocation setTarget:self];
		[invocation setSelector:selector];
		[invocation performSelector:@selector(invoke) withObject:nil afterDelay:0.5];
		return;
	}
	//return;
	
	NSMutableDictionary *newProps = [NSMutableDictionary dictionaryWithDictionary:[[bsp burnObject] properties]];
	[newProps setObject:DRBurnStrategyCDSAO forKey:DRBurnStrategyKey];
	NSString *mcn = [[[[parser trackList] objectAtIndex:0] metadata] objectForKey:XLD_METADATA_CATALOG];
	if(mcn) {
		NSMutableCharacterSet *cSet = [[NSMutableCharacterSet alloc] init];
		[cSet addCharactersInRange:NSMakeRange('0', 10)];
		NSRange range = [mcn rangeOfCharacterFromSet:cSet];
		if(range.location == 0 && range.length == [mcn length]) {
			if([mcn length] == 13) [newProps setObject:[NSData dataWithBytes:[mcn UTF8String] length:13] forKey:DRMediaCatalogNumberKey];
			else if([mcn length] == 12) [newProps setObject:[NSData dataWithBytes:[[@"0" stringByAppendingString:mcn] UTF8String] length:13] forKey:DRMediaCatalogNumberKey];
		}
		[cSet release];
	}
	DRBurn *burn = [DRBurn burnForDevice:[[bsp burnObject] device]];
	[burn setProperties:newProps];
	//NSLog(@"%@",[newProps description]);
	
	burner = [[XLDDiscBurner alloc] initWithTracks:[parser trackList] andLayout:[parser discLayout]];
	[burner setWriteOffset:[delegate writeOffset]];
	[burner setReadOffsetCorrectionValue:[delegate readOffsetForVerify]];
	
	SEL selector = @selector(startBurn:withLayout:);
	NSMethodSignature* signature = [self methodSignatureForSelector:selector];
	NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:signature];
	NSArray *trackLayout = [burner recordingTrackList];
	[invocation setTarget:self];
	[invocation setSelector:selector];
	[invocation setArgument:(void *)&burn atIndex:2];
	[invocation setArgument:(void *)&trackLayout atIndex:3];
	[invocation retainArguments];
	[invocation performSelectorOnMainThread:@selector(invoke) withObject:nil waitUntilDone:YES];
}

- (void) burnProgressPanelDidFinish:(NSNotification*)aNotification
{
	NSString *str = [burner reportString];
	if(str) [delegate showLogStr:str];
	[burner release];
	burner = nil;
	burning = NO;
	if(checkUpdateStatus) [delegate setCheckUpdateStatus:NO];
}

-(NSDragOperation)tableView:(NSTableView*)tv validateDrop:(id <NSDraggingInfo>)info proposedRow:(int)row proposedDropOperation:(NSTableViewDropOperation)op
{
	if(tv != o_selectorTable) return NSDragOperationNone;
	
	NSPasteboard *pboard = [info draggingPasteboard];
	if(op == NSTableViewDropAbove && [[pboard types] containsObject:NSFilenamesPboardType]) {
		NSArray *fileArr = [[info draggingPasteboard] propertyListForType:NSFilenamesPboardType];
		if([fileArr count] != 1) return NSDragOperationNone;
		return NSDragOperationCopy;
	}
	return NSDragOperationNone;
}

-(BOOL)tableView:(NSTableView*)tv acceptDrop:(id <NSDraggingInfo>)info row:(int)row dropOperation:(NSTableViewDropOperation)op
{
	if(tv != o_selectorTable) return NO;
	
	NSString *path = [[[info draggingPasteboard] propertyListForType:NSFilenamesPboardType] objectAtIndex:0];
	BOOL isDir;
	if([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir]) {
		proposedRow = row;
		if(isDir) [delegate openFolder:path offset:0 prepended:NO];
		else [delegate processSingleFile:path alwaysOpenAsDisc:YES];
		proposedRow = -1;
		return YES;
	}
	return NO;
}

- (void)accurateRipDatabaseDidBecomeAvailable:(NSNotification *)notification
{
	XLDAccurateRipDB *db = [notification object];
	id cueParser = [self cueParser];
	if ([cueParser accurateRipData] == db) {
		XLDAccurateRipDBState arState = [db state];
		NSString *arStateString = @"???";
		if (arState == kXLDAccurateRipDBStateFound) arStateString = LS(@"YES");
		else if (arState == kXLDAccurateRipDBStateNotFound) arStateString = LS(@"NO");
		else if (arState == kXLDAccurateRipDBStateNetworkError) arStateString = @"ERR";
		[o_accurateRipStatus setStringValue:arStateString];
		if (arState == kXLDAccurateRipDBStateFound && [cueParser fileToDecode] && ![[cueParser fileToDecode] hasPrefix:@"/dev/disk"])
			[o_verify setHidden:NO];
		else [o_verify setHidden:YES];
	}
	[[NSNotificationCenter defaultCenter] removeObserver:self name:@"XLDARDBDidFinishLoadingNotification" object:db];
}

@end
