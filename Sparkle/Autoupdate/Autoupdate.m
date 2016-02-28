#import <AppKit/AppKit.h>
#import "SUInstaller.h"
#import "SUHost.h"
#import "SUStandardVersionComparator.h"
#import "SUStatusController.h"
#import "SULog.h"
#import "SULocalizations.h"

#include <unistd.h>

/*!
 * Time this app uses to recheck if the host app has already died.
 */
static const NSTimeInterval SUParentQuitCheckInterval = .25;

/*!
 * Timeout to wait until the host app has died.
 */
static const NSTimeInterval SUParentQuitTimeoutInterval = 30.0;

@interface TerminationListener : NSObject

@end

@interface TerminationListener ()

@property (nonatomic, strong) NSNumber *processIdentifier;
@property (nonatomic, strong) NSTimer *watchdogTimer;
@property (nonatomic, strong) NSTimer *timeoutTimer;

@end

@implementation TerminationListener

@synthesize processIdentifier = _processIdentifier;
@synthesize watchdogTimer = _watchdogTimer;
@synthesize timeoutTimer = _timeoutTimer;

- (instancetype)initWithProcessIdentifier:(NSNumber *)processIdentifier
{
    if (!(self = [super init])) {
        return nil;
    }

    self.processIdentifier = processIdentifier;

    return self;
}

- (void)cleanupWithSuccess:(BOOL)success completion:(void (^)(BOOL))completionBlock
{
    [self.watchdogTimer invalidate];
    [self.timeoutTimer invalidate];
    
    completionBlock(success);
}

- (void)startListeningWithCompletion:(void (^)(BOOL))completionBlock
{
    BOOL alreadyTerminated = (self.processIdentifier == nil || (kill(self.processIdentifier.intValue, 0) != 0));
    if (alreadyTerminated) {
        [self cleanupWithSuccess:YES completion:completionBlock];
    } else {
        self.watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:SUParentQuitCheckInterval target:self selector:@selector(watchdog:) userInfo:completionBlock repeats:YES];
        
        self.timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:SUParentQuitTimeoutInterval target:self selector:@selector(timeout:) userInfo:completionBlock repeats:NO];
    }
}

- (void)watchdog:(NSTimer *)timer
{
    if ([NSRunningApplication runningApplicationWithProcessIdentifier:self.processIdentifier.intValue] == nil) {
        [self cleanupWithSuccess:YES completion:timer.userInfo];
    }
}

- (void)timeout:(NSTimer *)timer
{
    if (self.watchdogTimer.valid) {
        [self cleanupWithSuccess:NO completion:timer.userInfo];
    }
}

@end

/*!
 * If the Installation takes longer than this time the Application Icon is shown in the Dock so that the user has some feedback.
 */
static const NSTimeInterval SUInstallationTimeLimit = 5;

/*!
 * Terminate the application after a delay from launching the new update to avoid OS activation issues
 * This delay should be be high enough to increase the likelihood that our updated app will be launched up front,
 * but should be low enough so that the user doesn't ponder why the updater hasn't finished terminating yet
 */
static const NSTimeInterval SUTerminationTimeDelay = 0.5;

@interface AppInstaller : NSObject <NSApplicationDelegate>

@end

@interface AppInstaller ()

@property (nonatomic, strong) TerminationListener *terminationListener;
@property (nonatomic, strong) SUStatusController *statusController;

@property (nonatomic, copy) NSString *updateFolderPath;
@property (nonatomic, copy) NSString *hostPath;
@property (nonatomic, copy) NSString *relaunchPath;
@property (nonatomic, assign) BOOL shouldRelaunch;
@property (nonatomic, assign) BOOL shouldShowUI;

@property (nonatomic, assign) BOOL isTerminating;

@end

@implementation AppInstaller

@synthesize terminationListener = _terminationListener;
@synthesize statusController = _statusController;
@synthesize updateFolderPath = _updateFolderPath;
@synthesize hostPath = _hostPath;
@synthesize relaunchPath = _relaunchPath;
@synthesize shouldRelaunch = _shouldRelaunch;
@synthesize shouldShowUI = _shouldShowUI;
@synthesize isTerminating = _isTerminating;

