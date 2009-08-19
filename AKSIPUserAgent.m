//
//  AKSIPUserAgent.m
//  Telephone
//
//  Copyright (c) 2008-2009 Alexei Kuznetsov. All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//  1. Redistributions of source code must retain the above copyright notice,
//     this list of conditions and the following disclaimer.
//  2. Redistributions in binary form must reproduce the above copyright notice,
//     this list of conditions and the following disclaimer in the documentation
//     and/or other materials provided with the distribution.
//  3. Neither the name of the copyright holder nor the names of contributors
//     may be used to endorse or promote products derived from this software
//     without specific prior written permission.
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
//  THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
//  PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE THE COPYRIGHT HOLDER
//  OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
//  EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
//  PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
//  OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
//  WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
//  OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
//  ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

#import "AKSIPUserAgent.h"

#import <pjsua-lib/pjsua.h>

#import "AKNSString+PJSUA.h"
#import "AKSIPAccount.h"
#import "AKSIPCall.h"

#define THIS_FILE "AKSIPUserAgent.m"


const NSInteger kAKSIPUserAgentInvalidIdentifier = PJSUA_INVALID_ID;
const NSInteger kAKSIPUserAgentNameserversMax = 4;

NSString * const AKSIPUserAgentDidFinishStartingNotification
  = @"AKSIPUserAgentDidFinishStarting";
NSString * const AKSIPUserAgentDidFinishStoppingNotification
  = @"AKSIPUserAgentDidFinishStopping";
NSString * const AKSIPUserAgentDidDetectNATNotification
  = @"AKSIPUserAgentDidDetectNAT";

// Generic config defaults.
NSString * const kAKSIPUserAgentDefaultOutboundProxyHost = @"";
const NSInteger kAKSIPUserAgentDefaultOutboundProxyPort = 5060;
NSString * const kAKSIPUserAgentDefaultSTUNServerHost = @"";
const NSInteger kAKSIPUserAgentDefaultSTUNServerPort = 3478;
NSString * const kAKSIPUserAgentDefaultLogFileName = nil;
const NSInteger kAKSIPUserAgentDefaultLogLevel = 3;
const NSInteger kAKSIPUserAgentDefaultConsoleLogLevel = 0;
const BOOL kAKSIPUserAgentDefaultDetectsVoiceActivity = YES;
const BOOL kAKSIPUserAgentDefaultUsesICE = NO;
const NSInteger kAKSIPUserAgentDefaultTransportPort = 0;  // 0 for any available port.
NSString * const kAKSIPUserAgentDefaultTransportPublicHost = nil;

static AKSIPUserAgent *sharedUserAgent = nil;

enum {
  kAKRingbackFrequency1  = 440,
  kAKRingbackFrequency2  = 480,
  kAKRingbackOnDuration  = 2000,
  kAKRingbackOffDuration = 4000,
  kAKRingbackCount       = 1,
  kAKRingbackInterval    = 4000
};


@interface AKSIPUserAgent ()

@property(assign) AKSIPUserAgentState state;

@property(assign) pj_pool_t *pjPool;
@property(assign) NSInteger ringbackSlot;
@property(assign) pjmedia_port *ringbackPort;

// Create and start SIP user agent. Supposed to be run on the secondary thread.
- (void)ak_start;

// Stop and destroy SIP user agent. Supposed to be run on the secondary thread.
- (void)ak_stop;

@end


@implementation AKSIPUserAgent

@dynamic delegate;
@synthesize accounts = accounts_;
@synthesize started;
@synthesize state = state_;
@synthesize detectedNATType = detectedNATType_;
@synthesize pjsuaLock = pjsuaLock_;
@dynamic activeCallsCount;
@dynamic callData;
@synthesize pjPool = pjPool_;
@synthesize ringbackSlot = ringbackSlot_;
@synthesize ringbackCount = ringbackCount_;
@synthesize ringbackPort = ringbackPort_;

@dynamic nameservers;
@synthesize outboundProxyHost = outboundProxyHost_;
@dynamic outboundProxyPort;
@synthesize STUNServerHost = STUNServerHost_;
@dynamic STUNServerPort;
@synthesize userAgentString = userAgentString_;
@dynamic logFileName;
@synthesize logLevel = logLevel_;
@synthesize consoleLogLevel = consoleLogLevel_;
@synthesize detectsVoiceActivity = detectsVoiceActivity_;
@synthesize usesICE = usesICE_;
@dynamic transportPort;
@synthesize transportPublicHost = transportPublicHost_;

