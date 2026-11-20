#import "TorrentBridge.h"

#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <libtorrent/fingerprint.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/bencode.hpp>

#include <algorithm>
#include <fstream>
#include <map>
#include <memory>
#include <set>
#include <sstream>

namespace lt = libtorrent;

@implementation TBTorrent @end
@implementation TBFile @end
@implementation TBEvents @end
@implementation TBHealth @end
@implementation TBPeer @end
@implementation TBPieceMap @end

static NSString *str(std::string const &s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }

static std::string hashOf(lt::torrent_handle const &h) {
    std::stringstream ss;
    ss << h.info_hashes().get_best();
    return ss.str();
}

@implementation TBMaker

+ (nullable NSData *)createTorrentForPath:(NSString *)path isPrivate:(BOOL)isPrivate comment:(nullable NSString *)comment
                                 trackers:(NSArray<NSString *> *)trackers progress:(void (^)(double))progress shouldCancel:(BOOL (^)(void))shouldCancel
                                    error:(NSString **)error {
    struct Cancelled {};
    try {
        std::string full = path.stringByStandardizingPath.UTF8String;
        while (full.size() > 1 && full.back() == '/') full.pop_back();
        std::string parent = full.substr(0, full.find_last_of('/'));
        if (parent.empty()) parent = "/";
        std::vector<lt::create_file_entry> files = lt::list_files(full, lt::create_torrent::no_attributes);
        if (files.empty()) { if (error) *error = @"There is nothing to share in that folder."; return nil; }
        lt::create_torrent ct(std::move(files));
        ct.set_priv(isPrivate);
        ct.set_creator("Swarm");
        if (comment.length) ct.set_comment(comment.UTF8String);
        int tier = 0;
        for (NSString *t in trackers) { if (t.length) ct.add_tracker(t.UTF8String, tier++); }
        int pieces = ct.num_pieces();
        lt::error_code ec;
        lt::set_piece_hashes(ct, parent, [&](lt::piece_index_t i) {
            if (shouldCancel && shouldCancel()) throw Cancelled();
            if (progress && pieces > 0) progress((double)(static_cast<int>(i) + 1) / pieces);
        }, ec);
        if (ec) { if (error) *error = str(ec.message()); return nil; }
        std::vector<char> buf = ct.generate_buf();
        return [NSData dataWithBytes:buf.data() length:buf.size()];
    } catch (Cancelled const &) {
        if (error) *error = @"Cancelled.";
        return nil;
    } catch (std::exception const &e) {
        if (error) *error = str(e.what());
        return nil;
    }
}

+ (nullable NSDictionary<NSString *, id> *)describeTorrentData:(NSData *)data {
    try {
        lt::add_torrent_params p = lt::load_torrent_buffer(lt::span<char const>(static_cast<char const *>(data.bytes), (long)data.length));
        if (!p.ti) return nil;
        std::stringstream ss;
        ss << p.info_hashes.get_best();
        // Real files only: torrents carry invisible padding files that are never shown or saved.
        lt::file_storage const &fs = p.ti->layout();
        int64_t size = 0; int count = 0;
        for (lt::file_index_t i(0); i < fs.end_file(); ++i) {
            if (fs.pad_file_at(i)) continue;
            size += fs.file_size(i); count++;
        }
        return @{ @"name": str(p.ti->name()), @"size": @(size), @"files": @(count),
                  @"hash": str(ss.str()), @"private": @(p.ti->priv()) };
    } catch (...) { return nil; }
}

@end

@implementation TBSession {
    std::unique_ptr<lt::session> _session;
    std::map<std::string, lt::torrent_handle> _handles;
    std::set<std::string> _pickFiles;      // stop after metadata, wait for a choice
    std::map<std::string, std::set<std::string>> _trackersAnswered;   // hash -> tracker urls
    std::map<std::string, std::map<std::string, std::string>> _trackersFailed;  // hash -> url -> message
    std::map<std::string, int> _dhtPeers;
    int _savesPending;
    NSString *_stateFolder;
    NSMutableArray<NSString *> *_finished;
    NSMutableArray<NSString *> *_gotMetadata;
    NSMutableArray<NSString *> *_checked;
    NSMutableArray<NSString *> *_errors;
}

