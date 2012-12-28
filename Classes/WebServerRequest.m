// Copyright 2012 Pierre-Olivier Latour
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "WebServer.h"
#import "Extensions_Foundation.h"
#import "Logging.h"

#define kMultiPartBufferSize (256 * 1024)

enum {
  kParserState_Undefined = 0,
  kParserState_Start,
  kParserState_Headers,
  kParserState_Content,
  kParserState_End
};

static NSData* _newlineData = nil;
static NSData* _newlinesData = nil;
static NSData* _dashNewlineData = nil;

static NSString* _ExtractHeaderParameter(NSString* header, NSString* attribute) {
  NSString* value = nil;
  NSScanner* scanner = [[NSScanner alloc] initWithString:header];
  NSString* string = [NSString stringWithFormat:@"%@=", attribute];
  if ([scanner scanUpToString:string intoString:NULL]) {
    [scanner scanString:string intoString:NULL];
    [scanner scanUpToCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:&value];
  }
  if ([value hasPrefix:@"\""] && [value hasSuffix:@"\""]) {
    value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
  }
  [scanner release];
  return value;
}

// http://www.w3schools.com/tags/ref_charactersets.asp
static NSStringEncoding _StringEncodingFromCharset(NSString* charset) {
  NSStringEncoding encoding = kCFStringEncodingInvalidId;
  if (charset) {
    encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding((CFStringRef)charset));
  }
  return (encoding != kCFStringEncodingInvalidId ? encoding : NSUTF8StringEncoding);
}

@implementation WebServerRequest : NSObject

@synthesize method=_method, headers=_headers, path=_path, query=_query, contentType=_type, contentLength=_length;

- (id) initWithMethod:(NSString*)method headers:(NSDictionary*)headers path:(NSString*)path query:(NSString*)query {
  if ((self = [super init])) {
    _method = [method copy];
    _headers = [headers retain];
    _path = [path copy];
    _query = [query copy];
    
    _type = [[_headers objectForKey:@"Content-Type"] retain];
    NSInteger length = [[_headers objectForKey:@"Content-Length"] integerValue];
    if (length < 0) {
      DNOT_REACHED();
      [self release];
      return nil;
    }
    _length = length;
    
    if ((_length > 0) && (_type == nil)) {
      _type = [kWebServerDefaultMimeType copy];
    }
  }
  return self;
}

- (void) dealloc {
  [_method release];
  [_headers release];
  [_path release];
  [_query release];
  [_type release];
  
  [super dealloc];
}

- (BOOL) hasBody {
  return _type ? YES : NO;
}

@end

@implementation WebServerRequest (Subclassing)

- (BOOL) open {
  [self doesNotRecognizeSelector:_cmd];
  return NO;
}

- (NSInteger) write:(const void*)buffer maxLength:(NSUInteger)length {
  [self doesNotRecognizeSelector:_cmd];
  return -1;
}

- (BOOL) close {
  [self doesNotRecognizeSelector:_cmd];
  return NO;
}

@end

@implementation WebServerDataRequest

@synthesize data=_data;

- (void) dealloc {
  DCHECK(_data != nil);
  [_data release];
  
  [super dealloc];
}

- (BOOL) open {
  DCHECK(_data == nil);
  _data = [[NSMutableData alloc] initWithCapacity:self.contentLength];
  return _data ? YES : NO;
}

- (NSInteger) write:(const void*)buffer maxLength:(NSUInteger)length {
  DCHECK(_data != nil);
  [_data appendBytes:buffer length:length];
  return length;
}

- (BOOL) close {
  DCHECK(_data != nil);
  return YES;
}

@end

@implementation WebServerFileRequest

@synthesize filePath=_filePath;

- (id) initWithMethod:(NSString*)method headers:(NSDictionary*)headers path:(NSString*)path query:(NSString*)query {
  if ((self = [super initWithMethod:method headers:headers path:path query:query])) {
    _filePath = [[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]] retain];
  }
  return self;
}

- (void) dealloc {
  DCHECK(_file < 0);
  unlink([_filePath fileSystemRepresentation]);
  [_filePath release];
  
  [super dealloc];
}

- (BOOL) open {
  DCHECK(_file == 0);
  _file = open([_filePath fileSystemRepresentation], O_CREAT | O_TRUNC | O_WRONLY, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);
  return (_file > 0 ? YES : NO);
}

- (NSInteger) write:(const void*)buffer maxLength:(NSUInteger)length {
  DCHECK(_file > 0);
  return write(_file, buffer, length);
}

- (BOOL) close {
  DCHECK(_file > 0);
  int result = close(_file);
  _file = -1;
  return (result == 0 ? YES : NO);
}

@end

@implementation WebServerURLEncodedFormRequest

@synthesize arguments=_arguments;

+ (NSString*) mimeType {
  return @"application/x-www-form-urlencoded";
}