- (id <AKSIPUserAgentDelegate>)delegate {
  return delegate_;
}

- (void)setDelegate:(id <AKSIPUserAgentDelegate>)aDelegate {
  if (delegate_ == aDelegate)
    return;
  
  NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
  
  if (delegate_ != nil)
    [notificationCenter removeObserver:delegate_ name:nil object:self];
  
  if (aDelegate != nil) {
    if ([aDelegate respondsToSelector:@selector(SIPUserAgentDidFinishStarting:)])
      [notificationCenter addObserver:aDelegate
                             selector:@selector(SIPUserAgentDidFinishStarting:)
                                 name:AKSIPUserAgentDidFinishStartingNotification
                               object:self];
    
    if ([aDelegate respondsToSelector:@selector(SIPUserAgentDidFinishStopping:)])
      [notificationCenter addObserver:aDelegate
                             selector:@selector(SIPUserAgentDidFinishStopping:)
                                 name:AKSIPUserAgentDidFinishStoppingNotification
                               object:self];
    
    if ([aDelegate respondsToSelector:@selector(SIPUserAgentDidDetectNAT:)])
      [notificationCenter addObserver:aDelegate
                             selector:@selector(SIPUserAgentDidDetectNAT:)
                                 name:AKSIPUserAgentDidDetectNATNotification
                               object:self];
  }
  
  delegate_ = aDelegate;
}

- (BOOL)isStarted {
  return ([self state] == kAKSIPUserAgentStarted) ? YES : NO;
}

- (NSUInteger)activeCallsCount {
  return pjsua_call_get_count();
}

- (AKSIPUserAgentCallData *)callData {
  return callData_;
}

- (NSArray *)nameservers {
  return [[nameservers_ copy] autorelease];
}

- (void)setNameservers:(NSArray *)newNameservers {
  if (nameservers_ != newNameservers) {
    [nameservers_ release];
    
    if ([newNameservers count] > kAKSIPUserAgentNameserversMax) {
      nameservers_ = [[newNameservers subarrayWithRange:
                      NSMakeRange(0, kAKSIPUserAgentNameserversMax)] retain];
    } else {
      nameservers_ = [newNameservers copy];
    }
  }
}

- (NSUInteger)outboundProxyPort {
  return outboundProxyPort_;
}

- (void)setOutboundProxyPort:(NSUInteger)port {
  if (port > 0 && port < 65535)
    outboundProxyPort_ = port;
  else
    outboundProxyPort_ = kAKSIPUserAgentDefaultOutboundProxyPort;
}

- (NSUInteger)STUNServerPort {
  return STUNServerPort_;
}

- (void)setSTUNServerPort:(NSUInteger)port {
  if (port > 0 && port < 65535)
    STUNServerPort_ = port;
  else
    STUNServerPort_ = kAKSIPUserAgentDefaultSTUNServerPort;
}

- (NSString *)logFileName {
  return [[logFileName_ copy] autorelease];
}

- (void)setLogFileName:(NSString *)pathToFile {
  if (logFileName_ != pathToFile) {
    if ([pathToFile length] > 0) {
      [logFileName_ release];
      logFileName_ = [pathToFile copy];
    } else {
      [logFileName_ release];
      logFileName_ = kAKSIPUserAgentDefaultLogFileName;
    }
  }
}

- (NSUInteger)transportPort {
  return transportPort_;
}

- (void)setTransportPort:(NSUInteger)port {
  if (port > 0 && port < 65535)
    transportPort_ = port;
  else
    transportPort_ = kAKSIPUserAgentDefaultTransportPort;
}


#pragma mark AKSIPUserAgent singleton instance

+ (AKSIPUserAgent *)sharedUserAgent {
  @synchronized(self) {
    if (sharedUserAgent == nil)
      [[self alloc] init];  // Assignment not done here.
  }
  
  return sharedUserAgent;
}

+ (id)allocWithZone:(NSZone *)zone {
  @synchronized(self) {
    if (sharedUserAgent == nil) {
      sharedUserAgent = [super allocWithZone:zone];
      return sharedUserAgent;  // Assignment and return on first allocation.
    }
  }
  
  return nil;  // On subsequent allocation attempts return nil.
}