- (instancetype)initWithStateFolder:(NSString *)stateFolder {
    if ((self = [super init])) {
        _stateFolder = [stateFolder copy];
        [[NSFileManager defaultManager] createDirectoryAtPath:stateFolder withIntermediateDirectories:YES attributes:nil error:nil];
        _finished = [NSMutableArray new];
        _gotMetadata = [NSMutableArray new];
        _checked = [NSMutableArray new];
        _errors = [NSMutableArray new];

        lt::settings_pack pack;
        pack.set_int(lt::settings_pack::alert_mask,
                     lt::alert_category::status | lt::alert_category::error | lt::alert_category::storage
                     | lt::alert_category::tracker | lt::alert_category::dht);
        pack.set_str(lt::settings_pack::user_agent, "Swarm/1.0 libtorrent/2.1");
        pack.set_str(lt::settings_pack::peer_fingerprint, lt::generate_fingerprint("SW", 1, 0, 0, 0));
        pack.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:6881,[::]:6881");
        pack.set_bool(lt::settings_pack::enable_dht, true);
        pack.set_bool(lt::settings_pack::enable_lsd, true);
        pack.set_bool(lt::settings_pack::enable_upnp, true);
        pack.set_bool(lt::settings_pack::enable_natpmp, true);
        pack.set_int(lt::settings_pack::active_downloads, 4);
        pack.set_int(lt::settings_pack::active_seeds, 4);

        lt::session_params params(pack);
        // DHT routing table from the last run: finds peers in seconds.
        NSData *saved = [NSData dataWithContentsOfFile:[self sessionFile]];
        if (saved.length > 0) {
            try {
                lt::session_params old = lt::read_session_params(
                    lt::span<char const>(static_cast<char const *>(saved.bytes), (long)saved.length),
                    lt::session::save_dht_state);
                params.dht_state = std::move(old.dht_state);
            } catch (...) {}
        }
        _session = std::make_unique<lt::session>(std::move(params));

        __weak TBSession *weakSelf = self;
        _session->set_alert_notify([weakSelf] {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf drainAlerts]; });
        });
    }
    return self;
}

- (NSString *)sessionFile { return [_stateFolder stringByAppendingPathComponent:@"session.state"]; }

- (NSString *)resumeFileFor:(std::string const &)hash {
    return [_stateFolder stringByAppendingPathComponent:[str(hash) stringByAppendingString:@".resume"]];
}

#pragma mark Restore

- (void)restoreTorrents {
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_stateFolder error:nil];
    for (NSString *name in names) {
        if (![name hasSuffix:@".resume"]) continue;
        NSData *data = [NSData dataWithContentsOfFile:[_stateFolder stringByAppendingPathComponent:name]];
        if (data.length == 0) continue;
        lt::error_code ec;
        lt::add_torrent_params p = lt::read_resume_data(
            lt::span<char const>(static_cast<char const *>(data.bytes), (long)data.length), ec);
        if (ec) continue;
        lt::torrent_handle h = _session->add_torrent(std::move(p), ec);
        if (!ec) {
            _handles[hashOf(h)] = h;
            // Older builds could save under an all-zero name: write it again under
            // the right one and drop the zero-named copy.
            if ([name hasPrefix:@"0000000000"]) {
                h.save_resume_data(lt::torrent_handle::save_info_dict);
                [[NSFileManager defaultManager] removeItemAtPath:[_stateFolder stringByAppendingPathComponent:name] error:nil];
            }
        }
    }
}

#pragma mark Adding

- (nullable NSString *)addParams:(lt::add_torrent_params &)p savePath:(NSString *)savePath
                     startPaused:(BOOL)startPaused error:(NSString **)error {
    p.save_path = savePath.UTF8String;
    // Start now (libtorrent adds torrents paused and lets its queue start
    // them a moment later, which read as "Paused" in the app).
    p.flags &= ~lt::torrent_flags::paused;
    lt::error_code ec;
    lt::torrent_handle h = _session->add_torrent(std::move(p), ec);
    if (ec) {
        if (error) *error = str(ec.message());
        return nil;
    }
    std::string hash = hashOf(h);
    if (_handles.count(hash)) {
        if (error) *error = @"This torrent is already in the list.";
        return str(hash);
    }
    _handles[hash] = h;
    if (startPaused) {
        if (h.torrent_file()) {
            // .torrent file: the list is known now, stop before any data.
            [self stopForChoice:h];
        } else {
            _pickFiles.insert(hash);
        }
    }
    h.save_resume_data(lt::torrent_handle::save_info_dict);
    return str(hash);
}

