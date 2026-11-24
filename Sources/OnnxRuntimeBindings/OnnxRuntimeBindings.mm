#import "OnnxRuntimeBindings.h"

#include <cstdlib>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#define ORT_API_MANUAL_INIT  // Start() below runs first
#include <onnxruntime/onnxruntime_cxx_api.h>

NSErrorDomain const kOrtErrorDomain = @"onnxruntime";

namespace {

// Microsoft's builds send usage events to mobile.events.data.microsoft.com (1DS) unless ORT_DISABLE_TELEMETRY=1 is
// set before ONNX Runtime starts (Privacy.md in the NuGet package). Gapiring makes no network requests, so every
// entry point calls this before it touches ONNX Runtime.
void Start() {
  static std::once_flag once;
  std::call_once(once, [] {
    setenv("ORT_DISABLE_TELEMETRY", "1", 1);
    Ort::InitApi();
  });
}

void Fill(NSError** error, int code, const char* message) {
  if (error == nullptr) return;
  *error = [NSError errorWithDomain:kOrtErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithUTF8String:message] ?: @"onnxruntime error"}];
}

// Runs `body`; a C++ exception becomes an NSError and `fail` is returned.
template <typename T, typename F>
T Guard(NSError** error, T fail, F&& body) {
  try {
    return body();
  } catch (const Ort::Exception& e) {
    Fill(error, static_cast<int>(e.GetOrtErrorCode()), e.what());
  } catch (const std::exception& e) {
    Fill(error, ORT_FAIL, e.what());
  }
  return fail;
}

ONNXTensorElementDataType CxxType(ORTTensorElementDataType t) {
  switch (t) {
    case ORTTensorElementDataTypeFloat: return ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;
    case ORTTensorElementDataTypeInt8: return ONNX_TENSOR_ELEMENT_DATA_TYPE_INT8;
    case ORTTensorElementDataTypeUInt8: return ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8;
    case ORTTensorElementDataTypeInt32: return ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32;
    case ORTTensorElementDataTypeUInt32: return ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT32;
    case ORTTensorElementDataTypeInt64: return ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64;
    case ORTTensorElementDataTypeUInt64: return ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT64;
    case ORTTensorElementDataTypeString:
    case ORTTensorElementDataTypeUndefined: break;
  }
  throw Ort::Exception("a tensor made from data must have a numeric element type", ORT_INVALID_ARGUMENT);
}

OrtLoggingLevel CxxLevel(ORTLoggingLevel l) {
  switch (l) {
    case ORTLoggingLevelVerbose: return ORT_LOGGING_LEVEL_VERBOSE;
    case ORTLoggingLevelInfo: return ORT_LOGGING_LEVEL_INFO;
    case ORTLoggingLevelWarning: return ORT_LOGGING_LEVEL_WARNING;
    case ORTLoggingLevelError: return ORT_LOGGING_LEVEL_ERROR;
    case ORTLoggingLevelFatal: return ORT_LOGGING_LEVEL_FATAL;
  }
  return ORT_LOGGING_LEVEL_WARNING;
}

GraphOptimizationLevel CxxOptimization(ORTGraphOptimizationLevel l) {
  switch (l) {
    case ORTGraphOptimizationLevelNone: return ORT_DISABLE_ALL;
    case ORTGraphOptimizationLevelBasic: return ORT_ENABLE_BASIC;
    case ORTGraphOptimizationLevelExtended: return ORT_ENABLE_EXTENDED;
    case ORTGraphOptimizationLevelAll: return ORT_ENABLE_ALL;
  }
  return ORT_ENABLE_ALL;
}

}  // namespace

// MARK: - ORTEnv

@interface ORTEnv ()
- (Ort::Env&)cxx;
@end

@implementation ORTEnv {
  std::optional<Ort::Env> _env;
}

- (nullable instancetype)initWithLoggingLevel:(ORTLoggingLevel)loggingLevel error:(NSError**)error {
  if ((self = [super init]) == nil) return nil;
  return Guard<ORTEnv*>(error, nil, [&] {
    Start();
    _env.emplace(CxxLevel(loggingLevel), "gapiring");
    _env->DisableTelemetryEvents();
    return self;
  });
}

- (Ort::Env&)cxx {
  return *_env;
}

@end

// MARK: - ORTSessionOptions

@interface ORTSessionOptions ()
- (Ort::SessionOptions&)cxx;
@end

@implementation ORTSessionOptions {
  std::optional<Ort::SessionOptions> _options;
}

- (nullable instancetype)initWithError:(NSError**)error {
  if ((self = [super init]) == nil) return nil;
  return Guard<ORTSessionOptions*>(error, nil, [&] {
    Start();
    _options.emplace();
    return self;
  });
}

- (BOOL)setIntraOpNumThreads:(int)intraOpNumThreads error:(NSError**)error {
  return Guard<BOOL>(error, NO, [&] {
    _options->SetIntraOpNumThreads(intraOpNumThreads);
    return YES;
  });
}

- (BOOL)setGraphOptimizationLevel:(ORTGraphOptimizationLevel)graphOptimizationLevel error:(NSError**)error {
  return Guard<BOOL>(error, NO, [&] {
    _options->SetGraphOptimizationLevel(CxxOptimization(graphOptimizationLevel));
    return YES;
  });
}

- (Ort::SessionOptions&)cxx {
  return *_options;
}

@end

// MARK: - ORTRunOptions

