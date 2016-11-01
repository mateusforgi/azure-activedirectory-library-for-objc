// Copyright (c) Microsoft Corporation.
// All rights reserved.
//
// This code is licensed under the MIT License.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "ADAuthenticationRequest.h"
#import "ADAuthenticationContext+Internal.h"
#import "ADTokenCacheItem+Internal.h"
#import "ADInstanceDiscovery.h"
#import "ADHelpers.h"
#import "ADUserIdentifier.h"
#import "ADTokenCacheKey.h"
#import "ADAcquireTokenSilentHandler.h"
#import "ADTelemetry.h"
#import "ADTelemetry+Internal.h"
#import "ADTelemetryAPIEvent.h"

@implementation ADAuthenticationRequest (AcquireToken)

#pragma mark -
#pragma mark AcquireToken

- (void)acquireToken:(ADAuthenticationCallback)completionBlock
{
    THROW_ON_NIL_ARGUMENT(completionBlock);
    AD_REQUEST_CHECK_ARGUMENT([_requestParams resource]);
    [self ensureRequest];
#if AD_TELEMETRY
    NSString* telemetryRequestId = [_requestParams telemetryRequestId];
#endif
    
    __block NSString* log = [NSString stringWithFormat:@"##### BEGIN acquireToken%@ (authority = %@, resource = %@, clientId = %@, idtype = %@) #####",
                             _silent ? @"Silent" : @"", _requestParams.authority, _requestParams.resource, _requestParams.clientId, [_requestParams.identifier typeAsString]];
    AD_LOG_INFO_F(log, _requestParams.correlationId, @"userId = %@", _requestParams.identifier.userId);
    
    ADAuthenticationCallback wrappedCallback = ^void(ADAuthenticationResult* result)
    {
        NSString* finalLog = nil;
        if (result.status == AD_SUCCEEDED)
        {
            finalLog = [NSString stringWithFormat:@"##### END %@ succeeded. #####", log];
        }
        else
        {
            ADAuthenticationError* error = result.error;
            finalLog = [NSString stringWithFormat:@"##### END %@ failed { domain: %@ code: %ld protocolCode: %@ errorDetails: %@} #####",
                        log, error.domain, (long)error.code, error.protocolCode, error.errorDetails];
        }
        
        
        AD_LOG_INFO(finalLog, result.correlationId, nil);
        
        completionBlock(result);
    };
    
    if (!_silent && ![NSThread isMainThread])
    {
        ADAuthenticationError* error =
        [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_UI_NOT_ON_MAIN_THREAD
                                               protocolCode:nil
                                               errorDetails:@"Interactive authentication requests must originate from the main thread"
                                              correlationId:_requestParams.correlationId];
        
        wrappedCallback([ADAuthenticationResult resultFromError:error correlationId:_requestParams.correlationId]);
        return;
    }
    
    if (!_silent && _context.credentialsType == AD_CREDENTIALS_AUTO && ![ADAuthenticationRequest validBrokerRedirectUri:[_requestParams redirectUri]])
    {
        ADAuthenticationError* error =
        [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_TOKENBROKER_INVALID_REDIRECT_URI
                                               protocolCode:nil
                                               errorDetails:ADRedirectUriInvalidError
                                              correlationId:_requestParams.correlationId];
        wrappedCallback([ADAuthenticationResult resultFromError:error correlationId:_requestParams.correlationId]);
        return;
    }
    
    if (!_context.validateAuthority)
    {
        [self validatedAcquireToken:wrappedCallback];
        return;
    }
#if AD_TELEMETRY
    [[ADTelemetry sharedInstance] startEvent:telemetryRequestId eventName:@"authority_validation"];
#endif
    [[ADInstanceDiscovery sharedInstance] validateAuthority:_context.authority
                                              requestParams:_requestParams
                                            completionBlock:^(BOOL validated, ADAuthenticationError *error)
     {
         (void)validated;
#if AD_TELEMETRY
         ADTelemetryAPIEvent* event = [[ADTelemetryAPIEvent alloc] initWithName:@"authority_validation"
                                                                      requestId:telemetryRequestId
                                                                  correlationId:correlationId];
         [event setAuthorityValidationStatus:validated ? @"YES" : @"NO"];
         [event setAuthority:_context.authority];
         [[ADTelemetry sharedInstance] stopEvent:telemetryRequestId event:event];
         SAFE_ARC_RELEASE(event);
#endif
         if (error)
         {
             wrappedCallback([ADAuthenticationResult resultFromError:error correlationId:_requestParams.correlationId]);
         }
         else
         {
             [self validatedAcquireToken:wrappedCallback];
         }
     }];
    
}

