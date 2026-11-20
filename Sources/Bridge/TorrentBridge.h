// Swift-facing wrapper around libtorrent (C++). Plain Objective-C types only,
// so Swift imports it through the bridging header.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TBState) {
    TBStateCheckingFiles = 0,
    TBStateGettingInfo,     // magnet: fetching the file list from peers
    TBStateDownloading,
    TBStateFinished,        // wanted files done (some files skipped)
    TBStateSeeding,
    TBStateCheckingResume,
    TBStatePaused,
    TBStateWaitingToStart,  // stopped after metadata so files can be chosen
    TBStateError,
    TBStateQueued,          // waiting for a free slot (downloads run 4 at a time)
};

@interface TBTorrent : NSObject
@property (nonatomic, copy) NSString *infoHash;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *savePath;
@property (nonatomic) TBState state;
@property (nonatomic) double progress;          // 0...1 of wanted files
@property (nonatomic) int64_t totalWanted;
@property (nonatomic) int64_t totalWantedDone;
@property (nonatomic) int64_t totalSize;        // whole torrent
@property (nonatomic) int64_t chosenSize;       // exact bytes of the files chosen
@property (nonatomic) int64_t downloadRate;     // bytes/s
@property (nonatomic) int64_t uploadRate;
@property (nonatomic) int64_t totalUploaded;
@property (nonatomic) int64_t totalDownloaded;
@property (nonatomic) int peers;
@property (nonatomic) int seeds;
@property (nonatomic) int peersInSwarm;         // from the trackers
@property (nonatomic) int seedsInSwarm;
// Start-up phase, so the app can say what is happening before data flows.
@property (nonatomic) int knownPeers;           // addresses found (trackers, DHT, others)
@property (nonatomic) int connecting;           // connection attempts in progress
@property (nonatomic) int trackers;             // trackers in the torrent
@property (nonatomic) int trackersAnswered;     // replied at least once
@property (nonatomic) int trackersFailed;       // last attempt failed
@property (nonatomic) int peersFromDHT;         // addresses the DHT network returned
@property (nonatomic, copy, nullable) NSString *trackerError;  // last tracker problem
@property (nonatomic) BOOL hasMetadata;
@property (nonatomic) BOOL isPaused;
@property (nonatomic) BOOL sequential;
@property (nonatomic) int fileCount;
@property (nonatomic, copy, nullable) NSString *errorMessage;
@property (nonatomic) NSTimeInterval addedTime;
@property (nonatomic) NSTimeInterval completedTime;
@end

@interface TBFile : NSObject
@property (nonatomic) int index;
@property (nonatomic, copy) NSString *path;     // relative, inside the torrent
@property (nonatomic) int64_t size;
@property (nonatomic) int64_t done;
@property (nonatomic) BOOL wanted;
@end

/// What the connected peers can still give us (see -healthForTorrent:).
@interface TBHealth : NSObject
@property (nonatomic) int pieceCount;            // all pieces in the torrent
@property (nonatomic) int missingWanted;         // pieces still needed for the chosen files
@property (nonatomic) int missingUnadvertised;   // of those, pieces no connected peer has
@property (nonatomic) int peersChecked;          // peers the numbers are based on
@property (nonatomic) BOOL completeSourceSeen;   // a connected peer has every piece
@property (nonatomic) double copies;             // distributed copies among connected peers (-1 unknown)
@end

/// One connected peer.
@interface TBPeer : NSObject
@property (nonatomic, copy) NSString *address;     // "1.2.3.4" (no port)
@property (nonatomic, copy) NSString *client;      // "qBittorrent 5.0", or ""
@property (nonatomic) int64_t downRate;            // bytes/s from this peer
@property (nonatomic) int64_t upRate;              // bytes/s to this peer
@property (nonatomic) double progress;             // 0...1 of the torrent it has
@property (nonatomic) BOOL isSeed;
@property (nonatomic) BOOL weConnected;            // we dialled out (else they came to us)
@end

/// Which pieces are on disk, in `buckets` slices, for drawing a map.
@interface TBPieceMap : NSObject
@property (nonatomic) int pieceCount;
@property (nonatomic, copy) NSArray<NSNumber *> *have;     // 0...1 per slice: share of its pieces on disk
@property (nonatomic, copy) NSArray<NSNumber *> *wanted;   // 0...1 per slice: share of its pieces chosen
@end

/// Things that happened since the last poll.
@interface TBEvents : NSObject
@property (nonatomic, copy) NSArray<NSString *> *finished;      // info hashes
@property (nonatomic, copy) NSArray<NSString *> *gotMetadata;
@property (nonatomic, copy) NSArray<NSString *> *checked;       // info hashes whose file check just ended
@property (nonatomic, copy) NSArray<NSString *> *errors;        // "hash\tmessage"
@end

/// Making torrents. These touch no session state, so they may run on any thread.
@interface TBMaker : NSObject
/// A .torrent for a file or a folder, hashing every piece (slow for big data: not on the main
/// thread). `progress` gets 0...1; return YES from `shouldCancel` to stop. nil + error on failure.
+ (nullable NSData *)createTorrentForPath:(NSString *)path
                                isPrivate:(BOOL)isPrivate
                                  comment:(nullable NSString *)comment
                                 trackers:(NSArray<NSString *> *)trackers
                                 progress:(nullable void (^)(double))progress
                             shouldCancel:(nullable BOOL (^)(void))shouldCancel
                                    error:(NSString * _Nullable * _Nullable)error;
