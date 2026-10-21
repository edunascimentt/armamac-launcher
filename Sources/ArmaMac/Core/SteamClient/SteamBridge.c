#include "SteamBridge.h"

#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// All access goes through the flat C entry points libsteam_api.dylib exports, so the app
// needs no Steamworks SDK. The one piece of C++ ABI we cannot avoid is the response object
// the server-list request takes; see the fake vtable below.

typedef void *HServerListRequest;
typedef uint64_t SteamAPICall_t;

typedef struct {
    uint16_t connectionPort;  // host byte order
    uint16_t queryPort;
    uint32_t ip;
} servernetadr_t;

/// Mirrors the SDK's `gameserveritem_t`. Field order and types must match exactly.
typedef struct {
    servernetadr_t netAdr;
    int32_t ping;
    bool hadSuccessfulResponse;
    bool doNotRefresh;
    char gameDir[32];
    char map[32];
    char gameDescription[64];
    uint32_t appID;
    int32_t players;
    int32_t maxPlayers;
    int32_t botPlayers;
    bool password;
    bool secure;
    uint32_t timeLastPlayed;
    int32_t serverVersion;
    char serverName[64];
    char gameTags[128];
    uint64_t steamID;
} gameserveritem_t;

typedef struct {
    char key[256];
    char value[256];
} MatchMakingKeyValuePair_t;

typedef int (*PFN_InitFlat)(char *outErrMsg);
typedef void (*PFN_Void)(void);
typedef void *(*PFN_GetInterface)(void);
typedef HServerListRequest (*PFN_RequestInternet)(void *self, uint32_t app,
                                                  MatchMakingKeyValuePair_t **filters,
                                                  uint32_t filterCount, void *response);
typedef int32_t (*PFN_GetServerCount)(void *self, HServerListRequest request);
typedef gameserveritem_t *(*PFN_GetServerDetails)(void *self, HServerListRequest request, int index);
typedef bool (*PFN_IsRefreshing)(void *self, HServerListRequest request);
typedef void (*PFN_RequestOp)(void *self, HServerListRequest request);

typedef SteamAPICall_t (*PFN_SubscribeItem)(void *self, uint64_t publishedFileID);
typedef bool (*PFN_DownloadItem)(void *self, uint64_t publishedFileID, bool highPriority);
typedef uint32_t (*PFN_GetItemState)(void *self, uint64_t publishedFileID);
typedef bool (*PFN_GetItemDownloadInfo)(void *self, uint64_t publishedFileID,
                                        uint64_t *bytesDownloaded, uint64_t *bytesTotal);
typedef bool (*PFN_GetItemInstallInfo)(void *self, uint64_t publishedFileID, uint64_t *sizeOnDisk,
                                       char *folder, uint32_t folderSize, uint32_t *timestamp);

static struct {
    void *lib;
    int references;
    bool initialised;

    PFN_InitFlat initFlat;
    PFN_Void shutdown;
    PFN_Void runCallbacks;

    PFN_GetInterface getServers;
    PFN_RequestInternet requestInternet;
    PFN_GetServerCount getServerCount;
    PFN_GetServerDetails getServerDetails;
    PFN_IsRefreshing isRefreshing;
    PFN_RequestOp cancelQuery;
    PFN_RequestOp releaseRequest;

    PFN_GetInterface getUGC;
    PFN_SubscribeItem subscribeItem;
    PFN_SubscribeItem unsubscribeItem;
    PFN_DownloadItem downloadItem;
    PFN_GetItemState getItemState;
    PFN_GetItemDownloadInfo getItemDownloadInfo;
    PFN_GetItemInstallInfo getItemInstallInfo;
} g_steam;

static char g_lastError[1024] = {0};

static void set_error(const char *format, ...) {
    va_list args;
    va_start(args, format);
    vsnprintf(g_lastError, sizeof(g_lastError), format, args);
    va_end(args);
}

const char *armamac_steam_last_error(void) {
    return g_lastError[0] ? g_lastError : "no error";
}

void armamac_steam_free(ArmaMacSteamServer *servers) {
    free(servers);
}

#pragma mark - Session

