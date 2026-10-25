
#import <Foundation/Foundation.h>

@interface XLDTrack : NSObject
{
	xldoffset_t index;
	xldoffset_t frames;
	int gap;
	int seconds;
	BOOL enabled;
	NSString *desiredFileName;
	NSMutableDictionary *metadataDic;
	int ripState; /* 0 idle, 2 active (ripping), 3 done — for inline progress */
}

- (xldoffset_t)index;
- (void)setIndex:(xldoffset_t)idx;
- (xldoffset_t)frames;
- (void)setFrames:(xldoffset_t)blk;
- (int)gap;
- (void)setGap:(int)g;
- (BOOL)enabled;
- (void)setEnabled:(BOOL)flag;
- (NSString *)desiredFileName;
- (void)setDesiredFileName:(NSString *)str;
- (int)seconds;
- (void)setSeconds:(int)sec;
- (id)metadata;
- (void)setMetadata:(NSMutableDictionary *)data;
- (int)ripState;
- (void)setRipState:(int)s;

@end