/// Name, total size and file count read from .torrent data, without adding it.
+ (nullable NSDictionary<NSString *, id> *)describeTorrentData:(NSData *)data;
@end

@interface TBSession : NSObject

/// stateFolder holds resume data so torrents survive a quit.
- (instancetype)initWithStateFolder:(NSString *)stateFolder;

/// Re-adds every torrent saved in stateFolder.
- (void)restoreTorrents;

/// Returns the info hash, or nil with an error message.
/// startPaused: stop once the file list is known so files can be chosen.
- (nullable NSString *)addMagnet:(NSString *)uri savePath:(NSString *)savePath
                     startPaused:(BOOL)startPaused error:(NSString * _Nullable * _Nullable)error;
- (nullable NSString *)addTorrentFile:(NSString *)path savePath:(NSString *)savePath
                          startPaused:(BOOL)startPaused error:(NSString * _Nullable * _Nullable)error;

/// A torrent from .torrent bytes. privateTransfer: no DHT, local discovery or peer exchange, so
/// it is only ever reached by peers that are told about it directly (nearby-Mac transfers).
- (nullable NSString *)addTorrentData:(NSData *)data savePath:(NSString *)savePath
                      privateTransfer:(BOOL)privateTransfer error:(NSString * _Nullable * _Nullable)error;

- (NSArray<TBTorrent *> *)torrents;
- (NSArray<TBFile *> *)filesForTorrent:(NSString *)infoHash;
- (TBEvents *)popEvents;

- (void)pause:(NSString *)infoHash;
- (void)resume:(NSString *)infoHash;
- (void)remove:(NSString *)infoHash deleteFiles:(BOOL)deleteFiles;
- (void)setWanted:(NSArray<NSNumber *> *)wantedFileIndexes forTorrent:(NSString *)infoHash;
/// Download every file (skips choosing, even before the file list arrives).
- (void)startAll:(NSString *)infoHash;
- (void)setSequential:(BOOL)on forTorrent:(NSString *)infoHash;
- (void)recheck:(NSString *)infoHash;
/// Point the torrent at a folder that may already hold its files (the folder that
/// contains the torrent's top-level file or folder). Nothing is moved or overwritten:
/// libtorrent checks what is there against the piece hashes and downloads only what is
/// missing or wrong.
- (void)useExistingFiles:(NSString *)folder forTorrent:(NSString *)infoHash;
/// Ask the trackers again (and nudge peer discovery). Safe to call rarely.
- (void)reannounce:(NSString *)infoHash;
/// Connected peers, fastest first. Only for the torrent being looked at.
- (NSArray<TBPeer *> *)peersForTorrent:(NSString *)infoHash;
- (nullable TBPieceMap *)pieceMapForTorrent:(NSString *)infoHash buckets:(int)buckets;
/// One torrent only (tests throttle a local seeder with this). 0 = unlimited.
- (void)setUploadLimit:(int)bytesPerSecond forTorrent:(NSString *)infoHash;
/// Connect straight to a known peer (used by tests with a local seeder).
- (void)connectPeer:(NSString *)host port:(int)port forTorrent:(NSString *)infoHash;
/// nil until the torrent is running with a file list. Walks every piece, so
/// call it every few seconds, not every frame.
- (nullable TBHealth *)healthForTorrent:(NSString *)infoHash;
// MARK: Playing while downloading

/// Where a file sits on disk right now (nil without a file list).
- (nullable NSString *)diskPathForFile:(int)file inTorrent:(NSString *)infoHash;
/// Whole-file size.
- (int64_t)sizeOfFile:(int)file inTorrent:(NSString *)infoHash;
/// How many bytes, starting at `offset` inside the file, are already complete
/// and verified (stops at the first missing piece or the end of the file).
- (int64_t)contiguousBytesInFile:(int)file inTorrent:(NSString *)infoHash from:(int64_t)offset;
/// Ask for the pieces covering [offset, offset+length) of the file first, in
/// order, soonest first. Makes sure the file is downloaded at all.
- (void)prioritizeRange:(int64_t)length from:(int64_t)offset inFile:(int)file ofTorrent:(NSString *)infoHash;
/// Forget the playback deadlines; ordinary download order returns.
- (void)clearPlaybackDeadlinesForTorrent:(NSString *)infoHash;
/// Fraction (0...1) of the file's bytes that are complete, in `buckets` slices.
- (NSArray<NSNumber *> *)availabilityMapOfFile:(int)file inTorrent:(NSString *)infoHash buckets:(int)buckets;

- (nullable NSString *)magnetLinkFor:(NSString *)infoHash;

/// 0 means unlimited. Bytes per second.
- (void)setDownloadLimit:(int)bytesPerSecond uploadLimit:(int)upBytesPerSecond;
- (void)setListenPort:(int)port;
- (int)listenPort;

/// Writes resume data for every torrent and waits (up to the timeout).
- (void)saveAllAndWait:(NSTimeInterval)timeout;

@end

NS_ASSUME_NONNULL_END