static bool load_symbols(void) {
    void *lib = g_steam.lib;

    g_steam.initFlat = (PFN_InitFlat)dlsym(lib, "SteamAPI_InitFlat");
    g_steam.shutdown = (PFN_Void)dlsym(lib, "SteamAPI_Shutdown");
    g_steam.runCallbacks = (PFN_Void)dlsym(lib, "SteamAPI_RunCallbacks");

    g_steam.getServers = (PFN_GetInterface)dlsym(lib, "SteamAPI_SteamMatchmakingServers_v002");
    g_steam.requestInternet =
        (PFN_RequestInternet)dlsym(lib, "SteamAPI_ISteamMatchmakingServers_RequestInternetServerList");
    g_steam.getServerCount =
        (PFN_GetServerCount)dlsym(lib, "SteamAPI_ISteamMatchmakingServers_GetServerCount");
    g_steam.getServerDetails =
        (PFN_GetServerDetails)dlsym(lib, "SteamAPI_ISteamMatchmakingServers_GetServerDetails");
    g_steam.isRefreshing =
        (PFN_IsRefreshing)dlsym(lib, "SteamAPI_ISteamMatchmakingServers_IsRefreshing");
    g_steam.cancelQuery =
        (PFN_RequestOp)dlsym(lib, "SteamAPI_ISteamMatchmakingServers_CancelQuery");
    g_steam.releaseRequest =
        (PFN_RequestOp)dlsym(lib, "SteamAPI_ISteamMatchmakingServers_ReleaseRequest");

    g_steam.getUGC = (PFN_GetInterface)dlsym(lib, "SteamAPI_SteamUGC_v020");
    if (!g_steam.getUGC) {
        // Older clients expose a different interface revision.
        g_steam.getUGC = (PFN_GetInterface)dlsym(lib, "SteamAPI_SteamUGC_v018");
    }
    g_steam.subscribeItem = (PFN_SubscribeItem)dlsym(lib, "SteamAPI_ISteamUGC_SubscribeItem");
    g_steam.unsubscribeItem = (PFN_SubscribeItem)dlsym(lib, "SteamAPI_ISteamUGC_UnsubscribeItem");
    g_steam.downloadItem = (PFN_DownloadItem)dlsym(lib, "SteamAPI_ISteamUGC_DownloadItem");
    g_steam.getItemState = (PFN_GetItemState)dlsym(lib, "SteamAPI_ISteamUGC_GetItemState");
    g_steam.getItemDownloadInfo =
        (PFN_GetItemDownloadInfo)dlsym(lib, "SteamAPI_ISteamUGC_GetItemDownloadInfo");
    g_steam.getItemInstallInfo =
        (PFN_GetItemInstallInfo)dlsym(lib, "SteamAPI_ISteamUGC_GetItemInstallInfo");

    return g_steam.initFlat && g_steam.getServers && g_steam.requestInternet
        && g_steam.getServerCount && g_steam.getServerDetails;
}

bool armamac_steam_session_begin(const char *dylibPath, uint32_t appID) {
    g_lastError[0] = '\0';

    if (g_steam.initialised) {
        g_steam.references++;
        return true;
    }
    if (!dylibPath) {
        set_error("no libsteam_api.dylib path");
        return false;
    }

    // Steam needs to know which app is asking before the API is initialised.
    char appIDText[16];
    snprintf(appIDText, sizeof(appIDText), "%u", appID);
    setenv("SteamAppId", appIDText, 1);
    setenv("SteamGameId", appIDText, 1);

    if (!g_steam.lib) {
        g_steam.lib = dlopen(dylibPath, RTLD_NOW | RTLD_LOCAL);
        if (!g_steam.lib) {
            set_error("could not load %s: %s", dylibPath, dlerror());
            return false;
        }
        if (!load_symbols()) {
            set_error("libsteam_api.dylib is missing the flat entry points");
            dlclose(g_steam.lib);
            g_steam.lib = NULL;
            return false;
        }
    }

    char initError[1024] = {0};
    int result = g_steam.initFlat(initError);
    if (result != 0) {
        // 2 == k_ESteamAPIInitResult_NoSteamClient, by far the most common cause.
        if (result == 2) {
            set_error("Steam is not running. Start Steam and sign in, then try again.");
        } else {
            set_error("Steam refused the connection (code %d)%s%s", result,
                      initError[0] ? ": " : "", initError[0] ? initError : "");
        }
        return false;
    }

    g_steam.initialised = true;
    g_steam.references = 1;
    return true;
}

void armamac_steam_session_end(void) {
    if (!g_steam.initialised) { return; }
    if (--g_steam.references > 0) { return; }
    armamac_steam_session_end_all();
}

void armamac_steam_session_end_all(void) {
    if (!g_steam.initialised) { return; }
    if (g_steam.shutdown) { g_steam.shutdown(); }
    g_steam.initialised = false;
    g_steam.references = 0;
}

