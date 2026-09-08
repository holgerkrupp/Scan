#import "ScanUSBHostTransport.h"

#import <IOKit/IOCFPlugIn.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#import <IOKit/usb/USB.h>
#import <IOKit/usb/USBSpec.h>
#import <IOUSBHost/AppleUSBDescriptorParsing.h>
#import <IOUSBHost/IOUSBHost.h>
#import <libusb-1.0/libusb.h>

@interface ScanUSBHostTransport ()
@property(nonatomic, strong, nullable) IOUSBHostInterface *interface;
@property(nonatomic, strong, nullable) IOUSBHostPipe *bulkInPipe;
@property(nonatomic, strong, nullable) IOUSBHostPipe *bulkOutPipe;
@property(nonatomic) IOUSBDeviceInterface300 **legacyDeviceInterface;
@property(nonatomic) IOUSBInterfaceInterface300 **legacyInterface;
@property(nonatomic) UInt8 bulkInEndpoint;
@property(nonatomic) UInt8 bulkOutEndpoint;
@property(nonatomic) UInt8 legacyBulkInPipeRef;
@property(nonatomic) UInt8 legacyBulkOutPipeRef;
@property(nonatomic) BOOL usingLegacyTransport;
@property(nonatomic) libusb_context *libusbContext;
@property(nonatomic) libusb_device_handle *libusbHandle;
@property(nonatomic) int libusbInterfaceNumber;
@property(nonatomic) UInt8 libusbBulkInEndpoint;
@property(nonatomic) UInt8 libusbBulkOutEndpoint;
@property(nonatomic) BOOL usingLibUSB;
@property(nonatomic, copy) NSString *endpointSummary;
@end

@implementation ScanUSBHostTransport

- (instancetype)init {
    self = [super init];
    if (self) {
        _endpointSummary = @"Not opened";
    }
    return self;
}

- (BOOL)openWithVendorID:(UInt16)vendorID
               productID:(UInt16)productID
              locationID:(UInt32)locationID
                   error:(NSError **)error {
    [self close];

    NSError *libusbError = nil;
    if ([self openLibUSBWithVendorID:vendorID productID:productID error:&libusbError]) {
        return YES;
    }

    CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBHostInterfaceClassName);
    if (!matching) {
        [self assignError:error message:@"Could not create IOUSBHost matching dictionary." code:1];
        return NO;
    }

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (kr != KERN_SUCCESS) {
        [self assignError:error message:@"Could not enumerate USB interfaces." code:kr];
        return NO;
    }

    NSMutableArray<NSString *> *attemptSummaries = [NSMutableArray array];
    NSUInteger serviceCount = 0;
    NSUInteger matchingDeviceServiceCount = 0;
    NSUInteger skippedLocationCount = 0;
    io_service_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        @autoreleasepool {
            serviceCount++;
            NSString *serviceName = [self registryNameForService:service];
            BOOL skippedForLocation = NO;
            NSString *deviceSummary = nil;
            if (![self interfaceService:service
                        matchesVendorID:vendorID
                               productID:productID
                              locationID:locationID
                      skippedForLocation:&skippedForLocation
                           deviceSummary:&deviceSummary]) {
                if (skippedForLocation) {
                    skippedLocationCount++;
                }
                IOObjectRelease(service);
                continue;
            }
            matchingDeviceServiceCount++;

            NSError *openError = nil;
            IOUSBHostInterface *candidate = [[IOUSBHostInterface alloc] initWithIOService:service
                                                                                  options:IOUSBHostObjectInitOptionsNone
                                                                                    queue:nil
                                                                                    error:&openError
                                                                          interestHandler:nil];
            if (!candidate) {
                NSError *seizeError = nil;
                candidate = [[IOUSBHostInterface alloc] initWithIOService:service
                                                                   options:IOUSBHostObjectInitOptionsDeviceSeize
                                                                     queue:nil
                                                                     error:&seizeError
                                                           interestHandler:nil];
                if (candidate) {
                    [attemptSummaries addObject:[NSString stringWithFormat:@"%@ %@ opened after requesting current owner to close.",
                                                 serviceName,
                                                 deviceSummary ?: @""]];
                    openError = nil;
                } else if (seizeError) {
                    openError = seizeError;
                }
            }
            if (!candidate) {
                NSString *ownership = [self ownershipSummaryForService:service];
                IOObjectRelease(service);
                if (openError.localizedDescription.length > 0) {
                    [attemptSummaries addObject:[NSString stringWithFormat:@"%@ %@ open/seize failed: %@%@",
                                                 serviceName,
                                                 deviceSummary ?: @"",
                                                 openError.localizedDescription,
                                                 ownership]];
                } else {
                    [attemptSummaries addObject:[NSString stringWithFormat:@"%@ %@ open/seize failed without an NSError; interface may be busy or denied%@",
                                                 serviceName,
                                                 deviceSummary ?: @"",
                                                 ownership]];
                }
                continue;
            }
            IOObjectRelease(service);

            if ([self configurePipesForInterface:candidate error:&openError]) {
                self.interface = candidate;
                self.endpointSummary = [NSString stringWithFormat:@"bulk out 0x%02x, bulk in 0x%02x",
                                                                    self.bulkOutEndpoint,
                                                                    self.bulkInEndpoint];
                IOObjectRelease(iterator);
                return YES;
            }
            if (openError.localizedDescription.length > 0) {
                [attemptSummaries addObject:[NSString stringWithFormat:@"%@ %@: %@",
                                             serviceName,
                                             deviceSummary ?: @"",
                                             openError.localizedDescription]];
            }
        }
    }

    IOObjectRelease(iterator);
    NSString *details = @"";
    if (attemptSummaries.count > 0) {
        details = [NSString stringWithFormat:@" Details: %@", [attemptSummaries componentsJoinedByString:@" | "]];
    } else if (serviceCount == 0) {
        details = @" Details: no IOUSBHostInterface services exist in the IORegistry.";
    } else if (matchingDeviceServiceCount == 0 && skippedLocationCount > 0) {
        details = [NSString stringWithFormat:@" Details: skipped %lu interface service(s) because their locationID did not match 0x%08x.",
                   (unsigned long)skippedLocationCount,
                   locationID];
    } else if (matchingDeviceServiceCount == 0) {
        details = [NSString stringWithFormat:@" Details: inspected %lu IOUSBHostInterface service(s), but none belonged to USB device 0x%04x/0x%04x.",
                   (unsigned long)serviceCount,
                   vendorID,
                   productID];
    } else {
        details = [NSString stringWithFormat:@" Details: inspected %lu matching interface service(s), but none exposed a usable bulk pair.",
                   (unsigned long)matchingDeviceServiceCount];
    }
    NSError *legacyError = nil;
    if ([self openLegacyWithVendorID:vendorID productID:productID locationID:locationID error:&legacyError]) {
        return YES;
    }

    NSString *libusbDetails = libusbError.localizedDescription.length > 0
        ? [NSString stringWithFormat:@" libusb: %@", libusbError.localizedDescription]
        : @" libusb did not find a usable interface.";
    NSString *legacyDetails = legacyError.localizedDescription.length > 0
        ? [NSString stringWithFormat:@" Legacy IOUSBLib fallback: %@", legacyError.localizedDescription]
        : @" Legacy IOUSBLib fallback did not find a usable interface.";
    [self assignError:error
              message:[NSString stringWithFormat:@"No claimable USB interface with bulk IN/OUT endpoints was found.%@%@%@", details, libusbDetails, legacyDetails]
                 code:2];
    return NO;
}

