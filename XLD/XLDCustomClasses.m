//
//  XLDCustomClasses.m
//  XLD
//
//  Created by tmkk on 09/02/14.
//  Copyright 2009 tmkk. All rights reserved.
//

#import "XLDCustomClasses.h"
#import "XLDTrack.h"
#import <sys/sysctl.h>

#define NSAppKitVersionNumber10_4 824

extern int XLDDarkModeSupportEnabled;

static NSString *framesToMSFStr(xldoffset_t frames, int samplerate)
{
	int min = frames/samplerate/60;
	frames -= (xldoffset_t)min*samplerate*60;
	int sec = frames/samplerate;
	frames -= (xldoffset_t)sec*samplerate;
	int f = frames*75/samplerate;
	return [NSString stringWithFormat:@"%02d:%02d:%02d",min,sec,f];
}

@implementation XLDView

- (int)tag
{
	return tag;
}

- (void)setTag:(int)t
{
	tag = t;
}

@end

@implementation XLDTextView

- (void)dealloc
{
	if(actionTarget) [actionTarget release];
	[super dealloc];
}

- (void)setActionTarget:(id)target
{
	if(actionTarget) [actionTarget release];
	actionTarget = [target retain];
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
	NSMenu *menu = [super menuForEvent:event];
	int tag = [(XLDView *)[self delegate] tag];
	if(tag >= 100) {
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:LS(@"Apply This Item for All Tracks") action:@selector(applyForAll:) keyEquivalent:@""];
		[item setTarget:actionTarget];
		[item setTag:tag];
		[menu insertItem:item atIndex:0];
		[item release];
		[menu insertItem:[NSMenuItem separatorItem] atIndex:1];
	}
	else {
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:LS(@"Apply This Item for All Files") action:@selector(applyForAll:) keyEquivalent:@""];
		[item setTarget:actionTarget];
		[item setTag:tag];
		[menu insertItem:item atIndex:0];
		[item release];
		item = [[NSMenuItem alloc] initWithTitle:LS(@"Apply This Item for the Same Album") action:@selector(applyForAlbum:) keyEquivalent:@""];
		[item setTarget:actionTarget];
		[item setTag:tag];
		[menu insertItem:item atIndex:1];
		[menu insertItem:[NSMenuItem separatorItem] atIndex:2];
		[item release];
	}
	
	return menu;
}

@end

@implementation NSImage (String)
+ (NSImage *)imageWithString:(NSString *)string withFont:(NSFont *)font withColor:(NSColor *)color
{
    /* An empty string renders to a zero-width image; locking focus on a
       zero-size NSImage throws and crashes the app. Bail out instead. */
    if(!string || [string length] == 0) return nil;
    NSLayoutManager *layoutManager = [[[NSLayoutManager alloc] init] autorelease];
    NSTextContainer *textContainer = [[[NSTextContainer alloc] init] autorelease];
    NSTextStorage *textStorage = [[[NSTextStorage alloc] initWithString:string attributes:[NSDictionary dictionaryWithObjectsAndKeys:font,NSFontAttributeName,nil]] autorelease];
    NSGlyph *glyphs;
    unsigned int glyphLength;
    NSRange range;
    [layoutManager addTextContainer:textContainer];
    [textStorage addLayoutManager:layoutManager];
    range = [layoutManager glyphRangeForTextContainer:textContainer];
    
    glyphs = (NSGlyph *)malloc(10*sizeof(NSGlyph)*(range.length+1));
    glyphLength = [layoutManager getGlyphs:glyphs range:range];
    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:NSMakePoint(0, [font pointSize])];
    [path appendBezierPathWithGlyphs:glyphs count:glyphLength inFont:font];
    NSShadow *shadow = [[NSShadow alloc] init];
    [shadow setShadowOffset:NSMakeSize(3,-3)];
    [shadow setShadowBlurRadius:3];
    [shadow setShadowColor:[NSColor lightGrayColor]];
    if([path currentPoint].x <= 0) { free(glyphs); return nil; } /* nothing to draw */
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize([path currentPoint].x,[font pointSize]*2)];
    [img lockFocus];
    [color set];
    //[shadow set];
    [path fill];
    [img unlockFocus];
    [shadow release];
    
    NSRect targetImageFrame = NSMakeRect(0,0,170,170);
    NSImage *targetImage = [[NSImage alloc] initWithSize:targetImageFrame.size];
    [targetImage lockFocus];
    [[NSColor controlLightHighlightColor] set];
    NSRectFill(targetImageFrame);
    [img compositeToPoint:NSMakePoint((170-[img size].width)/2,(170-[img size].height)/2-5) operation:NSCompositeSourceOver];
    [targetImage unlockFocus];
    [img release];
    free(glyphs);
    return [targetImage autorelease];
}
@end

@implementation XLDButton

- (void)mouseDown:(NSEvent *)theEvent 
{
	modifierFlags = [theEvent modifierFlags];
	[super mouseDown:theEvent];
}

- (BOOL)commandKeyPressed
{
	return ((modifierFlags & NSCommandKeyMask) != 0);
}

- (BOOL)optionKeyPressed
{
	return ((modifierFlags & NSAlternateKeyMask) != 0);
}

- (BOOL)shiftKeyPressed
{
	return ((modifierFlags & NSShiftKeyMask) != 0);
}

@end

@implementation XLDTrackListUtil

+ (NSString *)artistForTracks:(NSArray *)tracks
{
	if(!tracks) return @"";
	if([tracks count] == 0) return @"";
	if([[[tracks objectAtIndex:0] metadata] objectForKey:XLD_METADATA_ALBUMARTIST])
		return [[[tracks objectAtIndex:0] metadata] objectForKey:XLD_METADATA_ALBUMARTIST];
	NSString *artist = nil;
	int i;
	for(i=0;i<[tracks count];i++) {
		BOOL dataTrack = NO;
		if([[[tracks objectAtIndex:i] metadata] objectForKey:XLD_METADATA_DATATRACK]) {
			dataTrack = [[[[tracks objectAtIndex:i] metadata] objectForKey:XLD_METADATA_DATATRACK] boolValue];
		}
		if(dataTrack) continue;
		NSString *str = [[[tracks objectAtIndex:i] metadata] objectForKey:XLD_METADATA_ARTIST];
		if(!str) continue;
		else if([str isEqualToString:@""]) continue;
		else if([str isEqualToString:@" "]) continue;
		else if([str isEqualToString:LS(@"multibyteSpace")]) continue;
		else if(!artist) artist = str;
		else if([artist isEqualToString:str]) continue;
		else return LS(@"Various Artists");
	}
	if(!artist) return @"";
	return artist;
}