bool armamac_steam_session_active(void) {
    return g_steam.initialised;
}

void armamac_steam_run_callbacks(void) {
    if (g_steam.initialised && g_steam.runCallbacks) { g_steam.runCallbacks(); }
}

#pragma mark - Server list

// `ISteamMatchmakingServerListResponse` is an abstract class with exactly three virtual
// methods and no virtual destructor. Under the Itanium C++ ABI an instance is just a
// pointer to its vtable's address point, so a struct holding a pointer into an array of
// function pointers is indistinguishable from a real C++ object as far as Steam is
// concerned. The slots before the address point hold offset-to-top and RTTI, which Steam
// never reads here; they are left present and zeroed.
typedef struct {
    void **vtable;
    volatile int32_t refreshComplete;
} FakeResponse;

static void on_server_responded(void *self, HServerListRequest request, int index) {
    (void)self; (void)request; (void)index;
}

static void on_server_failed(void *self, HServerListRequest request, int index) {
    (void)self; (void)request; (void)index;
}

static void on_refresh_complete(void *self, HServerListRequest request, int response) {
    (void)request;
    FakeResponse *me = (FakeResponse *)self;
    if (me) { me->refreshComplete = response; }
}

int32_t armamac_steam_fetch_servers(const char *dylibPath,
                                    uint32_t appID,
                                    double timeoutSeconds,
                                    ArmaMacSteamServer **outServers) {
    if (outServers) { *outServers = NULL; }
    if (!outServers) {
        set_error("invalid arguments");
        return ArmaMacSteamErrorDylibNotLoaded;
    }

    bool openedHere = !armamac_steam_session_active();
    if (!armamac_steam_session_begin(dylibPath, appID)) {
        return g_steam.lib ? ArmaMacSteamErrorInitFailed : ArmaMacSteamErrorDylibNotLoaded;
    }

    void *servers = g_steam.getServers();
    if (!servers) {
        set_error("Steam did not provide a matchmaking interface");
        if (openedHere) { armamac_steam_session_end(); }
        return ArmaMacSteamErrorNoInterface;
    }

    void *vtableSlots[8];
    memset(vtableSlots, 0, sizeof(vtableSlots));
    vtableSlots[2] = (void *)on_server_responded;
    vtableSlots[3] = (void *)on_server_failed;
    vtableSlots[4] = (void *)on_refresh_complete;

    FakeResponse response;
    response.vtable = &vtableSlots[2];
    response.refreshComplete = -1;

    HServerListRequest request = g_steam.requestInternet(servers, appID, NULL, 0, &response);
    if (!request) {
        set_error("Steam rejected the server list request");
        if (openedHere) { armamac_steam_session_end(); }
        return ArmaMacSteamErrorRequestFailed;
    }

    // Poll until Steam says the refresh is done, or we run out of patience. The list keeps
    // growing while this runs, so a longer timeout simply yields more servers.
    const int pollIntervalMicroseconds = 100 * 1000;
    const int maxPolls = (int)((timeoutSeconds * 1000000.0) / pollIntervalMicroseconds);
    int stableCount = 0;
    int32_t previousCount = 0;

    for (int poll = 0; poll < maxPolls; poll++) {
        armamac_steam_run_callbacks();
        usleep(pollIntervalMicroseconds);

        int32_t count = g_steam.getServerCount(servers, request);
        if (response.refreshComplete >= 0) { break; }
        if (g_steam.isRefreshing && !g_steam.isRefreshing(servers, request) && count > 0) { break; }

        // Stop once the list stops growing for a couple of seconds.
        if (count == previousCount && count > 0) {
            if (++stableCount >= 20) { break; }
        } else {
            stableCount = 0;
            previousCount = count;
        }
    }

    int32_t count = g_steam.getServerCount(servers, request);
    if (count < 0) { count = 0; }

    ArmaMacSteamServer *results = NULL;
    int32_t written = 0;
    if (count > 0) {
        results = (ArmaMacSteamServer *)calloc((size_t)count, sizeof(ArmaMacSteamServer));
        if (!results) {
            set_error("out of memory for %d servers", count);
            if (g_steam.cancelQuery) { g_steam.cancelQuery(servers, request); }
            if (g_steam.releaseRequest) { g_steam.releaseRequest(servers, request); }
            if (openedHere) { armamac_steam_session_end(); }
            return ArmaMacSteamErrorRequestFailed;
        }

        for (int32_t index = 0; index < count; index++) {
            gameserveritem_t *item = g_steam.getServerDetails(servers, request, index);
            if (!item) { continue; }
            // Guard against a layout drift in a future SDK handing us nonsense.
            if (item->appID != appID) { continue; }

            ArmaMacSteamServer *out = &results[written++];
            out->ip = item->netAdr.ip;
            out->gamePort = item->netAdr.connectionPort;
            out->queryPort = item->netAdr.queryPort;
            out->ping = item->ping;
            out->players = item->players;
            out->maxPlayers = item->maxPlayers;
            out->botPlayers = item->botPlayers;
            out->passwordProtected = item->password;
            out->secure = item->secure;
            out->appID = item->appID;

            memcpy(out->name, item->serverName, sizeof(out->name));
            out->name[sizeof(out->name) - 1] = '\0';
            memcpy(out->map, item->map, sizeof(out->map));
            out->map[sizeof(out->map) - 1] = '\0';
            memcpy(out->gameDescription, item->gameDescription, sizeof(out->gameDescription));
            out->gameDescription[sizeof(out->gameDescription) - 1] = '\0';
            memcpy(out->gameTags, item->gameTags, sizeof(out->gameTags));
            out->gameTags[sizeof(out->gameTags) - 1] = '\0';
        }
    }

    if (g_steam.cancelQuery) { g_steam.cancelQuery(servers, request); }
    if (g_steam.releaseRequest) { g_steam.releaseRequest(servers, request); }
    // Close only if this call opened the session; a download in progress keeps it alive.
    if (openedHere) { armamac_steam_session_end(); }

    *outServers = results;
    return written;
}

