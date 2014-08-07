#import "MapsAppDelegate.h"
#import "MapViewController.h"
#import "SettingsManager.h"
#import "Preferences.h"
#import "LocationManager.h"
#import "Statistics.h"
#import "AarkiContact.h"
#import <MobileAppTracker/MobileAppTracker.h>
#import "UIKitCategories.h"
#import "AppInfo.h"
#import "LocalNotificationManager.h"

#include <sys/xattr.h>

#import <FacebookSDK/FacebookSDK.h>

#include "Framework.h"

#include "../../../storage/storage.hpp"

#include "../../../platform/settings.hpp"
#include "../../../platform/platform.hpp"
#include "../../../platform/preferred_languages.hpp"


#define NOTIFICATION_ALERT_VIEW_TAG 665

/// Adds needed localized strings to C++ code
/// @TODO Refactor localization mechanism to make it simpler
void InitLocalizedStrings()
{
  Framework & f = GetFramework();
  // Texts on the map screen when map is not downloaded or is downloading
  f.AddString("country_status_added_to_queue", [NSLocalizedString(@"country_status_added_to_queue", @"Message to display at the center of the screen when the country is added to the downloading queue") UTF8String]);
  f.AddString("country_status_downloading", [NSLocalizedString(@"country_status_downloading", @"Message to display at the center of the screen when the country is downloading") UTF8String]);
  f.AddString("country_status_download", [NSLocalizedString(@"country_status_download", @"Button text for the button at the center of the screen when the country is not downloaded") UTF8String]);
  f.AddString("country_status_download_failed", [NSLocalizedString(@"country_status_download_failed", @"Message to display at the center of the screen when the country download has failed") UTF8String]);
  f.AddString("try_again", [NSLocalizedString(@"try_again", @"Button text for the button under the country_status_download_failed message") UTF8String]);
  // Default texts for bookmarks added in C++ code (by URL Scheme API)
  f.AddString("dropped_pin", [NSLocalizedString(@"dropped_pin", nil) UTF8String]);
  f.AddString("my_places", [NSLocalizedString(@"my_places", nil) UTF8String]);
  f.AddString("my_position", [NSLocalizedString(@"my_position", nil) UTF8String]);
  f.AddString("routes", [NSLocalizedString(@"routes", nil) UTF8String]);
}

@interface MapsAppDelegate()

@property (nonatomic) NSString * lastGuidesUrl;

@end

@implementation MapsAppDelegate
{
  NSString * m_geoURL;
  NSString * m_mwmURL;
  NSString * m_fileURL;

  NSString * m_scheme;
  NSString * m_sourceApplication;
}

+ (MapsAppDelegate *)theApp
{
  return (MapsAppDelegate *)[UIApplication sharedApplication].delegate;
}

+ (BOOL)isFirstAppLaunch
{
  // TODO: check if possible when user reinstall the app
  return [[NSUserDefaults standardUserDefaults] boolForKey:FIRST_LAUNCH_KEY];
}

- (void)initMAT
{
  NSString * advertiserId = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"MobileAppTrackerAdvertiserId"];
  NSString * conversionKey = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"MobileAppTrackerConversionKey"];

  // Account Configuration info - must be set
  [MobileAppTracker initializeWithMATAdvertiserId:advertiserId MATConversionKey:conversionKey];

  // Used to pass us the IFA, enables highly accurate 1-to-1 attribution.
  // Required for many advertising networks.
  NSUUID * ifa = [AppInfo sharedInfo].advertisingId;
  [MobileAppTracker setAppleAdvertisingIdentifier:ifa advertisingTrackingEnabled:(ifa != nil)];

  // Only if you have pre-existing users before MAT SDK implementation, identify these users
  // using this code snippet.
  // Otherwise, pre-existing users will be counted as new installs the first time they run your app.
  if (![MapsAppDelegate isFirstAppLaunch])
    [MobileAppTracker setExistingUser:YES];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
  [[Statistics instance] startSession];
  [AppInfo sharedInfo]; // we call it to init -firstLaunchDate
  if ([AppInfo sharedInfo].advertisingId)
    [[Statistics instance] logEvent:@"Device Info" withParameters:@{@"IFA" : [AppInfo sharedInfo].advertisingId, @"Country" : [AppInfo sharedInfo].countryCode}];

  InitLocalizedStrings();

  [self.m_mapViewController onEnterForeground];

  [Preferences setup:self.m_mapViewController];
  _m_locationManager = [[LocationManager alloc] init];

  m_navController = [[NavigationController alloc] initWithRootViewController:self.m_mapViewController];
  m_navController.navigationBarHidden = YES;
  m_window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  m_window.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  m_window.clearsContextBeforeDrawing = NO;
  m_window.multipleTouchEnabled = YES;
  [m_window setRootViewController:m_navController];
  [m_window makeKeyAndVisible];

  if (GetPlatform().HasBookmarks())
  {
    int val = 0;
    if (Settings::Get("NumberOfBookmarksPerSession", val))
      [[Statistics instance] logEvent:@"Bookmarks Per Session" withParameters:@{@"Number of bookmarks" : [NSNumber numberWithInt:val]}];
    Settings::Set("NumberOfBookmarksPerSession", 0);
  }

  [self subscribeToStorage];

  [self customizeAppearance];

  [self initMAT];

  if ([application respondsToSelector:@selector(setMinimumBackgroundFetchInterval:)])
    [application setMinimumBackgroundFetchInterval:(6 * 60 * 60)];

  LocalNotificationManager * notificationManager = [LocalNotificationManager sharedManager];
