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

- **cracker** `:80` → proxies `/auth` and `/api` to **sharer**
- **sharer** `:8080` → **postgres** + covers volume
- Gmail SMTP via `APP_MAIL_*`
