//
//  XLDAccurateRipDB.h
//  XLD
//
//  Created by tmkk on 08/08/17.
//  Copyright 2008 tmkk. All rights reserved.
//
//  Access to AccurateRip is regulated, see  http://www.accuraterip.com/3rdparty-access.htm for details.

#import <Cocoa/Cocoa.h>

typedef enum {
	kXLDAccurateRipDBStateNetworkError = 0,
	kXLDAccurateRipDBStatePending,
	kXLDAccurateRipDBStateFound,
	kXLDAccurateRipDBStateNotFound,
} XLDAccurateRipDBState;

@interface XLDAccurateRipDB : NSObject {
	NSMutableArray *database;
	NSMutableArray *offsetDatabase;
	NSString *discID;
	XLDAccurateRipDBState _state;
	NSMutableData *_receiveData;
	NSURLConnection *_connection;
	long _httpStatusCode;
}

- (id)initWithURL:(NSURL *)url;
- (int)isAccurateCRC:(unsigned int)crc forTrack:(int)track;
- (int)isAccurateOffsetCRC:(unsigned int)crc forTrack:(int)track;
- (BOOL)hasValidDataForTrack:(int)track;
- (BOOL)hasValidDataForDisc;
- (int)totalSubmissionsForTrack:(int)track;
- (NSString *)discID;
- (XLDAccurateRipDBState)state;
- (void)dismiss;
@end