#pragma mark - Workshop

bool armamac_steam_subscribe_item(uint64_t publishedFileID) {
    if (!g_steam.initialised || !g_steam.getUGC || !g_steam.subscribeItem) {
        set_error("no Steam session for the Workshop request");
        return false;
    }
    void *ugc = g_steam.getUGC();
    if (!ugc) {
        set_error("Steam did not provide a Workshop interface");
        return false;
    }
    g_steam.subscribeItem(ugc, publishedFileID);
    // Subscribing queues the download in the Steam client; nudge it in case the item was
    // already subscribed but never fetched.
    if (g_steam.downloadItem) { g_steam.downloadItem(ugc, publishedFileID, true); }
    return true;
}

bool armamac_steam_unsubscribe_item(uint64_t publishedFileID) {
    if (!g_steam.initialised || !g_steam.getUGC || !g_steam.unsubscribeItem) { return false; }
    void *ugc = g_steam.getUGC();
    if (!ugc) { return false; }
    g_steam.unsubscribeItem(ugc, publishedFileID);
    return true;
}

bool armamac_steam_download_item(uint64_t publishedFileID, bool highPriority) {
    if (!g_steam.initialised || !g_steam.getUGC || !g_steam.downloadItem) { return false; }
    void *ugc = g_steam.getUGC();
    if (!ugc) { return false; }
    return g_steam.downloadItem(ugc, publishedFileID, highPriority);
}

bool armamac_steam_item_status(uint64_t publishedFileID, ArmaMacWorkshopItemStatus *out) {
    if (!out) { return false; }
    memset(out, 0, sizeof(*out));
    out->publishedFileID = publishedFileID;

    if (!g_steam.initialised || !g_steam.getUGC || !g_steam.getItemState) { return false; }
    void *ugc = g_steam.getUGC();
    if (!ugc) { return false; }

    out->state = g_steam.getItemState(ugc, publishedFileID);

    if (g_steam.getItemDownloadInfo) {
        uint64_t downloaded = 0;
        uint64_t total = 0;
        if (g_steam.getItemDownloadInfo(ugc, publishedFileID, &downloaded, &total)) {
            out->bytesDownloaded = downloaded;
            out->bytesTotal = total;
        }
    }

    if (g_steam.getItemInstallInfo && (out->state & ArmaMacWorkshopStateInstalled)) {
        uint64_t sizeOnDisk = 0;
        uint32_t timestamp = 0;
        char folder[1024] = {0};
        if (g_steam.getItemInstallInfo(ugc, publishedFileID, &sizeOnDisk, folder,
                                       (uint32_t)sizeof(folder), &timestamp)) {
            out->sizeOnDisk = sizeOnDisk;
            out->timestamp = timestamp;
            memcpy(out->installPath, folder, sizeof(out->installPath));
            out->installPath[sizeof(out->installPath) - 1] = '\0';
        }
    }

    return true;
}
