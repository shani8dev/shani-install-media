# Shani *arr media stack (optional)

This is an **optional** Podman Compose stack for the gamescope edition. It is
not started by default. Most people run the *arr server and Jellyfin on a
separate always-on NAS/home server, and keep the gamescope console as a
**client** (Kodi / Jellyfin Media Player). Use this only for an all-in-one box.

## Enable

```sh
sudo systemctl enable --now shani-arr.service
sudo systemctl status shani-arr.service
```

## Web UIs (host ports)

| App         | Port |
|-------------|------|
| Radarr      | 7878 |
| Sonarr      | 8989 |
| Prowlarr    | 9696 |
| Bazarr      | 6767 |
| qBittorrent | 8080 |
| Jellyfin    | 8096 |

## Paths

- Library: `/mnt/media` (mounted into the containers as `/media`)
- Downloads: `/mnt/downloads` (mounted as `/downloads`)
- Config: `/var/lib/shani-arr/<app>` (persistent across image updates)

## Notes

- The linuxserver images run as PUID/PGID 1000 (the gamescope user). If the
  gamescope UID differs, edit `PUID`/`PGID` in `podman-compose.yml`.
- The *arr apps need their indexers, API keys, and download client configured
  through their web UIs on first start.
- Jellyfin's library points at `/media`; Kodi can play the same files from
  `/mnt/media` (the Flatpak has access via the gamescope overrides).
- If you run the Flatpak qBittorrent and the container qBittorrent together,
  change one of their Web UI ports (both default to 8080).
- Most people should run this on a server, not on the console. The console's
  job is playback (Kodi / Jellyfin Media Player), not media management.