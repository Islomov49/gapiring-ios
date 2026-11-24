// The part of ONNX Runtime's Objective-C API that Gapiring uses (ORTEnv, ORTSessionOptions, ORTRunOptions, ORTSession,
// ORTValue), with the official names and behaviour, written over ONNX Runtime's C++ API. Microsoft ships its own
// bindings only as sources inside the CocoaPods archive; the binary comes from Frameworks/onnxruntime.xcframework.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int32_t, ORTLoggingLevel) {
  ORTLoggingLevelVerbose,
  ORTLoggingLevelInfo,
  ORTLoggingLevelWarning,
  ORTLoggingLevelError,
  ORTLoggingLevelFatal,
};

typedef NS_ENUM(int32_t, ORTTensorElementDataType) {
  ORTTensorElementDataTypeUndefined,
  ORTTensorElementDataTypeFloat,
  ORTTensorElementDataTypeInt8,
  ORTTensorElementDataTypeUInt8,
  ORTTensorElementDataTypeInt32,
  ORTTensorElementDataTypeUInt32,
  ORTTensorElementDataTypeInt64,
  ORTTensorElementDataTypeUInt64,
  ORTTensorElementDataTypeString,
};

typedef NS_ENUM(int32_t, ORTGraphOptimizationLevel) {
  ORTGraphOptimizationLevelNone,
  ORTGraphOptimizationLevelBasic,
  ORTGraphOptimizationLevelExtended,
  ORTGraphOptimizationLevelAll,
};

/// Errors carry ONNX Runtime's OrtErrorCode as their code.
extern NSErrorDomain const kOrtErrorDomain;

/// The ONNX Runtime environment: one per process is enough; sessions keep theirs alive.
@interface ORTEnv : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithLoggingLevel:(ORTLoggingLevel)loggingLevel
                                        error:(NSError**)error NS_DESIGNATED_INITIALIZER;
@end

@interface ORTSessionOptions : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithError:(NSError**)error NS_SWIFT_NAME(init()) NS_DESIGNATED_INITIALIZER;
- (BOOL)setIntraOpNumThreads:(int)intraOpNumThreads error:(NSError**)error;
- (BOOL)setGraphOptimizationLevel:(ORTGraphOptimizationLevel)graphOptimizationLevel error:(NSError**)error;
@end

@interface ORTRunOptions : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithError:(NSError**)error NS_SWIFT_NAME(init()) NS_DESIGNATED_INITIALIZER;
@end

/// A tensor. One made from data does not copy it: it keeps `tensorData` and reads it at every run.
@interface ORTValue : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithTensorData:(NSMutableData*)tensorData
                                elementType:(ORTTensorElementDataType)elementType
                                      shape:(NSArray<NSNumber*>*)shape
                                      error:(NSError**)error NS_DESIGNATED_INITIALIZER;
/// The tensor's bytes, not copied (the data keeps the value alive). Any element type but strings.
- (nullable NSMutableData*)tensorDataWithError:(NSError**)error;
@end

@interface ORTSession : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithEnv:(ORTEnv*)env
                           modelPath:(NSString*)path
                      sessionOptions:(nullable ORTSessionOptions*)sessionOptions
                               error:(NSError**)error NS_DESIGNATED_INITIALIZER;
/// Runs the graph; the result has a value for every name in `outputNames`. Inputs are not changed.
- (nullable NSDictionary<NSString*, ORTValue*>*)runWithInputs:(NSDictionary<NSString*, ORTValue*>*)inputs
                                                  outputNames:(NSSet<NSString*>*)outputNames
                                                   runOptions:(nullable ORTRunOptions*)runOptions
                                                        error:(NSError**)error;
@end

NS_ASSUME_NONNULL_END