- (id)copyWithZone:(NSZone *)zone {
  return self;
}

- (id)retain {
  return self;
}

- (NSUInteger)retainCount {
  return UINT_MAX;  // Denotes an object that cannot be released.
}

- (void)release {
  // Do nothing.
}

- (id)autorelease {
  return self;
}


#pragma mark -

- (id)initWithDelegate:(id)aDelegate {
  self = [super init];
  if (self == nil)
    return nil;
  
  [self setDelegate:aDelegate];
  accounts_ = [[NSMutableArray alloc] init];
  [self setDetectedNATType:kAKNATTypeUnknown];
  pjsuaLock_ = [[NSLock alloc] init];
  
  [self setOutboundProxyHost:kAKSIPUserAgentDefaultOutboundProxyHost];
  [self setOutboundProxyPort:kAKSIPUserAgentDefaultOutboundProxyPort];
  [self setSTUNServerHost:kAKSIPUserAgentDefaultSTUNServerHost];
  [self setSTUNServerPort:kAKSIPUserAgentDefaultSTUNServerPort];
  [self setLogFileName:kAKSIPUserAgentDefaultLogFileName];
  [self setLogLevel:kAKSIPUserAgentDefaultLogLevel];
  [self setConsoleLogLevel:kAKSIPUserAgentDefaultConsoleLogLevel];
  [self setDetectsVoiceActivity:kAKSIPUserAgentDefaultDetectsVoiceActivity];
  [self setUsesICE:kAKSIPUserAgentDefaultUsesICE];
  [self setTransportPort:kAKSIPUserAgentDefaultTransportPort];
  [self setTransportPublicHost:kAKSIPUserAgentDefaultTransportPublicHost];
  
  [self setRingbackSlot:kAKSIPUserAgentInvalidIdentifier];
  
  return self;
}

- (id)init {
  return [self initWithDelegate:nil];
}

- (void)dealloc {
  [accounts_ release];
  [pjsuaLock_ release];
  [nameservers_ release];
  [outboundProxyHost_ release];
  [STUNServerHost_ release];
  [userAgentString_ release];
  [logFileName_ release];
  [transportPublicHost_ release];
  
  [super dealloc];
}


#pragma mark -

- (void)start {
  // Do nothing if it's already started or being started.
  if ([self state] > kAKSIPUserAgentStopped)
    return;
  
  [[self pjsuaLock] lock];
  
  [self setState:kAKSIPUserAgentStarting];
  
  // Create PJSUA on the main thread to make all subsequent calls from the main
  // thread.
  pj_status_t status = pjsua_create();
  if (status != PJ_SUCCESS) {
    NSLog(@"Error creating PJSUA");
    [self setState:kAKSIPUserAgentStopped];
    [[self pjsuaLock] unlock];
    return;
  }
  
  [[self pjsuaLock] unlock];
  
  [self performSelectorInBackground:@selector(ak_start)
                         withObject:nil];
}

