// Copyright © Microsoft Open Technologies, Inc.
//
// All Rights Reserved
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS
// OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
// ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A
// PARTICULAR PURPOSE, MERCHANTABILITY OR NON-INFRINGEMENT.
//
// See the Apache License, Version 2.0 for the specific language
// governing permissions and limitations under the License.


#import "ADTestAppAcquireViewController.h"
#import <ADALiOS/ADAL.h>
#import "ADTestAppSettings.h"
#import "ADTestAppLogger.h"


ADAuthenticationContext* context = nil;

@interface ADTestAppAcquireViewController ()
- (IBAction)pressMeAction:(id)sender;
- (IBAction)clearCachePressed:(id)sender;
- (IBAction)getUsersPressed:(id)sender;
- (IBAction)expireAllPressed:(id)sender;
- (IBAction)promptAlways:(id)sender;
- (IBAction)acquireTokenSilentAction:(id)sender;
@end

@implementation ADTestAppAcquireViewController


- (void)setStatus:(NSString*)status
             type:(TALogType)type
{
    NSDictionary* attributes = nil;
    
    switch (type)
    {
        case TALogSuccess: attributes = @{ NSForegroundColorAttributeName : [UIColor greenColor] }; break;
        case TALogError: attributes = @{ NSForegroundColorAttributeName : [UIColor redColor] }; break;
        default:
            break;
    }
    
    NSAttributedString* attrMessage = [[NSAttributedString alloc] initWithString:status attributes:attributes];
    [_statusLabel setAttributedText:attrMessage];
    
    [ADTestAppLogger logMessage:status type:type];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    _settings = [ADTestAppSettings defaultSettings];
    
    //settings.credentialsType = AD_CREDENTIALS_EMBEDDED;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(consumeToken)
     name:UIApplicationWillEnterForegroundNotification object:nil];
    
    // Do any additional setup after loading the view, typically from a nib.
    [ADLogger setLevel:ADAL_LOG_LEVEL_VERBOSE];//Log everything
    
        //[ADAuthenticationSettings sharedInstance].credentialsType = AD_CREDENTIALS_EMBEDDED;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [ADLogger setLogCallBack:nil];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

#pragma mark - Flipside View Controller

- (void)flipsideViewControllerDidFinish:(ADTestAppSettingsViewController *)controller
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)popoverControllerDidDismissPopover:(UIPopoverController *)popoverController
{
    self.flipsidePopoverController = nil;
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender
{
    if ([[segue identifier] isEqualToString:@"showAlternate"]) {
        [[segue destinationViewController] setDelegate:self];
    }
}

- (IBAction)togglePopover:(id)sender
{
    if (self.flipsidePopoverController) {
        [self.flipsidePopoverController dismissPopoverAnimated:YES];
        self.flipsidePopoverController = nil;
    } else {
        [self performSegueWithIdentifier:@"showAlternate" sender:sender];
    }
}

- (IBAction)pressMeAction:(id)sender
{
    NSString* authority = [_settings authority];
    NSString* clientId = [_settings clientId];
    NSString* redirectUri = [_settings redirectUri];
    BOOL validateAuthority = [_settings validateAuthority];
    NSString* userId = [_settings userId];
    
    ADAuthenticationError* error = nil;
    //[weakSelf setStatus:[NSString stringWithFormat:@"Authority: %@", params.authority]];
    context = [ADAuthenticationContext authenticationContextWithAuthority:authority
                                                        validateAuthority:validateAuthority
                                                                    error:&error];
    if (!context)
    {
        [self setStatus:error.errorDetails type:TALogError];
        return;
    }
    context.parentController = self;
    
    NSArray* scopes = [_settings scopes];
    NSArray* additionalScopes = [_settings additionalScopes];
    
    [self setStatus:@"Acquiring Token" type:TALogStatus];
    
    ADUserIdentifier* adUserId = [ADUserIdentifier identifierWithId:userId type:(ADUserIdentifierType)[_scUserType selectedSegmentIndex]];
    [context acquireTokenForScopes:scopes
                  additionalScopes:additionalScopes
                          clientId:clientId
                       redirectUri:[NSURL URLWithString:redirectUri]
                    promptBehavior:[_scPromptBehavior selectedSegmentIndex]
                        identifier:adUserId
              extraQueryParameters:nil
                   completionBlock:^(ADAuthenticationResult *result)
    {
        if (result.status != AD_SUCCEEDED)
        {
            [self setStatus:result.error.errorDetails type:TALogError];
            return;
        }
        
        ADProfileInfo* userInfo = result.tokenCacheStoreItem.profileInfo;
        if (!userInfo)
        {
            [self setStatus:@"Succesfully signed in but no user info?" type:TALogStatus];
            return;
        }
        else
        {
            [self setStatus:[NSString stringWithFormat:@"Successfully logged in as %@", userInfo.userId] type:TALogSuccess];
            [ADTestAppLogger logMessage:[NSString stringWithFormat:@"allclaims=%@", userInfo.allClaims] type:TALogInformation];
        }
    }];
}


- (IBAction)acquireTokenSilentAction:(id)sender
{
    
    [self setStatus:@"Starting Acquire Token Silent." type:TALogStatus];
    
    //    NSURL* resource = [NSURL URLWithString:@"http://testapi007.azurewebsites.net/api/WorkItem"];
    ADAuthenticationError * error;
    
    //401 worked, now try to acquire the token:
    //TODO: replace the authority here with the one that comes back from 'params'
    NSString* authority = [_settings authority];//params.authority;
    NSString* clientId = [_settings clientId];
    NSString* userId = [_settings userId];
    //NSString* __block resourceString = mAADInstance.resource;
    NSString* redirectUri = [_settings redirectUri];
    [ADTestAppLogger logMessage:[NSString stringWithFormat:@"Authority: %@", authority] type:TALogInformation];
    context = [ADAuthenticationContext authenticationContextWithAuthority:authority
                                                                    error:&error];
    if (!context)
    {
        [self setStatus:error.errorDetails type:TALogError];
        return;
    }
    context.parentController = self;
    
    [context acquireTokenSilentForScopes:[_settings scopes]
                                clientId:clientId
                             redirectUri:[NSURL URLWithString:redirectUri]
                              identifier:[ADUserIdentifier identifierWithId:userId]
                         completionBlock:^(ADAuthenticationResult *result)
    {
        if (result.status != AD_SUCCEEDED)
        {
            [self setStatus:result.error.errorDetails type:TALogError];
            return;
        }
    }];
}

- (IBAction)clearCachePressed:(id)sender
{
    ADAuthenticationError* error;
    id<ADTokenCacheStoring> cache = [ADAuthenticationSettings sharedInstance].defaultTokenCacheStore;
    NSArray* allItems = [cache allItems:&error];
    if (error)
    {
        [self setStatus:error.errorDetails type:TALogError];
        return;
    }
    NSString* status = nil;
    if (allItems.count > 0)
    {
        [cache removeAll:&error];
        if (error)
        {
            status = error.errorDetails;
        }
        else
        {
            status = @"Items removed.";
        }
    }
    else
    {
        status = @"Nothing in the cache.";
    }
    NSHTTPCookieStorage* cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSArray* cookies = cookieStorage.cookies;
    if (cookies.count)
    {
        for(NSHTTPCookie* cookie in cookies)
        {
            [cookieStorage deleteCookie:cookie];
        }
        status = [status stringByAppendingString:@" Cookies cleared."];
    }
}

-(NSString*) processAccessToken: (NSString*) accessToken
{
    //Add any future processing of the token here (e.g. opening to see what is inside):
    return accessToken;
}


@end
