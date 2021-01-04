//
//  SPUStandardUserDriver.m
//  Sparkle
//
//  Created by Mayur Pawashe on 2/14/16.
//  Copyright © 2016 Sparkle Project. All rights reserved.
//

#import "SPUStandardUserDriver.h"
#import "SPUUserDriverCoreComponent.h"
#import "SPUStandardUserDriverDelegate.h"
#import "SUAppcastItem.h"
#import "SUVersionDisplayProtocol.h"
#import "SUHost.h"
#import "SUUpdatePermissionPrompt.h"
#import "SUStatusController.h"
#import "SUUpdateAlert.h"
#import "SULocalizations.h"
#import "SUApplicationInfo.h"
#import "SUOperatingSystem.h"

@interface SPUStandardUserDriver ()

@property (nonatomic, readonly) SUHost *host;

@property (nonatomic, readonly) SPUUserDriverCoreComponent *coreComponent;
@property (nonatomic, weak, nullable, readonly) id <SPUStandardUserDriverDelegate> delegate;

@property (nonatomic) SUStatusController *checkingController;
@property (nonatomic) SUUpdateAlert *activeUpdateAlert;
@property (nonatomic) SUStatusController *statusController;

@end

@implementation SPUStandardUserDriver

@synthesize host = _host;
@synthesize coreComponent = _coreComponent;
@synthesize delegate = _delegate;
@synthesize checkingController = _checkingController;
@synthesize activeUpdateAlert = _activeUpdateAlert;
@synthesize hideOnDeactivate = _hideOnDeactivate;
@synthesize statusController = _statusController;

#pragma mark Birth

- (instancetype)initWithHostBundle:(NSBundle *)hostBundle delegate:(nullable id<SPUStandardUserDriverDelegate>)delegate
{
    self = [super init];
    if (self != nil) {
        _host = [[SUHost alloc] initWithBundle:hostBundle];
        _delegate = delegate;
        _coreComponent = [[SPUUserDriverCoreComponent alloc] init];
        _hideOnDeactivate = YES;
    }
    return self;
}

#pragma mark Is Update Busy?

- (void)showCanCheckForUpdates:(BOOL)canCheckForUpdates
{
    assert(NSThread.isMainThread);
    
    [self.coreComponent showCanCheckForUpdates:canCheckForUpdates];
}

- (BOOL)canCheckForUpdates
{
    assert(NSThread.isMainThread);
    
    return self.coreComponent.canCheckForUpdates;
}

#pragma mark Update Permission

- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply
{
    assert(NSThread.isMainThread);
    
    // This shows a modal alert dialog which unlike other alerts cannot be closed until the user makes a decision
    // This means that we can never programatically close the dialog if something goes horribly wrong
    // But this dialog should only show up once in the application's lifetime so this may be an OK decision
    
    [SUUpdatePermissionPrompt promptWithHost:self.host request:request reply:reply];
}

#pragma mark Update Alert Focus

- (void)setUpFocusForActiveUpdateAlert
{
    // Make sure the window is loaded in any case
    [self.activeUpdateAlert window];
    
    if (!self.hideOnDeactivate) {
        [self.activeUpdateAlert.window setHidesOnDeactivate:NO];
    }
    
    // If the app is a menubar app or the like, we need to focus it first and alter the
    // update prompt to behave like a normal window. Otherwise if the window were hidden
    // there may be no way for the application to be activated to make it visible again.
    if ([SUApplicationInfo isBackgroundApplication:[NSApplication sharedApplication]]) {
        [self.activeUpdateAlert.window setHidesOnDeactivate:NO];
        [NSApp activateIgnoringOtherApps:YES];
    }
    
    // Only show the update alert if the app is active; otherwise, we'll wait until it is.
    if ([NSApp isActive])
        [self.activeUpdateAlert.window makeKeyAndOrderFront:self];
    else
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) name:NSApplicationDidBecomeActiveNotification object:NSApp];
}

- (void)applicationDidBecomeActive:(NSNotification *)__unused aNotification
{
    [self.activeUpdateAlert.window makeKeyAndOrderFront:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSApplicationDidBecomeActiveNotification object:NSApp];
}

#pragma mark Update Found

- (void)showUpdateFoundWithAlertHandler:(SUUpdateAlert *(^)(SPUStandardUserDriver *, SUHost *, id<SUVersionDisplay>))alertHandler
{
    id <SUVersionDisplay> versionDisplayer = nil;
    if ([self.delegate respondsToSelector:@selector(standardUserDriverRequestsVersionDisplayer)]) {
        versionDisplayer = [self.delegate standardUserDriverRequestsVersionDisplayer];
    }
    
    __weak SPUStandardUserDriver *weakSelf = self;
    SUHost *host = self.host;
    self.activeUpdateAlert = alertHandler(weakSelf, host, versionDisplayer);
    
    [self setUpFocusForActiveUpdateAlert];
}

- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)appcastItem userInitiated:(BOOL)__unused userInitiated reply:(void (^)(SPUUpdateAlertChoice))reply
{
    assert(NSThread.isMainThread);
    
    [self showUpdateFoundWithAlertHandler:^SUUpdateAlert *(SPUStandardUserDriver *weakSelf, SUHost *host, id<SUVersionDisplay> versionDisplayer) {
        return [[SUUpdateAlert alloc] initWithAppcastItem:appcastItem alreadyDownloaded:NO host:host versionDisplayer:versionDisplayer completionBlock:^(SPUUpdateAlertChoice choice) {
            reply(choice);
            weakSelf.activeUpdateAlert = nil;
        }];
    }];
}

- (void)showDownloadedUpdateFoundWithAppcastItem:(SUAppcastItem *)appcastItem userInitiated:(BOOL)__unused userInitiated reply:(void (^)(SPUUpdateAlertChoice))reply
{
    assert(NSThread.isMainThread);
    
    [self showUpdateFoundWithAlertHandler:^SUUpdateAlert *(SPUStandardUserDriver *weakSelf, SUHost *host, id<SUVersionDisplay> versionDisplayer) {
        return [[SUUpdateAlert alloc] initWithAppcastItem:appcastItem alreadyDownloaded:YES host:host versionDisplayer:versionDisplayer completionBlock:^(SPUUpdateAlertChoice choice) {
            reply(choice);
            weakSelf.activeUpdateAlert = nil;
        }];
    }];
}

- (void)showResumableUpdateFoundWithAppcastItem:(SUAppcastItem *)appcastItem userInitiated:(BOOL)__unused userInitiated reply:(void (^)(SPUInstallUpdateStatus))reply
{
    assert(NSThread.isMainThread);
    
    [self showUpdateFoundWithAlertHandler:^SUUpdateAlert *(SPUStandardUserDriver *weakSelf, SUHost *host, id<SUVersionDisplay> versionDisplayer) {
        return [[SUUpdateAlert alloc] initWithAppcastItem:appcastItem host:host versionDisplayer:versionDisplayer resumableCompletionBlock:^(SPUInstallUpdateStatus choice) {
            reply(choice);
            weakSelf.activeUpdateAlert = nil;
        }];
    }];
}

- (void)showInformationalUpdateFoundWithAppcastItem:(SUAppcastItem *)appcastItem userInitiated:(BOOL)__unused userInitiated reply:(void (^)(SPUInformationalUpdateAlertChoice))reply
{
    assert(NSThread.isMainThread);
    
    [self showUpdateFoundWithAlertHandler:^SUUpdateAlert *(SPUStandardUserDriver *weakSelf, SUHost *host, id<SUVersionDisplay> versionDisplayer) {
        return [[SUUpdateAlert alloc] initWithAppcastItem:appcastItem host:host versionDisplayer:versionDisplayer informationalCompletionBlock:^(SPUInformationalUpdateAlertChoice choice) {
            reply(choice);
            weakSelf.activeUpdateAlert = nil;
        }];
    }];
}

- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)downloadData
{
    assert(NSThread.isMainThread);
    
    [self.activeUpdateAlert showUpdateReleaseNotesWithDownloadData:downloadData];
}

- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error
{
    assert(NSThread.isMainThread);
    
    // I don't want to expose SULog here because it's more of a user driver facing error
    // For our purposes we just ignore it and continue on..
    NSLog(@"Failed to download release notes with error: %@", error);
    [self.activeUpdateAlert showReleaseNotesFailedToDownload];
}

#pragma mark Install & Relaunch Update

- (void)showReadyToInstallAndRelaunch:(void (^)(SPUInstallUpdateStatus))installUpdateHandler
{
    assert(NSThread.isMainThread);
    
    [self.statusController beginActionWithTitle:SULocalizedString(@"Ready to Install", nil) maxProgressValue:1.0 statusText:nil];
    [self.statusController setProgressValue:1.0]; // Fill the bar.
    [self.statusController setButtonEnabled:YES];
    [self.statusController setButtonTitle:SULocalizedString(@"Install and Relaunch", nil) target:self action:@selector(installAndRestart:) isDefault:YES];
    [[self.statusController window] makeKeyAndOrderFront:self];
    [NSApp requestUserAttention:NSInformationalRequest];
    
    [self.coreComponent registerInstallUpdateHandler:installUpdateHandler];
}