- (void)close {
    if (self.libusbHandle) {
        libusb_release_interface(self.libusbHandle, self.libusbInterfaceNumber);
        libusb_close(self.libusbHandle);
    }
    if (self.libusbContext) {
        libusb_exit(self.libusbContext);
    }
    if (self.legacyInterface) {
        (*self.legacyInterface)->USBInterfaceClose(self.legacyInterface);
        (*self.legacyInterface)->Release(self.legacyInterface);
    }
    if (self.legacyDeviceInterface) {
        (*self.legacyDeviceInterface)->USBDeviceClose(self.legacyDeviceInterface);
        (*self.legacyDeviceInterface)->Release(self.legacyDeviceInterface);
    }
    if (self.interface) {
        [self.interface destroy];
    }
    self.legacyInterface = NULL;
    self.legacyDeviceInterface = NULL;
    self.libusbHandle = NULL;
    self.libusbContext = NULL;
    self.libusbInterfaceNumber = 0;
    self.libusbBulkInEndpoint = 0;
    self.libusbBulkOutEndpoint = 0;
    self.usingLibUSB = NO;
    self.bulkInPipe = nil;
    self.bulkOutPipe = nil;
    self.interface = nil;
    self.bulkInEndpoint = 0;
    self.bulkOutEndpoint = 0;
    self.legacyBulkInPipeRef = 0;
    self.legacyBulkOutPipeRef = 0;
    self.usingLegacyTransport = NO;
    self.endpointSummary = @"Closed";
}

- (BOOL)bulkWrite:(NSData *)data timeout:(NSTimeInterval)timeout error:(NSError **)error {
    if (self.usingLibUSB) {
        int transferred = 0;
        int result = libusb_bulk_transfer(self.libusbHandle,
                                          self.libusbBulkOutEndpoint,
                                          (unsigned char *)data.bytes,
                                          (int)data.length,
                                          &transferred,
                                          [self millisecondsForTimeout:timeout]);
        if (result != LIBUSB_SUCCESS || transferred != (int)data.length) {
            [self assignError:error
                      message:[NSString stringWithFormat:@"libusb bulk write failed: %s (%d), transferred %d/%lu.",
                               libusb_error_name(result),
                               result,
                               transferred,
                               (unsigned long)data.length]
                         code:4];
            return NO;
        }
        return YES;
    }

    if (self.usingLegacyTransport) {
        if (!self.legacyInterface || self.legacyBulkOutPipeRef == 0) {
            [self assignError:error message:@"Legacy USB bulk OUT pipe is not open." code:3];
            return NO;
        }
        UInt32 timeoutMS = [self millisecondsForTimeout:timeout];
        IOReturn kr = (*self.legacyInterface)->WritePipeTO(self.legacyInterface,
                                                           self.legacyBulkOutPipeRef,
                                                           (void *)data.bytes,
                                                           (UInt32)data.length,
                                                           timeoutMS,
                                                           timeoutMS);
        if (kr != kIOReturnSuccess) {
            [self assignError:error message:[NSString stringWithFormat:@"Legacy USB bulk write failed: 0x%08x.", kr] code:4];
            return NO;
        }
        return YES;
    }

    if (!self.bulkOutPipe) {
        [self assignError:error message:@"USB bulk OUT pipe is not open." code:3];
        return NO;
    }

    NSMutableData *mutable = [data mutableCopy];
    NSUInteger bytesTransferred = 0;
    BOOL ok = [self.bulkOutPipe sendIORequestWithData:mutable
                                     bytesTransferred:&bytesTransferred
                                    completionTimeout:timeout
                                                error:error];
    if (!ok) {
        return NO;
    }
    if (bytesTransferred != data.length) {
        [self assignError:error message:@"Short USB bulk write." code:4];
        return NO;
    }
    return YES;
}

