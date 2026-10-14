#include "bifrost_plugin.h"

BIFROST_EXPORT bifrost_status bifrost_plugin_init(const bifrost_host *host, bifrost_plugin *plugin) {
    (void)host;
    (void)plugin;
    return BIFROST_STATUS_FAILED;
}