- (void) dealloc {
  [_arguments release];
  
  [super dealloc];
}

- (BOOL) close {
  if (![super close]) {
    return NO;
  }
  
  NSString* charset = _ExtractHeaderParameter(self.contentType, @"charset");
  NSString* string = [[NSString alloc] initWithData:self.data encoding:_StringEncodingFromCharset(charset)];
  _arguments = [[NSURL parseURLEncodedForm:string unescapeKeysAndValues:YES] retain];
  [string release];
  
  return (_arguments ? YES : NO);
}

@end

@implementation WebServerMultiPart

@synthesize contentType=_contentType, mimeType=_mimeType;

- (id) initWithContentType:(NSString*)contentType {
  if ((self = [super init])) {
    _contentType = [contentType copy];
    _mimeType = [[[[_contentType componentsSeparatedByString:@";"] firstObject] lowercaseString] retain];
    if (_mimeType == nil) {
      _mimeType = @"text/plain";
    }
  }
  return self;
}

- (void) dealloc {
  [_contentType release];
  [_mimeType release];
  
  [super dealloc];
}

@end

@implementation WebServerMultiPartArgument

@synthesize data=_data;

- (id) initWithContentType:(NSString*)contentType data:(NSData*)data {
  if ((self = [super initWithContentType:contentType])) {
    _data = [data retain];
  }
  return self;
}

- (void) dealloc {
  [_data release];
  
  [super dealloc];
}

- (NSString*) description {
  return [NSString stringWithFormat:@"<%@ | '%@' | %i bytes>", [self class], self.mimeType, (int)_data.length];
}

@end

@implementation WebServerMultiPartFile

@synthesize fileName=_fileName, temporaryPath=_temporaryPath;

- (id) initWithContentType:(NSString*)contentType fileName:(NSString*)fileName temporaryPath:(NSString*)temporaryPath {
  if ((self = [super initWithContentType:contentType])) {
    _fileName = [fileName copy];
    _temporaryPath = [temporaryPath copy];
  }
  return self;
}

- (void) dealloc {
  unlink([_temporaryPath fileSystemRepresentation]);
  
  [_fileName release];
  [_temporaryPath release];
  
  [super dealloc];
}

- (NSString*) description {
  return [NSString stringWithFormat:@"<%@ | '%@' | '%@>'", [self class], self.mimeType, _fileName];
}

@end

@implementation WebServerMultiPartFormRequest

@synthesize arguments=_arguments, files=_files;

+ (void) initialize {
  if (_newlineData == nil) {
    _newlineData = [[NSData alloc] initWithBytes:"\r\n" length:2];
    DCHECK(_newlineData);
  }
  if (_newlinesData == nil) {
    _newlinesData = [[NSData alloc] initWithBytes:"\r\n\r\n" length:4];
    DCHECK(_newlinesData);
  }
  if (_dashNewlineData == nil) {
    _dashNewlineData = [[NSData alloc] initWithBytes:"--\r\n" length:4];
    DCHECK(_dashNewlineData);
  }
}

+ (NSString*) mimeType {
  return @"multipart/form-data";
}

- (id) initWithMethod:(NSString*)method headers:(NSDictionary*)headers path:(NSString*)path query:(NSString*)query {
  if ((self = [super initWithMethod:method headers:headers path:path query:query])) {
    NSString* boundary = _ExtractHeaderParameter(self.contentType, @"boundary");
    if (boundary) {
      _boundary = [[[NSString stringWithFormat:@"--%@", boundary] dataUsingEncoding:NSASCIIStringEncoding] retain];
    }
    if (_boundary == nil) {
      DNOT_REACHED();
      [self release];
      return nil;
    }
    
    _arguments = [[NSMutableDictionary alloc] init];
    _files = [[NSMutableDictionary alloc] init];
  }
  return self;
}

- (BOOL) open {
  DCHECK(_parserData == nil);
  _parserData = [[NSMutableData alloc] initWithCapacity:kMultiPartBufferSize];
  _parserState = kParserState_Start;
  return YES;
}