@interface ORTRunOptions ()
- (Ort::RunOptions&)cxx;
@end

@implementation ORTRunOptions {
  std::optional<Ort::RunOptions> _options;
}

- (nullable instancetype)initWithError:(NSError**)error {
  if ((self = [super init]) == nil) return nil;
  return Guard<ORTRunOptions*>(error, nil, [&] {
    Start();
    _options.emplace();
    return self;
  });
}

- (Ort::RunOptions&)cxx {
  return *_options;
}

@end

// MARK: - ORTValue

@interface ORTValue ()
- (instancetype)initWithOwnedValue:(OrtValue*)value NS_DESIGNATED_INITIALIZER;
- (const OrtValue*)cxx;
@end

@implementation ORTValue {
  NSMutableData* _data;  // the buffer of a tensor made from data: ONNX Runtime reads it in place
  std::optional<Ort::Value> _value;
}

- (nullable instancetype)initWithTensorData:(NSMutableData*)tensorData
                                elementType:(ORTTensorElementDataType)elementType
                                      shape:(NSArray<NSNumber*>*)shape
                                      error:(NSError**)error {
  if ((self = [super init]) == nil) return nil;
  return Guard<ORTValue*>(error, nil, [&] {
    Start();
    std::vector<int64_t> dims;
    dims.reserve(shape.count);
    for (NSNumber* d in shape) dims.push_back(d.longLongValue);
    const auto info = Ort::MemoryInfo::CreateCpu(OrtDeviceAllocator, OrtMemTypeCPU);
    _value.emplace(Ort::Value::CreateTensor(info, tensorData.mutableBytes, tensorData.length, dims.data(), dims.size(),
                                            CxxType(elementType)));
    _data = tensorData;
    return self;
  });
}

- (instancetype)initWithOwnedValue:(OrtValue*)value {
  if ((self = [super init]) == nil) return nil;
  _value.emplace(value);
  return self;
}

- (nullable NSMutableData*)tensorDataWithError:(NSError**)error {
  return Guard<NSMutableData*>(error, nil, [&]() -> NSMutableData* {
    if (!_value->IsTensor()) throw Ort::Exception("the value is not a tensor", ORT_INVALID_ARGUMENT);
    const size_t bytes = _value->GetTensorSizeInBytes();
    void* raw = bytes == 0 ? nullptr : _value->GetTensorMutableData<void>();
    ORTValue* owner = self;  // the data keeps the tensor it points into alive
    return [[NSMutableData alloc] initWithBytesNoCopy:raw
                                               length:bytes
                                          deallocator:^(void*, NSUInteger) {
                                            (void)owner;
                                          }];
  });
}

- (const OrtValue*)cxx {
  return *_value;
}

@end

// MARK: - ORTSession

@implementation ORTSession {
  ORTEnv* _env;  // ONNX Runtime needs the environment to outlive the session
  std::optional<Ort::Session> _session;
}

- (nullable instancetype)initWithEnv:(ORTEnv*)env
                           modelPath:(NSString*)path
                      sessionOptions:(nullable ORTSessionOptions*)sessionOptions
                               error:(NSError**)error {
  if ((self = [super init]) == nil) return nil;
  return Guard<ORTSession*>(error, nil, [&] {
    _env = env;
    if (sessionOptions != nil) {
      _session.emplace([env cxx], path.fileSystemRepresentation, [sessionOptions cxx]);
    } else {
      _session.emplace([env cxx], path.fileSystemRepresentation, Ort::SessionOptions());
    }
    return self;
  });
}

- (nullable NSDictionary<NSString*, ORTValue*>*)runWithInputs:(NSDictionary<NSString*, ORTValue*>*)inputs
                                                  outputNames:(NSSet<NSString*>*)outputNames
                                                   runOptions:(nullable ORTRunOptions*)runOptions
                                                        error:(NSError**)error {
  return Guard<NSDictionary<NSString*, ORTValue*>*>(error, nil, [&] {
    std::vector<std::string> inNames, outNames;
    std::vector<const OrtValue*> inValues;
    for (NSString* name in inputs) {
      inNames.emplace_back(name.UTF8String);
      inValues.push_back([inputs[name] cxx]);
    }
    NSArray<NSString*>* outKeys = outputNames.allObjects;
    for (NSString* name in outKeys) outNames.emplace_back(name.UTF8String);

    std::vector<const char*> inPtrs, outPtrs;
    for (const auto& n : inNames) inPtrs.push_back(n.c_str());
    for (const auto& n : outNames) outPtrs.push_back(n.c_str());
    std::vector<OrtValue*> outValues(outPtrs.size(), nullptr);

    OrtStatus* status = Ort::GetApi().Run(*_session, runOptions != nil ? (const OrtRunOptions*)[runOptions cxx] : nullptr,
                                          inPtrs.data(), inValues.data(), inPtrs.size(), outPtrs.data(), outPtrs.size(),
                                          outValues.data());
    // Take every output that was made, so none leaks if the run failed half way.
    NSMutableDictionary<NSString*, ORTValue*>* result = [NSMutableDictionary dictionaryWithCapacity:outKeys.count];
    for (NSUInteger i = 0; i < outKeys.count; ++i) {
      if (outValues[i] != nullptr) result[outKeys[i]] = [[ORTValue alloc] initWithOwnedValue:outValues[i]];
    }
    Ort::ThrowOnError(status);
    return (NSDictionary<NSString*, ORTValue*>*)result;
  });
}

@end
