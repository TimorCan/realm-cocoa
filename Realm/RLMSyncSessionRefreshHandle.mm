////////////////////////////////////////////////////////////////////////////
//
// Copyright 2016 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMSyncSessionRefreshHandle.hpp"

#import "RLMJSONModels.h"
#import "RLMNetworkTransport.h"
#import "RLMSyncManager_Private.h"
#import "RLMSyncUser_Private.hpp"
#import "RLMSyncUtil_Private.hpp"
#import "RLMUtil.hpp"

#import "sync/sync_session.hpp"

using namespace realm;

namespace {

void unregisterRefreshHandle(const std::weak_ptr<SyncUser>& user, const std::string& path) {
    if (auto strong_user = user.lock()) {
        context_for(strong_user).unregister_refresh_handle(path);
    }
}

void reportInvalidAccessToken(const std::weak_ptr<SyncUser>& user, NSError *error) {
    if (auto strong_user = user.lock()) {
        if (RLMUserErrorReportingBlock block = context_for(strong_user).error_handler()) {
            RLMSyncUser *theUser = [[RLMSyncUser alloc] initWithSyncUser:std::move(strong_user)];
            // FIXME: [realmapp] logout the user
            // [theUser logOut];
            block(theUser, error);
        }
    }
}

}

static const NSTimeInterval RLMRefreshBuffer = 10;

@interface RLMSyncSessionRefreshHandle () {
    std::weak_ptr<SyncUser> _user;
    std::string _path;
    std::weak_ptr<SyncSession> _session;
    std::shared_ptr<SyncSession> _strongSession;
}

@property (nonatomic) dispatch_source_t timer;

@property (nonatomic) NSURL *realmURL;
@property (nonatomic, copy) RLMSyncBasicErrorReportingBlock completionBlock;

@end

@implementation RLMSyncSessionRefreshHandle

- (instancetype)initWithRealmURL:(NSURL *)realmURL
                            user:(std::shared_ptr<realm::SyncUser>)user
                         session:(std::shared_ptr<realm::SyncSession>)session
                 completionBlock:(RLMSyncBasicErrorReportingBlock)completionBlock {
    if (self = [super init]) {
        NSString *path = [realmURL path];
        _path = [path UTF8String];
        self.completionBlock = completionBlock;
        self.realmURL = realmURL;
        // For the initial bind, we want to prolong the session's lifetime.
        _strongSession = std::move(session);
        _session = _strongSession;
        _user = user;
        // Immediately fire off the network request.
        [self _timerFired];
        return self;
    }
    return nil;
}

- (void)dealloc {
    [self cancelTimer];
}

- (void)invalidate {
    _strongSession = nullptr;
    [self cancelTimer];
}

- (void)cancelTimer {
    if (self.timer) {
        dispatch_source_cancel(self.timer);
        self.timer = nil;
    }
}

+ (NSDate *)fireDateForTokenExpirationDate:(NSDate *)date nowDate:(NSDate *)nowDate {
    NSDate *fireDate = [date dateByAddingTimeInterval:-RLMRefreshBuffer];
    // Only fire times in the future are valid.
    return ([fireDate compare:nowDate] == NSOrderedDescending ? fireDate : nil);
}

- (void)scheduleRefreshTimer:(NSDate *)dateWhenTokenExpires {
    [self cancelTimer];

    NSDate *fireDate = [RLMSyncSessionRefreshHandle fireDateForTokenExpirationDate:dateWhenTokenExpires
                                                                           nowDate:[NSDate date]];
    if (!fireDate) {
        unregisterRefreshHandle(_user, _path);
        return;
    }

    NSTimeInterval timeToExpiration = [fireDate timeIntervalSinceNow];
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, timeToExpiration * NSEC_PER_SEC),
                              /* interval */ DISPATCH_TIME_FOREVER,
                              /* leeway */ NSEC_PER_SEC * (timeToExpiration / 10));
    dispatch_source_set_event_handler(self.timer, ^{ [self _timerFired]; });
    dispatch_resume(self.timer);
}

/// Handler for network requests whose responses successfully parse into an auth response model.
- (BOOL)_handleSuccessfulRequest:(RLMAuthResponseModel *)model session:(SyncSession&)session {
    // Realm Cloud will give us a url prefix in the auth response that we need
    // to pass onto objectstore to have it connect to the proper sync worker
    if (model.urlPrefix) {
        session.set_url_prefix(model.urlPrefix.UTF8String);
    }

    // Calculate the resolved path.
    NSString *resolvedURLString = nil;
    RLMServerPath resolvedPath = model.accessToken.tokenData.path;
    // Munge the path back onto the original URL, because the `sync` API expects an entire URL.
    NSURLComponents *urlBuffer = [NSURLComponents componentsWithURL:self.realmURL
                                            resolvingAgainstBaseURL:YES];
    urlBuffer.path = resolvedPath;
    resolvedURLString = [[urlBuffer URL] absoluteString];
    if (!resolvedURLString) {
        @throw RLMException(@"Resolved path returned from the server was invalid (%@).", resolvedPath);
    }
    // Pass the token and resolved path to the underlying sync subsystem.
    session.refresh_access_token([model.accessToken.token UTF8String], {resolvedURLString.UTF8String});

    // Schedule a refresh. If we're successful we must already have `bind()`ed the session
    // initially, so we can null out the strong pointer.
    _strongSession = nullptr;
    NSDate *expires = [NSDate dateWithTimeIntervalSince1970:model.accessToken.tokenData.expires];
    [self scheduleRefreshTimer:expires];

    if (self.completionBlock) {
        self.completionBlock(nil);
    }
    return true;
}