/*
 * hostPath - path to host (original) application
 * relaunchPath - path to what the host wants to relaunch (default is same as hostPath)
 * hostProcessIdentifier - process identifier of the host before launching us
 * updateFolderPath - path to update folder (i.e, temporary directory containing the new update)
 * shouldRelaunch - indicates if the new installed app should re-launched
 * shouldShowUI - indicates if we should show the status window when installing the update
 */
- (instancetype)initWithHostPath:(NSString *)hostPath relaunchPath:(NSString *)relaunchPath hostProcessIdentifier:(NSNumber *)hostProcessIdentifier updateFolderPath:(NSString *)updateFolderPath shouldRelaunch:(BOOL)shouldRelaunch shouldShowUI:(BOOL)shouldShowUI
{
    if (!(self = [super init])) {
        return nil;
    }
    
    self.hostPath = hostPath;
    self.relaunchPath = relaunchPath;
    self.terminationListener = [[TerminationListener alloc] initWithProcessIdentifier:hostProcessIdentifier];
    self.updateFolderPath = updateFolderPath;
    self.shouldRelaunch = shouldRelaunch;
    self.shouldShowUI = shouldShowUI;
    
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification __unused *)notification
{
    [self.terminationListener startListeningWithCompletion:^(BOOL success){
        self.terminationListener = nil;
        
        if (!success) {
            // We should just give up now - should we show an alert though??
            SULog(@"Timed out waiting for target to terminate. Target path is %@", self.hostPath);
            [self cleanupAndExit];
        } else {
            if (self.shouldShowUI) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SUInstallationTimeLimit * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (!self.isTerminating) {
                        // Show app icon in the dock
                        ProcessSerialNumber psn = { 0, kCurrentProcess };
                        TransformProcessType(&psn, kProcessTransformToForegroundApplication);
                    }
                });
            }
            
            [self install];
        }
    }];
}

- (void)install
{
    NSBundle *theBundle = [NSBundle bundleWithPath:self.hostPath];
    SUHost *host = [[SUHost alloc] initWithBundle:theBundle];
    NSString *installationPath = [[host installationPath] copy];
    
    if (self.shouldShowUI) {
        self.statusController = [[SUStatusController alloc] initWithHost:host];
        [self.statusController setButtonTitle:SULocalizedString(@"Cancel Update", @"") target:nil action:Nil isDefault:NO];
        [self.statusController beginActionWithTitle:SULocalizedString(@"Installing update...", @"")
                                   maxProgressValue: 0 statusText: @""];
        [self.statusController showWindow:self];
        [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
    }
    
    [SUInstaller installFromUpdateFolder:self.updateFolderPath
                                overHost:host
                        installationPath:installationPath
                       versionComparator:[SUStandardVersionComparator defaultComparator]
                       completionHandler:^(NSError *error) {
                           if (error) {
                               SULog(@"Installation Error: %@", error);
                               if (self.shouldShowUI) {
                                   NSAlert *alert = [[NSAlert alloc] init];
                                   alert.messageText = @"";
                                   alert.informativeText = [NSString stringWithFormat:@"%@", [error localizedDescription]];
                                   [alert runModal];
                               }
                               exit(EXIT_FAILURE);
                           } else {
                               NSString *pathToRelaunch = nil;
                               // If the installation path differs from the host path, we give higher precedence for it than
                               // if the desired relaunch path differs from the host path
                               if (![installationPath.pathComponents isEqualToArray:self.hostPath.pathComponents] || [self.relaunchPath.pathComponents isEqualToArray:self.hostPath.pathComponents]) {
                                   pathToRelaunch = installationPath;
                               } else {
                                   pathToRelaunch = self.relaunchPath;
                               }
                               [self cleanupAndTerminateWithPathToRelaunch:pathToRelaunch];
                           }
                       }];
}

- (void)cleanupAndExit __attribute__((noreturn))
{
    NSError *theError = nil;
    if (![[NSFileManager defaultManager] removeItemAtPath:self.updateFolderPath error:&theError]) {
        SULog(@"Couldn't remove update folder: %@.", theError);
    }
    
    [[NSFileManager defaultManager] removeItemAtPath:[[NSBundle mainBundle] bundlePath] error:NULL];
    
    exit(EXIT_SUCCESS);
}

- (void)cleanupAndTerminateWithPathToRelaunch:(NSString *)relaunchPath
{
    self.isTerminating = YES;
    
    if (self.shouldRelaunch) {
        // The auto updater can terminate before the newly updated app is finished launching
        // If that happens, the OS may not make the updated app active and frontmost
        // (Or it does become frontmost, but the OS backgrounds it afterwards.. It's some kind of timing/activation issue that doesn't occur all the time)
        // The only remedy I've been able to find is waiting an arbitrary delay before exiting our application
        
        // Don't use -launchApplication: because we may not be launching an application. Eg: it could be a system prefpane
        if (![[NSWorkspace sharedWorkspace] openFile:relaunchPath]) {
            SULog(@"Failed to launch %@", relaunchPath);
        }
        
        [self.statusController close];
        
        // Don't even think about hiding the app icon from the dock if we've already shown it
        // Transforming the app back to a background one has a backfiring effect, decreasing the likelihood
        // that the updated app will be brought up front
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SUTerminationTimeDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self cleanupAndExit];
        });
    } else {
        [self cleanupAndExit];
    }
}