- (nullable NSData *)bulkReadLength:(NSUInteger)length timeout:(NSTimeInterval)timeout error:(NSError **)error {
    if (self.usingLibUSB) {
        NSMutableData *data = [NSMutableData dataWithLength:length];
        NSUInteger totalTransferred = 0;
        const NSUInteger transferLimit = 16 * 1024;
        while (totalTransferred < length) {
            int transferred = 0;
            NSUInteger requested = MIN(transferLimit, length - totalTransferred);
            int result = libusb_bulk_transfer(self.libusbHandle,
                                              self.libusbBulkInEndpoint,
                                              (unsigned char *)data.mutableBytes + totalTransferred,
                                              (int)requested,
                                              &transferred,
                                              [self millisecondsForTimeout:timeout]);
            if (transferred > 0) {
                totalTransferred += (NSUInteger)transferred;
            }
            if (result != LIBUSB_SUCCESS) {
                int clearResult = libusb_clear_halt(self.libusbHandle, self.libusbBulkInEndpoint);
                [self assignError:error
                          message:[NSString stringWithFormat:@"libusb bulk read failed: %s (%d), accumulated %lu/%lu bytes (last %d/%lu); clear halt: %s (%d).",
                                   libusb_error_name(result),
                                   result,
                                   (unsigned long)totalTransferred,
                                   (unsigned long)length,
                                   transferred,
                                   (unsigned long)requested,
                                   libusb_error_name(clearResult),
                                   clearResult]
                             code:5];
                return nil;
            }
            if (transferred == 0 || (NSUInteger)transferred < requested) {
                break;
            }
        }
        data.length = totalTransferred;
        return data;
    }

    if (self.usingLegacyTransport) {
        if (!self.legacyInterface || self.legacyBulkInPipeRef == 0) {
            [self assignError:error message:@"Legacy USB bulk IN pipe is not open." code:5];
            return nil;
        }
        NSMutableData *data = [NSMutableData dataWithLength:length];
        UInt32 bytesRead = (UInt32)length;
        UInt32 timeoutMS = [self millisecondsForTimeout:timeout];
        IOReturn kr = (*self.legacyInterface)->ReadPipeTO(self.legacyInterface,
                                                          self.legacyBulkInPipeRef,
                                                          data.mutableBytes,
                                                          &bytesRead,
                                                          timeoutMS,
                                                          timeoutMS);
        if (kr != kIOReturnSuccess && kr != kIOReturnUnderrun) {
            if (kr == kIOReturnNotResponding || kr == kIOReturnTimeout || kr == kIOUSBPipeStalled) {
                (*self.legacyInterface)->ClearPipeStallBothEnds(self.legacyInterface, self.legacyBulkInPipeRef);
            }
            [self assignError:error
                      message:[NSString stringWithFormat:@"Legacy USB bulk read failed: 0x%08x while requesting %lu bytes.",
                               kr,
                               (unsigned long)length]
                         code:5];
            return nil;
        }
        data.length = bytesRead;
        return data;
    }

    if (!self.bulkInPipe) {
        [self assignError:error message:@"USB bulk IN pipe is not open." code:5];
        return nil;
    }

    NSMutableData *data = [NSMutableData dataWithLength:length];
    NSUInteger bytesTransferred = 0;
    BOOL ok = [self.bulkInPipe sendIORequestWithData:data
                                    bytesTransferred:&bytesTransferred
                                   completionTimeout:timeout
                                               error:error];
    if (!ok) {
        return nil;
    }
    data.length = bytesTransferred;
    return data;
}

- (BOOL)abortWithError:(NSError **)error {
    if (self.usingLibUSB) {
        int inResult = libusb_clear_halt(self.libusbHandle, self.libusbBulkInEndpoint);
        int outResult = libusb_clear_halt(self.libusbHandle, self.libusbBulkOutEndpoint);
        if (inResult != LIBUSB_SUCCESS || outResult != LIBUSB_SUCCESS) {
            [self assignError:error message:@"libusb could not clear one or more bulk endpoints." code:7];
            return NO;
        }
        return YES;
    }

    if (self.usingLegacyTransport) {
        BOOL ok = YES;
        if (self.legacyInterface && self.legacyBulkInPipeRef != 0) {
            IOReturn kr = (*self.legacyInterface)->AbortPipe(self.legacyInterface, self.legacyBulkInPipeRef);
            ok = (kr == kIOReturnSuccess) && ok;
        }
        if (self.legacyInterface && self.legacyBulkOutPipeRef != 0) {
            IOReturn kr = (*self.legacyInterface)->AbortPipe(self.legacyInterface, self.legacyBulkOutPipeRef);
            ok = (kr == kIOReturnSuccess) && ok;
        }
        if (!ok) {
            [self assignError:error message:@"Legacy USB abort failed for one or more pipes." code:7];
        }
        return ok;
    }

    BOOL ok = YES;
    if (self.bulkInPipe) {
        ok = [self.bulkInPipe abortWithOption:IOUSBHostAbortOptionSynchronous error:error] && ok;
    }
    if (self.bulkOutPipe) {
        ok = [self.bulkOutPipe abortWithOption:IOUSBHostAbortOptionSynchronous error:error] && ok;
    }
    return ok;
}