#ifdef OMIM_LITE
  [notificationManager schedulePromoNotification];
#endif
  if (launchOptions[UIApplicationLaunchOptionsLocalNotificationKey])
    [notificationManager processNotification:launchOptions[UIApplicationLaunchOptionsLocalNotificationKey]];
  else
    [notificationManager showDownloadMapAlertIfNeeded];

  return [launchOptions objectForKey:UIApplicationLaunchOptionsURLKey] != nil;
}

- (void)application:(UIApplication *)application performFetchWithCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler
{
  LocalNotificationManager * notificationManager = [LocalNotificationManager sharedManager];
#ifdef OMIM_LITE
    [notificationManager schedulePromoNotification];
#endif
  [notificationManager showDownloadMapNotificationIfNeeded:completionHandler];
}

- (void)applicationWillTerminate:(UIApplication *)application
{
	[self.m_mapViewController onTerminate];
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
	[self.m_mapViewController onEnterBackground];
  if (m_activeDownloadsCounter)
  {
    m_backgroundTask = [application beginBackgroundTaskWithExpirationHandler:^{
      [application endBackgroundTask:m_backgroundTask];
      m_backgroundTask = UIBackgroundTaskInvalid;
    }];
  }
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
  [self.m_locationManager orientationChanged];
  [self.m_mapViewController onEnterForeground];
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
  Framework & f = GetFramework();
  if (m_geoURL)
  {
    if (f.ShowMapForURL([m_geoURL UTF8String]))
    {
      if ([m_scheme isEqualToString:@"geo"])
        [[Statistics instance] logEvent:@"geo Import"];
      if ([m_scheme isEqualToString:@"ge0"])
        [[Statistics instance] logEvent:@"ge0(zero) Import"];

      [self showMap];
    }
  }
  else if (m_mwmURL)
  {
    if (f.ShowMapForURL([m_mwmURL UTF8String]));
    {
      [self.m_mapViewController setApiMode:YES animated:NO];
      [[Statistics instance] logApiUsage:m_sourceApplication];
      [self showMap];
    }
  }
  else if (m_fileURL)
  {
    if (!f.AddBookmarksFile([m_fileURL UTF8String]))
      [self showLoadFileAlertIsSuccessful:NO];

    [[NSNotificationCenter defaultCenter] postNotificationName:@"KML file added" object:nil];
    [self showLoadFileAlertIsSuccessful:YES];
    [[Statistics instance] logEvent:@"KML Import"];
  }
  else
  {
    UIPasteboard * pasteboard = [UIPasteboard generalPasteboard];
    if ([pasteboard.string length])
    {
      if (GetFramework().ShowMapForURL([pasteboard.string UTF8String]))
      {
        [self showMap];
        pasteboard.string = @"";
      }
    }
  }
  m_geoURL = nil;
  m_mwmURL = nil;
  m_fileURL = nil;

  [FBSettings setDefaultAppID:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"FacebookAppID"]];
  [FBAppEvents activateApp];

  if ([MapsAppDelegate isFirstAppLaunch])
  {
    NSString * appId = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"AarkiClientSecurityKey"];
    [AarkiContact registerApp:appId];
  }

  // MAT will not function without the measureSession call included
  [MobileAppTracker measureSession];
}