// This method is supposed to run in the secondary thread.
- (void)ak_start {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  
  [[self pjsuaLock] lock];
  
  [self setState:kAKSIPUserAgentStarting];
  
  pj_status_t status;
  
  pj_thread_desc aPJThreadDesc;
  if (!pj_thread_is_registered()) {
    pj_thread_t *pjThread;
    status = pj_thread_register(NULL, aPJThreadDesc, &pjThread);
    if (status != PJ_SUCCESS)
      NSLog(@"Error registering thread at PJSUA");
  }
  
  // Create pool for PJSUA.
  pj_pool_t *aPJPool;
  aPJPool = pjsua_pool_create("AKSIPUserAgent-pjsua", 1000, 1000);
  [self setPjPool:aPJPool];
  
  pjsua_config userAgentConfig;
  pjsua_logging_config loggingConfig;
  pjsua_media_config mediaConfig;
  pjsua_transport_config transportConfig;
  
  pjsua_config_default(&userAgentConfig);
  pjsua_logging_config_default(&loggingConfig);
  pjsua_media_config_default(&mediaConfig);
  pjsua_transport_config_default(&transportConfig);
  
  userAgentConfig.max_calls = kAKSIPCallsMax;
  
  if ([[self nameservers] count] > 0) {
    userAgentConfig.nameserver_count = [[self nameservers] count];
    for (NSUInteger i = 0; i < [[self nameservers] count]; ++i)
      userAgentConfig.nameserver[i] = [[[self nameservers] objectAtIndex:i]
                                       pjString];
  }
  
  if ([[self outboundProxyHost] length] > 0) {
    userAgentConfig.outbound_proxy_cnt = 1;
    
    if ([self outboundProxyPort] == kAKSIPUserAgentDefaultOutboundProxyPort) {
      userAgentConfig.outbound_proxy[0] = [[NSString stringWithFormat:@"sip:%@",
                                            [self outboundProxyHost]]
                                           pjString];
    } else {
      userAgentConfig.outbound_proxy[0] = [[NSString stringWithFormat:@"sip:%@:%u",
                                            [self outboundProxyHost],
                                            [self outboundProxyPort]]
                                           pjString];
    }
  }
  
  
  if ([[self STUNServerHost] length] > 0) {
    userAgentConfig.stun_host = [[NSString stringWithFormat:@"%@:%u",
                                  [self STUNServerHost], [self STUNServerPort]]
                                 pjString];
  }
  
  userAgentConfig.user_agent = [[self userAgentString] pjString];
  
  if ([[self logFileName] length] > 0) {
    loggingConfig.log_filename
      = [[[self logFileName] stringByExpandingTildeInPath]
         pjString];
  }
  
  loggingConfig.level = [self logLevel];
  loggingConfig.console_level = [self consoleLogLevel];
  mediaConfig.no_vad = ![self detectsVoiceActivity];
  mediaConfig.enable_ice = [self usesICE];
  mediaConfig.snd_auto_close_time = 1;
  transportConfig.port = [self transportPort];
  
  if ([[self transportPublicHost] length] > 0)
    transportConfig.public_addr = [[self transportPublicHost] pjString];
  
  userAgentConfig.cb.on_incoming_call = &AKSIPCallIncomingReceived;
  userAgentConfig.cb.on_call_media_state = &AKSIPCallMediaStateChanged;
  userAgentConfig.cb.on_call_state = &AKSIPCallStateChanged;
  userAgentConfig.cb.on_reg_state = &AKSIPAccountRegistrationStateChanged;
  userAgentConfig.cb.on_nat_detect = &AKSIPUserAgentDetectedNAT;
  
  // Initialize PJSUA.
  status = pjsua_init(&userAgentConfig, &loggingConfig, &mediaConfig);
  if (status != PJ_SUCCESS) {
    NSLog(@"Error initializing PJSUA");
    [self stop];
    [[self pjsuaLock] unlock];
    [pool release];
    return;
  }
  
  // Create ringback tones.
  unsigned i, samplesPerFrame;
  pjmedia_tone_desc tone[kAKRingbackCount];
  pj_str_t name;
  
  samplesPerFrame = mediaConfig.audio_frame_ptime *
  mediaConfig.clock_rate *
  mediaConfig.channel_count / 1000;
  
  name = pj_str("ringback");
  pjmedia_port *aRingbackPort;
  status = pjmedia_tonegen_create2([self pjPool], &name,
                                   mediaConfig.clock_rate,
                                   mediaConfig.channel_count,
                                   samplesPerFrame, 16, PJMEDIA_TONEGEN_LOOP,
                                   &aRingbackPort);
  if (status != PJ_SUCCESS) {
    NSLog(@"Error creating ringback tones");
    [self stop];
    [[self pjsuaLock] unlock];
    [pool release];
    return;
  }
  
  [self setRingbackPort:aRingbackPort];
  
  pj_bzero(&tone, sizeof(tone));
  for (i = 0; i < kAKRingbackCount; ++i) {
    tone[i].freq1 = kAKRingbackFrequency1;
    tone[i].freq2 = kAKRingbackFrequency2;
    tone[i].on_msec = kAKRingbackOnDuration;
    tone[i].off_msec = kAKRingbackOffDuration;
  }
  tone[kAKRingbackCount - 1].off_msec = kAKRingbackInterval;
  
  pjmedia_tonegen_play([self ringbackPort], kAKRingbackCount, tone, PJMEDIA_TONEGEN_LOOP);
  
  NSInteger aRingbackSlot;
  status = pjsua_conf_add_port([self pjPool], [self ringbackPort], &aRingbackSlot);
  if (status != PJ_SUCCESS) {
    NSLog(@"Error adding media port for ringback tones");
    [self stop];
    [[self pjsuaLock] unlock];
    [pool release];
    return;
  }
  
  [self setRingbackSlot:aRingbackSlot];
  
  // Add UDP transport.
  pjsua_transport_id transportIdentifier;
  status = pjsua_transport_create(PJSIP_TRANSPORT_UDP, &transportConfig,
                                  &transportIdentifier);
  if (status != PJ_SUCCESS) {
    NSLog(@"Error creating transport");
    [self stop];
    [[self pjsuaLock] unlock];
    [pool release];
    return;
  }
  
  // Get transport port chosen by PJSUA.
  if ([self transportPort] == 0) {
    pjsua_transport_info transportInfo;
    status = pjsua_transport_get_info(transportIdentifier, &transportInfo);
    if (status != PJ_SUCCESS)
      NSLog(@"Error getting transport info");
    
    [self setTransportPort:transportInfo.local_name.port];
    
    // Set chosen port back to transportConfig to add TCP transport below.
    transportConfig.port = [self transportPort];
  }
  
  // Add TCP transport. Don't return, just leave a log message on error.
  status = pjsua_transport_create(PJSIP_TRANSPORT_TCP, &transportConfig, NULL);
  if (status != PJ_SUCCESS)
    NSLog(@"Error creating TCP transport");
  
  // Start PJSUA.
  status = pjsua_start();
  if (status != PJ_SUCCESS) {
    NSLog(@"Error starting PJSUA");
    [self stop];
    [[self pjsuaLock] unlock];
    [pool release];
    return;
  }
  
  [self setState:kAKSIPUserAgentStarted];
  
  NSNotification *notification
  = [NSNotification notificationWithName:AKSIPUserAgentDidFinishStartingNotification
                                  object:self];
  
  [[NSNotificationCenter defaultCenter]
   performSelectorOnMainThread:@selector(postNotification:)
                    withObject:notification
                 waitUntilDone:NO];
  
  [[self pjsuaLock] unlock];
  
  [pool release];
}