+ (NSString *)artistForTracks:(NSArray *)tracks sameArtistForAllTracks:(BOOL*)allSame
{
	*allSame = NO;
	if(!tracks) return @"";
	if([tracks count] == 0) return @"";
	if([[[tracks objectAtIndex:0] metadata] objectForKey:XLD_METADATA_ALBUMARTIST])
		return [[[tracks objectAtIndex:0] metadata] objectForKey:XLD_METADATA_ALBUMARTIST];
	NSString *artist = nil;
	int i;
	for(i=0;i<[tracks count];i++) {
		BOOL dataTrack = NO;
		if([[[tracks objectAtIndex:i] metadata] objectForKey:XLD_METADATA_DATATRACK]) {
			dataTrack = [[[[tracks objectAtIndex:i] metadata] objectForKey:XLD_METADATA_DATATRACK] boolValue];
		}
		if(dataTrack) continue;
		*allSame = NO;
		NSString *str = [[[tracks objectAtIndex:i] metadata] objectForKey:XLD_METADATA_ARTIST];
		if(!str) continue;
		else if([str isEqualToString:@""]) continue;
		else if([str isEqualToString:@" "]) continue;
		else if([str isEqualToString:LS(@"multibyteSpace")]) continue;
		else if(!artist) {
			*allSame = YES;
			artist = str;
		}
		else if([artist isEqualToString:str]) {
			*allSame = YES;
		}
		else return LS(@"Various Artists");
	}
	if(!artist) return @"";
	return artist;
}

+ (NSString *)dateForTracks:(NSArray *)tracks
{
	if(!tracks) return nil;
	if([tracks count] == 0) return nil;
	NSString *date = nil;
	int i;
	for(i=0;i<[tracks count];i++) {
		BOOL dataTrack = NO;
		if([[[tracks objectAtIndex:i] metadata] objectForKey:XLD_METADATA_DATATRACK]) {
			dataTrack = [[[[tracks objectAtIndex:i] metadata] objectForKey:XLD_METADATA_DATATRACK] boolValue];
		}
		if(dataTrack) continue;
		NSString *str = [[[tracks objectAtIndex:i] metadata] objectForKey:XLD_METADATA_DATE];
		if(!str) str = [[[[tracks objectAtIndex:i] metadata] objectForKey:XLD_METADATA_YEAR] stringValue];
		if(!str) return nil;
		else if(!date) {
			date = str;
		}
		else if([date isEqualToString:str]) continue;
		else return nil;
	}
	return date;
}

+ (NSString *)genreForTracks:(NSArray *)tracks
{
	if(!tracks) return nil;
	if([tracks count] == 0) return nil;
	NSString *genre = nil;
	int i;
	for(i=0;i<[tracks count];i++) {
		BOOL dataTrack = NO;
		if([[[tracks objectAtIndex:i] metadata] objectForKey:XLD_METADATA_DATATRACK]) {
			dataTrack = [[[[tracks objectAtIndex:i] metadata] objectForKey:XLD_METADATA_DATATRACK] boolValue];
		}
		if(dataTrack) continue;
		NSString *str = [[[tracks objectAtIndex:i] metadata] objectForKey:XLD_METADATA_GENRE];
		if(!str) return nil;
		else if(!genre) {
			genre = str;
		}
		else if([genre isEqualToString:str]) continue;
		else return nil;
	}
	return genre;
}

+ (NSString *)albumTitleForTracks:(NSArray *)tracks
{
	if(!tracks) return nil;
	if([tracks count] == 0) return nil;
	NSString *title = nil;
	int i;
	for(i=0;i<[tracks count];i++) {
		BOOL dataTrack = NO;
		if([[[tracks objectAtIndex:i] metadata] objectForKey:XLD_METADATA_DATATRACK]) {
			dataTrack = [[[[tracks objectAtIndex:i] metadata] objectForKey:XLD_METADATA_DATATRACK] boolValue];
		}
		if(dataTrack) continue;
		NSString *str = [[[tracks objectAtIndex:i] metadata] objectForKey:XLD_METADATA_ALBUM];
		if(!str) return nil;
		else if(!title) {
			title = str;
		}
		else if([title isEqualToString:str]) continue;
		else return nil;
	}
	return title;
}