- (SettingsManager *)settingsManager
{
  if (!m_settingsManager)
    m_settingsManager = [[SettingsManager alloc] init];
  return m_settingsManager;
}

- (void)dealloc
{
  // Global cleanup
  DeleteFramework();
}

- (void)disableStandby
{
  ++m_standbyCounter;
  [UIApplication sharedApplication].idleTimerDisabled = YES;
}

- (void)enableStandby
{
  --m_standbyCounter;
  if (m_standbyCounter <= 0)
  {
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    m_standbyCounter = 0;
  }
}

- (void)disableDownloadIndicator
{
  --m_activeDownloadsCounter;
  if (m_activeDownloadsCounter <= 0)
  {
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
    m_activeDownloadsCounter = 0;
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground)
    {
      [[UIApplication sharedApplication] endBackgroundTask:m_backgroundTask];
      m_backgroundTask = UIBackgroundTaskInvalid;
    }
  }
}

- (void)enableDownloadIndicator
{
  ++m_activeDownloadsCounter;
  [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
}

- (void)customizeAppearance
{
  NSMutableDictionary * attributes = [[NSMutableDictionary alloc] init];
  attributes[UITextAttributeTextColor] = [UIColor whiteColor];
  attributes[UITextAttributeTextShadowColor] = [UIColor clearColor];
  [[UINavigationBar appearanceWhenContainedIn:[NavigationController class], nil] setTintColor:[UIColor colorWithColorCode:@"15c584"]];

  if (!SYSTEM_VERSION_IS_LESS_THAN(@"7"))
  {
    [[UIBarButtonItem appearance] setTitleTextAttributes:attributes forState:UIControlStateNormal];

    [[UINavigationBar appearanceWhenContainedIn:[NavigationController class], nil] setBackgroundImage:[UIImage imageNamed:@"NavigationBarBackground7"] forBarMetrics:UIBarMetricsDefault];

    attributes[UITextAttributeFont] = [UIFont fontWithName:@"HelveticaNeue" size:17.5];
  }

  if ([UINavigationBar instancesRespondToSelector:@selector(setShadowImage:)])
    [[UINavigationBar appearanceWhenContainedIn:[NavigationController class], nil] setShadowImage:[[UIImage alloc] init]];

  [[UINavigationBar appearanceWhenContainedIn:[NavigationController class], nil] setTitleTextAttributes:attributes];
}

- (void)application:(UIApplication *)application didReceiveLocalNotification:(UILocalNotification *)notification
{
  NSDictionary * dict = notification.userInfo;
  if ([[dict objectForKey:@"Proposal"] isEqual:@"OpenGuides"])
  {
    self.lastGuidesUrl = [dict objectForKey:@"GuideUrl"];
    UIAlertView * view = [[UIAlertView alloc] initWithTitle:[dict objectForKey:@"GuideTitle"] message:[dict objectForKey:@"GuideMessage"] delegate:self cancelButtonTitle:NSLocalizedString(@"later", nil) otherButtonTitles:NSLocalizedString(@"get_it_now", nil), nil];
    view.tag = NOTIFICATION_ALERT_VIEW_TAG;
    [view show];
  }
  else
  {
    [[LocalNotificationManager sharedManager] processNotification:notification];
  }
}

// We don't support HandleOpenUrl as it's deprecated from iOS 4.2
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation
{
  // AlexZ: do we really need this? Need to ask them with a letter
  [MobileAppTracker applicationDidOpenURL:[url absoluteString] sourceApplication:sourceApplication];

  NSString * scheme = url.scheme;

  m_scheme = scheme;
  m_sourceApplication = sourceApplication;

  // geo scheme support, see http://tools.ietf.org/html/rfc5870
  if ([scheme isEqualToString:@"geo"] || [scheme isEqualToString:@"ge0"])
  {
    m_geoURL = [url absoluteString];
    return YES;
  }
  else if ([scheme isEqualToString:@"mapswithme"] || [scheme isEqualToString:@"mwm"])
  {
    m_mwmURL = [url absoluteString];
    return YES;
  }
  else if ([scheme isEqualToString:@"file"])
  {
    m_fileURL = [url relativePath];
    return YES;
  }
  NSLog(@"Scheme %@ is not supported", scheme);

  return NO;
}

- (void)showLoadFileAlertIsSuccessful:(BOOL)successful
{
  m_loadingAlertView = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"load_kmz_title", nil)
                                                  message:
                        (successful ? NSLocalizedString(@"load_kmz_successful", nil) : NSLocalizedString(@"load_kmz_failed", nil))
                                                 delegate:nil
                                        cancelButtonTitle:NSLocalizedString(@"ok", nil) otherButtonTitles:nil];
  m_loadingAlertView.delegate = self;
  [m_loadingAlertView show];
  [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(dismissAlert) userInfo:nil repeats:NO];
}