- (UInt32)millisecondsForTimeout:(NSTimeInterval)timeout {
    if (timeout <= 0) {
        return 0;
    }
    NSTimeInterval milliseconds = timeout * 1000.0;
    if (milliseconds >= (NSTimeInterval)UINT32_MAX) {
        return UINT32_MAX;
    }
    return (UInt32)ceil(milliseconds);
}

- (BOOL)openLibUSBWithVendorID:(UInt16)vendorID
                     productID:(UInt16)productID
                          error:(NSError **)error {
    libusb_context *context = NULL;
    int result = libusb_init(&context);
    if (result != LIBUSB_SUCCESS) {
        [self assignError:error
                  message:[NSString stringWithFormat:@"initialization failed: %s (%d).", libusb_error_name(result), result]
                     code:40];
        return NO;
    }

    libusb_device_handle *handle = libusb_open_device_with_vid_pid(context, vendorID, productID);
    if (!handle) {
        libusb_exit(context);
        [self assignError:error message:@"device could not be opened." code:41];
        return NO;
    }

    struct libusb_config_descriptor *configuration = NULL;
    result = libusb_get_active_config_descriptor(libusb_get_device(handle), &configuration);
    if (result != LIBUSB_SUCCESS || !configuration) {
        libusb_close(handle);
        libusb_exit(context);
        [self assignError:error
                  message:[NSString stringWithFormat:@"active configuration could not be read: %s (%d).",
                           libusb_error_name(result),
                           result]
                     code:43];
        return NO;
    }

    int interfaceNumber = -1;
    UInt8 bulkIn = 0;
    UInt8 bulkOut = 0;
    for (UInt8 interfaceIndex = 0; interfaceIndex < configuration->bNumInterfaces && interfaceNumber < 0; interfaceIndex++) {
        const struct libusb_interface *interface = &configuration->interface[interfaceIndex];
        for (int alternateIndex = 0; alternateIndex < interface->num_altsetting && interfaceNumber < 0; alternateIndex++) {
            const struct libusb_interface_descriptor *alternate = &interface->altsetting[alternateIndex];
            UInt8 candidateIn = 0;
            UInt8 candidateOut = 0;
            for (UInt8 endpointIndex = 0; endpointIndex < alternate->bNumEndpoints; endpointIndex++) {
                const struct libusb_endpoint_descriptor *endpoint = &alternate->endpoint[endpointIndex];
                if ((endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) != LIBUSB_TRANSFER_TYPE_BULK) {
                    continue;
                }
                if ((endpoint->bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK) == LIBUSB_ENDPOINT_IN) {
                    candidateIn = endpoint->bEndpointAddress;
                } else {
                    candidateOut = endpoint->bEndpointAddress;
                }
            }
            if (candidateIn != 0 && candidateOut != 0) {
                interfaceNumber = alternate->bInterfaceNumber;
                bulkIn = candidateIn;
                bulkOut = candidateOut;
            }
        }
    }
    libusb_free_config_descriptor(configuration);

    if (interfaceNumber < 0) {
        libusb_close(handle);
        libusb_exit(context);
        [self assignError:error message:@"no interface exposed bulk IN and OUT endpoints." code:44];
        return NO;
    }

    result = libusb_claim_interface(handle, interfaceNumber);
    if (result != LIBUSB_SUCCESS) {
        libusb_close(handle);
        libusb_exit(context);
        [self assignError:error
                  message:[NSString stringWithFormat:@"interface %d could not be claimed: %s (%d).",
                           interfaceNumber,
                           libusb_error_name(result),
                           result]
                     code:45];
        return NO;
    }

    int clearInResult = libusb_clear_halt(handle, bulkIn);
    int clearOutResult = libusb_clear_halt(handle, bulkOut);
    if (clearInResult != LIBUSB_SUCCESS || clearOutResult != LIBUSB_SUCCESS) {
        libusb_release_interface(handle, interfaceNumber);
        libusb_close(handle);
        libusb_exit(context);
        [self assignError:error
                  message:[NSString stringWithFormat:@"endpoint cleanup failed: IN %s (%d), OUT %s (%d).",
                           libusb_error_name(clearInResult),
                           clearInResult,
                           libusb_error_name(clearOutResult),
                           clearOutResult]
                     code:46];
        return NO;
    }

    self.libusbContext = context;
    self.libusbHandle = handle;
    self.libusbInterfaceNumber = interfaceNumber;
    self.libusbBulkInEndpoint = bulkIn;
    self.libusbBulkOutEndpoint = bulkOut;
    self.bulkInEndpoint = bulkIn;
    self.bulkOutEndpoint = bulkOut;
    self.usingLibUSB = YES;
    self.endpointSummary = [NSString stringWithFormat:@"libusb interface %d, bulk out 0x%02x, bulk in 0x%02x",
                            interfaceNumber,
                            bulkOut,
                            bulkIn];
    return YES;
}

