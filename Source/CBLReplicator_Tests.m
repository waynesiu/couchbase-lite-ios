//
//  CBL_Replicator_Tests.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 12/7/11.
//  Copyright (c) 2011 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "CBL_Puller.h"
#import "CBL_Pusher.h"
#import "CBL_ReplicatorManager.h"
#import "CBL_Server.h"
#import "CBLDatabase+Replication.h"
#import "CBLDatabase+Insertion.h"
#import "CBLRevision.h"
#import "CBLOAuth1Authorizer.h"
#import "CBLBase64.h"
#import "CBLInternal.h"
#import "Test.h"
#import "MYURLUtils.h"


#if DEBUG

// Change port to 59840 to test against LiteServ :)
#if TARGET_OS_IPHONE && !TARGET_IPHONE_SIMULATOR
#define kRemoteDBURLStr @"http://jens.local:5984/tdreplicator_test"
#else
#define kRemoteDBURLStr @"http://127.0.0.1:5984/tdreplicator_test"
#endif


static id<CBLAuthorizer> authorizer(void) {
#if 1
    return nil;
#else
    NSURLCredential* cred = [NSURLCredential credentialWithUser: @"XXXX" password: @"XXXX"
                                                    persistence:NSURLCredentialPersistenceNone];
    return [[[CBLBasicAuthorizer alloc] initWithCredential: cred] autorelease];
#endif
}


static void deleteRemoteDB(void) {
    Log(@"Deleting %@", kRemoteDBURLStr);
    NSURL* url = [NSURL URLWithString: kRemoteDBURLStr];
    __block NSError* error = nil;
    __block BOOL finished = NO;
    CBLRemoteRequest* request = [[CBLRemoteRequest alloc] initWithMethod: @"DELETE"
                                                                   URL: url
                                                                  body: nil
                                                        requestHeaders: nil
                                                          onCompletion:
        ^(id result, NSError *err) {
            finished = YES;
            error = err;
        }
                                ];
    request.authorizer = authorizer();
    [request start];
    NSDate* timeout = [NSDate dateWithTimeIntervalSinceNow: 10];
    while (!finished && [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                                                 beforeDate: timeout])
        ;
    CAssert(error == nil || error.code == kCBLStatusNotFound, @"Couldn't delete remote: %@", error);
}


static NSString* replic8(CBLDatabase* db, NSString* urlStr, BOOL push, NSString* filter) {
    NSURL* remote = [NSURL URLWithString: urlStr];
    CBL_Replicator* repl = [[CBL_Replicator alloc] initWithDB: db remote: remote
                                                        push: push continuous: NO];
    if (push)
        ((CBL_Pusher*)repl).createTarget = YES;
    repl.filterName = filter;
    repl.authorizer = authorizer();
    [repl start];
    
    CAssert(repl.running);
    Log(@"Waiting for replicator to finish...");
    while (repl.running || repl.savingCheckpoint) {
        if (![[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                                      beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.5]])
            break;
    }
    CAssert(!repl.running);
    CAssert(!repl.savingCheckpoint);
    CAssertNil(repl.error);
    Log(@"...replicator finished. lastSequence=%@", repl.lastSequence);
    return repl.lastSequence;
}


TestCase(CBL_Pusher) {
    RequireTestCase(CBLDatabase);
    CBLManager* server = [CBLManager createEmptyAtTemporaryPath: @"CBL_PusherTest"];
    CBLDatabase* db = [server createDatabaseNamed: @"db" error: NULL];
    CAssert(db);
    
    __block int filterCalls = 0;
    [db defineFilter: @"filter" asBlock: ^BOOL(CBLRevision *revision, NSDictionary* params) {
        Log(@"Test filter called with params = %@", params);
        Log(@"Rev = %@, properties = %@", revision, revision.properties);
        CAssert(revision.properties);
        ++filterCalls;
        return YES;
    }];
    
    deleteRemoteDB();

    // Create some documents:
    NSMutableDictionary* props = $mdict({@"_id", @"doc1"},
                                        {@"foo", @1}, {@"bar", $false});
    CBLStatus status;
    CBL_Revision* rev1 = [db putRevision: [CBL_Revision revisionWithProperties: props]
                        prevRevisionID: nil allowConflict: NO status: &status];
    CAssertEq(status, kCBLStatusCreated);
    
    props[@"_rev"] = rev1.revID;
    props[@"UPDATED"] = $true;
    CBL_Revision* rev2 = [db putRevision: [CBL_Revision revisionWithProperties: props]
                        prevRevisionID: rev1.revID allowConflict: NO status: &status];
    CAssertEq(status, kCBLStatusCreated);
    
    props = $mdict({@"_id", @"doc2"},
                   {@"baz", @(666)}, {@"fnord", $true});
    [db putRevision: [CBL_Revision revisionWithProperties: props]
                        prevRevisionID: nil allowConflict: NO status: &status];
    CAssertEq(status, kCBLStatusCreated);
#pragma unused(rev2)
    
    // Push them to the remote:
    id lastSeq = replic8(db, kRemoteDBURLStr, YES, @"filter");
    CAssertEqual(lastSeq, @"3");
    CAssertEq(filterCalls, 2);
    
    [db close];
    [server close];
}