- (nullable NSString *)addMagnet:(NSString *)uri savePath:(NSString *)savePath
                     startPaused:(BOOL)startPaused error:(NSString **)error {
    lt::error_code ec;
    lt::add_torrent_params p = lt::parse_magnet_uri(uri.UTF8String, ec);
    if (ec) {
        if (error) *error = @"That isn't a valid magnet link.";
        return nil;
    }
    return [self addParams:p savePath:savePath startPaused:startPaused error:error];
}

- (nullable NSString *)addTorrentFile:(NSString *)path savePath:(NSString *)savePath
                          startPaused:(BOOL)startPaused error:(NSString **)error {
    try {
        lt::add_torrent_params p = lt::load_torrent_file(path.UTF8String);
        return [self addParams:p savePath:savePath startPaused:startPaused error:error];
    } catch (std::exception const &e) {
        if (error) *error = @"That file isn't a valid .torrent file.";
        return nil;
    }
}

/// Nothing downloads until the person picks files.
- (void)stopForChoice:(lt::torrent_handle const &)h {
    auto ti = h.torrent_file();
    if (!ti) return;
    std::vector<lt::download_priority_t> none(static_cast<size_t>(ti->num_files()), lt::dont_download);
    h.prioritize_files(none);
    h.unset_flags(lt::torrent_flags::auto_managed);
    h.pause();
}

#pragma mark Alerts

- (void)drainAlerts {
    if (!_session) return;
    std::vector<lt::alert *> alerts;
    _session->pop_alerts(&alerts);
    for (lt::alert *a : alerts) {
        if (auto *m = lt::alert_cast<lt::metadata_received_alert>(a)) {
            std::string hash = hashOf(m->handle);
            if (_pickFiles.count(hash)) {
                [self stopForChoice:m->handle];
                _pickFiles.erase(hash);
            }
            [_gotMetadata addObject:str(hash)];
            m->handle.save_resume_data(lt::torrent_handle::save_info_dict);
        } else if (auto *c = lt::alert_cast<lt::torrent_checked_alert>(a)) {
            [_checked addObject:str(hashOf(c->handle))];
        } else if (auto *f = lt::alert_cast<lt::torrent_finished_alert>(a)) {
            [_finished addObject:str(hashOf(f->handle))];
            f->handle.save_resume_data(lt::torrent_handle::save_info_dict);
        } else if (auto *e = lt::alert_cast<lt::torrent_error_alert>(a)) {
            [_errors addObject:[NSString stringWithFormat:@"%@\t%@", str(hashOf(e->handle)), str(e->error.message())]];
        } else if (auto *fe = lt::alert_cast<lt::file_error_alert>(a)) {
            [_errors addObject:[NSString stringWithFormat:@"%@\t%@", str(hashOf(fe->handle)), str(fe->error.message())]];
        } else if (auto *tr = lt::alert_cast<lt::tracker_reply_alert>(a)) {
            std::string hash = hashOf(tr->handle), url = tr->tracker_url();
            _trackersAnswered[hash].insert(url);
            _trackersFailed[hash].erase(url);
        } else if (auto *te = lt::alert_cast<lt::tracker_error_alert>(a)) {
            std::string msg = te->failure_reason();
            if (msg.empty()) msg = te->error.message();
            _trackersFailed[hashOf(te->handle)][te->tracker_url()] = msg;
        } else if (auto *dr = lt::alert_cast<lt::dht_reply_alert>(a)) {
            _dhtPeers[hashOf(dr->handle)] += dr->num_peers;
        } else if (auto *r = lt::alert_cast<lt::save_resume_data_alert>(a)) {
            // Name the file from the data itself: the handle can already be gone
            // (it used to give an all-zero name and a ghost torrent after a restart).
            std::stringstream ss;
            ss << r->params.info_hashes.get_best();
            std::string hash = ss.str();
            if (_handles.count(hash)) {   // a removed torrent must not come back
                std::vector<char> buf = lt::write_resume_data_buf(r->params);
                NSData *data = [NSData dataWithBytes:buf.data() length:buf.size()];
                [data writeToFile:[self resumeFileFor:hash] atomically:YES];
            }
            if (_savesPending > 0) _savesPending--;
        } else if (lt::alert_cast<lt::save_resume_data_failed_alert>(a)) {
            if (_savesPending > 0) _savesPending--;
        }
    }
}