- (void)validatedAcquireToken:(ADAuthenticationCallback)completionBlock
{
    [self ensureRequest];
    
    if (![ADAuthenticationContext isForcedAuthorization:_promptBehavior] && [_context hasCacheStore])
    {
#if AD_TELEMETRY
        [[ADTelemetry sharedInstance] startEvent:[self telemetryRequestId] eventName:@"acquire_token_silent_handler"];
#endif
        ADAcquireTokenSilentHandler* request = [ADAcquireTokenSilentHandler requestWithParams:_requestParams];
        [request getToken:^(ADAuthenticationResult *result)
        {
#if AD_TELEMETRY
            ADTelemetryAPIEvent* event = [[ADTelemetryAPIEvent alloc] initWithName:@"acquire_token_silent_handler"
                                                                         requestId:[self telemetryRequestId]
                                                                     correlationId:[self correlationId]];
            [[ADTelemetry sharedInstance] stopEvent:[self telemetryRequestId] event:event];
            SAFE_ARC_RELEASE(event);
#endif
            if ([ADAuthenticationContext isFinalResult:result])
            {
                completionBlock(result);
                return;
            }
            
            SAFE_ARC_RELEASE(_underlyingError);
            _underlyingError = result.error;
            SAFE_ARC_RETAIN(_underlyingError);
            
            [self requestToken:completionBlock];
        }];
        return;
    }
    
    [self requestToken:completionBlock];
}

- (void)requestToken:(ADAuthenticationCallback)completionBlock
{
    [self ensureRequest];
    NSUUID* correlationId = [_requestParams correlationId];
#if AD_TELEMETRY
    NSString* telemetryRequestId = [_requestParams telemetryRequestId];
#endif
    
    if (_samlAssertion)
    {
        [self requestTokenByAssertion:completionBlock];
        return;
    }

    if (_silent && !_allowSilent)
    {
        //The cache lookup and refresh token attempt have been unsuccessful,
        //so credentials are needed to get an access token, but the developer, requested
        //no UI to be shown:
        NSDictionary* underlyingError = _underlyingError ? @{NSUnderlyingErrorKey:_underlyingError} : nil;
        ADAuthenticationError* error =
        [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_SERVER_USER_INPUT_NEEDED
                                               protocolCode:nil
                                               errorDetails:ADCredentialsNeeded
                                                   userInfo:underlyingError
                                              correlationId:correlationId];
        
        ADAuthenticationResult* result = [ADAuthenticationResult resultFromError:error correlationId:correlationId];
        completionBlock(result);
        return;
    }
    
    //can't pop UI or go to broker in an extension
    if ([[[NSBundle mainBundle] bundlePath] hasSuffix:@".appex"])
    {
        // This is an app extension. Return an error unless a webview is specified by the
        // extension and embedded auth is being used.
        BOOL isEmbeddedWebView = (nil != _context.webView) && (AD_CREDENTIALS_EMBEDDED == _context.credentialsType);
        if (!isEmbeddedWebView)
        {
            ADAuthenticationError* error =
            [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_UI_NOT_SUPPORTED_IN_APP_EXTENSION
                                                   protocolCode:nil
                                                   errorDetails:ADInteractionNotSupportedInExtension
                                                  correlationId:correlationId];
            ADAuthenticationResult* result = [ADAuthenticationResult resultFromError:error correlationId:correlationId];
            completionBlock(result);
            return;
        }
    }
    
    if (![self takeExclusionLock:completionBlock])
    {
        return;
    }
    
    [self requestTokenImpl:^(ADAuthenticationResult *result)
    {
        [ADAuthenticationRequest releaseExclusionLock];
        completionBlock(result);
    }];
}

