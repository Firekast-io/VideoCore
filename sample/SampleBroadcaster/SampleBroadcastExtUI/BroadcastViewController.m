//
//  BroadcastViewController.m
//  SampleBroadcastExtUI
//
//  Created by Sopl’Wang on 2016/10/10.
//  Copyright © 2016年 videocore. All rights reserved.
//

#import "BroadcastViewController.h"

@implementation BroadcastViewController

// Called when the user has finished interacting with the view controller and a broadcast stream can start
- (void)userDidFinishSetup {
    
    // Broadcast url that will be returned to the application
    NSURL *broadcastURL = [NSURL URLWithString:@"http://broadcastURL_example/stream1"];
    
    // Service specific broadcast data example which will be supplied to the process extension during broadcast
    NSString *userID = @"user1";
    NSString *endpointURL = @"http://172.0.0.82:3000/upload";
    NSDictionary *setupInfo = @{ @"userID" : userID, @"endpointURL" : endpointURL };
    
    // Set broadcast settings
    RPBroadcastConfiguration *broadcastConfig = [[RPBroadcastConfiguration alloc] init];
    broadcastConfig.videoCompressionProperties = @{ AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel };

    // Tell ReplayKit that the extension is finished setting up and can begin broadcasting
    [self.extensionContext completeRequestWithBroadcastURL:broadcastURL broadcastConfiguration:broadcastConfig setupInfo:setupInfo];
}

- (void)userDidCancelSetup {
    // Tell ReplayKit that the extension was cancelled by the user
    [self.extensionContext cancelRequestWithError:[NSError errorWithDomain:@"YourAppDomain" code:-1     userInfo:nil]];
}

- (IBAction)startBroadcast:(id)sender {
    [self userDidFinishSetup];
}

- (IBAction)cancelBroadcast:(id)sender {
    [self userDidCancelSetup];
}

@end