- (TBEvents *)popEvents {
    [self drainAlerts];
    TBEvents *ev = [TBEvents new];
    ev.finished = [_finished copy];
    ev.gotMetadata = [_gotMetadata copy];
    ev.checked = [_checked copy];
    ev.errors = [_errors copy];
    [_finished removeAllObjects];
    [_gotMetadata removeAllObjects];
    [_checked removeAllObjects];
    [_errors removeAllObjects];
    return ev;
}

#pragma mark Reading

- (nullable NSString *)addTorrentData:(NSData *)data savePath:(NSString *)savePath privateTransfer:(BOOL)privateTransfer
                               error:(NSString **)error {
    try {
        lt::add_torrent_params p = lt::load_torrent_buffer(lt::span<char const>(static_cast<char const *>(data.bytes), (long)data.length));
        if (privateTransfer) p.flags |= lt::torrent_flags::disable_dht | lt::torrent_flags::disable_lsd | lt::torrent_flags::disable_pex;
        return [self addParams:p savePath:savePath startPaused:NO error:error];
    } catch (std::exception const &e) {
        if (error) *error = @"That isn't a valid torrent.";
        return nil;
    }
}

- (NSArray<TBTorrent *> *)torrents {
    NSMutableArray *out = [NSMutableArray new];
    for (auto const &[hash, h] : _handles) {
        if (!h.is_valid()) continue;
        lt::torrent_status st = h.status();
        TBTorrent *t = [TBTorrent new];
        t.infoHash = str(hash);
        t.name = st.name.empty() ? @"" : str(st.name);
        t.savePath = str(st.save_path);
        t.progress = st.progress;
        t.totalWanted = st.total_wanted;
        t.totalWantedDone = st.total_wanted_done;
        t.downloadRate = st.download_payload_rate;
        t.uploadRate = st.upload_payload_rate;
        t.totalUploaded = st.all_time_upload;
        t.totalDownloaded = st.all_time_download;
        t.peers = st.num_peers;
        t.seeds = st.num_seeds;
        t.peersInSwarm = st.num_incomplete;
        t.seedsInSwarm = st.num_complete;
        t.hasMetadata = st.has_metadata;
        t.isPaused = (st.flags & lt::torrent_flags::paused) ? YES : NO;
        t.sequential = (st.flags & lt::torrent_flags::sequential_download) ? YES : NO;
        t.knownPeers = st.list_peers;
        t.connecting = std::max(0, st.num_connections - st.num_peers);
        t.trackers = (int)h.trackers().size();
        t.trackersAnswered = (int)_trackersAnswered[hash].size();
        int failed = 0;   // a tracker that answered on any connection is not "failed"
        for (auto const &[url, msg] : _trackersFailed[hash]) if (!_trackersAnswered[hash].count(url)) failed++;
        t.trackersFailed = failed;
        t.peersFromDHT = _dhtPeers[hash];
        for (auto const &[url, msg] : _trackersFailed[hash]) {
            if (!_trackersAnswered[hash].count(url)) { t.trackerError = str(msg); break; }
        }
        t.addedTime = (NSTimeInterval)st.added_time;
        t.completedTime = (NSTimeInterval)st.completed_time;
        if (auto ti = h.torrent_file()) {
            t.totalSize = ti->total_size();
            t.fileCount = ti->num_files();
            lt::file_storage const &fs = ti->layout();
            std::vector<lt::download_priority_t> prios = h.get_file_priorities();
            int64_t chosen = 0;
            for (lt::file_index_t i(0); i < fs.end_file(); ++i) {
                int n = static_cast<int>(i);
                if (fs.pad_file_at(i)) continue;
                if (n >= (int)prios.size() || prios[n] != lt::dont_download) chosen += fs.file_size(i);
            }
            t.chosenSize = chosen;
        }
        if (st.errc) {
            t.state = TBStateError;
            t.errorMessage = str(st.errc.message());
        } else if (t.isPaused && st.has_metadata && st.total_wanted == 0) {
            t.state = TBStateWaitingToStart;
        } else if (t.isPaused && (st.flags & lt::torrent_flags::auto_managed) && !st.is_finished) {
            t.state = TBStateQueued;   // paused by the queue, not by the person
        } else if (t.isPaused) {
            t.state = TBStatePaused;
        } else {
            switch (st.state) {
                case lt::torrent_status::checking_files: t.state = TBStateCheckingFiles; break;
                case lt::torrent_status::downloading_metadata: t.state = TBStateGettingInfo; break;
                case lt::torrent_status::downloading: t.state = TBStateDownloading; break;
                case lt::torrent_status::finished: t.state = TBStateFinished; break;
                case lt::torrent_status::seeding: t.state = TBStateSeeding; break;
                case lt::torrent_status::checking_resume_data: t.state = TBStateCheckingResume; break;
                default: t.state = TBStateDownloading; break;
            }
        }
        [out addObject:t];
    }
    return out;
}