- (BOOL)openLegacyWithVendorID:(UInt16)vendorID
                     productID:(UInt16)productID
                    locationID:(UInt32)locationID
                         error:(NSError **)error {
    CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBDeviceClassName);
    if (!matching) {
        [self assignError:error message:@"Could not create IOUSBLib device matching dictionary." code:20];
        return NO;
    }

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (kr != KERN_SUCCESS) {
        [self assignError:error message:[NSString stringWithFormat:@"Could not enumerate IOUSBLib devices: 0x%08x.", kr] code:kr];
        return NO;
    }

    NSMutableArray<NSString *> *attempts = [NSMutableArray array];
    NSUInteger inspectedDevices = 0;
    NSUInteger matchingDevices = 0;
    io_service_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        @autoreleasepool {
            inspectedDevices++;
            NSNumber *entryVendorID = [self numberProperty:@"idVendor" fromService:service];
            NSNumber *entryProductID = [self numberProperty:@"idProduct" fromService:service];
            NSNumber *entryLocationID = [self numberProperty:@"locationID" fromService:service];
            UInt16 foundVendorID = (UInt16)entryVendorID.unsignedIntValue;
            UInt16 foundProductID = (UInt16)entryProductID.unsignedIntValue;
            UInt32 foundLocationID = entryLocationID ? entryLocationID.unsignedIntValue : 0;

            if (!entryVendorID || !entryProductID || foundVendorID != vendorID || foundProductID != productID) {
                IOObjectRelease(service);
                continue;
            }
            if (locationID != 0 && foundLocationID != 0 && foundLocationID != locationID) {
                IOObjectRelease(service);
                continue;
            }
            matchingDevices++;

            NSString *deviceSummary = [NSString stringWithFormat:@"legacy device 0x%04x/0x%04x loc 0x%08x",
                                       foundVendorID,
                                       foundProductID,
                                       foundLocationID];
            NSString *ownership = [self ownershipSummaryForService:service];
            IOUSBDeviceInterface300 **deviceInterface = NULL;
            IOReturn openResult = kIOReturnError;
            BOOL ok = [self createLegacyDeviceInterfaceForService:service
                                                  deviceInterface:&deviceInterface
                                                     openIOReturn:&openResult
                                                            error:error];
            if (!ok || !deviceInterface) {
                [attempts addObject:[NSString stringWithFormat:@"%@ create/open failed: %@%@",
                                     deviceSummary,
                                     (*error).localizedDescription ?: [NSString stringWithFormat:@"0x%08x", openResult],
                                     ownership]];
                IOObjectRelease(service);
                continue;
            }

            NSString *interfaceSummary = nil;
            if ([self openLegacyInterfaceForDevice:deviceInterface summary:&interfaceSummary error:error]) {
                self.legacyDeviceInterface = deviceInterface;
                self.usingLegacyTransport = YES;
                self.endpointSummary = interfaceSummary ?: @"legacy USB bulk pipes open";
                IOObjectRelease(service);
                IOObjectRelease(iterator);
                return YES;
            }

            [attempts addObject:[NSString stringWithFormat:@"%@ interface scan failed: %@%@",
                                 deviceSummary,
                                 (*error).localizedDescription ?: @"unknown error",
                                 ownership]];
            (*deviceInterface)->USBDeviceClose(deviceInterface);
            (*deviceInterface)->Release(deviceInterface);
            IOObjectRelease(service);
        }
    }

    IOObjectRelease(iterator);
    NSString *details = attempts.count > 0
        ? [attempts componentsJoinedByString:@" | "]
        : [NSString stringWithFormat:@"inspected %lu IOUSBDevice service(s), matched %lu.",
           (unsigned long)inspectedDevices,
           (unsigned long)matchingDevices];
    [self assignError:error message:details code:21];
    return NO;
}

- (BOOL)createLegacyDeviceInterfaceForService:(io_service_t)service
                              deviceInterface:(IOUSBDeviceInterface300 ***)deviceInterface
                                 openIOReturn:(IOReturn *)openIOReturn
                                        error:(NSError **)error {
    IOCFPlugInInterface **plugIn = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(service,
                                                    kIOUSBDeviceUserClientTypeID,
                                                    kIOCFPlugInInterfaceID,
                                                    &plugIn,
                                                    &score);
    if (kr != kIOReturnSuccess || !plugIn) {
        [self assignError:error message:[NSString stringWithFormat:@"IOCreatePlugInInterfaceForService(device) failed: 0x%08x.", kr] code:22];
        return NO;
    }

    HRESULT result = (*plugIn)->QueryInterface(plugIn,
                                               CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID300),
                                               (LPVOID *)deviceInterface);
    (*plugIn)->Release(plugIn);
    if (result != S_OK || !*deviceInterface) {
        [self assignError:error message:[NSString stringWithFormat:@"QueryInterface(kIOUSBDeviceInterfaceID300) failed: 0x%08x.", (unsigned int)result] code:23];
        return NO;
    }

    kr = (**deviceInterface)->USBDeviceOpen(*deviceInterface);
    if (kr != kIOReturnSuccess) {
        IOReturn seizeKr = (**deviceInterface)->USBDeviceOpenSeize(*deviceInterface);
        if (openIOReturn) {
            *openIOReturn = seizeKr;
        }
        if (seizeKr != kIOReturnSuccess) {
            (**deviceInterface)->Release(*deviceInterface);
            *deviceInterface = NULL;
            [self assignError:error message:[NSString stringWithFormat:@"USBDeviceOpen/USBDeviceOpenSeize failed: 0x%08x / 0x%08x.", kr, seizeKr] code:24];
            return NO;
        }
    } else if (openIOReturn) {
        *openIOReturn = kr;
    }

    return YES;
}