/// Handler for network requests that failed before the JSON parsing stage.
- (void)_handleFailedRequest:(NSError *)error {
    NSError *authError;
    if ([error.domain isEqualToString:RLMSyncAuthErrorDomain]) {
        // Network client may return sync related error
        authError = error;
        // Try to report this error to the expiration callback.
        reportInvalidAccessToken(_user, authError);
    } else {
        // Something else went wrong
        authError = make_auth_error_bad_response();
    }
    if (self.completionBlock) {
        self.completionBlock(authError);
    }
    [[RLMSyncManager sharedManager] _fireError:make_sync_error(authError)];
    // Certain errors related to network connectivity should trigger a retry.
    NSDate *nextTryDate = nil;
    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        switch (error.code) {
            case NSURLErrorCannotConnectToHost:
            case NSURLErrorNotConnectedToInternet:
            case NSURLErrorNetworkConnectionLost:
            case NSURLErrorTimedOut:
            case NSURLErrorDNSLookupFailed:
            case NSURLErrorCannotFindHost:
                // FIXME: 10 seconds is an arbitrarily chosen value, consider rationalizing it.
                nextTryDate = [NSDate dateWithTimeIntervalSinceNow:RLMRefreshBuffer + 10];
                break;
            default:
                break;
        }
    }
    if (!nextTryDate) {
        // This error isn't a network failure error. Just invalidate the refresh handle and stop.
        if (_strongSession) {
            _strongSession->log_out();
        }
        unregisterRefreshHandle(_user, _path);
        [self invalidate];
        return;
    }
    // If we tried to initially bind the session and failed, we'll try again. However, each
    // subsequent attempt will use a weak pointer to avoid prolonging the session's lifetime
    // unnecessarily.
    _strongSession = nullptr;
    [self scheduleRefreshTimer:nextTryDate];
    return;
}

/// Callback handler for network requests.
- (BOOL)_onRefreshCompletionWithError:(NSError *)error json:(NSDictionary *)json {
    std::shared_ptr<SyncSession> session = _session.lock();
    if (!session) {
        // The session is dead or in a fatal error state.
        unregisterRefreshHandle(_user, _path);
        [self invalidate];
        return NO;
    }

    if (json && !error) {
        RLMAuthResponseModel *model = [[RLMAuthResponseModel alloc] initWithDictionary:json
                                                                    requireAccessToken:YES
                                                                   requireRefreshToken:NO];
        if (model) {
            return [self _handleSuccessfulRequest:model session:*session];
        }
        // Otherwise, malformed JSON
        unregisterRefreshHandle(_user, _path);
        NSError *error = make_sync_error(make_auth_error_bad_response(json));
        if (self.completionBlock) {
            self.completionBlock(error);
        }
        [[RLMSyncManager sharedManager] _fireError:error];
    } else {
        REALM_ASSERT(error);
        [self _handleFailedRequest:error];
    }
    return NO;
}

- (void)_timerFired {
    RLMServerToken refreshToken = nil;
    if (auto user = _user.lock()) {
        refreshToken = @(user->refresh_token().c_str());
    }
    if (!refreshToken) {
        unregisterRefreshHandle(_user, _path);
        return;
    }

    NSDictionary *json = @{
                           kRLMSyncProviderKey: @"realm",
                           kRLMSyncPathKey: @(_path.c_str()),
                           kRLMSyncDataKey: refreshToken,
                           kRLMSyncAppIDKey: [RLMSyncManager sharedManager].appID,
                           };

    __weak RLMSyncSessionRefreshHandle *weakSelf = self;
    RLMSyncCompletionBlock handler = ^(NSError *error, NSDictionary *json) {
        [weakSelf _onRefreshCompletionWithError:error json:json];
    };
// FIXME: [realmapp] This still potentially has use. It is unclear at the moment
// FIXME: if this should be handled in the OS or at this layer.
//    [RLMSyncAuthEndpoint sendRequestToServer:self.authServerURL
//                                        JSON:json
//                                     timeout:60.0
//                                  completion:handler];
}

@end
