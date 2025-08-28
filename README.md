# BookStack Deployment (Docker Compose)

This repo holds a maintainable BookStack deployment: bind-mounted app data, automated Git snapshots of config + data (uploads, storage, DB dumps), optional Nginx, and a small mobile theme.

## Files
- `docker-compose.yml` — BookStack + MariaDB with bind mounts, port bound to localhost, and theme volume.
- `.env.sample` — Copy to `.env` and fill in your values (do not commit `.env`).
- `scripts/git_auto_push.sh` — Dumps DB into `db_dumps/`, stages uploads/storage, commits, and pushes.
- `systemd/git-backup.service` & `.timer` — Daily Git commit+push at 02:30.
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

4) Automatic Git commits/pushes (backup via Git)
- Configure your remote first (SSH recommended):
```
cd ~/bookstack
git remote add origin git@github.com:YOURUSER/YOURREPO.git
# or: git remote set-url origin git@github.com:YOURUSER/YOURREPO.git
git push -u origin $(git rev-parse --abbrev-ref HEAD)
```
- Install the wrapper and systemd units:
```
sudo install -m 0755 scripts/git_auto_push.sh /usr/local/bin/git_auto_push_bookstack
sudo cp systemd/git-backup.service /etc/systemd/system/
sudo cp systemd/git-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now git-backup.timer
```
- Test once and view logs:
```
sudo systemctl start git-backup.service
sudo journalctl -u git-backup.service -n 100 --no-pager
```
- Check schedule:
```
systemctl list-timers | grep git-backup
```

## Notes
- Git snapshots now include:
  - `uploads/` and `storage/` (except volatile cache/log paths ignored under `storage/`)
  - Daily DB dumps in `db_dumps/db_YYYY-MM-DD_HH-MM-SS.sql.gz` (keeps last 30)
- Do not commit `.env` or secrets. `.gitignore` excludes `.env` and `db/` (the MariaDB data directory). DB dumps contain your content (make your GitHub repo private unless you intend to publish it).
- The theme is mounted into `/var/www/bookstack/public/themes/custom`; ensure `APP_THEME=custom`.
- Port `8080` binds to `127.0.0.1` for reverse-proxy-only exposure.
