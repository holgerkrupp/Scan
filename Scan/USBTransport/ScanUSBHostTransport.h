#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ScanUSBHostTransport : NSObject

@property(nonatomic, readonly) UInt8 bulkInEndpoint;
@property(nonatomic, readonly) UInt8 bulkOutEndpoint;
@property(nonatomic, readonly, copy) NSString *endpointSummary;

/// Options for scanners that need a different USB handling. Each default keeps
/// the behaviour every other scanner relies on; the S1300i turns all three on
/// or off as noted.

/// Clear both bulk endpoints' halt state after claiming the interface, after
/// a failed read, and on abort (default YES). The S1300i does not reset its
/// data toggle on CLEAR_FEATURE, so after an earlier session the next
/// transfer is lost and it stops responding until it is power-cycled.
@property(nonatomic) BOOL clearsEndpointHalts;
/// Select the first configuration when the device has none (default NO). The
/// S1300i comes up unconfigured after power-on.
@property(nonatomic) BOOL configuresUnconfiguredDevice;
/// Use one libusb context for the whole process instead of one per session
/// (default NO). libusb_exit() can deadlock against libusb's hotplug thread
/// when the device detaches at the same time, which the S1300i does whenever
/// its feeder cover closes.
@property(nonatomic) BOOL usesSharedLibUSBContext;

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
