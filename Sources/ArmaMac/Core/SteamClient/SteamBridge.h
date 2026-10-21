#ifndef ARMAMAC_STEAM_BRIDGE_H
#define ARMAMAC_STEAM_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

// A thin C bridge to a running Steam client, reached through the flat entry points that
// libsteam_api.dylib exports. No Steamworks SDK headers or import library required.

#pragma mark - Session

/// Opens a Steam API session for `appID`. Safe to call repeatedly; reference counted.
///
/// While a session is open Steam considers the app to be running the game, so callers
/// should close it once their work is done.
bool armamac_steam_session_begin(const char *dylibPath, uint32_t appID);

/// Releases one reference; the session closes when the last one goes away.
void armamac_steam_session_end(void);

/// Closes the session regardless of outstanding references.
void armamac_steam_session_end_all(void);

bool armamac_steam_session_active(void);

/// Pumps Steam's callbacks. Call periodically while a session is open.
void armamac_steam_run_callbacks(void);

/// Describes the most recent failure. Valid until the next call.
const char *armamac_steam_last_error(void);

#pragma mark - Server list

/// One server as reported by the Steam client's matchmaking service.
typedef struct {
    uint32_t ip;          // host byte order
    uint16_t gamePort;
    uint16_t queryPort;
    int32_t ping;         // milliseconds, as measured by Steam
    int32_t players;
    int32_t maxPlayers;
    int32_t botPlayers;
    bool passwordProtected;
    bool secure;          // VAC
    uint32_t appID;
    char name[64];
    char map[32];
    char gameDescription[64];
    char gameTags[128];   // Arma packs its keyword string in here
} ArmaMacSteamServer;

typedef enum {
    ArmaMacSteamErrorDylibNotLoaded = -1,
    ArmaMacSteamErrorMissingSymbols = -2,
    ArmaMacSteamErrorInitFailed = -3,
    ArmaMacSteamErrorNoInterface = -4,
    ArmaMacSteamErrorRequestFailed = -5,
} ArmaMacSteamError;

/// Enumerates the internet server list for `appID`. Returns the server count, or a negative
/// `ArmaMacSteamError`. On success the caller owns `outServers` and frees it with
/// `armamac_steam_free`.
int32_t armamac_steam_fetch_servers(const char *dylibPath,
                                    uint32_t appID,
                                    double timeoutSeconds,
                                    ArmaMacSteamServer **outServers);

void armamac_steam_free(ArmaMacSteamServer *servers);

#pragma mark - Workshop

/// Steam's `EItemState` bit flags.
typedef enum {
    ArmaMacWorkshopStateNone = 0,
    ArmaMacWorkshopStateSubscribed = 1,
    ArmaMacWorkshopStateLegacyItem = 2,
    ArmaMacWorkshopStateInstalled = 4,
    ArmaMacWorkshopStateNeedsUpdate = 8,
    ArmaMacWorkshopStateDownloading = 16,
    ArmaMacWorkshopStateDownloadPending = 32,
} ArmaMacWorkshopState;

typedef struct {
    uint64_t publishedFileID;
    uint32_t state;
    uint64_t bytesDownloaded;
    uint64_t bytesTotal;
    uint64_t sizeOnDisk;
    uint32_t timestamp;
    char installPath[1024];
} ArmaMacWorkshopItemStatus;

/// Subscribes the signed-in account to a Workshop item. Steam then downloads it itself,
/// exactly as if the user had pressed Subscribe on the Workshop page.
bool armamac_steam_subscribe_item(uint64_t publishedFileID);

bool armamac_steam_unsubscribe_item(uint64_t publishedFileID);

/// Nudges Steam to (re)download an item it already knows about.
bool armamac_steam_download_item(uint64_t publishedFileID, bool highPriority);

/// Current state, download progress and install location for one item.
bool armamac_steam_item_status(uint64_t publishedFileID, ArmaMacWorkshopItemStatus *out);

#endif /* ARMAMAC_STEAM_BRIDGE_H */