// http://www.w3.org/TR/html401/interact/forms.html#h-17.13.4
- (BOOL) _parseData {
  BOOL success = YES;
  
  if (_parserState == kParserState_Headers) {
    NSRange range = [_parserData rangeOfData:_newlinesData options:0 range:NSMakeRange(0, _parserData.length)];
    if (range.location != NSNotFound) {
      
      [_controlName release];
      _controlName = nil;
      [_fileName release];
      _fileName = nil;
      [_contentType release];
      _contentType = nil;
      [_tmpPath release];
      _tmpPath = nil;
      CFHTTPMessageRef message = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, true);
      const char* temp = "GET / HTTP/1.0\r\n";
      CFHTTPMessageAppendBytes(message, (const UInt8*)temp, strlen(temp));
      CFHTTPMessageAppendBytes(message, _parserData.bytes, range.location + range.length);
      if (CFHTTPMessageIsHeaderComplete(message)) {
        NSString* controlName = nil;
        NSString* fileName = nil;
        NSDictionary* headers = [(id)CFHTTPMessageCopyAllHeaderFields(message) autorelease];
        NSString* contentDisposition = [headers objectForKey:@"Content-Disposition"];
        if ([[contentDisposition lowercaseString] hasPrefix:@"form-data;"]) {
          controlName = _ExtractHeaderParameter(contentDisposition, @"name");
          fileName = _ExtractHeaderParameter(contentDisposition, @"filename");
        }
        _controlName = [controlName copy];
        _fileName = [fileName copy];
        _contentType = [[headers objectForKey:@"Content-Type"] retain];
      }
      CFRelease(message);
      if (_controlName) {
        if (_fileName) {
          NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
          _tmpFile = open([path fileSystemRepresentation], O_CREAT | O_TRUNC | O_WRONLY, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);
          if (_tmpFile > 0) {
            _tmpPath = [path copy];
          } else {
            DNOT_REACHED();
            success = NO;
          }
        }
      } else {
        DNOT_REACHED();
        success = NO;
      }
      
      [_parserData replaceBytesInRange:NSMakeRange(0, range.location + range.length) withBytes:NULL length:0];
      _parserState = kParserState_Content;
    }
  }
  
  if ((_parserState == kParserState_Start) || (_parserState == kParserState_Content)) {
    NSRange range = [_parserData rangeOfData:_boundary options:0 range:NSMakeRange(0, _parserData.length)];
    if (range.location != NSNotFound) {
      NSRange subRange = NSMakeRange(range.location + range.length, _parserData.length - range.location - range.length);
      NSRange subRange1 = [_parserData rangeOfData:_newlineData options:NSDataSearchAnchored range:subRange];
      NSRange subRange2 = [_parserData rangeOfData:_dashNewlineData options:NSDataSearchAnchored range:subRange];
      if ((subRange1.location != NSNotFound) || (subRange2.location != NSNotFound)) {
        
        if (_parserState == kParserState_Content) {
          const void* dataBytes = _parserData.bytes;
          NSUInteger dataLength = range.location - 2;
          if (_tmpPath) {
            int result = write(_tmpFile, dataBytes, dataLength);
            if (result == dataLength) {
              if (close(_tmpFile) == 0) {
                _tmpFile = 0;
                WebServerMultiPartFile* file = [[WebServerMultiPartFile alloc] initWithContentType:_contentType fileName:_fileName temporaryPath:_tmpPath];
                [_files setObject:file forKey:_controlName];
                [file release];
              } else {
                DNOT_REACHED();
                success = NO;
              }
            } else {
              DNOT_REACHED();
              success = NO;
            }
            [_tmpPath release];
            _tmpPath = nil;
          } else {
            NSData* data = [[NSData alloc] initWithBytesNoCopy:(void*)dataBytes length:dataLength freeWhenDone:NO];
            WebServerMultiPartArgument* argument = [[WebServerMultiPartArgument alloc] initWithContentType:_contentType data:data];
            [_arguments setObject:argument forKey:_controlName];
            [argument release];
            [data release];
          }
        }
        
        if (subRange1.location != NSNotFound) {
          [_parserData replaceBytesInRange:NSMakeRange(0, subRange1.location + subRange1.length) withBytes:NULL length:0];
          _parserState = kParserState_Headers;
          success = [self _parseData];
        } else {
          _parserState = kParserState_End;
        }
      }
    } else {
      NSUInteger margin = 2 * _boundary.length;
      if (_tmpPath && (_parserData.length > margin)) {
        NSUInteger length = _parserData.length - margin;
        int result = write(_tmpFile, _parserData.bytes, length);
        if (result == length) {
          [_parserData replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
        } else {
          DNOT_REACHED();
          success = NO;
        }
      }
    }
  }
  return success;
}

- (NSInteger) write:(const void*)buffer maxLength:(NSUInteger)length {
  DCHECK(_parserData != nil);
  [_parserData appendBytes:buffer length:length];
  return ([self _parseData] ? length : -1);
}

- (BOOL) close {
  DCHECK(_parserData != nil);
  [_parserData release];
  _parserData = nil;
  [_controlName release];
  [_fileName release];
  [_contentType release];
  if (_tmpFile > 0) {
    close(_tmpFile);
    unlink([_tmpPath fileSystemRepresentation]);
  }
  [_tmpPath release];
  return (_parserState == kParserState_End ? YES : NO);
}

- (void) dealloc {
  DCHECK(_parserData == nil);
  [_arguments release];
  [_files release];
  [_boundary release];
  
  [super dealloc];
}

@end