- (BOOL)openLegacyInterfaceForDevice:(IOUSBDeviceInterface300 **)deviceInterface
                              summary:(NSString **)summary
                                error:(NSError **)error {
    IOUSBFindInterfaceRequest request;
    request.bInterfaceClass = kIOUSBFindInterfaceDontCare;
    request.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    request.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    request.bAlternateSetting = kIOUSBFindInterfaceDontCare;

    io_iterator_t iterator = IO_OBJECT_NULL;
    IOReturn kr = (*deviceInterface)->CreateInterfaceIterator(deviceInterface, &request, &iterator);
    if (kr != kIOReturnSuccess) {
        [self assignError:error message:[NSString stringWithFormat:@"CreateInterfaceIterator failed: 0x%08x.", kr] code:25];
        return NO;
    }

    NSMutableArray<NSString *> *attempts = [NSMutableArray array];
    io_service_t interfaceService = IO_OBJECT_NULL;
    while ((interfaceService = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        IOUSBInterfaceInterface300 **candidate = NULL;
        NSString *serviceName = [self registryNameForService:interfaceService];
        if (![self createLegacyInterfaceForService:interfaceService interface:&candidate error:error] || !candidate) {
            [attempts addObject:[NSString stringWithFormat:@"%@ create failed: %@", serviceName, (*error).localizedDescription ?: @"unknown error"]];
            IOObjectRelease(interfaceService);
            continue;
        }

        kr = (*candidate)->USBInterfaceOpen(candidate);
        if (kr != kIOReturnSuccess) {
            IOReturn seizeKr = (*candidate)->USBInterfaceOpenSeize(candidate);
            if (seizeKr != kIOReturnSuccess) {
                [attempts addObject:[NSString stringWithFormat:@"%@ open/seize failed: 0x%08x / 0x%08x%@",
                                     serviceName,
                                     kr,
                                     seizeKr,
                                     [self ownershipSummaryForService:interfaceService]]];
                (*candidate)->Release(candidate);
                IOObjectRelease(interfaceService);
                continue;
            }
        }

        UInt8 outPipe = 0;
        UInt8 inPipe = 0;
        NSString *pipeSummary = nil;
        if ([self findLegacyBulkPipesForInterface:candidate outPipe:&outPipe inPipe:&inPipe summary:&pipeSummary error:error]) {
            self.legacyInterface = candidate;
            self.legacyBulkOutPipeRef = outPipe;
            self.legacyBulkInPipeRef = inPipe;
            if (summary) {
                *summary = pipeSummary;
            }
            IOObjectRelease(interfaceService);
            IOObjectRelease(iterator);
            return YES;
        }

        [attempts addObject:[NSString stringWithFormat:@"%@ pipes failed: %@", serviceName, (*error).localizedDescription ?: @"unknown error"]];
        (*candidate)->USBInterfaceClose(candidate);
        (*candidate)->Release(candidate);
        IOObjectRelease(interfaceService);
    }

    IOObjectRelease(iterator);
    NSString *details = attempts.count > 0 ? [attempts componentsJoinedByString:@" | "] : @"no legacy interface services returned.";
    [self assignError:error message:details code:26];
    return NO;
}

- (BOOL)createLegacyInterfaceForService:(io_service_t)service
                              interface:(IOUSBInterfaceInterface300 ***)interface
                                  error:(NSError **)error {
    IOCFPlugInInterface **plugIn = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(service,
                                                    kIOUSBInterfaceUserClientTypeID,
                                                    kIOCFPlugInInterfaceID,
                                                    &plugIn,
                                                    &score);
    if (kr != kIOReturnSuccess || !plugIn) {
        [self assignError:error message:[NSString stringWithFormat:@"IOCreatePlugInInterfaceForService(interface) failed: 0x%08x.", kr] code:27];
        return NO;
    }

    HRESULT result = (*plugIn)->QueryInterface(plugIn,
                                               CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300),
                                               (LPVOID *)interface);
    (*plugIn)->Release(plugIn);
    if (result != S_OK || !*interface) {
        [self assignError:error message:[NSString stringWithFormat:@"QueryInterface(kIOUSBInterfaceInterfaceID300) failed: 0x%08x.", (unsigned int)result] code:28];
        return NO;
    }
    return YES;
}

- (BOOL)findLegacyBulkPipesForInterface:(IOUSBInterfaceInterface300 **)interface
                                outPipe:(UInt8 *)outPipe
                                 inPipe:(UInt8 *)inPipe
                                summary:(NSString **)summary
                                  error:(NSError **)error {
    UInt8 endpointCount = 0;
    IOReturn kr = (*interface)->GetNumEndpoints(interface, &endpointCount);
    if (kr != kIOReturnSuccess) {
        [self assignError:error message:[NSString stringWithFormat:@"GetNumEndpoints failed: 0x%08x.", kr] code:29];
        return NO;
    }

    NSMutableArray<NSString *> *endpointDetails = [NSMutableArray array];
    UInt8 foundOut = 0;
    UInt8 foundIn = 0;
    for (UInt8 pipeRef = 1; pipeRef <= endpointCount; pipeRef++) {
        UInt8 direction = 0;
        UInt8 number = 0;
        UInt8 transferType = 0;
        UInt16 maxPacketSize = 0;
        UInt8 interval = 0;
        kr = (*interface)->GetPipeProperties(interface,
                                             pipeRef,
                                             &direction,
                                             &number,
                                             &transferType,
                                             &maxPacketSize,
                                             &interval);
        if (kr != kIOReturnSuccess) {
            [endpointDetails addObject:[NSString stringWithFormat:@"pipe %u properties failed 0x%08x", pipeRef, kr]];
            continue;
        }

        NSString *directionName = direction == kUSBIn ? @"in" : @"out";
        NSString *typeName = [self endpointTypeName:transferType];
        [endpointDetails addObject:[NSString stringWithFormat:@"pipe %u ep %u %@ %@ max %u",
                                    pipeRef,
                                    number,
                                    directionName,
                                    typeName,
                                    maxPacketSize]];
        if (transferType != kUSBBulk) {
            continue;
        }
        if (direction == kUSBIn) {
            foundIn = pipeRef;
        } else if (direction == kUSBOut) {
            foundOut = pipeRef;
        }
    }

    if (foundIn == 0 || foundOut == 0) {
        NSString *details = endpointDetails.count > 0 ? [endpointDetails componentsJoinedByString:@", "] : @"no endpoints";
        [self assignError:error message:[NSString stringWithFormat:@"No legacy bulk IN/OUT pipe pair. Endpoints: %@", details] code:30];
        return NO;
    }

    if (outPipe) {
        *outPipe = foundOut;
    }
    if (inPipe) {
        *inPipe = foundIn;
    }
    if (summary) {
        *summary = [NSString stringWithFormat:@"legacy bulk out pipe %u, bulk in pipe %u (%@)",
                    foundOut,
                    foundIn,
                    [endpointDetails componentsJoinedByString:@", "]];
    }
    return YES;
}

