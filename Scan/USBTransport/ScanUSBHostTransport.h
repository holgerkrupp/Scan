#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ScanUSBHostTransport : NSObject

@property(nonatomic, readonly) UInt8 bulkInEndpoint;
@property(nonatomic, readonly) UInt8 bulkOutEndpoint;
@property(nonatomic, readonly, copy) NSString *endpointSummary;

- (BOOL)openWithVendorID:(UInt16)vendorID
               productID:(UInt16)productID
              locationID:(UInt32)locationID
                   error:(NSError **)error;

- (void)close;
- (BOOL)bulkWrite:(NSData *)data timeout:(NSTimeInterval)timeout error:(NSError **)error;
- (nullable NSData *)bulkReadLength:(NSUInteger)length timeout:(NSTimeInterval)timeout error:(NSError **)error;
- (BOOL)abortWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