- (NSArray<TBFile *> *)filesForTorrent:(NSString *)infoHash {
    auto it = _handles.find(infoHash.UTF8String);
    if (it == _handles.end() || !it->second.is_valid()) return @[];
    lt::torrent_handle const &h = it->second;
    auto ti = h.torrent_file();
    if (!ti) return @[];
    lt::file_storage const &fs = ti->layout();
    std::vector<std::int64_t> progress = h.file_progress(lt::torrent_handle::piece_granularity);
    std::vector<lt::download_priority_t> prios = h.get_file_priorities();
    NSMutableArray *out = [NSMutableArray new];
    for (lt::file_index_t i(0); i < fs.end_file(); ++i) {
        if (fs.pad_file_at(i)) continue;
        int n = static_cast<int>(i);
        TBFile *f = [TBFile new];
        f.index = n;
        f.path = str(fs.file_path(i));
        f.size = fs.file_size(i);
        f.done = n < (int)progress.size() ? progress[n] : 0;
        f.wanted = n < (int)prios.size() ? prios[n] != lt::dont_download : YES;
        [out addObject:f];
    }
    return out;
}

#pragma mark Actions

- (lt::torrent_handle const *)handleFor:(NSString *)infoHash {
    auto it = _handles.find(infoHash.UTF8String);
    if (it == _handles.end() || !it->second.is_valid()) return nullptr;
    return &it->second;
}

- (void)pause:(NSString *)infoHash {
    if (auto h = [self handleFor:infoHash]) {
        h->unset_flags(lt::torrent_flags::auto_managed);
        h->pause(lt::torrent_handle::graceful_pause);
        h->save_resume_data(lt::torrent_handle::save_info_dict);
    }
}

- (void)resume:(NSString *)infoHash {
    if (auto h = [self handleFor:infoHash]) {
        h->set_flags(lt::torrent_flags::auto_managed);
        h->resume();
    }
}

- (void)remove:(NSString *)infoHash deleteFiles:(BOOL)deleteFiles {
    auto it = _handles.find(infoHash.UTF8String);
    if (it == _handles.end()) return;
    _session->remove_torrent(it->second, deleteFiles ? lt::session::delete_files : lt::remove_flags_t{});
    _pickFiles.erase(it->first);
    _trackersAnswered.erase(it->first);
    _trackersFailed.erase(it->first);
    _dhtPeers.erase(it->first);
    [[NSFileManager defaultManager] removeItemAtPath:[self resumeFileFor:it->first] error:nil];
    _handles.erase(it);
}

- (void)setWanted:(NSArray<NSNumber *> *)wantedFileIndexes forTorrent:(NSString *)infoHash {
    auto h = [self handleFor:infoHash];
    if (!h) return;
    auto ti = h->torrent_file();
    if (!ti) return;
    std::vector<lt::download_priority_t> prios(static_cast<size_t>(ti->num_files()), lt::dont_download);
    for (NSNumber *n in wantedFileIndexes) {
        int i = n.intValue;
        if (i >= 0 && i < (int)prios.size()) prios[i] = lt::default_priority;
    }
    h->prioritize_files(prios);
    h->save_resume_data(lt::torrent_handle::save_info_dict);
}

