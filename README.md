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

### SSH Deploy Key (recommended for unattended pushes)
- Generate a dedicated key and add it to the repo as a Deploy key with write access:
```
ssh-keygen -t ed25519 -f /root/.ssh/dnd-bookstack -N "" -C "dnd-bookstack-deploy"
cat /root/.ssh/dnd-bookstack.pub  # paste into GitHub → Repo → Settings → Deploy keys → Allow write
printf "Host github.com\n  HostName github.com\n  User git\n  IdentityFile /root/.ssh/dnd-bookstack\n" >> /root/.ssh/config
chmod 600 /root/.ssh/dnd-bookstack /root/.ssh/config && chmod 644 /root/.ssh/dnd-bookstack.pub
ssh -T git@github.com  # should say authenticated, no shell access
git remote set-url origin git@github.com:YOURUSER/YOURREPO.git
```

### Seed data into the repo (first run)
If your repo does not yet contain `uploads/` and `storage/`, copy from the running app once, then commit:
```
docker compose cp bookstack:/var/www/bookstack/storage ./storage
docker compose cp bookstack:/var/www/bookstack/public/uploads ./uploads
git add -A && git commit -m "seed data" && git push
```

### How the backup works
- Runs daily at 02:30 by `git-backup.timer`.
- Creates a DB dump via `mariadb-dump` (or `mysqldump` fallback) inside the DB container to `db_dumps/db_YYYY-MM-DD_HH-MM-SS.sql.gz`.
- Stages changes in `uploads/`, `storage/` (ignoring cache/logs), and `db_dumps/`, commits with message `chore(backup): auto snapshot …`, then pushes to `origin` on the current branch.
- Keeps the last 30 dumps by modification time.

### Troubleshooting
- Compose file error: `no configuration file provided`
  - The script forces `-f /root/srv/projects/bookstack/docker-compose.yml` but verify it exists and matches your path.
  - Run interactive debug: `DEBUG=1 /usr/local/bin/git_auto_push_bookstack`.
- Dump tool missing: `mysqldump: not found`
  - The script prefers `mariadb-dump` and falls back to `mysqldump`. Ensure your DB container has one; otherwise switch to the official `mariadb` image or install client tools.
- Push/auth issues
  - Use SSH deploy key above and set the remote to `git@github.com:...`. Ensure `/root/.ssh/config` points to the key and host key is accepted.
- Docker availability
  - Service declares `Wants/After=docker.service`. Ensure the stack is running: `docker compose -f ./docker-compose.yml ps`.
- Wrong repo path
  - Unit uses `WorkingDirectory=/root/srv/projects/bookstack`. Update `systemd/git-backup.service` if your path differs.

### Change schedule
Edit `/etc/systemd/system/git-backup.timer` and adjust `OnCalendar=` (e.g., `hourly`), then:
```
sudo systemctl daemon-reload && sudo systemctl restart git-backup.timer
```

## Notes
- Git snapshots now include:
  - `uploads/` and `storage/` (except volatile cache/log paths ignored under `storage/`)
  - Daily DB dumps in `db_dumps/db_YYYY-MM-DD_HH-MM-SS.sql.gz` (keeps last 30)
- Do not commit `.env` or secrets. `.gitignore` excludes `.env` and `db/` (the MariaDB data directory). DB dumps contain your content (make your GitHub repo private unless you intend to publish it).
- The theme is mounted into `/var/www/bookstack/public/themes/custom`; ensure `APP_THEME=custom`.
- Port `8080` binds to `127.0.0.1` for reverse-proxy-only exposure.