@end

int main(int __unused argc, const char __unused *argv[])
{
    @autoreleasepool
    {
        NSArray *args = [[NSProcessInfo processInfo] arguments];
        if (args.count != 8) {
            return EXIT_FAILURE;
        }
        
        NSString *hostPath = args[1];
        NSString *relaunchPath = args[2];
        NSString *hostBundlePath = args[3];
        NSString *updateDirectoryPath = args[4];
        BOOL shouldRelaunchApp = [args[5] boolValue];
        BOOL shouldShowUI = [args[6] boolValue];
        BOOL shouldRelaunchTool = [args[7] boolValue];
        
        if (shouldRelaunchTool) {
            NSURL *mainBundleURL = [[NSBundle mainBundle] bundleURL];
            
            if (mainBundleURL == nil) {
                SULog(@"Error: No bundle path located found for main bundle!");
                return EXIT_FAILURE;
            }
            
            NSMutableArray *launchArguments = [args mutableCopy];
            [launchArguments removeObjectAtIndex:0]; // argv[0] is not important
            launchArguments[launchArguments.count - 1] = @"0"; // we don't want to relaunch the tool this time
            
            // We want to launch our tool through LaunchServices, not through a NSTask instance
            // This has a few advantages: one being that we don't inherit the privileges of the parent owner.
            // Another is if we try to spawn a task, it may be prematurely terminated if the parent is like a XPC service,
            // which is what the shouldRelaunchTool flag exists to prevent. Thus, a caller may specify to relaunch the tool again and
            // wait until we exit. When we exit the first time, the caller will be notified, and we can launch a second instance through LS.
            // The caller may not have AppKit available which is why it may not launch through LS itself.
            NSError *launchError = nil;
            NSRunningApplication *newRunningApplication = [[NSWorkspace sharedWorkspace] launchApplicationAtURL:mainBundleURL options:(NSWorkspaceLaunchOptions)(NSWorkspaceLaunchDefault | NSWorkspaceLaunchNewInstance) configuration:@{NSWorkspaceLaunchConfigurationArguments : [launchArguments copy]} error:&launchError];
            
            if (newRunningApplication == nil) {
                SULog(@"Failed to create second instance of tool with error: %@", launchError);
            }
            
            return EXIT_SUCCESS;
        }
        
        NSApplication *application = [NSApplication sharedApplication];
        
        NSNumber *activeProcessIdentifier = nil;
        for (NSRunningApplication *runningApplication in [[NSWorkspace sharedWorkspace] runningApplications]) {
            if ([runningApplication.bundleURL.path isEqual:hostBundlePath]) {
                activeProcessIdentifier = @(runningApplication.processIdentifier);
                break;
            }
        }
        
        AppInstaller *appInstaller = [[AppInstaller alloc] initWithHostPath:hostPath
                                                               relaunchPath:relaunchPath
                                                            hostProcessIdentifier:activeProcessIdentifier
                                                           updateFolderPath:updateDirectoryPath
                                                             shouldRelaunch:shouldRelaunchApp
                                                               shouldShowUI:shouldShowUI];
        [application setDelegate:appInstaller];
        [application run];
    }

    return EXIT_SUCCESS;
}