- (void)startAll:(NSString *)infoHash {
    auto h = [self handleFor:infoHash];
    if (!h) return;
    _pickFiles.erase(infoHash.UTF8String);
    if (auto ti = h->torrent_file()) {
        std::vector<lt::download_priority_t> all(static_cast<size_t>(ti->num_files()), lt::default_priority);
        h->prioritize_files(all);
    }
    h->set_flags(lt::torrent_flags::auto_managed);
    h->resume();
    h->save_resume_data(lt::torrent_handle::save_info_dict);
}

- (void)setSequential:(BOOL)on forTorrent:(NSString *)infoHash {
    if (auto h = [self handleFor:infoHash]) {
        if (on) h->set_flags(lt::torrent_flags::sequential_download);
        else h->unset_flags(lt::torrent_flags::sequential_download);
    }
}

- (void)recheck:(NSString *)infoHash {
    if (auto h = [self handleFor:infoHash]) h->force_recheck();
}

#pragma mark Playing while downloading

- (nullable NSString *)diskPathForFile:(int)file inTorrent:(NSString *)infoHash {
    auto h = [self handleFor:infoHash];
    if (!h) return nil;
    auto ti = h->torrent_file();
    if (!ti || file < 0 || file >= ti->num_files()) return nil;
    std::string root = h->status(lt::torrent_handle::query_save_path).save_path;
    return str(root + "/" + ti->layout().file_path(lt::file_index_t(file)));
}

- (int64_t)sizeOfFile:(int)file inTorrent:(NSString *)infoHash {
    auto h = [self handleFor:infoHash];
    auto ti = h ? h->torrent_file() : nullptr;
    if (!ti || file < 0 || file >= ti->num_files()) return 0;
    return ti->layout().file_size(lt::file_index_t(file));
}

- (int64_t)contiguousBytesInFile:(int)file inTorrent:(NSString *)infoHash from:(int64_t)offset {
    auto h = [self handleFor:infoHash];
    auto ti = h ? h->torrent_file() : nullptr;
    if (!ti || file < 0 || file >= ti->num_files()) return 0;
    lt::file_storage const &fs = ti->layout();
    lt::file_index_t fi(file);
    int64_t size = fs.file_size(fi);
    if (offset < 0 || offset >= size) return 0;
    int64_t plen = fs.piece_length(), base = fs.file_offset(fi);
    int64_t absStart = base + offset, absEnd = base + size;
    int64_t pos = absStart;
    while (pos < absEnd) {
        int piece = (int)(pos / plen);
        if (piece >= ti->num_pieces() || !h->have_piece(lt::piece_index_t(piece))) break;
        pos = std::min(absEnd, (int64_t)(piece + 1) * plen);
    }
    return pos - absStart;
}

- (void)prioritizeRange:(int64_t)length from:(int64_t)offset inFile:(int)file ofTorrent:(NSString *)infoHash {
    auto h = [self handleFor:infoHash];
    auto ti = h ? h->torrent_file() : nullptr;
    if (!ti || file < 0 || file >= ti->num_files()) return;
    lt::file_storage const &fs = ti->layout();
    lt::file_index_t fi(file);
    int64_t size = fs.file_size(fi);
    if (offset < 0 || offset >= size || length <= 0) return;
    // The file has to be wanted at all, or its pieces never download.
    if (h->file_priority(fi) == lt::dont_download) h->file_priority(fi, lt::default_priority);
    int64_t plen = fs.piece_length(), base = fs.file_offset(fi);
    int first = (int)((base + offset) / plen);
    int last = (int)((base + std::min(size, offset + length) - 1) / plen);
    int rank = 0;
    for (int p = first; p <= last && p < ti->num_pieces(); p++, rank++) {
        if (h->have_piece(lt::piece_index_t(p))) continue;
        // Top priority so nothing else is fetched first, and a deadline so the
        // nearest piece comes first among them.
        h->piece_priority(lt::piece_index_t(p), lt::top_priority);
        h->set_piece_deadline(lt::piece_index_t(p), 150 + rank * 100);
    }
}

- (void)clearPlaybackDeadlinesForTorrent:(NSString *)infoHash {
    if (auto h = [self handleFor:infoHash]) {
        h->clear_piece_deadlines();
        h->prioritize_files(h->get_file_priorities());   // piece priorities back to what the files say
    }
}