- (void)installAndRestart:(id)__unused sender
{
    [self.coreComponent installUpdateWithChoice:SPUInstallAndRelaunchUpdateNow];
}

#pragma mark Check for Updates

- (void)showUserInitiatedUpdateCheckWithCompletion:(void (^)(SPUUserInitiatedCheckStatus))updateCheckStatusCompletion
{
    assert(NSThread.isMainThread);
    
    [self.coreComponent registerUpdateCheckStatusHandler:updateCheckStatusCompletion];
    
    self.checkingController = [[SUStatusController alloc] initWithHost:self.host];
    [[self.checkingController window] center]; // Force the checking controller to load its window.
    [self.checkingController beginActionWithTitle:SULocalizedString(@"Checking for updates...", nil) maxProgressValue:0.0 statusText:nil];
    [self.checkingController setButtonTitle:SULocalizedString(@"Cancel", nil) target:self action:@selector(cancelCheckForUpdates:) isDefault:NO];
    [self.checkingController showWindow:self];
    
    // For background applications, obtain focus.
    // Useful if the update check is requested from another app like System Preferences.
    if ([SUApplicationInfo isBackgroundApplication:[NSApplication sharedApplication]])
    {
        [NSApp activateIgnoringOtherApps:YES];
    }
}

- (void)closeCheckingWindow
{
    if (self.checkingController != nil)
    {
        [[self.checkingController window] close];
        self.checkingController = nil;
    }
}

- (void)cancelCheckForUpdates:(id)__unused sender
{
    [self.coreComponent cancelUpdateCheckStatus];
    [self closeCheckingWindow];
}

- (void)dismissUserInitiatedUpdateCheck
{
    assert(NSThread.isMainThread);
    
    [self.coreComponent completeUpdateCheckStatus];
    [self closeCheckingWindow];
}

#pragma mark Update Errors

- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement
{
    assert(NSThread.isMainThread);
    
    [self.coreComponent registerAcknowledgement:acknowledgement];
    
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = SULocalizedString(@"Update Error!", nil);
    alert.informativeText = [NSString stringWithFormat:@"%@", [error localizedDescription]];
    [alert addButtonWithTitle:SULocalizedString(@"Cancel Update", nil)];
    [self showAlert:alert];
    
    [self.coreComponent acceptAcknowledgement];
}

- (void)showUpdateNotFoundWithAcknowledgement:(void (^)(void))acknowledgement
{
    assert(NSThread.isMainThread);
    
    [self.coreComponent registerAcknowledgement:acknowledgement];
    
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = SULocalizedString(@"You're up-to-date!", "Status message shown when the user checks for updates but is already current or the feed doesn't contain any updates.");
    alert.informativeText = [NSString stringWithFormat:SULocalizedString(@"%@ %@ is currently the newest version available.", nil), [self.host name], [self.host displayVersion]];
    [alert addButtonWithTitle:SULocalizedString(@"OK", nil)];
    [self showAlert:alert];
    
    [self.coreComponent acceptAcknowledgement];
}

- (void)showAlert:(NSAlert *)alert
{
    id <SPUStandardUserDriverDelegate> delegate = self.delegate;
    
    if ([delegate respondsToSelector:@selector(standardUserDriverWillShowModalAlert)]) {
        [delegate standardUserDriverWillShowModalAlert];
    }
    
    // When showing a modal alert we need to ensure that background applications
    // are focused to inform the user since there is no dock icon to notify them.
    if ([SUApplicationInfo isBackgroundApplication:[NSApplication sharedApplication]]) { [[NSApplication sharedApplication] activateIgnoringOtherApps:YES]; }
    
    [alert setIcon:[SUApplicationInfo bestIconForHost:self.host]];
    [alert runModal];
    
    if ([delegate respondsToSelector:@selector(standardUserDriverDidShowModalAlert)]) {
        [delegate standardUserDriverDidShowModalAlert];
    }
}

#pragma mark Download & Install Updates

- (void)showStatusController
{
    if (self.statusController == nil) {
        self.statusController = [[SUStatusController alloc] initWithHost:self.host];
        [self.statusController showWindow:self];
    }
}

- (void)showDownloadInitiatedWithCompletion:(void (^)(SPUDownloadUpdateStatus))downloadUpdateStatusCompletion
{
    assert(NSThread.isMainThread);
    
    [self.coreComponent registerDownloadStatusHandler:downloadUpdateStatusCompletion];
    
    [self showStatusController];
    [self.statusController beginActionWithTitle:SULocalizedString(@"Downloading update...", @"Take care not to overflow the status window.") maxProgressValue:0.0 statusText:nil];
    [self.statusController setButtonTitle:SULocalizedString(@"Cancel", nil) target:self action:@selector(cancelDownload:) isDefault:NO];
}