TestCase(CBL_Puller) {
    RequireTestCase(CBL_Pusher);
    CBLManager* server = [CBLManager createEmptyAtTemporaryPath: @"CBL_PullerTest"];
    CBLDatabase* db = [server createDatabaseNamed: @"db" error: NULL];
    CAssert(db);
    
    id lastSeq = replic8(db, kRemoteDBURLStr, NO, nil);
    CAssertEqual(lastSeq, @2);
    
    CAssertEq(db.documentCount, 2u);
    CAssertEq(db.lastSequenceNumber, 3);
    
    // Replicate again; should complete but add no revisions:
    Log(@"Second replication, should get no more revs:");
    replic8(db, kRemoteDBURLStr, NO, nil);
    CAssertEq(db.lastSequenceNumber, 3);
    
    CBL_Revision* doc = [db getDocumentWithID: @"doc1" revisionID: nil];
    CAssert(doc);
    CAssert([doc.revID hasPrefix: @"2-"]);
    CAssertEqual(doc[@"foo"], @1);
    
    doc = [db getDocumentWithID: @"doc2" revisionID: nil];
    CAssert(doc);
    CAssert([doc.revID hasPrefix: @"1-"]);
    CAssertEqual(doc[@"fnord"], $true);

    [db close];
    [server close];
}

TestCase(CBLPuller_DocIDs) {
    RequireTestCase(CBL_Pusher);
    
    CBLManager* server = [CBLManager createEmptyAtTemporaryPath: @"CBLPuller_DocIDs_Test"];
    CBLDatabase* db = [server createDatabaseNamed: @"db" error: NULL];
    CAssert(db);

    // Start a named document pull replication.
    NSURL* remote = [NSURL URLWithString: kRemoteDBURLStr];
    CBL_Replicator* repl = [[CBL_Replicator alloc] initWithDB: db remote: remote
                                                     push: NO continuous: NO];
    repl.docIDs = @[@"doc1"];
    repl.authorizer = authorizer();
    [repl start];
    
    // Let the replicator run.
    CAssert(repl.running);
    Log(@"Waiting for replicator to finish...");
    while (repl.running || repl.savingCheckpoint) {
        if (![[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                                      beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.5]])
            break;
    }
    CAssert(!repl.running);
    CAssert(!repl.savingCheckpoint);
    CAssertNil(repl.error);
    Log(@"...replicator finished. lastSequence=%@", repl.lastSequence);
    id lastSeq = repl.lastSequence;
    
    CAssertEqual(lastSeq, @1);
    
    Log(@"GOT DOCS: %@", [db getAllDocs:nil]);
    
    CAssertEq(db.documentCount, 1u);
    CAssertEq(db.lastSequenceNumber, 2);
    
    // Replicate again; should complete but add no revisions:
    Log(@"Second replication, should get no more revs:");
    replic8(db, kRemoteDBURLStr, NO, nil);
    CAssertEq(db.lastSequenceNumber, 3);
    
    CBL_Revision* doc = [db getDocumentWithID: @"doc1" revisionID: nil];
    CAssert(doc);
    CAssert([doc.revID hasPrefix: @"2-"]);
    CAssertEqual(doc[@"foo"], @1);
    
    [db close];
    [server close];
}


TestCase(CBL_Puller_FromCouchApp) {
    /** This test case requires that there be an empty CouchApp installed on a local CouchDB server, in a database named "couchapp_helloworld". To keep the test from breaking for most people, I've disabled it unless you're me :) If you want to run this test, just delete the lines below. */
    if (!$equal(NSUserName(), @"snej")) {
        Log(@"Skipping CBL_Puller_FromCouchApp test");
        return;
    }
    
    RequireTestCase(CBL_Puller);
    CBLManager* server = [CBLManager createEmptyAtTemporaryPath: @"CBL_Puller_FromCouchApp"];
    CBLDatabase* db = [server createDatabaseNamed: @"couchapp_helloworld" error: NULL];
    CAssert(db);
    
    replic8(db, @"http://127.0.0.1:5984/couchapp_helloworld", NO, nil);

    CBLStatus status;
    CBL_Revision* rev = [db getDocumentWithID: @"_design/helloworld" revisionID: nil options: kCBLIncludeAttachments status: &status];
    NSDictionary* attachments = rev[@"_attachments"];
    CAssertEq(attachments.count, 10u);
    for (NSString* name in attachments) { 
        NSDictionary* attachment = attachments[name];
        NSData* data = [CBLBase64 decode: attachment[@"data"]];
        Log(@"Attachment %@: %u bytes", name, (unsigned)data.length);
        CAssert(data);
        CAssertEq([data length], [attachment[@"length"] unsignedLongLongValue]);
    }
    [db close];
    [server close];
}


