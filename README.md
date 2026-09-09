# arena-set-stack

Cheap single-box AWS deploy for **arena-set-cracker** (nginx SPA) + **arena-set-sharer** (Spring) + Postgres in Docker.

No RDS, NAT, ALB, or SSM. When CloudWatch emails you that people are hitting the box, graduate to real infra.

## Cost posture

Roughly **t3.small + 30GB gp3** (~$17–20/mo in us-east-2). Postgres lives on the instance; nightly EBS snapshots (7-day retain).

## One-time: rename this GitHub repo

Local folder and `origin` already point at `arena-set-stack`. If GitHub still shows `arena-set-cracker-infra`:

```bash
gh repo rename arena-set-stack
# or rename in the GitHub UI, then:
git remote set-url origin git@github.com:fixerrD40/arena-set-stack.git
```

## Docker Hub images

Build and overwrite:

```bash
# cracker (from arena-set-cracker)
docker build -t hhmidb/arena-set-cracker:latest .
docker push hhmidb/arena-set-cracker:latest

# sharer (from arena-set-sharer) — create the Hub repo once if needed
docker build -t hhmidb/arena-set-sharer:latest .
docker push hhmidb/arena-set-sharer:latest
```

Legacy `hhmidb/arena-set-cracker-frontend` is unused.

## Configure

```bash
cp terraform.tfvars.example terraform.tfvars
# fill: alert_email, app_crypto_secret, app_mail_*, ssh_ingress_cidr, ssh_public_key
```

AWS account/credentials come from your profile (`AWS_PROFILE` / `aws configure`), not tfvars.

## Apply

```bash
terraform init
terraform apply
terraform output public_url
terraform output -raw db_password   # generated Postgres password
```

Then open the **Confirm subscription** email from SNS (once). Without that, alarms never reach your inbox.

## Alarms (email only)

| Alarm | Meaning |
|---|---|
| traffic | Sustained NetworkIn — people may be using the app |
| status | EC2 status check failed |
| cpu | CPU > 70% for ~15 minutes — box may be too small |

You do not need to babysit the AWS console.

## Electron (friends, no Node)

After apply, from `arena-set-cracker`:

```bash
npm run desktop:package
# or: ARENA_BASE_URL=http://x.x.x.x npm run desktop:package
```

That bakes `terraform output public_url` into the build, then restores local `config.json` to localhost. Artifact under `dist-electron/`.

Browser/dev stays `ng serve` + `http://localhost:8080`.

User-data installs Docker and runs `docker-compose.stack.yml` under `/opt/arena-set-stack`:

- **cracker** `:80` / `:443` → proxies `/auth` and `/api` to **sharer**
- **sharer** `:8080` → **postgres** + covers volume
- Gmail SMTP via `APP_MAIL_*`

## HTTPS (Cloudflare Origin CA + Full strict)

Orange-cloud DNS at Cloudflare; browsers get Universal SSL. Origin TLS uses a free **Origin CA** cert on the box (not in the Docker image).

1. **Terraform** — in `terraform.tfvars`:

   ```hcl
   hostname = "your.example"
   ```

   That becomes `APP_HOST=https://your.example`. Leave empty to keep `http://EIP`.

   `terraform apply` opens **443** on the SG and (for new boots) sets `APP_HOST`. Existing instances do **not** re-run user-data; patch the box `.env` yourself (step 4).

2. **Origin cert** — Cloudflare → SSL/TLS → Origin Server → Create certificate for your domain (and `www` if you use it). Save as:

   ```text
   /opt/arena-set-stack/certs/origin.pem
   /opt/arena-set-stack/certs/origin-key.pem
   ```

   `chmod 600` the key. Create the directory if missing: `sudo mkdir -p /opt/arena-set-stack/certs`.

3. **Cracker image** — from `arena-set-cracker`, rebuild/push so nginx listens on 443:

   ```bash
   docker build -t hhmidb/arena-set-cracker:latest .
   docker push hhmidb/arena-set-cracker:latest
   ```

4. **On the box** — refresh compose (scp the updated `docker-compose.stack.yml` → `/opt/arena-set-stack/docker-compose.yml`), then:

   ```bash
   cd /opt/arena-set-stack
   # set APP_HOST=https://your.example in .env
   sudo docker-compose pull cracker
   sudo docker-compose up -d
   ```

5. **Cloudflare** — SSL/TLS mode → **Full (strict)**. Confirm `https://your.example` loads (clipboard API needs this secure context).

Until the origin cert + new image are live, leave mode on **Flexible** so Cloudflare still reaches `:80`.