- (NSArray<NSNumber *> *)availabilityMapOfFile:(int)file inTorrent:(NSString *)infoHash buckets:(int)buckets {
    NSMutableArray *out = [NSMutableArray new];
    auto h = [self handleFor:infoHash];
    auto ti = h ? h->torrent_file() : nullptr;
    if (!ti || file < 0 || file >= ti->num_files() || buckets <= 0) return out;
    lt::file_storage const &fs = ti->layout();
    lt::file_index_t fi(file);
    int64_t size = fs.file_size(fi), plen = fs.piece_length(), base = fs.file_offset(fi);
    if (size <= 0) return out;
    lt::torrent_status st = h->status(lt::torrent_handle::query_pieces);
    for (int b = 0; b < buckets; b++) {
        int64_t s = size * b / buckets, e = std::max(s + 1, size * (b + 1) / buckets);
        int64_t have = 0;
        for (int64_t pos = base + s; pos < base + e;) {
            int piece = (int)(pos / plen);
            int64_t next = std::min(base + e, (int64_t)(piece + 1) * plen);
            if (piece < ti->num_pieces() && st.pieces.get_bit(lt::piece_index_t(piece))) have += next - pos;
            pos = next;
        }
        [out addObject:@((double)have / (double)(e - s))];
    }
    return out;
}

- (void)connectPeer:(NSString *)host port:(int)port forTorrent:(NSString *)infoHash {
    auto h = [self handleFor:infoHash];
    if (!h) return;
    lt::error_code ec;
    lt::address a = lt::make_address(host.UTF8String, ec);
    if (!ec) h->connect_peer(lt::tcp::endpoint(a, (unsigned short)port));
}

- (void)setUploadLimit:(int)bytesPerSecond forTorrent:(NSString *)infoHash {
    if (auto h = [self handleFor:infoHash]) h->set_upload_limit(bytesPerSecond);
}

- (NSArray<TBPeer *> *)peersForTorrent:(NSString *)infoHash {
    NSMutableArray *out = [NSMutableArray new];
    auto h = [self handleFor:infoHash];
    if (!h) return out;
    std::vector<lt::peer_info> peers;
    h->get_peer_info(peers);
    std::sort(peers.begin(), peers.end(), [](lt::peer_info const &a, lt::peer_info const &b) {
        return (a.down_speed + a.up_speed) > (b.down_speed + b.up_speed);
    });
    for (auto const &p : peers) {
        // Only peers that are really connected, not ones still being dialled.
        if (p.flags & (lt::peer_info::connecting | lt::peer_info::handshake)) continue;
        TBPeer *t = [TBPeer new];
        t.address = str(p.ip.address().to_string());
        t.client = str(p.client);
        t.downRate = p.down_speed;
        t.upRate = p.up_speed;
        t.progress = p.progress;
        t.isSeed = (p.flags & lt::peer_info::seed) ? YES : NO;
        t.weConnected = (p.flags & lt::peer_info::local_connection) ? YES : NO;
        [out addObject:t];
    }
    return out;
}

- (nullable TBPieceMap *)pieceMapForTorrent:(NSString *)infoHash buckets:(int)buckets {
    auto h = [self handleFor:infoHash];
    auto ti = h ? h->torrent_file() : nullptr;
    if (!ti || buckets <= 0) return nil;
    int n = ti->num_pieces();
    if (n <= 0) return nil;
    lt::torrent_status st = h->status(lt::torrent_handle::query_pieces);
    std::vector<lt::download_priority_t> prios = h->get_piece_priorities();
    int cells = std::min(buckets, n);
    NSMutableArray *have = [NSMutableArray new], *wanted = [NSMutableArray new];
    for (int c = 0; c < cells; c++) {
        int a = (int)((int64_t)n * c / cells), b = std::max(a + 1, (int)((int64_t)n * (c + 1) / cells));
        int hv = 0, wn = 0;
        for (int i = a; i < b && i < n; i++) {
            if (st.pieces.get_bit(lt::piece_index_t(i))) hv++;
            if (i >= (int)prios.size() || prios[i] != lt::dont_download) wn++;
        }
        [have addObject:@((double)hv / (b - a))];
        [wanted addObject:@((double)wn / (b - a))];
    }
    TBPieceMap *m = [TBPieceMap new];
    m.pieceCount = n; m.have = have; m.wanted = wanted;
    return m;
}

