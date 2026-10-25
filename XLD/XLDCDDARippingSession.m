//
//  XLDCDDARippingSession.m
//  XLD-64
//
//  Created by Taihei Momma on 2021/01/07.
//
//

#import "XLDCDDARippingSession.h"

static NSMutableDictionary *sessions;

@implementation XLDCDDARippingSession

+ (void)initialize
{
    if (!sessions) sessions = [[NSMutableDictionary alloc] init];
}

+ (XLDCDDARippingSession *)createSessionForDevice:(NSString *)device
{
    /* Close and drop any prior session for this device before overwriting the
       dictionary entry, so its open device fd is released rather than
       orphaned. The scan opens a session, then the rip opens a second one for
       the same device; without this the scan's session lingers in -dealloc
       with its fd still open. A leaked fd on the old CD media wedges the drive
       after the disc ejects, so the next disc inserted into it is never
       enumerated (it shows up in neither Finder nor XLD). */
    XLDCDDARippingSession *existing = [sessions objectForKey:device];
    if(existing) [existing destroy];
    XLDCDDARippingSession *session = [[XLDCDDARippingSession alloc] initWithDevicePath:device];
    [sessions setObject:session forKey:device];
    return [session autorelease];
}

+ (XLDCDDARippingSession *)sessionForDevice:(const char *)device
{
    return [sessions objectForKey:[NSString stringWithUTF8String:device]];
}

+ (BOOL)isDeviceBusy:(NSString *)devicePath
{
    /* A session exists for a device path from the moment a rip opens it until
       -destroy, so it is an authoritative per-drive busy indicator. Used to
       gate automount and the Open Audio CD menu per drive rather than
       app-wide. (SourceForge ticket #631) */
    if(!devicePath) return NO;
    return ([sessions objectForKey:devicePath] != nil);
}

- (id)initWithDevicePath:(NSString *)device
{
    self = [super init];
    if (self) {
        devicePath = [device retain];
        retryCount = 20;
    }
    return self;
}

- (void)dealloc
{
    /* Backstop: never let a session go away with its device fd still open,
       whatever path orphaned it. xld_cdda_close is idempotent. */
    xld_cdda_close(&cdread);
    [devicePath release];
    [super dealloc];
}

- (int)open
{
    if (cdread.opened) return cdread.fd;
    if (xld_cdda_open(&cdread, [devicePath UTF8String]) != 0) return -1;
    return cdread.fd;
}

- (void)close
{
    xld_cdda_close(&cdread);
}

- (void)destroy
{
    xld_cdda_close(&cdread);
    /* Only unregister if this object is still the registered session for the
       device; a newer session for the same device must not be removed.
       (SourceForge ticket #630) */
    if([sessions objectForKey:devicePath] == self)
        [sessions removeObjectForKey:devicePath];
}

- (XLDCDDAResult *)result
{
    return result;
}

- (void)setResult:(XLDCDDAResult *)obj
{
    result = [obj retain];
}

- (BOOL)allTasksFinished
{
    return [result allTasksFinished];
}

- (xld_cdread_t *)descriptor
{
    return &cdread;
}

- (NSString *)devicePath
{
    return devicePath;
}

- (int)offsetCorrectionValue
{
    return offsetCorrectionValue;
}

- (void)setOffsetCorrectionValue:(int)value
{
    offsetCorrectionValue = value;
}

- (BOOL)resolveOffsetCorrectionValueFromDrive
{
    /* Resolve the read offset from this session's own drive, so that discs in
       different drives no longer share a single offset value.
       (SourceForge ticket #629) */
    if(!cdread.product) return NO;
    NSDictionary *dic = [NSDictionary dictionaryWithContentsOfFile:
        [[NSBundle mainBundle] pathForResource:@"offsetlist" ofType:@"plist"]];
    NSString *name = [NSString stringWithUTF8String:cdread.product];
    id value = [dic objectForKey:name];
    if(!value && [name length] > 1)
        value = [dic objectForKey:[name substringToIndex:[name length]-1]];
    if(!value) return NO;
    offsetCorrectionValue = [value intValue];
    return YES;
}

- (int)retryCount
{
    return retryCount;
}

- (void)setRetryCount:(int)value
{
    retryCount = value;
}

- (xldoffset_t)firstAudioFrame
{
    return firstAudioFrame;
}

- (void)setFirstAudioFrame:(xldoffset_t)frame
{
    firstAudioFrame = frame;
}

- (xldoffset_t)lastAudioFrame
{
    return lastAudioFrame;
}

- (void)setLastAudioFrame:(xldoffset_t)frame
{
    lastAudioFrame = frame;
}

- (XLDRipperMode)ripperMode
{
    return ripperMode;
}

- (void)setRipperMode:(XLDRipperMode)mode
{
    ripperMode = mode;
}

- (int)maxRippingSpeed
{
    return maxRippingSpeed;
}

- (void)setMaxRippingSpeed:(int)maxSpeed
{
    maxRippingSpeed = maxSpeed;
}

@end