- (void)stop {
  // If there was an error while starting, post a notification from here.
  if ([self state] == kAKSIPUserAgentStarting) {
    NSNotification *notification
    = [NSNotification notificationWithName:AKSIPUserAgentDidFinishStartingNotification
                                    object:self];
    
    [[NSNotificationCenter defaultCenter]
     performSelectorOnMainThread:@selector(postNotification:)
                      withObject:notification
                   waitUntilDone:NO];
  }
  
  [self performSelectorInBackground:@selector(ak_stop)
                         withObject:nil];
}

- (void)ak_stop {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  
  pj_status_t status;
  pj_thread_desc aPJThreadDesc;
  
  if (!pj_thread_is_registered()) {
    pj_thread_t *pjThread;
    pj_status_t status = pj_thread_register(NULL, aPJThreadDesc, &pjThread);
    
    if (status != PJ_SUCCESS)
      NSLog(@"Error registering thread at PJSUA");
  }
  
  [[self pjsuaLock] lock];
  
  [self setState:kAKSIPUserAgentStopped];
  
  // Explicitly remove all accounts.
  [[self accounts] removeAllObjects];
  
  // Close ringback port.
  if ([self ringbackPort] != NULL &&
      [self ringbackSlot] != kAKSIPUserAgentInvalidIdentifier)
  {
    pjsua_conf_remove_port([self ringbackSlot]);
    [self setRingbackSlot:kAKSIPUserAgentInvalidIdentifier];
    pjmedia_port_destroy([self ringbackPort]);
    [self setRingbackPort:NULL];
  }
  
  if ([self pjPool] != NULL) {
    pj_pool_release([self pjPool]);
    [self setPjPool:NULL];
  }
  
  // Destroy PJSUA.
  status = pjsua_destroy();
  
  if (status != PJ_SUCCESS)
    NSLog(@"Error stopping SIP user agent");
  
  NSNotification *notification
  = [NSNotification notificationWithName:AKSIPUserAgentDidFinishStoppingNotification
                                  object:self];
  
  [[NSNotificationCenter defaultCenter]
   performSelectorOnMainThread:@selector(postNotification:)
                    withObject:notification
                 waitUntilDone:NO];
  
  [[self pjsuaLock] unlock];
  
  [pool release];
}