- (void)cancelDownload:(id)__unused sender
{
    [self.coreComponent cancelDownloadStatus];
}

- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)expectedContentLength
{
    assert(NSThread.isMainThread);
    
    [self.statusController setMaxProgressValue:expectedContentLength];
}

- (NSString *)localizedStringFromByteCount:(long long)value
{
    if (![SUOperatingSystem isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){10, 8, 0}]) {
        if (value < 1000) {
            return [NSString stringWithFormat:@"%.0lf %@", value / 1.0,
                    SULocalizedString(@"B", @"the unit for bytes")];
        }
        
        if (value < 1000 * 1000) {
            return [NSString stringWithFormat:@"%.0lf %@", value / 1000.0,
                    SULocalizedString(@"KB", @"the unit for kilobytes")];
        }
        
        if (value < 1000 * 1000 * 1000) {
            return [NSString stringWithFormat:@"%.1lf %@", value / 1000.0 / 1000.0,
                    SULocalizedString(@"MB", @"the unit for megabytes")];
        }
        
        return [NSString stringWithFormat:@"%.2lf %@", value / 1000.0 / 1000.0 / 1000.0,
                SULocalizedString(@"GB", @"the unit for gigabytes")];
    }
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpartial-availability"
    NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
    [formatter setZeroPadsFractionDigits:YES];
    return [formatter stringFromByteCount:value];
#pragma clang diagnostic pop
}

- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length
{
    assert(NSThread.isMainThread);
    
    double newProgressValue = [self.statusController progressValue] + (double)length;
    
    // In case our expected content length was incorrect
    if (newProgressValue > [self.statusController maxProgressValue]) {
        [self.statusController setMaxProgressValue:newProgressValue];
    }
    
    [self.statusController setProgressValue:newProgressValue];
    if ([self.statusController maxProgressValue] > 0.0)
        [self.statusController setStatusText:[NSString stringWithFormat:SULocalizedString(@"%@ of %@", nil), [self localizedStringFromByteCount:(long long)self.statusController.progressValue], [self localizedStringFromByteCount:(long long)self.statusController.maxProgressValue]]];
    else
        [self.statusController setStatusText:[NSString stringWithFormat:SULocalizedString(@"%@ downloaded", nil), [self localizedStringFromByteCount:(long long)self.statusController.progressValue]]];
}

- (void)showDownloadDidStartExtractingUpdate
{
    assert(NSThread.isMainThread);
    
    [self.coreComponent completeDownloadStatus];
    
    [self showStatusController];
    [self.statusController beginActionWithTitle:SULocalizedString(@"Extracting update...", @"Take care not to overflow the status window.") maxProgressValue:0.0 statusText:nil];
    [self.statusController setButtonTitle:SULocalizedString(@"Cancel", nil) target:nil action:nil isDefault:NO];
    [self.statusController setButtonEnabled:NO];
}

- (void)showExtractionReceivedProgress:(double)progress
{
    assert(NSThread.isMainThread);
    
    if ([self.statusController maxProgressValue] == 0.0) {
        [self.statusController setMaxProgressValue:1];
    }
    [self.statusController setProgressValue:progress];
}

- (void)showInstallingUpdate
{
    assert(NSThread.isMainThread);
    
    [self.statusController beginActionWithTitle:SULocalizedString(@"Installing update...", @"Take care not to overflow the status window.") maxProgressValue:0.0 statusText:nil];
    [self.statusController setButtonEnabled:NO];
}

- (void)showUpdateInstallationDidFinishWithAcknowledgement:(void (^)(void))acknowledgement
{
    assert(NSThread.isMainThread);
    
    // Deciding not to show anything here
    [self.coreComponent registerAcknowledgement:acknowledgement];
    [self.coreComponent acceptAcknowledgement];
}

#pragma mark Aborting Everything

- (void)showSendingTerminationSignal
{
    assert(NSThread.isMainThread);
    
    // The "quit" event can always be canceled or delayed by the application we're updating
    // So we can't easily predict how long the installation will take or if it won't happen right away
    // We close our status window because we don't want it persisting for too long and have it obscure other windows
    [self.statusController close];
    self.statusController = nil;
}

- (void)dismissUpdateInstallation
{
    assert(NSThread.isMainThread);
    
    [self.coreComponent dismissUpdateInstallation];
    
    [self closeCheckingWindow];
    
    if (self.statusController) {
        [self.statusController close];
        self.statusController = nil;
    }
    
    if (self.activeUpdateAlert) {
        [self.activeUpdateAlert close];
        self.activeUpdateAlert = nil;
    }
}

@end
