# BookStack Deployment (Docker Compose)

This repo holds a maintainable BookStack deployment: bind-mounted app data, daily backups, optional Nginx, and a small mobile theme.

## Files
- `docker-compose.yml` — BookStack + MariaDB with bind mounts, port bound to localhost, and theme volume.
- `.env.sample` — Copy to `.env` and fill in your values (do not commit `.env`).
- `scripts/backup_bookstack.sh` — DB + files backup with 14-day retention.
- `systemd/backup-bookstack.service` & `.timer` — Daily backup at 02:15.
- `nginx.bookstack.conf` — Example reverse-proxy to 127.0.0.1:8080 with HTTPS.
- `theme/bookstack.css` — Mobile polish, enabled via `APP_THEME=custom`.

## First-time Setup
1) Copy `.env.sample` to `.env` and set:
   - `APP_URL` to your public URL, e.g. `https://dnd.techlett.xyz`.
   - `APP_KEY` from your existing instance: `docker compose exec bookstack printenv APP_KEY`.
   - DB passwords as appropriate.

2) If migrating an existing container to bind mounts:
```
cd ~/bookstack
# Copy data out of the running container
docker compose cp bookstack:/var/www/bookstack/storage ./storage-tmp
docker compose cp bookstack:/var/www/bookstack/public/uploads ./uploads-tmp

# Stop old container set if needed
# docker compose down

# Put data into bind mounts
mv storage-tmp storage && mv uploads-tmp uploads

# Recreate & fix permissions
docker compose up -d --force-recreate
docker compose exec -u root bookstack chown -R www-data:www-data /var/www/bookstack/storage /var/www/bookstack/public/uploads

# Clear caches
docker compose exec bookstack php artisan config:clear && docker compose exec bookstack php artisan cache:clear
```

3) Optional Nginx
- Copy `nginx.bookstack.conf` to `/etc/nginx/sites-available/bookstack`, adjust `server_name` and SSL paths, then enable:
```
sudo cp nginx.bookstack.conf /etc/nginx/sites-available/bookstack
sudo ln -sf /etc/nginx/sites-available/bookstack /etc/nginx/sites-enabled/bookstack
sudo nginx -t && sudo systemctl reload nginx
```

4) Backups
- Install script & systemd units:
```
sudo install -m 0755 scripts/backup_bookstack.sh /usr/local/bin/backup_bookstack.sh
sudo cp systemd/backup-bookstack.service /etc/systemd/system/
sudo cp systemd/backup-bookstack.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now backup-bookstack.timer
```
- Test once:
```
sudo systemctl start backup-bookstack.service
sudo journalctl -u backup-bookstack.service -n 100 --no-pager
```
- Backups land in `./backups`. Consider adding offsite sync (e.g., `rclone`) to the script.

## Notes
- Do not commit `.env` or secrets. `.gitignore` excludes data & backups.
- The theme is mounted into `/var/www/bookstack/public/themes/custom`; ensure `APP_THEME=custom`.
- Port `8080` binds to `127.0.0.1` for reverse-proxy-only exposure.