+ (NSMutableData *)cueDataForTracks:(NSArray *)tracks withFileName:(NSString *)filename appendBOM:(BOOL)appendBOM samplerate:(int)samplerate
{
	if(!tracks) return nil;
	int i,n=1;
	int offset = 0;
	BOOL removeRedundancy = NO;
	NSMutableData *data = [[NSMutableData alloc] init];
	if(appendBOM) {
		const unsigned char bom[] = {0xEF,0xBB,0xBF};
		[data appendBytes:bom length:3];
	}
	NSString *albumDate = [XLDTrackListUtil dateForTracks:tracks];
	NSString *albumGenre = [XLDTrackListUtil genreForTracks:tracks];
	id obj;
	if(obj=[[[tracks objectAtIndex:0] metadata] objectForKey:XLD_METADATA_ALBUM])
		[data appendData:[[NSString stringWithFormat:@"TITLE \"%@\"\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
	if(obj=[[[tracks objectAtIndex:0] metadata] objectForKey:XLD_METADATA_ALBUMARTIST])
		[data appendData:[[NSString stringWithFormat:@"PERFORMER \"%@\"\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
	else {
		NSString *aartist = [XLDTrackListUtil artistForTracks:tracks sameArtistForAllTracks:&removeRedundancy];
		if(removeRedundancy)
			[data appendData:[[NSString stringWithFormat:@"PERFORMER \"%@\"\n",aartist] dataUsingEncoding:NSUTF8StringEncoding]];
	}
	if(obj=[[[tracks objectAtIndex:0] metadata] objectForKey:XLD_METADATA_CATALOG])
		[data appendData:[[NSString stringWithFormat:@"CATALOG %@\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
	if(albumGenre) {
		[data appendData:[[NSString stringWithFormat:@"REM GENRE \"%@\"\n",albumGenre] dataUsingEncoding:NSUTF8StringEncoding]];
	}
	if(albumDate) {
		[data appendData:[[NSString stringWithFormat:@"REM DATE \"%@\"\n",albumDate] dataUsingEncoding:NSUTF8StringEncoding]];
	}
	if(obj=[[[tracks objectAtIndex:0] metadata] objectForKey:XLD_METADATA_DISC])
		[data appendData:[[NSString stringWithFormat:@"REM DISCNUMBER %d\n",[obj intValue]] dataUsingEncoding:NSUTF8StringEncoding]];
	if(obj=[[[tracks objectAtIndex:0] metadata] objectForKey:XLD_METADATA_TOTALDISCS])
		[data appendData:[[NSString stringWithFormat:@"REM TOTALDISCS %d\n",[obj intValue]] dataUsingEncoding:NSUTF8StringEncoding]];
	if(obj=[[[tracks objectAtIndex:0] metadata] objectForKey:XLD_METADATA_FREEDBDISCID])
		[data appendData:[[NSString stringWithFormat:@"REM DISCID %08X\n",[obj unsignedIntValue]] dataUsingEncoding:NSUTF8StringEncoding]];
	if(obj=[[[tracks objectAtIndex:0] metadata] objectForKey:XLD_METADATA_REPLAYGAIN_ALBUM_GAIN])
		[data appendData:[[NSString stringWithFormat:@"REM REPLAYGAIN_ALBUM_GAIN %.2f dB\n",[obj floatValue]] dataUsingEncoding:NSUTF8StringEncoding]];
	if(obj=[[[tracks objectAtIndex:0] metadata] objectForKey:XLD_METADATA_REPLAYGAIN_ALBUM_PEAK])
		[data appendData:[[NSString stringWithFormat:@"REM REPLAYGAIN_ALBUM_PEAK %f\n",[obj floatValue]] dataUsingEncoding:NSUTF8StringEncoding]];
	if(obj=[[[tracks objectAtIndex:0] metadata] objectForKey:XLD_METADATA_COMPILATION])
		if([obj boolValue]) [data appendData:[@"REM COMPILATION TRUE\n" dataUsingEncoding:NSUTF8StringEncoding]];
	[data appendData:[[NSString stringWithFormat:@"FILE \"%@\" WAVE\n",[filename precomposedStringWithCanonicalMapping]] dataUsingEncoding:NSUTF8StringEncoding]];
	
	for(i=0;i<[tracks count];i++) {
		XLDTrack *track = [tracks objectAtIndex:i];
		if([[track metadata] objectForKey:XLD_METADATA_DATATRACK]) {
			if(i==0) {
				offset = [track frames];
				if(i+1 < [tracks count]) offset += [[tracks objectAtIndex:i+1] gap];
			}
			continue;
		}
		[data appendData:[[NSString stringWithFormat:@"  TRACK %02d AUDIO\n",n] dataUsingEncoding:NSUTF8StringEncoding]];
		if(obj=[[track metadata] objectForKey:XLD_METADATA_TITLE])
			[data appendData:[[NSString stringWithFormat:@"    TITLE \"%@\"\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
		if((obj=[[track metadata] objectForKey:XLD_METADATA_ARTIST]) && !removeRedundancy)
			[data appendData:[[NSString stringWithFormat:@"    PERFORMER \"%@\"\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
		if(obj=[[track metadata] objectForKey:XLD_METADATA_COMPOSER])
			[data appendData:[[NSString stringWithFormat:@"    SONGWRITER \"%@\"\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
		if(obj=[[track metadata] objectForKey:XLD_METADATA_ISRC]) 
			[data appendData:[[NSString stringWithFormat:@"    ISRC %@\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
		if(obj=[[track metadata] objectForKey:XLD_METADATA_PREEMPHASIS]) {
			if([obj boolValue]) [data appendData:[@"    FLAGS PRE\n" dataUsingEncoding:NSUTF8StringEncoding]];
		}
		if(obj=[[track metadata] objectForKey:XLD_METADATA_DCP]) {
			if([obj boolValue]) [data appendData:[@"    FLAGS DCP\n" dataUsingEncoding:NSUTF8StringEncoding]];
		}
		if(!albumGenre) {
			if(obj=[[track metadata] objectForKey:XLD_METADATA_GENRE])
				[data appendData:[[NSString stringWithFormat:@"    REM GENRE \"%@\"\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
		}
		if(!albumDate) {
			if(obj=[[track metadata] objectForKey:XLD_METADATA_DATE])
				[data appendData:[[NSString stringWithFormat:@"    REM DATE \"%@\"\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
			else if(obj=[[track metadata] objectForKey:XLD_METADATA_YEAR])
				[data appendData:[[NSString stringWithFormat:@"    REM DATE %d\n",[obj intValue]] dataUsingEncoding:NSUTF8StringEncoding]];
		}
		if(obj=[[track metadata] objectForKey:XLD_METADATA_COMMENT]) {
			NSMutableString *str = [NSMutableString stringWithString:obj];
			[str replaceOccurrencesOfString:@"\n" withString:@" " options:0 range:NSMakeRange(0,[obj length])];
			[data appendData:[[NSString stringWithFormat:@"    REM COMMENT \"%@\"\n",str] dataUsingEncoding:NSUTF8StringEncoding]];
		}
		if(obj=[[track metadata] objectForKey:XLD_METADATA_REPLAYGAIN_TRACK_GAIN])
			[data appendData:[[NSString stringWithFormat:@"    REM REPLAYGAIN_TRACK_GAIN %.2f dB\n",[obj floatValue]] dataUsingEncoding:NSUTF8StringEncoding]];
		if(obj=[[track metadata] objectForKey:XLD_METADATA_REPLAYGAIN_TRACK_PEAK])
			[data appendData:[[NSString stringWithFormat:@"    REM REPLAYGAIN_TRACK_PEAK %f\n",[obj floatValue]] dataUsingEncoding:NSUTF8StringEncoding]];
		
		if([track gap] != 0)
			[data appendData:[[NSString stringWithFormat:@"    INDEX 00 %@\n",framesToMSFStr([track index]-[track gap]-offset,samplerate)] dataUsingEncoding:NSUTF8StringEncoding]];
		[data appendData:[[NSString stringWithFormat:@"    INDEX 01 %@\n",framesToMSFStr([track index]-offset,samplerate)] dataUsingEncoding:NSUTF8StringEncoding]];
		n++;
	}
	return [data autorelease];
}

+ (NSMutableData *)nonCompliantCueDataForTracks:(NSArray *)trackList withFileNameArray:(NSArray *)filelist appendBOM:(BOOL)appendBOM gapStatus:(unsigned int)status samplerate:(int)samplerate
{
	if(!trackList) return nil;
	int i,n=1;
	BOOL removeRedundancy = NO;
	BOOL nogap = NO;
	BOOL HTOA = NO;
	switch(status & 0xffff) {
		case 0:
			HTOA = YES;
			break;
		case 1:
			nogap = YES;
			break;
		case 2:
			HTOA = YES;
			break;
		case 3:
			HTOA = NO;
			break;
	}
	
	NSMutableData *data = [[NSMutableData alloc] init];
	NSString *albumDate = [XLDTrackListUtil dateForTracks:trackList];
	NSString *albumGenre = [XLDTrackListUtil genreForTracks:trackList];
	id obj;
	if(obj=[[[trackList objectAtIndex:0] metadata] objectForKey:XLD_METADATA_ALBUM])
		[data appendData:[[NSString stringWithFormat:@"TITLE \"%@\"\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
	if(obj=[[[trackList objectAtIndex:0] metadata] objectForKey:XLD_METADATA_ALBUMARTIST])
		[data appendData:[[NSString stringWithFormat:@"PERFORMER \"%@\"\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
	else {
		NSString *aartist = [XLDTrackListUtil artistForTracks:trackList sameArtistForAllTracks:&removeRedundancy];
		if(removeRedundancy)
			[data appendData:[[NSString stringWithFormat:@"PERFORMER \"%@\"\n",aartist] dataUsingEncoding:NSUTF8StringEncoding]];
	}
	if(obj=[[[trackList objectAtIndex:0] metadata] objectForKey:XLD_METADATA_CATALOG])
		[data appendData:[[NSString stringWithFormat:@"CATALOG %@\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
	if(albumGenre) {
		[data appendData:[[NSString stringWithFormat:@"REM GENRE \"%@\"\n",albumGenre] dataUsingEncoding:NSUTF8StringEncoding]];
	}
	if(albumDate) {
		[data appendData:[[NSString stringWithFormat:@"REM DATE \"%@\"\n",albumDate] dataUsingEncoding:NSUTF8StringEncoding]];
	}
	if(obj=[[[trackList objectAtIndex:0] metadata] objectForKey:XLD_METADATA_DISC])
		[data appendData:[[NSString stringWithFormat:@"REM DISCNUMBER %d\n",[obj intValue]] dataUsingEncoding:NSUTF8StringEncoding]];
	if(obj=[[[trackList objectAtIndex:0] metadata] objectForKey:XLD_METADATA_TOTALDISCS])
		[data appendData:[[NSString stringWithFormat:@"REM TOTALDISCS %d\n",[obj intValue]] dataUsingEncoding:NSUTF8StringEncoding]];
	if(obj=[[[trackList objectAtIndex:0] metadata] objectForKey:XLD_METADATA_FREEDBDISCID])
		[data appendData:[[NSString stringWithFormat:@"REM DISCID %08X\n",[obj unsignedIntValue]] dataUsingEncoding:NSUTF8StringEncoding]];
	if(obj=[[[trackList objectAtIndex:0] metadata] objectForKey:XLD_METADATA_REPLAYGAIN_ALBUM_GAIN])
		[data appendData:[[NSString stringWithFormat:@"REM REPLAYGAIN_ALBUM_GAIN %.2f dB\n",[obj floatValue]] dataUsingEncoding:NSUTF8StringEncoding]];
	if(obj=[[[trackList objectAtIndex:0] metadata] objectForKey:XLD_METADATA_REPLAYGAIN_ALBUM_PEAK])
		[data appendData:[[NSString stringWithFormat:@"REM REPLAYGAIN_ALBUM_PEAK %f\n",[obj floatValue]] dataUsingEncoding:NSUTF8StringEncoding]];
	if(obj=[[[trackList objectAtIndex:0] metadata] objectForKey:XLD_METADATA_COMPILATION])
		if([obj boolValue]) [data appendData:[@"REM COMPILATION TRUE\n" dataUsingEncoding:NSUTF8StringEncoding]];
	
	for(i=0;i<[trackList count];i++) {
		XLDTrack *track = [trackList objectAtIndex:i];
		BOOL dataTrack = NO;
		if([[track metadata] objectForKey:XLD_METADATA_DATATRACK]) {
			dataTrack = [[[track metadata] objectForKey:XLD_METADATA_DATATRACK] boolValue];
		}
		if(dataTrack) continue;
		
		[data appendData:[[NSString stringWithFormat:@"FILE \"%@\" WAVE\n",[[[filelist objectAtIndex:n-1] lastPathComponent] precomposedStringWithCanonicalMapping]] dataUsingEncoding:NSUTF8StringEncoding]];
		if(([track gap] != 0) && (i != 0) && !nogap) {
			[data appendData:[@"    INDEX 01 00:00:00\n" dataUsingEncoding:NSUTF8StringEncoding]];
		}
		else {
			[data appendData:[[NSString stringWithFormat:@"  TRACK %02d AUDIO\n",n] dataUsingEncoding:NSUTF8StringEncoding]];
			if(obj=[[track metadata] objectForKey:XLD_METADATA_TITLE])
				[data appendData:[[NSString stringWithFormat:@"    TITLE \"%@\"\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
			if((obj=[[track metadata] objectForKey:XLD_METADATA_ARTIST]) && !removeRedundancy)
				[data appendData:[[NSString stringWithFormat:@"    PERFORMER \"%@\"\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
			if(obj=[[track metadata] objectForKey:XLD_METADATA_COMPOSER])
				[data appendData:[[NSString stringWithFormat:@"    SONGWRITER \"%@\"\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
			if(obj=[[track metadata] objectForKey:XLD_METADATA_ISRC])
				[data appendData:[[NSString stringWithFormat:@"    ISRC %@\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
			if(obj=[[track metadata] objectForKey:XLD_METADATA_PREEMPHASIS]) {
				if([obj boolValue]) [data appendData:[@"    FLAGS PRE\n" dataUsingEncoding:NSUTF8StringEncoding]];
			}
			if(obj=[[track metadata] objectForKey:XLD_METADATA_DCP]) {
				if([obj boolValue]) [data appendData:[@"    FLAGS DCP\n" dataUsingEncoding:NSUTF8StringEncoding]];
			}
			if(!albumGenre) {
				if(obj=[[track metadata] objectForKey:XLD_METADATA_GENRE])
					[data appendData:[[NSString stringWithFormat:@"    REM GENRE \"%@\"\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
			}
			if(!albumDate) {
				if(obj=[[track metadata] objectForKey:XLD_METADATA_DATE])
					[data appendData:[[NSString stringWithFormat:@"    REM DATE \"%@\"\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
				else if(obj=[[track metadata] objectForKey:XLD_METADATA_YEAR])
					[data appendData:[[NSString stringWithFormat:@"    REM DATE %d\n",[obj intValue]] dataUsingEncoding:NSUTF8StringEncoding]];
			}
			if(obj=[[track metadata] objectForKey:XLD_METADATA_COMMENT]) {
				NSMutableString *str = [NSMutableString stringWithString:obj];
				[str replaceOccurrencesOfString:@"\n" withString:@" " options:0 range:NSMakeRange(0,[obj length])];
				[data appendData:[[NSString stringWithFormat:@"    REM COMMENT \"%@\"\n",str] dataUsingEncoding:NSUTF8StringEncoding]];
			}
			if(obj=[[track metadata] objectForKey:XLD_METADATA_REPLAYGAIN_TRACK_GAIN])
				[data appendData:[[NSString stringWithFormat:@"    REM REPLAYGAIN_TRACK_GAIN %.2f dB\n",[obj floatValue]] dataUsingEncoding:NSUTF8StringEncoding]];
			if(obj=[[track metadata] objectForKey:XLD_METADATA_REPLAYGAIN_TRACK_PEAK])
				[data appendData:[[NSString stringWithFormat:@"    REM REPLAYGAIN_TRACK_PEAK %f\n",[obj floatValue]] dataUsingEncoding:NSUTF8StringEncoding]];
			if(([track gap] != 0) && (i == 0)) {
				if(HTOA && !nogap) {
					[data appendData:[@"    INDEX 00 00:00:00\n" dataUsingEncoding:NSUTF8StringEncoding]];
					[data appendData:[[NSString stringWithFormat:@"    INDEX 01 %@\n",framesToMSFStr([track index],samplerate)] dataUsingEncoding:NSUTF8StringEncoding]];
				}
				else {
					[data appendData:[[NSString stringWithFormat:@"    PREGAP %@\n",framesToMSFStr([track index],samplerate)] dataUsingEncoding:NSUTF8StringEncoding]];
					[data appendData:[@"    INDEX 01 00:00:00\n" dataUsingEncoding:NSUTF8StringEncoding]];
				}
			}
			else if(([track gap] != 0) && nogap) {
				[data appendData:[[NSString stringWithFormat:@"    PREGAP %@\n",framesToMSFStr([track gap],samplerate)] dataUsingEncoding:NSUTF8StringEncoding]];
				[data appendData:[@"    INDEX 01 00:00:00\n" dataUsingEncoding:NSUTF8StringEncoding]];
			}
			else {
				[data appendData:[@"    INDEX 01 00:00:00\n" dataUsingEncoding:NSUTF8StringEncoding]];
			}
		}
		n++;
		
		if((i != [trackList count]-1) && [[trackList objectAtIndex:i+1] gap] && !nogap) {
			[data appendData:[[NSString stringWithFormat:@"  TRACK %02d AUDIO\n",n] dataUsingEncoding:NSUTF8StringEncoding]];
			if(obj=[[[trackList objectAtIndex:i+1] metadata] objectForKey:XLD_METADATA_TITLE])
				[data appendData:[[NSString stringWithFormat:@"    TITLE \"%@\"\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
			if((obj=[[[trackList objectAtIndex:i+1] metadata] objectForKey:XLD_METADATA_ARTIST]) && !removeRedundancy)
				[data appendData:[[NSString stringWithFormat:@"    PERFORMER \"%@\"\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
			if(obj=[[[trackList objectAtIndex:i+1] metadata] objectForKey:XLD_METADATA_COMPOSER])
				[data appendData:[[NSString stringWithFormat:@"    SONGWRITER \"%@\"\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
			if(obj=[[[trackList objectAtIndex:i+1] metadata] objectForKey:XLD_METADATA_ISRC])
				[data appendData:[[NSString stringWithFormat:@"    ISRC %@\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
			if(obj=[[[trackList objectAtIndex:i+1] metadata] objectForKey:XLD_METADATA_PREEMPHASIS]) {
				if([obj boolValue]) [data appendData:[@"    FLAGS PRE\n" dataUsingEncoding:NSUTF8StringEncoding]];
			}
			if(obj=[[[trackList objectAtIndex:i+1] metadata] objectForKey:XLD_METADATA_DCP]) {
				if([obj boolValue]) [data appendData:[@"    FLAGS DCP\n" dataUsingEncoding:NSUTF8StringEncoding]];
			}
			if(!albumGenre) {
				if(obj=[[[trackList objectAtIndex:i+1] metadata] objectForKey:XLD_METADATA_GENRE])
					[data appendData:[[NSString stringWithFormat:@"    REM GENRE \"%@\"\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
			}
			if(!albumDate) {
				if(obj=[[[trackList objectAtIndex:i+1] metadata] objectForKey:XLD_METADATA_DATE])
					[data appendData:[[NSString stringWithFormat:@"    REM DATE \"%@\"\n",obj] dataUsingEncoding:NSUTF8StringEncoding]];
				else if(obj=[[[trackList objectAtIndex:i+1] metadata] objectForKey:XLD_METADATA_YEAR])
					[data appendData:[[NSString stringWithFormat:@"    REM DATE %d\n",[obj intValue]] dataUsingEncoding:NSUTF8StringEncoding]];
			}
			if(obj=[[[trackList objectAtIndex:i+1] metadata] objectForKey:XLD_METADATA_COMMENT]) {
				NSMutableString *str = [NSMutableString stringWithString:obj];
				[str replaceOccurrencesOfString:@"\n" withString:@" " options:0 range:NSMakeRange(0,[obj length])];
				[data appendData:[[NSString stringWithFormat:@"    REM COMMENT \"%@\"\n",str] dataUsingEncoding:NSUTF8StringEncoding]];
			}
			if(obj=[[[trackList objectAtIndex:i+1] metadata] objectForKey:XLD_METADATA_REPLAYGAIN_TRACK_GAIN])
				[data appendData:[[NSString stringWithFormat:@"    REM REPLAYGAIN_TRACK_GAIN %.2f dB\n",[obj floatValue]] dataUsingEncoding:NSUTF8StringEncoding]];
			if(obj=[[[trackList objectAtIndex:i+1] metadata] objectForKey:XLD_METADATA_REPLAYGAIN_TRACK_PEAK])
				[data appendData:[[NSString stringWithFormat:@"    REM REPLAYGAIN_TRACK_PEAK %f\n",[obj floatValue]] dataUsingEncoding:NSUTF8StringEncoding]];
			if(i==0 && HTOA && !nogap) [data appendData:[[NSString stringWithFormat:@"    INDEX 00 %@\n",framesToMSFStr([track frames]+[track gap],samplerate)] dataUsingEncoding:NSUTF8StringEncoding]];
			else [data appendData:[[NSString stringWithFormat:@"    INDEX 00 %@\n",framesToMSFStr([track frames],samplerate)] dataUsingEncoding:NSUTF8StringEncoding]];
		}
	}
	return [data autorelease];
}

+ (NSString *)gracenoteDiscIDForTracks:(NSArray *)tracks totalFrames:(xldoffset_t)totalFrames freeDBDiscID:(unsigned int)discid
{
	NSMutableString *str = [NSMutableString string];
	[str appendFormat:@"%08X+%lld+%lu",discid,(totalFrames)/588+150,[tracks count]];
	int i;
	for(i=0;i<[tracks count];i++) {
		[str appendFormat:@"+%lld",[(XLDTrack *)[tracks objectAtIndex:i] index]/588+150];
	}
	//NSLog(str);
	return str;
}

@end

@implementation NSFileManager (DirectoryAdditions)
- (void)createDirectoryWithIntermediateDirectoryInPath:(NSString *)path
{
	if([self fileExistsAtPath:path]) return;
	if([self respondsToSelector:@selector(createDirectoryAtPath:withIntermediateDirectories:attributes:error:)]) {
		[self createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL];
	}
	else {
		[self _web_createDirectoryAtPathWithIntermediateDirectories:path attributes:nil];
	}
}

- (NSArray *)directoryContentsAt:(NSString *)path
{
	if([self respondsToSelector:@selector(contentsOfDirectoryAtPath:error:)]) {
		return [self contentsOfDirectoryAtPath:path error:NULL];
	}
	else return [self directoryContentsAtPath:path];
}
@end

@implementation NSMutableDictionary (NSUserDefaultsCompatibility)
- (void)setInteger:(int)value forKey:(NSString *)defaultName
{
	[self setObject:[NSNumber numberWithInt:value] forKey:defaultName];
}

- (void)setBool:(BOOL)value forKey:(NSString *)defaultName
{
	[self setObject:[NSNumber numberWithBool:value] forKey:defaultName];
}
@end

@implementation XLDSplitView
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5
/*- (CGFloat)dividerThickness
{
	return 1.0;
}*/
#else
- (float)dividerThickness
{
	return 1.0f;
}

- (void)drawDividerInRect:(NSRect)rect
{
	[[NSColor grayColor] set];
	NSRectFill(rect);
}
#endif
@end

@implementation XLDAdaptiveTexturedWindow
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_5
- (id)initWithContentRect:(NSRect)contentRect styleMask:(NSUInteger)windowStyle backing:(NSBackingStoreType)bufferingType defer:(BOOL)deferCreation
#else
- (id)initWithContentRect:(NSRect)contentRect styleMask:(unsigned int)windowStyle backing:(NSBackingStoreType)bufferingType defer:(BOOL)deferCreation
#endif
{
	if(floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_4) {
		windowStyle |= NSTexturedBackgroundWindowMask;
	}
	else {
		windowStyle &= ~NSTexturedBackgroundWindowMask;
	}
	return [super initWithContentRect:contentRect styleMask:windowStyle backing:bufferingType defer:deferCreation];
}
@end

@implementation NSWorkspace (IconAdditions)
- (NSImage *)iconForFolder
{
	 return [self iconForFileType:NSFileTypeForHFSTypeCode(kGenericFolderIcon)];
}

- (NSImage *)iconForDisc
{
	 return [self iconForFileType:NSFileTypeForHFSTypeCode(kGenericCDROMIcon)];
}

- (NSImage *)iconForBurn
{
	return [self iconForFileType:NSFileTypeForHFSTypeCode(kBurningIcon)];
}

- (NSImage *)iconForNetwork
{
	return [self iconForFileType:NSFileTypeForHFSTypeCode(kGenericNetworkIcon)];
}

- (NSImage *)iconForGeneral
{
	NSImage *icon = [[NSImage alloc] initWithContentsOfFile:@"/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/General.icns"];
	if(icon) return [icon autorelease];
	return [NSImage imageNamed:@"general"];
}
@end

@implementation NSData (FasterSynchronusDownload)

+ (NSData *)fastDataWithContentsOfURL:(NSURL *)url
{
	NSURLResponse *resp;
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:30.0];
	if(floor(NSAppKitVersionNumber) <= NSAppKitVersionNumber10_4) {
		int sels[2] = { CTL_KERN , KERN_OSRELEASE };
		char darwin[32];
		size_t size = 32;
		sysctl(sels,2,&darwin,&size,NULL,0);
		NSBundle *cfnetwork = [NSBundle bundleWithPath:@"/System/Library/Frameworks/CoreServices.framework/Frameworks/CFNetwork.framework"];
		[req addValue:[NSString stringWithFormat:@"XLD/%@ CFNetwork/%@ Darwin/%s",[[[NSBundle mainBundle] infoDictionary] valueForKey:@"CFBundleVersion"],[[cfnetwork infoDictionary] objectForKey:@"CFBundleVersion"],darwin] forHTTPHeaderField:@"User-Agent"];
	}
	return [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:nil];
}

+ (NSData *)fastDataWithContentsOfURL:(NSURL *)url error:(NSError **)err
{
	NSURLResponse *resp;
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:30.0];
	if(floor(NSAppKitVersionNumber) <= NSAppKitVersionNumber10_4) {
		int sels[2] = { CTL_KERN , KERN_OSRELEASE };
		char darwin[32];
		size_t size = 32;
		sysctl(sels,2,&darwin,&size,NULL,0);
		NSBundle *cfnetwork = [NSBundle bundleWithPath:@"/System/Library/Frameworks/CoreServices.framework/Frameworks/CFNetwork.framework"];
		[req addValue:[NSString stringWithFormat:@"XLD/%@ CFNetwork/%@ Darwin/%s",[[[NSBundle mainBundle] infoDictionary] valueForKey:@"CFBundleVersion"],[[cfnetwork infoDictionary] objectForKey:@"CFBundleVersion"],darwin] forHTTPHeaderField:@"User-Agent"];
	}
	return [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:err];
}

@end

@implementation NSFlippedView

- (BOOL)isFlipped
{
	return YES;
}

@end

@implementation NSDate (XLDLocalizedDateDecription)

- (NSString *)localizedDateDescription
{
	if([NSDateFormatter instancesRespondToSelector:@selector(setFormatterBehavior:)]) {
		NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
		[dateFormatter setFormatterBehavior:NSDateFormatterBehavior10_4];
		[dateFormatter setLocale:[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease]];
		[dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss ZZZ"];
		NSString *str = [dateFormatter stringFromDate:self];
		[dateFormatter release];
		return str;
	}
	return [self description];
}

@end

#if MAC_OS_X_VERSION_MAX_ALLOWED < MAC_OS_X_VERSION_10_5
@implementation XLDBundle
- (NSDictionary *)infoDictionary
{
	//NSLog(@"infoDictionary");
	id dic = [super infoDictionary];
	//NSDictionary *newDic = [[NSDictionary alloc] initWithDictionary:dic];
	if([dic respondsToSelector:@selector(setBool:forKey:)]) [dic setBool:YES forKey:@"LSUIElement"];
	return dic;
}
@end
#else
@implementation NSBundle (XLDLSUIElement)
- (NSDictionary *)mod_infoDictionary
{
	id dic = [self mod_infoDictionary];
	if([dic respondsToSelector:@selector(setBool:forKey:)]) [dic setBool:YES forKey:@"LSUIElement"];
	return dic;
}
- (NSDictionary *)mod_infoDictionary2
{
	BOOL darkModeDisabled = XLDDarkModeSupportEnabled ? NO : YES;
	id dic = [self mod_infoDictionary2];
	if([dic respondsToSelector:@selector(setBool:forKey:)]) [dic setBool:darkModeDisabled forKey:@"NSRequiresAquaSystemAppearance"];
	return dic;
}
@end
#endif

@implementation NSFileManager (XLDFileMove)
- (void)moveFileAtPath:(NSString *)src toPath:(NSString *)dst
{
	if([self respondsToSelector:@selector(moveItemAtPath:toPath:error:)]) {
		[self moveItemAtPath:src toPath:dst error:nil];
	}
	else [self movePath:src toPath:dst handler:nil];
}
@end

@implementation NSImage (XLDOrientation)

+ (BOOL)hasOrientationTag:(NSData *)data
{
	if(!data) return NO;
	CGImageSourceRef imageSource = CGImageSourceCreateWithData((CFDataRef)data, NULL);
	if(!imageSource) return NO;
	CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, NULL);
	if(!properties) return NO;
	CFNumberRef orientationRef = CFDictionaryGetValue(properties, kCGImagePropertyOrientation);
	SInt32 orientation = 1;
	if(orientationRef){
		CFNumberGetValue(orientationRef, kCFNumberIntType, &orientation);
		CFRelease(orientationRef);
	}
	CFRelease(imageSource);
	CFRelease(properties);
	if(orientation <= 1 || orientation > 8) return NO;
	return YES;
}

+ (NSImage *)imageWithDataConsideringOrientation:(NSData *)data
{
	if(!data) return nil;
	CGImageSourceRef imageSource = CGImageSourceCreateWithData((CFDataRef)data, NULL);
	if(!imageSource) return nil;
	CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, NULL);
	CFNumberRef orientationRef = nil;
	NSImage *srcImg;
	NSImage *dstImg = nil;
	
	if(properties) orientationRef = CFDictionaryGetValue(properties, kCGImagePropertyOrientation);
	if([NSImage instancesRespondToSelector:@selector(initWithDataIgnoringOrientation:)])
		srcImg = [[NSImage alloc] initWithDataIgnoringOrientation:data];
	else
		srcImg = [[NSImage alloc] initWithData:data];

	
	SInt32 orientation = 1;
	if(orientationRef){
		CFNumberGetValue(orientationRef, kCFNumberIntType, &orientation);
		CFRelease(orientationRef);
	}
	CFRelease(imageSource);
	if(properties) CFRelease(properties);
	
	if(orientation <= 1 || orientation > 8) return [srcImg autorelease];
	
	NSAffineTransform *affineTransform = [NSAffineTransform transform];
	NSImageRep *rep = [srcImg bestRepresentationForDevice:nil];
	NSSize dstSize;
	
	switch (orientation) {
		case 2:
			dstSize = NSMakeSize([rep pixelsWide], [rep pixelsHigh]);
			[affineTransform scaleXBy:-1.0 yBy:1.0];
			[affineTransform translateXBy:-dstSize.width yBy:0];
			break;
		case 3:
			dstSize = NSMakeSize([rep pixelsWide], [rep pixelsHigh]);
			[affineTransform translateXBy:dstSize.width/2 yBy:dstSize.height/2];
			[affineTransform rotateByDegrees:180];
			[affineTransform translateXBy:-dstSize.width/2 yBy:-dstSize.height/2];
			break;
		case 4:
			dstSize = NSMakeSize([rep pixelsWide], [rep pixelsHigh]);
			[affineTransform scaleXBy:1.0 yBy:-1.0];
			[affineTransform translateXBy:0 yBy:-dstSize.height];
			break;
		case 5:
			dstSize = NSMakeSize([rep pixelsHigh], [rep pixelsWide]);
			[affineTransform scaleXBy:-1.0 yBy:1.0];
			[affineTransform translateXBy:-dstSize.width/2 yBy:dstSize.height/2];
			[affineTransform rotateByDegrees:-90];
			[affineTransform translateXBy:-dstSize.height/2 yBy:-dstSize.width/2];
			break;
		case 6:
			dstSize = NSMakeSize([rep pixelsHigh], [rep pixelsWide]);
			[affineTransform translateXBy:dstSize.width/2 yBy:dstSize.height/2];
			[affineTransform rotateByDegrees:-90];
			[affineTransform translateXBy:-dstSize.height/2 yBy:-dstSize.width/2];
			break;
		case 7:
			dstSize = NSMakeSize([rep pixelsHigh], [rep pixelsWide]);
			[affineTransform scaleXBy:-1.0 yBy:1.0];
			[affineTransform translateXBy:-dstSize.width/2 yBy:dstSize.height/2];
			[affineTransform rotateByDegrees:90];
			[affineTransform translateXBy:-dstSize.height/2 yBy:-dstSize.width/2];
			break;
		case 8:
			dstSize = NSMakeSize([rep pixelsHigh], [rep pixelsWide]);
			[affineTransform translateXBy:dstSize.width/2 yBy:dstSize.height/2];
			[affineTransform rotateByDegrees:90];
			[affineTransform translateXBy:-dstSize.height/2 yBy:-dstSize.width/2];
			break;
	}
	
	dstImg = [[NSImage alloc] initWithSize:dstSize];
	[dstImg lockFocus];
	[[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
	[affineTransform concat];
	[rep drawInRect: NSMakeRect(0, 0, [rep pixelsWide], [rep pixelsHigh])];
	[dstImg unlockFocus];
	return [dstImg autorelease];
}


@end

@interface NSObject (XLDScanProgressSource)
- (double)scanProgressForRow:(NSInteger)row;
- (double)cylonSeedForRow:(NSInteger)row;
@end

/* The eject glyph button is laid out at x = bounds.width - 22 (see
   XLDDiscView.layoutEjectButtons). The selection pill's right edge is locked to
   that left edge, and the title cell is clamped to just inside it so a long
   title truncates with an ellipsis INSIDE the pill rather than spilling under
   the glyph. */
#define XLD_EJECT_GLYPH_X 22.0
#define XLD_EJECT_TEXT_INSET 4.0
@implementation XLDSourceTableView
/* Right edge of the selection pill: locked to the left edge of the eject glyph. */
- (CGFloat)pillRightEdge
{
	return NSWidth([self bounds]) - XLD_EJECT_GLYPH_X;
}
/* Narrow every row so the source-list selection pill (which follows the row
   rect) ends exactly at the eject glyph that sits in the right-hand gutter. */
- (NSRect)rectOfRow:(NSInteger)row
{
	NSRect r = [super rectOfRow:row];
	CGFloat right = [self pillRightEdge];
	if(right > r.origin.x + 20.0) r.size.width = right - r.origin.x;
	return r;
}
/* Clamp the title cell to the pill so a long name truncates inside it, with a
   small inset so the ellipsis sits clear of the pill's rounded right edge. */
- (NSRect)frameOfCellAtColumn:(NSInteger)column row:(NSInteger)row
{
	NSRect f = [super frameOfCellAtColumn:column row:row];
	CGFloat right = [self pillRightEdge] - XLD_EJECT_TEXT_INSET;
	if(NSMaxX(f) > right) {
		f.size.width = (right > f.origin.x) ? (right - f.origin.x) : 0.0;
	}
	return f;
}
/* While the selected row is itself being scanned, suppress the red selection
   pill so the row shows only its Cylon sweep — scanning and selected read as two
   distinct states, never layered red-over-cyan. */
- (void)highlightSelectionInClipRect:(NSRect)clipRect
{
	NSInteger sel = [self selectedRow];
	id del = [self delegate];
	if(sel >= 0 && [del respondsToSelector:@selector(scanProgressForRow:)] && [del scanProgressForRow:sel] >= 0.0)
		return;
	[super highlightSelectionInClipRect:clipRect];
}
/* A disc still being scanned gets a distinct look from the selected (showing)
   disc: a solid dark pill with a bright cyan light that sweeps back and forth
   across it like a Cylon / KITT scanner, instead of the red selection pill and
   instead of a left-to-right progress bar. The sweep is time-driven; XLDDiscView
   redraws these rows on a timer. (scanProgressForRow: returns >= 0 while a row
   is scanning, -1 otherwise.) */
- (void)drawRow:(NSInteger)row clipRect:(NSRect)clipRect
{
	double p = -1.0;
	id del = [self delegate];
	if([del respondsToSelector:@selector(scanProgressForRow:)]) p = [del scanProgressForRow:row];
	if(p >= 0.0) {
		NSRect r = NSInsetRect([self rectOfRow:row], 2.0, 2.0);
		CGFloat radius = r.size.height/2.0;
		NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius];
		[[NSColor colorWithCalibratedRed:0.11 green:0.13 blue:0.17 alpha:1.0] setFill];
		[pill fill];
		[NSGraphicsContext saveGraphicsState];
		[pill addClip];
		double t = [NSDate timeIntervalSinceReferenceDate];
		/* Each drive sweeps on a slightly different period and phase (from a stable
		   per-drive seed) so multiple busy drives are never synchronised. */
		double seed = 0.0;
		if([del respondsToSelector:@selector(cylonSeedForRow:)]) seed = [del cylonSeedForRow:row];
		double freq = 4.1 + seed * 1.6;        /* ~4.1..5.7 rad/s */
		double phase = seed * 6.2831853;
		double pos = 0.5 * (1.0 - cos(t * freq + phase)); /* smooth 0..1..0 ping-pong */
		CGFloat margin = r.size.height * 0.6;
		CGFloat eyeX = r.origin.x + margin + (CGFloat)pos * (r.size.width - 2.0*margin);
		CGFloat eyeY = NSMidY(r);
		CGFloat eyeR = r.size.height * 1.25;
		NSColor *bright = [NSColor colorWithCalibratedRed:0.45 green:0.9 blue:1.0 alpha:1.0];
		NSColor *faint  = [NSColor colorWithCalibratedRed:0.2 green:0.55 blue:0.8 alpha:0.0];
		NSGradient *glow = [[NSGradient alloc] initWithStartingColor:bright endingColor:faint];
		[glow drawFromCenter:NSMakePoint(eyeX,eyeY) radius:0.0 toCenter:NSMakePoint(eyeX,eyeY) radius:eyeR options:0];
		[glow release];
		[NSGraphicsContext restoreGraphicsState];
	}
	[super drawRow:row clipRect:clipRect];
}
@end

@interface NSObject (XLDRipStateSource)
- (int)ripStateForRow:(NSInteger)row;
@end

@implementation XLDTrackTableView
/* The track currently being ripped shows a soft cyan Cylon sweep across its row,
   drawn under the cell contents so the text stays readable. Completed rows are
   greyed by the data source (attributed strings) and need no drawing here. */
- (void)drawRow:(NSInteger)row clipRect:(NSRect)clipRect
{
	int st = 0;
	id src = [self delegate];
	if(![src respondsToSelector:@selector(ripStateForRow:)]) src = [self dataSource];
	if([src respondsToSelector:@selector(ripStateForRow:)]) st = (int)[src ripStateForRow:row];
	if(st == 2) {
		NSRect r = [self rectOfRow:row];
		[NSGraphicsContext saveGraphicsState];
		[[NSBezierPath bezierPathWithRect:r] addClip];
		double t = [NSDate timeIntervalSinceReferenceDate];
		double pos = 0.5 * (1.0 - cos(t * 4.5)); /* smooth 0..1..0 ping-pong */
		CGFloat margin = r.size.height * 2.0;
		CGFloat eyeX = r.origin.x + margin + (CGFloat)pos * (r.size.width - 2.0*margin);
		CGFloat eyeY = NSMidY(r);
		CGFloat eyeR = r.size.height * 3.0;
		NSColor *bright = [NSColor colorWithCalibratedRed:0.30 green:0.75 blue:1.0 alpha:0.55];
		NSColor *faint  = [NSColor colorWithCalibratedRed:0.20 green:0.55 blue:0.80 alpha:0.0];
		NSGradient *glow = [[NSGradient alloc] initWithStartingColor:bright endingColor:faint];
		[glow drawFromCenter:NSMakePoint(eyeX,eyeY) radius:0.0 toCenter:NSMakePoint(eyeX,eyeY) radius:eyeR options:0];
		[glow release];
		[NSGraphicsContext restoreGraphicsState];
	}
	[super drawRow:row clipRect:clipRect];
}
@end

@implementation XLDScanningDisc
- (id)initWithVolume:(NSString *)volume device:(NSString *)device
{
	[super init];
	volumeName = [volume retain];
	devicePath = [device retain];
	scanProgress = 0.0;
	return self;
}
- (void)dealloc { [volumeName release]; [devicePath release]; [super dealloc]; }
- (NSString *)devicePath { return devicePath; }
- (double)scanProgress { return scanProgress; }
- (void)setScanProgress:(double)p { scanProgress = p; }
/* Accessors the disc view may call on a (selected) source-list entry. */
- (NSString *)title { return volumeName ? volumeName : @"Audio CD"; }
- (NSString *)artist { return @""; }
- (NSString *)fileToDecode { return devicePath; }
- (NSData *)coverData { return nil; }
- (NSString *)representedFilename { return nil; }
- (id)accurateRipData { return nil; }
- (NSArray *)trackList { return [NSArray array]; }
- (NSArray *)checkList { return [NSArray array]; }
- (xldoffset_t)totalFrames { return 0; }
- (int)samplerate { return 44100; }
- (BOOL)isCompilation { return NO; }
- (BOOL)writable { return NO; }
@end