- (BOOL)addAccount:(AKSIPAccount *)anAccount
      withPassword:(NSString *)aPassword {
  
  if ([[self delegate] respondsToSelector:@selector(SIPUserAgentShouldAddAccount:)])
    if (![[self delegate] SIPUserAgentShouldAddAccount:anAccount])
      return NO;
  
  pjsua_acc_config accountConfig;
  pjsua_acc_config_default(&accountConfig);
  
  NSString *fullSIPURL = [NSString stringWithFormat:@"%@ <sip:%@>",
                          [anAccount fullName], [anAccount SIPAddress]];
  accountConfig.id = [fullSIPURL pjString];
  
  NSString *registerURI = [NSString stringWithFormat:@"sip:%@",
                           [anAccount registrar]];
  accountConfig.reg_uri = [registerURI pjString];
  
  accountConfig.cred_count = 1;
  accountConfig.cred_info[0].realm = pj_str("*");
  accountConfig.cred_info[0].scheme = pj_str("digest");
  accountConfig.cred_info[0].username = [[anAccount username] pjString];
  accountConfig.cred_info[0].data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
  accountConfig.cred_info[0].data = [aPassword pjString];
  
  if ([[anAccount proxyHost] length] > 0) {
    accountConfig.proxy_cnt = 1;
    
    if ([anAccount proxyPort] == kAKSIPAccountDefaultSIPProxyPort)
      accountConfig.proxy[0] = [[NSString stringWithFormat:@"sip:%@",
                                 [anAccount proxyHost]] pjString];
    else
      accountConfig.proxy[0] = [[NSString stringWithFormat:@"sip:%@:%u",
                                 [anAccount proxyHost], [anAccount proxyPort]]
                                pjString];
  }
  
  accountConfig.reg_timeout = [anAccount reregistrationTime];
  
  if ([self usesICE] && [[self STUNServerHost] length] > 0)
    accountConfig.allow_contact_rewrite = PJ_TRUE;
  else
    accountConfig.allow_contact_rewrite = PJ_FALSE;
  
  pjsua_acc_id accountIdentifier;
  pj_status_t status = pjsua_acc_add(&accountConfig, PJ_FALSE,
                                     &accountIdentifier);
  if (status != PJ_SUCCESS) {
    NSLog(@"Error adding account %@ with status %d", anAccount, status);
    return NO;
  }
  
  [anAccount setIdentifier:accountIdentifier];
  
  [[self accounts] addObject:anAccount];
  
  [anAccount setOnline:YES];
  
  return YES;
}

- (BOOL)removeAccount:(AKSIPAccount *)anAccount {
  if (![self isStarted] ||
      [anAccount identifier] == kAKSIPUserAgentInvalidIdentifier)
    return NO;
  
  [[NSNotificationCenter defaultCenter]
   postNotificationName:AKSIPAccountWillRemoveNotification
                 object:anAccount];
  
  // Explicitly remove all calls.
  [[anAccount calls] removeAllObjects];
  
  pj_status_t status = pjsua_acc_del([anAccount identifier]);
  if (status != PJ_SUCCESS)
    return NO;
  
  [[self accounts] removeObject:anAccount];
  [anAccount setIdentifier:kAKSIPUserAgentInvalidIdentifier];
  
  return YES;
}

- (AKSIPAccount *)accountByIdentifier:(NSInteger)anIdentifier {
  for (AKSIPAccount *anAccount in [[[self accounts] copy] autorelease])
    if ([anAccount identifier] == anIdentifier)
      return [[anAccount retain] autorelease];
  
  return nil;
}

- (AKSIPCall *)SIPCallByIdentifier:(NSInteger)anIdentifier {
  for (AKSIPAccount *anAccount in [[[self accounts] copy] autorelease])
    for (AKSIPCall *aCall in [[[anAccount calls] copy] autorelease])
      if ([aCall identifier] == anIdentifier)
        return [[aCall retain] autorelease];
  
  return nil;
}

- (void)hangUpAllCalls {
  pjsua_call_hangup_all();
}