static CBL_Replicator* findActiveReplicator(CBLDatabase* db, NSURL* remote, BOOL isPush) {
    for (CBL_Replicator* repl in db.activeReplicators) {
        if (repl.db == db && $equal(repl.remote, remote) && repl.isPush == isPush)
            return repl;
    }
    return nil;
}


TestCase(CBL_ReplicatorManager) {
    RequireTestCase(ParseReplicatorProperties);
    CBLManager* server = [CBLManager createEmptyAtTemporaryPath: @"CBL_ReplicatorManagerTest"];
    CAssert([server replicatorManager]);    // start the replicator
    CBLDatabase* replicatorDb = [server createDatabaseNamed: kCBL_ReplicatorDatabaseName
                                                error: NULL];
    CAssert(replicatorDb);
    
    // Try some bogus validation docs that will fail the validator function:
    CBL_Revision* rev = [CBL_Revision revisionWithProperties: $dict({@"source", @"foo"},
                                                                {@"target", @7})];
#pragma unused (rev) // some of the 'rev=' assignments below are unnecessary
    CBLStatus status;
    rev = [replicatorDb putRevision: rev prevRevisionID: nil allowConflict: NO status: &status];
    CAssertEq(status, kCBLStatusForbidden);

    rev = [CBL_Revision revisionWithProperties: $dict({@"source", @"foo"},
                                                    {@"target", @"http://foo.com"},
                                                    {@"_internal", $true})];  // <--illegal prop
    rev = [replicatorDb putRevision: rev prevRevisionID: nil allowConflict: NO status: &status];
    CAssertEq(status, kCBLStatusForbidden);
    
    CBLDatabase* sourceDB = [server createDatabaseNamed: @"foo" error: NULL];
    CAssert(sourceDB);

    // Now try a valid replication document:
    NSURL* remote = [NSURL URLWithString: @"http://localhost:5984/tdreplicator_test"];
    rev = [CBL_Revision revisionWithProperties: $dict({@"source", @"foo"},
                                                    {@"target", remote.absoluteString})];
    rev = [replicatorDb putRevision: rev prevRevisionID: nil allowConflict: NO status: &status];
    CAssertEq(status, kCBLStatusCreated);
    
    // Get back the document and verify it's been updated with replicator properties:
    CBL_Revision* newRev = [replicatorDb getDocumentWithID: rev.docID revisionID: nil];
    Log(@"Updated doc = %@", newRev.properties);
    CAssert(!$equal(newRev.revID, rev.revID), @"Replicator doc wasn't updated");
    NSString* sessionID = newRev[@"_replication_id"];
    CAssert([sessionID length] >= 10);
    CAssertEqual(newRev[@"_replication_state"], @"triggered");
    CAssert([newRev[@"_replication_state_time"] longLongValue] >= 1000);
    
    // Check that a CBL_Replicator exists:
    CBL_Replicator* repl = findActiveReplicator(sourceDB, remote, YES);
    CAssert(repl);
    CAssertEqual(repl.sessionID, sessionID);
    CAssert(repl.running);
    
    // Delete the _replication_state property, and add "reset" while we're at it:
    NSMutableDictionary* updatedProps = [newRev.properties mutableCopy];
    updatedProps[@"reset"] = $true;
    [updatedProps removeObjectForKey: @"_replication_state"];
    rev = [CBL_Revision revisionWithProperties: updatedProps];
    rev = [replicatorDb putRevision: rev prevRevisionID: rev.revID allowConflict: NO status: &status];
    CAssertEq(status, kCBLStatusCreated);

    // Get back the document and verify it's been updated with replicator properties:
    newRev = [replicatorDb getDocumentWithID: rev.docID revisionID: nil];
    Log(@"Updated doc = %@", newRev.properties);
    sessionID = newRev[@"_replication_id"];
    CAssert([sessionID length] >= 10);
    CAssertEqual(newRev[@"_replication_state"], @"triggered");
    CAssert([newRev[@"_replication_state_time"] longLongValue] >= 1000);
    
    // Check that this restarted the replicator:
    CBL_Replicator* newRepl = findActiveReplicator(sourceDB, remote, YES);
    CAssert(newRepl);
    CAssert(newRepl != repl);
    CAssertEqual(newRepl.sessionID, sessionID);
    CAssert(newRepl.running);

    // Now delete the database, and check that the replication doc is deleted too:
    CAssert([sourceDB deleteDatabase: NULL]);
    CAssertNil([replicatorDb getDocumentWithID: rev.docID revisionID: nil]);
    
    [server close];
}


