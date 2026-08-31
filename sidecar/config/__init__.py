"""Config subsystem — ~/.subagent/config.json is the single source of truth."""
from sidecar.config.store import (
    get_config, get_config_path,
    data_root, projects_root, plugins_root,
    reload_config,
)