- (BOOL)setSoundInputDevice:(NSInteger)input
          soundOutputDevice:(NSInteger)output {
  if (![self isStarted])
    return NO;
  
  pj_status_t status = pjsua_set_snd_dev(input, output);
  
  return (status == PJ_SUCCESS) ? YES : NO;
}

- (BOOL)stopSound {
  if (![self isStarted])
    return NO;
  
  pj_status_t status = pjsua_set_null_snd_dev();
  
  return (status == PJ_SUCCESS) ? YES : NO;
}

// This method will leave application silent.
// setSoundInputDevice:soundOutputDevice: must be called explicitly after calling
// this method to set sound IO.
// Usually application controller is responsible of sending
// setSoundInputDevice:soundOutputDevice: to set sound IO after this method is called.
- (void)updateAudioDevices {
  if (![self isStarted])
    return;
  
  // Stop sound device and disconnect it from the conference.
  pjsua_set_null_snd_dev();
  
  // Reinit sound device.
  pjmedia_snd_deinit();
  pjmedia_snd_init(pjsua_get_pool_factory());
}

- (NSString *)stringForSIPResponseCode:(NSInteger)responseCode {
  NSString *theString = nil;
  
  switch (responseCode) {
        // Provisional 1xx.
      case PJSIP_SC_TRYING:
        theString = @"Trying";
        break;
      case PJSIP_SC_RINGING:
        theString = @"Ringing";
        break;
      case PJSIP_SC_CALL_BEING_FORWARDED:
        theString = @"Call Is Being Forwarded";
        break;
      case PJSIP_SC_QUEUED:
        theString = @"Queued";
        break;
      case PJSIP_SC_PROGRESS:
        theString = @"Session Progress";
        break;
        
        // Successful 2xx.
      case PJSIP_SC_OK:
        theString = @"OK";
        break;
      case PJSIP_SC_ACCEPTED:
        theString = @"Accepted";
        break;
        
        // Redirection 3xx.
      case PJSIP_SC_MULTIPLE_CHOICES:
        theString = @"Multiple Choices";
        break;
      case PJSIP_SC_MOVED_PERMANENTLY:
        theString = @"Moved Permanently";
        break;
      case PJSIP_SC_MOVED_TEMPORARILY:
        theString = @"Moved Temporarily";
        break;
      case PJSIP_SC_USE_PROXY:
        theString = @"Use Proxy";
        break;
      case PJSIP_SC_ALTERNATIVE_SERVICE:
        theString = @"Alternative Service";
        break;
        
        // Request Failure 4xx.
      case PJSIP_SC_BAD_REQUEST:
        theString = @"Bad Request";
        break;
      case PJSIP_SC_UNAUTHORIZED:
        theString = @"Unauthorized";
        break;
      case PJSIP_SC_PAYMENT_REQUIRED:
        theString = @"Payment Required";
        break;
      case PJSIP_SC_FORBIDDEN:
        theString = @"Forbidden";
        break;
      case PJSIP_SC_NOT_FOUND:
        theString = @"Not Found";
        break;
      case PJSIP_SC_METHOD_NOT_ALLOWED:
        theString = @"Method Not Allowed";
        break;
      case PJSIP_SC_NOT_ACCEPTABLE:
        theString = @"Not Acceptable";
        break;
      case PJSIP_SC_PROXY_AUTHENTICATION_REQUIRED:
        theString = @"Proxy Authentication Required";
        break;
      case PJSIP_SC_REQUEST_TIMEOUT:
        theString = @"Request Timeout";
        break;
      case PJSIP_SC_GONE:
        theString = @"Gone";
        break;
      case PJSIP_SC_REQUEST_ENTITY_TOO_LARGE:
        theString = @"Request Entity Too Large";
        break;
      case PJSIP_SC_REQUEST_URI_TOO_LONG:
        theString = @"Request-URI Too Long";
        break;
      case PJSIP_SC_UNSUPPORTED_MEDIA_TYPE:
        theString = @"Unsupported Media Type";
        break;
      case PJSIP_SC_UNSUPPORTED_URI_SCHEME:
        theString = @"Unsupported URI Scheme";
        break;
      case PJSIP_SC_BAD_EXTENSION:
        theString = @"Bad Extension";
        break;
      case PJSIP_SC_EXTENSION_REQUIRED:
        theString = @"Extension Required";
        break;
      case PJSIP_SC_SESSION_TIMER_TOO_SMALL:
        theString = @"Session Timer Too Small";
        break;
      case PJSIP_SC_INTERVAL_TOO_BRIEF:
        theString = @"Interval Too Brief";
        break;
      case PJSIP_SC_TEMPORARILY_UNAVAILABLE:
        theString = @"Temporarily Unavailable";
        break;
      case PJSIP_SC_CALL_TSX_DOES_NOT_EXIST:
        theString = @"Call/Transaction Does Not Exist";
        break;
      case PJSIP_SC_LOOP_DETECTED:
        theString = @"Loop Detected";
        break;
      case PJSIP_SC_TOO_MANY_HOPS:
        theString = @"Too Many Hops";
        break;
      case PJSIP_SC_ADDRESS_INCOMPLETE:
        theString = @"Address Incomplete";
        break;
      case PJSIP_AC_AMBIGUOUS:
        theString = @"Ambiguous";
        break;
      case PJSIP_SC_BUSY_HERE:
        theString = @"Busy Here";
        break;
      case PJSIP_SC_REQUEST_TERMINATED:
        theString = @"Request Terminated";
        break;
      case PJSIP_SC_NOT_ACCEPTABLE_HERE:
        theString = @"Not Acceptable Here";
        break;
      case PJSIP_SC_BAD_EVENT:
        theString = @"Bad Event";
        break;
      case PJSIP_SC_REQUEST_UPDATED:
        theString = @"Request Updated";
        break;
      case PJSIP_SC_REQUEST_PENDING:
        theString = @"Request Pending";
        break;
      case PJSIP_SC_UNDECIPHERABLE:
        theString = @"Undecipherable";
        break;
        
        // Server Failure 5xx.
      case PJSIP_SC_INTERNAL_SERVER_ERROR:
        theString = @"Server Internal Error";
        break;
      case PJSIP_SC_NOT_IMPLEMENTED:
        theString = @"Not Implemented";
        break;
      case PJSIP_SC_BAD_GATEWAY:
        theString = @"Bad Gateway";
        break;
      case PJSIP_SC_SERVICE_UNAVAILABLE:
        theString = @"Service Unavailable";
        break;
      case PJSIP_SC_SERVER_TIMEOUT:
        theString = @"Server Time-out";
        break;
      case PJSIP_SC_VERSION_NOT_SUPPORTED:
        theString = @"Version Not Supported";
        break;
      case PJSIP_SC_MESSAGE_TOO_LARGE:
        theString = @"Message Too Large";
        break;
      case PJSIP_SC_PRECONDITION_FAILURE:
        theString = @"Precondition Failure";
        break;
        
        // Global Failures 6xx.
      case PJSIP_SC_BUSY_EVERYWHERE:
        theString = @"Busy Everywhere";
        break;
      case PJSIP_SC_DECLINE:
        theString = @"Decline";
        break;
      case PJSIP_SC_DOES_NOT_EXIST_ANYWHERE:
        theString = @"Does Not Exist Anywhere";
        break;
      case PJSIP_SC_NOT_ACCEPTABLE_ANYWHERE:
        theString = @"Not Acceptable";
        break;
      default:
        theString = [NSString stringWithFormat:@"Response code: %d",
                     responseCode];
        break;
  }
  
  return theString;
}

@end


void AKSIPUserAgentDetectedNAT(const pj_stun_nat_detect_result *result) {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  
  if (result->status != PJ_SUCCESS) {
    pjsua_perror(THIS_FILE, "NAT detection failed", result->status);
    
  } else {
    PJ_LOG(3, (THIS_FILE, "NAT detected as %s", result->nat_type_name));
    
    [[AKSIPUserAgent sharedUserAgent] setDetectedNATType:result->nat_type];
    
    NSNotification *notification
      = [NSNotification notificationWithName:AKSIPUserAgentDidDetectNATNotification
                                      object:[AKSIPUserAgent sharedUserAgent]];
    
    [[NSNotificationCenter defaultCenter]
     performSelectorOnMainThread:@selector(postNotification:)
                      withObject:notification
                   waitUntilDone:NO];
  }
  
  [pool release];
}