- (void)dismissAlert
{
  if (m_loadingAlertView)
    [m_loadingAlertView dismissWithClickedButtonIndex:0 animated:YES];
}

- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex
{
  if (alertView.tag == NOTIFICATION_ALERT_VIEW_TAG)
  {
    if (buttonIndex != alertView.cancelButtonIndex)
    {
      [[Statistics instance] logEvent:@"Download Guides Proposal" withParameters:@{@"Answer" : @"YES"}];
      NSURL * url = [NSURL URLWithString:self.lastGuidesUrl];
      [[UIApplication sharedApplication] openURL:url];
    }
    else
      [[Statistics instance] logEvent:@"Download Guides Proposal" withParameters:@{@"Answer" : @"NO"}];
  }
  else
    m_loadingAlertView = nil;
}

- (void)showMap
{
  [m_navController popToRootViewControllerAnimated:YES];
  [self.m_mapViewController dismissPopover];
}

- (void)subscribeToStorage
{
  typedef void (*TChangeFunc)(id, SEL, storage::TIndex const &);
  SEL changeSel = @selector(OnCountryChange:);
  TChangeFunc changeImpl = (TChangeFunc)[self methodForSelector:changeSel];

  typedef void (*TProgressFunc)(id, SEL, storage::TIndex const &, pair<int64_t, int64_t> const &);
  SEL emptySel = @selector(EmptyFunction:withProgress:);
  TProgressFunc progressImpl = (TProgressFunc)[self methodForSelector:emptySel];

  GetFramework().Storage().Subscribe(bind(changeImpl, self, changeSel, _1),
                                     bind(progressImpl, self, emptySel, _1, _2));
}

- (void)OnCountryChange:(storage::TIndex const &)index
{
  Framework const & f = GetFramework();
  guides::GuideInfo guide;
  if (f.GetCountryStatus(index) == storage::EOnDisk && f.GetGuideInfo(index, guide))
    [self ShowNotificationWithGuideInfo:guide];
}

- (void)EmptyFunction:(storage::TIndex const &)index withProgress:(pair<int64_t, int64_t> const &)progress {}

- (BOOL)ShowNotificationWithGuideInfo:(guides::GuideInfo const &)guide
{
  guides::GuidesManager & guidesManager = GetFramework().GetGuidesManager();
  string const appID = guide.GetAppID();

  if (guidesManager.WasAdvertised(appID) ||
      [[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:[NSString stringWithUTF8String:appID.c_str()]]])
    return NO;

  UILocalNotification * notification = [[UILocalNotification alloc] init];
  notification.fireDate = [NSDate dateWithTimeIntervalSinceNow:0];
  notification.repeatInterval = 0;
  notification.timeZone = [NSTimeZone defaultTimeZone];
  notification.soundName = UILocalNotificationDefaultSoundName;

  string const lang = languages::CurrentLanguage();
  NSString * message = [NSString stringWithUTF8String:guide.GetAdMessage(lang).c_str()];
  notification.alertBody = message;
  notification.userInfo = @{
                            @"Proposal" : @"OpenGuides",
                            @"GuideUrl" : [NSString stringWithUTF8String:guide.GetURL().c_str()],
                            @"GuideTitle" : [NSString stringWithUTF8String:guide.GetAdTitle(lang).c_str()],
                            @"GuideMessage" : message
                            };

  [[UIApplication sharedApplication] scheduleLocalNotification:notification];

  guidesManager.SetWasAdvertised(appID);

  return YES;
}

@end