- (void)reannounce:(NSString *)infoHash {
    if (auto h = [self handleFor:infoHash]) h->force_reannounce();
}

- (nullable TBHealth *)healthForTorrent:(NSString *)infoHash {
    auto h = [self handleFor:infoHash];
    if (!h) return nil;
    auto ti = h->torrent_file();
    if (!ti) return nil;
    lt::torrent_status st = h->status(lt::torrent_handle::query_pieces);
    if (st.errc || (st.flags & lt::torrent_flags::paused)) return nil;
    int n = ti->num_pieces();
    std::vector<int> avail;
    h->piece_availability(avail);
    if ((int)avail.size() != n) return nil;   // not downloading (checking, seeding, ...)
    std::vector<lt::download_priority_t> prios = h->get_piece_priorities();
    TBHealth *out = [TBHealth new];
    out.pieceCount = n;
    out.peersChecked = st.num_peers;
    out.copies = st.distributed_copies;
    int missing = 0, none = 0;
    bool anyComplete = false;
    for (int i = 0; i < n; i++) {
        bool have = st.pieces.get_bit(lt::piece_index_t(i));
        bool wanted = i >= (int)prios.size() || prios[i] != lt::dont_download;
        if (!have && wanted) {
            missing++;
            if (avail[i] == 0) none++;
        }
    }
    anyComplete = st.num_seeds > 0;
    out.missingWanted = missing;
    out.missingUnadvertised = none;
    out.completeSourceSeen = anyComplete;
    return out;
}

- (void)useExistingFiles:(NSString *)folder forTorrent:(NSString *)infoHash {
    if (auto h = [self handleFor:infoHash]) {
        // A paused torrent does not check files. Let it check, then pause again by itself.
        bool wasPaused = (h->flags() & lt::torrent_flags::paused) ? true : false;
        h->move_storage(folder.UTF8String, lt::move_flags_t::reset_save_path);   // forget the old place, check the new one
        if (wasPaused) {
            h->set_flags(lt::torrent_flags::stop_when_ready);
            h->resume();
        }
        h->save_resume_data(lt::torrent_handle::save_info_dict);
    }
}

- (nullable NSString *)magnetLinkFor:(NSString *)infoHash {
    auto h = [self handleFor:infoHash];
    if (!h) return nil;
    lt::add_torrent_params atp;
    atp.info_hashes = h->info_hashes();
    atp.name = h->status(lt::torrent_handle::query_name).name;
    for (auto const &ae : h->trackers()) atp.trackers.push_back(ae.url);
    return str(lt::make_magnet_uri(atp));
}

- (void)setDownloadLimit:(int)down uploadLimit:(int)up {
    lt::settings_pack pack;
    pack.set_int(lt::settings_pack::download_rate_limit, down);
    pack.set_int(lt::settings_pack::upload_rate_limit, up);
    _session->apply_settings(pack);
}

- (void)setListenPort:(int)port {
    lt::settings_pack pack;
    std::string iface = "0.0.0.0:" + std::to_string(port) + ",[::]:" + std::to_string(port);
    pack.set_str(lt::settings_pack::listen_interfaces, iface);
    _session->apply_settings(pack);
}

- (int)listenPort { return _session ? _session->listen_port() : 0; }

#pragma mark Saving

- (void)saveAllAndWait:(NSTimeInterval)timeout {
    _savesPending = 0;
    for (auto const &[hash, h] : _handles) {
        if (!h.is_valid()) continue;
        h.save_resume_data(lt::torrent_handle::save_info_dict | lt::torrent_handle::flush_disk_cache);
        _savesPending++;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (_savesPending > 0 && [deadline timeIntervalSinceNow] > 0) {
        _session->wait_for_alert(lt::milliseconds(100));
        [self drainAlerts];
    }
    std::vector<char> state = lt::write_session_params_buf(_session->session_state(lt::session::save_dht_state),
                                                           lt::session::save_dht_state);
    [[NSData dataWithBytes:state.data() length:state.size()] writeToFile:[self sessionFile] atomically:YES];
}

@end