- (void)requestTokenImpl:(ADAuthenticationCallback)completionBlock
{
#if !AD_BROKER
    //call the broker.
    if ([self canUseBroker])
    {
        [self callBroker:completionBlock];
        return;
    }
#endif
    
    __block BOOL silentRequest = _allowSilent;
    
// Get the code first:
#if AD_TELEMETRY
    [[ADTelemetry sharedInstance] startEvent:telemetryRequestId eventName:@"authorization_code"];
#endif
    [self requestCode:^(NSString * code, ADAuthenticationError *error)
     {
#if AD_TELEMETRY
         ADTelemetryAPIEvent* event = [[ADTelemetryAPIEvent alloc] initWithName:@"authorization_code"
                                                                      requestId:telemetryRequestId
                                                                  correlationId:_requestParams.correlationId];
#endif

         if (error)
         {
             if (silentRequest)
             {
                 _allowSilent = NO;
                 [self requestToken:completionBlock];
                 return;
             }
             
             ADAuthenticationResult* result = (AD_ERROR_UI_USER_CANCEL == error.code) ? [ADAuthenticationResult resultFromCancellation:_requestParams.correlationId]
             : [ADAuthenticationResult resultFromError:error correlationId:_requestParams.correlationId];
#if AD_TELEMETRY
             [event setAPIStatus:(AD_ERROR_UI_USER_CANCEL == error.code) ? @"canceled":@"failed"];
             [[ADTelemetry sharedInstance] stopEvent:_requestParams.telemetryRequestId event:event];
#endif
             completionBlock(result);
         }
         else
         {
             if([code hasPrefix:@"msauth://"])
             {
#if AD_TELEMETRY
                 [event setAPIStatus:@"try to invoke broker from webview"];
                 [[ADTelemetry sharedInstance] stopEvent:_requestParams.telemetryRequestId event:event];
#endif
                 [self callBroker:completionBlock];
             }
             else
             {
#if AD_TELEMETRY
                 [event setAPIStatus:@"succeeded"];
                 [[ADTelemetry sharedInstance] stopEvent:_requestParams.telemetryRequestId event:event];
                 
                 [[ADTelemetry sharedInstance] startEvent:_requestParams.telemetryRequestId eventName:@"token_grant"];
#endif
                 [self requestTokenByCode:code
                          completionBlock:^(ADAuthenticationResult *result)
                  {
#if AD_TELEMETRY
                      ADTelemetryAPIEvent* event = [[ADTelemetryAPIEvent alloc] initWithName:@"token_grant"
                                                                                   requestId:_requestParams.telemetryRequestId
                                                                               correlationId:_requestParams.correlationId];
                      [event setGrantType:@"by code"];
                      [event setResultStatus:[result status]];
                      [[ADTelemetry sharedInstance] stopEvent:_requestParams.telemetryRequestId event:event];
                      SAFE_ARC_RELEASE(event);
#endif
                      if (AD_SUCCEEDED == result.status)
                      {
                          [[_requestParams tokenCache] updateCacheToResult:result
                                                                 cacheItem:nil
                                                              refreshToken:nil
                                                                   context:_requestParams];
                          result = [ADAuthenticationContext updateResult:result toUser:[_requestParams identifier]];
                      }
                      completionBlock(result);
                  }];
             }
         }
#if AD_TELEMETRY
         SAFE_ARC_RELEASE(event);
#endif
     }];
}

// Generic OAuth2 Authorization Request, obtains a token from an authorization code.
- (void)requestTokenByCode:(NSString *)code
           completionBlock:(ADAuthenticationCallback)completionBlock
{
    HANDLE_ARGUMENT(code, [_requestParams correlationId]);
    [self ensureRequest];
    AD_LOG_VERBOSE_F(@"Requesting token from authorization code.", [_requestParams correlationId], @"Requesting token by authorization code for resource: %@", [_requestParams resource]);
    
    //Fill the data for the token refreshing:
    NSMutableDictionary *request_data = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                         OAUTH2_AUTHORIZATION_CODE, OAUTH2_GRANT_TYPE,
                                         code, OAUTH2_CODE,
                                         [_requestParams clientId], OAUTH2_CLIENT_ID,
                                         [_requestParams redirectUri], OAUTH2_REDIRECT_URI,
                                         nil];
    if (![NSString adIsStringNilOrBlank:_scope])
    {
        [request_data setValue:_scope forKey:OAUTH2_SCOPE];
    }
    
    [self executeRequest:request_data
              completion:completionBlock];
}

@end