- (BOOL)configurePipesForInterface:(IOUSBHostInterface *)interface error:(NSError **)error {
    const IOUSBConfigurationDescriptor *configurationDescriptor = interface.configurationDescriptor;
    const IOUSBInterfaceDescriptor *activeInterfaceDescriptor = interface.interfaceDescriptor;
    if (!configurationDescriptor || !activeInterfaceDescriptor) {
        [self assignError:error message:@"Could not read USB interface descriptors." code:6];
        return NO;
    }

    NSMutableArray<NSString *> *diagnostics = [NSMutableArray array];
    const UInt8 targetInterfaceNumber = activeInterfaceDescriptor->bInterfaceNumber;
    const IOUSBInterfaceDescriptor *candidateInterfaceDescriptor = NULL;

    while ((candidateInterfaceDescriptor = IOUSBGetNextInterfaceDescriptor(
                configurationDescriptor,
                (const IOUSBDescriptorHeader *)candidateInterfaceDescriptor
            )) != NULL) {
        if (candidateInterfaceDescriptor->bInterfaceNumber != targetInterfaceNumber) {
            continue;
        }

        UInt8 inAddress = 0;
        UInt8 outAddress = 0;
        NSMutableArray<NSString *> *endpointDetails = [NSMutableArray array];
        const IOUSBEndpointDescriptor *endpointDescriptor = NULL;

        while ((endpointDescriptor = IOUSBGetNextEndpointDescriptor(
                    configurationDescriptor,
                    candidateInterfaceDescriptor,
                    (const IOUSBDescriptorHeader *)endpointDescriptor
                )) != NULL) {
            UInt8 address = IOUSBGetEndpointAddress(endpointDescriptor);
            UInt8 type = IOUSBGetEndpointType(endpointDescriptor);
            UInt8 direction = IOUSBGetEndpointDirection(endpointDescriptor);
            NSString *directionName = direction == kUSBIn ? @"in" : @"out";
            NSString *typeName = [self endpointTypeName:type];
            [endpointDetails addObject:[NSString stringWithFormat:@"0x%02x %@ %@", address, directionName, typeName]];

            if (type != kUSBBulk) {
                continue;
            }
            if (direction == kUSBIn || (address & 0x80) != 0) {
                inAddress = address;
            } else {
                outAddress = address;
            }
        }

        NSString *endpointSummary = endpointDetails.count > 0 ? [endpointDetails componentsJoinedByString:@", "] : @"no endpoints";
        [diagnostics addObject:[NSString stringWithFormat:@"interface %u alt %u class 0x%02x subclass 0x%02x protocol 0x%02x endpoints [%@]",
                                candidateInterfaceDescriptor->bInterfaceNumber,
                                candidateInterfaceDescriptor->bAlternateSetting,
                                candidateInterfaceDescriptor->bInterfaceClass,
                                candidateInterfaceDescriptor->bInterfaceSubClass,
                                candidateInterfaceDescriptor->bInterfaceProtocol,
                                endpointSummary]];

        if (inAddress == 0 || outAddress == 0) {
            continue;
        }

        if (candidateInterfaceDescriptor->bAlternateSetting != activeInterfaceDescriptor->bAlternateSetting) {
            NSError *selectError = nil;
            if (![interface selectAlternateSetting:candidateInterfaceDescriptor->bAlternateSetting error:&selectError]) {
                [diagnostics addObject:[NSString stringWithFormat:@"select alt %u failed: %@",
                                        candidateInterfaceDescriptor->bAlternateSetting,
                                        selectError.localizedDescription ?: @"unknown error"]];
                continue;
            }
        }

        NSError *outError = nil;
        NSError *inError = nil;
        IOUSBHostPipe *outPipe = [interface copyPipeWithAddress:outAddress error:&outError];
        IOUSBHostPipe *inPipe = [interface copyPipeWithAddress:inAddress error:&inError];
        if (!inPipe || !outPipe) {
            [diagnostics addObject:[NSString stringWithFormat:@"open pipes out 0x%02x/in 0x%02x failed: %@ %@",
                                    outAddress,
                                    inAddress,
                                    outError.localizedDescription ?: @"",
                                    inError.localizedDescription ?: @""]];
            continue;
        }

        self.bulkInPipe = inPipe;
        self.bulkOutPipe = outPipe;
        self.bulkInEndpoint = inAddress;
        self.bulkOutEndpoint = outAddress;
        return YES;
    }

    NSString *diagnosticSummary = diagnostics.count > 0 ? [diagnostics componentsJoinedByString:@"; "] : @"no interface descriptors";
    [self assignError:error
              message:[NSString stringWithFormat:@"Could not open USB bulk IN/OUT pipes for interface %u. Descriptor scan: %@",
                       targetInterfaceNumber,
                       diagnosticSummary]
                 code:6];
    return NO;
}

