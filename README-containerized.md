# Task 1 — Переход на контейнеры (Docker + Amazon ECS Fargate)

Краткое руководство и объяснение по контейнеризации Django‑приложения
**Healthchecks** и его развёртыванию в AWS ECS Fargate. Полная инструкция по
инфраструктуре — в [`terraform-aws-ecs-fargate/README.md`](terraform-aws-ecs-fargate/README.md).

---

## Что требовалось

1. Форк репозитория `kaaalim/django-sample-app` с изменениями.
2. `Dockerfile` для упаковки Django + Postgres.
3. Сборка и push образа в **Amazon ECR**.
4. Проверка образа инструментом **dive**.
5. Инфраструктура в Terraform со структурой `terraform-aws-ecs-fargate/`.
6. ECS‑кластер + **RDS PostgreSQL** + деплой приложения.
7. Тестирование работы приложения.

## Что сделано (карта файлов)

| Требование | Файл |
|---|---|
| Dockerfile | [`Dockerfile`](Dockerfile), [`docker/entrypoint.sh`](docker/entrypoint.sh), [`.dockerignore`](.dockerignore) |
| Прод‑зависимости | [`requirements-prod.txt`](requirements-prod.txt) |
| Локальный smoke‑тест | [`docker-compose.yml`](docker-compose.yml) |
| CI/CD + Trivy | [`.github/workflows/ci-cd.yml`](.github/workflows/ci-cd.yml) |
| Проверка IaC | [`.github/workflows/terraform.yml`](.github/workflows/terraform.yml) |
| IaC | [`terraform-aws-ecs-fargate/`](terraform-aws-ecs-fargate) |

---

## 1. Как устроен образ

Сборка **multi‑stage**, чтобы прод‑образ был маленьким и без компиляторов:

- **builder** (`python:3.12-slim` + `build-essential`, `libpq-dev`,
  `libcurl4-openssl-dev`, `libssl-dev`): собирает C‑расширения
  (`psycopg`, `pycurl`, `cryptography`, `argon2-cffi`, `fido2`) в venv `/opt/venv`.
- **runtime** (`python:3.12-slim` + только `libpq5`, `libcurl4`, `tzdata`):
  копирует venv и код, собирает статику (`collectstatic` + `compress`),
  работает под непривилегированным пользователем (`USER 1000:1000`).

Особенности приложения, которые важно учесть:

- Движок БД выбирается переменной `DB=postgres`; далее `DB_HOST`, `DB_PORT`,
  `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DB_SSLMODE` (`hc/settings.py`).
- Нужен `SECRET_KEY`; статика обслуживается Whitenoise, поэтому статику
  собираем на этапе `docker build`.
- `gunicorn` не входил в `requirements.txt`, он добавлен в
  `requirements-prod.txt`.

Контейнер стартует через `docker/entrypoint.sh`:
`wait-for-DB` → `manage.py migrate` → `exec gunicorn hc.wsgi:application`.

## 2. Локальная проверка

```bash
docker compose up --build      # http://localhost:8000
docker build -t django-sample-app:local .
brew install dive
dive django-sample-app:local   # анализ слоёв/размера
```

## 3. CI/CD и сканирование

`.github/workflows/ci-cd.yml` при push в `main`:

1. Django `check` и проверку миграций;
2. Trivy‑скан исходников (vuln/secret/misconfig) → SARIF в GitHub Security;
3. сборку образа (`linux/amd64`);
4. Trivy‑скан образа (падает на HIGH/CRITICAL);
5. push в ECR;
6. регистрацию новой ревизии task definition и обновление ECS‑сервиса.

AWS‑доступ — через **GitHub OIDC** (без статичных ключей). Роль создаёт
Terraform; её ARN нужно положить в переменную репозитория `AWS_ROLE_ARN`.

## 4. Инфраструктура

Полностью описана в `terraform-aws-ecs-fargate/` с использованием модулей
**terraform-aws-modules** (vpc / security-group / alb / rds / ecs). Подробности,
команды `init/plan/apply`, переменные, секреты и проверка — в
[README инфраструктуры](terraform-aws-ecs-fargate/README.md).

```bash
cd terraform-aws-ecs-fargate
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform plan && terraform apply
```

## 5. Проверка результата

```bash
URL=$(terraform -chdir=terraform-aws-ecs-fargate output -raw application_url)
curl -sS -o /dev/null -w "%{http_code}\n" "$URL"

aws ecs describe-services --cluster django-sample-app --services django-sample-app \
  --query 'services[0].{running:runningCount,rollout:deployments[0].rolloutState}'
```