@interface CBLManager (Seekrit)
- (CBLStatus) parseReplicatorProperties: (NSDictionary*)properties
                            toDatabase: (CBLDatabase**)outDatabase   // may be NULL
                                remote: (NSURL**)outRemote          // may be NULL
                                isPush: (BOOL*)outIsPush
                          createTarget: (BOOL*)outCreateTarget
                               headers: (NSDictionary**)outHeaders
                            authorizer: (id<CBLAuthorizer>*)outAuthorizer;
@end


TestCase(ParseReplicatorProperties) {
    CBLManager* dbManager = [CBLManager createEmptyAtTemporaryPath: @"CBL_ReplicatorManagerTest"];
    CBLDatabase* localDB = [dbManager _databaseNamed: @"foo" mustExist: NO error: NULL];

    CBLDatabase* db = nil;
    NSURL* remote = nil;
    BOOL isPush = NO, createTarget = NO;
    NSDictionary* headers = nil;
    
    NSDictionary* props;
    props = $dict({@"source", @"foo"},
                  {@"target", @"http://example.com"},
                  {@"create_target", $true});
    CAssertEq(200, [dbManager parseReplicatorProperties: props
                                             toDatabase: &db
                                                 remote: &remote
                                                 isPush: &isPush
                                           createTarget: &createTarget
                                                headers: &headers
                                             authorizer: NULL]);
    CAssertEq(db, localDB);
    CAssertEqual(remote, $url(@"http://example.com"));
    CAssertEq(isPush, YES);
    CAssertEq(createTarget, YES);
    CAssertEqual(headers, nil);
    
    props = $dict({@"source", @"cbl:///foo"},
                  {@"target", @"foo"});
    CAssertEq(200, [dbManager parseReplicatorProperties: props
                                             toDatabase: &db
                                                 remote: &remote
                                                 isPush: &isPush
                                           createTarget: &createTarget
                                                headers: &headers
                                             authorizer: NULL]);
    CAssertEq(db, localDB);
    CAssertEqual(remote, $url(@"cbl:///foo"));
    CAssertEq(isPush, NO);
    CAssertEq(createTarget, NO);
    CAssertEqual(headers, nil);

    // Local-to-local replication:
    props = $dict({@"source", @"foo"},
                  {@"target", @"bar"});
    CAssertEq([dbManager parseReplicatorProperties: props
                                        toDatabase: &db
                                            remote: &remote
                                            isPush: &isPush
                                      createTarget: &createTarget
                                           headers: &headers
                                        authorizer: NULL],
              404);
    props = $dict({@"source", @"foo"},
                  {@"target", @"bar"}, {@"create_target", $true});
    CAssertEq([dbManager parseReplicatorProperties: props
                                        toDatabase: &db
                                            remote: &remote
                                            isPush: &isPush
                                      createTarget: &createTarget
                                           headers: &headers
                                        authorizer: NULL],
              200);
    CAssertEq(db, localDB);
    CAssertEqual(remote, $url(@"http://lite.couchbase./bar/"));
    CAssertEq(isPush, YES);
    CAssertEq(createTarget, YES);
    CAssertEqual(headers, nil);
    
    NSDictionary* oauthDict = $dict({@"consumer_secret", @"consumer_secret"},
                                    {@"consumer_key", @"consumer_key"},
                                    {@"token_secret", @"token_secret"},
                                    {@"token", @"token"});
    props = $dict({@"source", $dict({@"url", @"http://example.com"},
                                    {@"headers", $dict({@"Excellence", @"Most"})},
                                    {@"auth", $dict({@"oauth", oauthDict})})},
                  {@"target", @"foo"});
    id<CBLAuthorizer> authorizer = nil;
    CAssertEq(200, [dbManager parseReplicatorProperties: props
                                             toDatabase: &db
                                                 remote: &remote
                                                 isPush: &isPush
                                           createTarget: &createTarget
                                                headers: &headers
                                             authorizer: &authorizer]);
    CAssertEq(db, localDB);
    CAssertEqual(remote, $url(@"http://example.com"));
    CAssertEq(isPush, NO);
    CAssertEq(createTarget, NO);
    CAssertEqual(headers, $dict({@"Excellence", @"Most"}));
    CAssert([authorizer isKindOfClass: [CBLOAuth1Authorizer class]]);
    
    [dbManager close];
}

#endif