- (NSString *)endpointTypeName:(UInt8)type {
    switch (type) {
        case kUSBControl:
            return @"control";
        case kUSBBulk:
            return @"bulk";
        case kUSBIsoc:
            return @"isoc";
        case kUSBInterrupt:
            return @"interrupt";
        default:
            return [NSString stringWithFormat:@"type-0x%02x", type];
    }
}

- (NSString *)registryNameForService:(io_service_t)service {
    io_name_t name;
    kern_return_t kr = IORegistryEntryGetName(service, name);
    if (kr == KERN_SUCCESS) {
        return [NSString stringWithUTF8String:name] ?: @"USB interface";
    }
    return @"USB interface";
}

- (BOOL)interfaceService:(io_service_t)service
         matchesVendorID:(UInt16)vendorID
                productID:(UInt16)productID
               locationID:(UInt32)locationID
       skippedForLocation:(BOOL *)skippedForLocation
            deviceSummary:(NSString **)deviceSummary {
    if (skippedForLocation) {
        *skippedForLocation = NO;
    }
    if (deviceSummary) {
        *deviceSummary = nil;
    }

    io_registry_entry_t entry = service;
    IOObjectRetain(entry);

    while (entry != IO_OBJECT_NULL) {
        NSNumber *entryVendorID = [self numberProperty:@"idVendor" fromService:entry];
        NSNumber *entryProductID = [self numberProperty:@"idProduct" fromService:entry];
        if (entryVendorID && entryProductID) {
            UInt16 foundVendorID = (UInt16)entryVendorID.unsignedIntValue;
            UInt16 foundProductID = (UInt16)entryProductID.unsignedIntValue;
            NSNumber *entryLocationID = [self numberProperty:@"locationID" fromService:entry];
            UInt32 foundLocationID = entryLocationID ? entryLocationID.unsignedIntValue : 0;

            if (deviceSummary) {
                *deviceSummary = [NSString stringWithFormat:@"device 0x%04x/0x%04x loc 0x%08x",
                                  foundVendorID,
                                  foundProductID,
                                  foundLocationID];
            }

            IOObjectRelease(entry);

            if (foundVendorID != vendorID || foundProductID != productID) {
                return NO;
            }
            if (locationID != 0 && foundLocationID != 0 && foundLocationID != locationID) {
                if (skippedForLocation) {
                    *skippedForLocation = YES;
                }
                return NO;
            }
            return YES;
        }

        io_registry_entry_t parent = IO_OBJECT_NULL;
        kern_return_t kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent);
        IOObjectRelease(entry);
        if (kr != KERN_SUCCESS) {
            break;
        }
        entry = parent;
    }

    return NO;
}

- (nullable NSNumber *)numberProperty:(NSString *)name fromService:(io_service_t)service {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, (__bridge CFStringRef)name, kCFAllocatorDefault, 0);
    if (!value) {
        return nil;
    }
    id object = CFBridgingRelease(value);
    return [object isKindOfClass:NSNumber.class] ? object : nil;
}

- (NSString *)ownershipSummaryForService:(io_service_t)service {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [self appendStringProperty:@"UsbExclusiveOwner" fromService:service toParts:parts label:@"owner"];
    [self appendStringProperty:@"UsbUserClientEntitlementRequired" fromService:service toParts:parts label:@"entitlement"];

    io_registry_entry_t entry = service;
    IOObjectRetain(entry);
    while (entry != IO_OBJECT_NULL) {
        [self appendStringProperty:@"UsbExclusiveOwner" fromService:entry toParts:parts label:@"owner"];
        [self appendStringProperty:@"UsbUserClientEntitlementRequired" fromService:entry toParts:parts label:@"entitlement"];

        io_registry_entry_t parent = IO_OBJECT_NULL;
        kern_return_t kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent);
        IOObjectRelease(entry);
        if (kr != KERN_SUCCESS) {
            break;
        }
        entry = parent;
    }

    if (parts.count == 0) {
        return @"";
    }
    return [NSString stringWithFormat:@" (%@)", [parts componentsJoinedByString:@", "]];
}

- (void)appendStringProperty:(NSString *)name
                 fromService:(io_service_t)service
                     toParts:(NSMutableArray<NSString *> *)parts
                       label:(NSString *)label {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, (__bridge CFStringRef)name, kCFAllocatorDefault, 0);
    if (!value) {
        return;
    }
    id object = CFBridgingRelease(value);
    if ([object isKindOfClass:NSString.class]) {
        NSString *text = (NSString *)object;
        if (text.length > 0) {
            NSString *part = [NSString stringWithFormat:@"%@ %@", label, text];
            if (![parts containsObject:part]) {
                [parts addObject:part];
            }
        }
    } else if ([object isKindOfClass:NSDictionary.class]) {
        NSString *part = [NSString stringWithFormat:@"%@ %@", label, object];
        if (![parts containsObject:part]) {
            [parts addObject:part];
        }
    }
}

- (void)assignError:(NSError **)error message:(NSString *)message code:(NSInteger)code {
    if (!error) {
        return;
    }
    *error = [NSError errorWithDomain:@"ScanUSBHostTransport"
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end
