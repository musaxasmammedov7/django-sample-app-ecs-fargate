# django-sample-app → AWS ECS Fargate (Terraform IaC)

Перевод Django‑приложения **Healthchecks** с EC2 на контейнеры в **Amazon ECS
Fargate**. Вся инфраструктура описана как код (IaC) с использованием
официальных модулей **terraform-aws-modules** (Антон Бабенко) и поставляется
вместе с CI/CD‑пайплайном (GitHub Actions), сканированием образа (**Trivy**) и
проверкой слоёв (**dive**).

---

## 1. Что делает этот стек

Один `terraform apply` создаёт полностью рабочее, отказоустойчивое окружение:

```
                       Internet
                          │
                          ▼
            ┌─────────────────────────────┐
            │   Application Load Balancer │   (public subnets, 2 AZ)
            │        HTTP :80             │
            └──────────────┬──────────────┘
                           │  target group (target_type = ip)
                           ▼
        ┌──────────────────────────────────────┐
        │        ECS Cluster (Fargate)         │   (private subnets)
        │   service: django-sample-app         │
        │   task: gunicorn + Django (миграции) │
        │   image: <ECR>:<git-sha>             │
        └───────────────┬──────────────────────┘
                        │  :5432 (SG: только из ECS)
                        ▼
            ┌─────────────────────────────┐
            │   Amazon RDS PostgreSQL     │   (private subnets)
            │   пароль в Secrets Manager  │
            └─────────────────────────────┘
```

Ключевые решения:

- **ECS Fargate** — не нужно управлять EC2, патчить ОС и настраивать ASG.
- **RDS PostgreSQL** — managed‑база; мастер‑пароль генерируется и хранится
  в **AWS Secrets Manager** (`manage_master_user_password = true`), в Terraform
  state он не попадает.
- **Секреты** (`SECRET_KEY`, `DB_PASSWORD`) инжектируются в контейнер как ECS
  `secrets` — они не видны в описании задачи и не пишутся в файлы.
- **Приватные сабнеты** для ECS и RDS, публичные — только для ALB и NAT.
- **OIDC** для GitHub Actions: никаких долгоживущих AWS‑ключей в секретах
  репозитория.

---

## 2. Структура репозитория

```
django-sample-app/
├── Dockerfile                     # multi-stage сборка приложения (в корне форка)
├── requirements-prod.txt          # gunicorn и пр. прод-зависимости
├── .dockerignore
├── docker/
│   └── entrypoint.sh              # wait-for-DB → migrate → exec gunicorn
├── .github/workflows/
│   ├── ci-cd.yml                  # build → Trivy → ECR → ECS
│   ├── security.yml               # hadolint + Trivy + Syft + Grype
│   └── terraform.yml              # fmt + validate IaC
└── terraform-aws-ecs-fargate/
    ├── providers.tf               # Terraform + AWS provider + default_tags
    ├── variables.tf               # все входные переменные + locals
    ├── vpc.tf                     # VPC, подсети, NAT, security groups
    ├── alb.tf                     # Application Load Balancer + target group
    ├── db.tf                      # RDS PostgreSQL + секреты Secrets Manager
    ├── ecs.tf                     # ECR + ECS Fargate + IAM/OIDC для CI
    ├── outputs.tf                 # полезные значения после apply
    ├── Dockerfile                 # копия Dockerfile (по требованию структуры)
    ├── terraform.tfvars.example   # пример переменных
    ├── .gitignore
    └── README.md                  # этот файл
```

---

## 3. Используемые модули (terraform-aws-modules)

Вместо «самописных» ресурсов используются проверенные модули сообщества,
которые и есть отраслевой best practice:

| Модуль | Версия | Назначение |
|---|---|---|
| `terraform-aws-modules/vpc/aws` | `~> 6.7` | VPC, сабнеты, IGW, NAT, route tables |
| `terraform-aws-modules/security-group/aws` | `~> 6.0` | Security groups (ALB / ECS / RDS) |
| `terraform-aws-modules/alb/aws` | `~> 10.5` | ALB, listener, target group, health check |
| `terraform-aws-modules/rds/aws` | `~> 7.2` | RDS PostgreSQL, subnet/param group, Secrets Manager |
| `terraform-aws-modules/ecs/aws` | `~> 7.6` | ECS cluster, task definition, service, IAM |

---

## 4. Требования

- Terraform ≥ 1.11.1
- AWS CLI v2 с настроенными правами (не ниже прав на создание VPC/ECS/RDS/IAM)
- Docker (для локальной сборки)
- `dive` (проверка образа): `brew install dive`
- (для CI) репозиторий GitHub с правом на OIDC

Быстрая проверка версий:

```bash
terraform version
docker version
aws sts get-caller-identity
```

---

## 5. Пошаговый запуск

### Шаг 0. Форк и клон

```bash
git clone https://github.com/<ВАШ_АККАУНТ>/django-sample-app.git
cd django-sample-app
```

### Шаг 1. Сборка образа

```bash
docker build -t django-sample-app:local .
```

### Шаг 2. Проверка образа через `dive`

```bash
brew install dive

# Анализ слоёв, размера и потенциальных проблем
dive django-sample-app:local
```

Что смотреть в `dive`:

- **Efficiency** — доля «полезного» размера образа (у нас multi‑stage, поэтому
  кэш `apt` и pip удаляются, а build‑зависимости не попадают в runtime‑слой).
- **Лишние файлы** — в образ не должны попадать `.git`, `.terraform`,
  `search.db`, тесты и кэши (это решает `.dockerignore`).
- **Health score** — стремимся к «A».

### Шаг 3. Разворачивание инфраструктуры

```bash
cd terraform-aws-ecs-fargate
cp terraform.tfvars.example terraform.tfvars   # при необходимости отредактируйте

terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```

Первый `apply` создаёт в том числе **ECR‑репозиторий** и ECS‑сервис. Сервис
ещё не поднимется: образа в реестре пока нет — это ожидаемо. Сохраните
выводы:

```bash
terraform output
# application_url / ecr_repository_url / github_actions_role_arn / ...
```

### Шаг 4. Push образа в ECR

Вручную:

```bash
AWS_REGION=eu-north-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URL=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/django-sample-app
TAG=$(git rev-parse --short HEAD)

aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

docker build -t $ECR_URL:$TAG .
docker push $ECR_URL:$TAG
```

Либо просто положиться на CI/CD (шаг 5) — пайплайн сам соберёт, просканирует,
запушит образ и обновит сервис.

### Шаг 5. Настройка CI/CD (GitHub Actions + OIDC)

1. Возьмите ARN роли, которую создал Terraform:

   ```bash
   terraform output -raw github_actions_role_arn
   ```

2. В GitHub: **Settings → Secrets and variables → Actions → Variables** создайте
   переменную `AWS_ROLE_ARN` со значением из предыдущего шага.
   (Необязательные переопределения: `AWS_REGION`, `ECR_REPOSITORY`,
   `ECS_CLUSTER`, `ECS_SERVICE` — по умолчанию уже совпадают со стеком.)

3. Сделайте push в `main`. Пайплайн `.github/workflows/ci-cd.yml`:

   ```
   lint-test → trivy-repo-scan → build → trivy-image-scan → ECR push → register task def → update ECS service
   ```

### Шаг 6. Проверка

```bash
# URL приложения из Terraform
URL=$(terraform -chdir=terraform-aws-ecs-fargate output -raw application_url)
curl -sS -o /dev/null -w "%{http_code}\n" "$URL"

# Состояние сервиса и задач
aws ecs describe-services \
  --cluster django-sample-app --services django-sample-app \
  --query 'services[0].{status:status,desired:desiredCount,running:runningCount,rollout:deployments[0].rolloutState}'
```

Откройте `application_url` в браузере — отобразится интерфейс Healthchecks.

---

## 6. Переменные (основные)

| Переменная | По умолчанию | Описание |
|---|---|---|
| `aws_region` | `eu-north-1` | Регион AWS |
| `project_name` | `django-sample-app` | Префикс имён ресурсов / имя ECR |
| `vpc_cidr` | `10.0.0.0/16` | CIDR VPC |
| `single_nat_gateway` | `true` | Один NAT (дешевле) вместо NAT на AZ |
| `container_image` | `""` | Явный URI образа; пусто → ECR стека |
| `image_tag` | `latest` | Тег для bootstrap‑образа |
| `ecs_task_cpu` / `ecs_task_memory` | `512` / `1024` | Размер Fargate‑задачи |
| `ecs_cpu_architecture` | `X86_64` | `ARM64` (Graviton) дешевле |
| `db_instance_class` | `db.t4g.micro` | Класс RDS |
| `db_multi_az` | `false` | Multi‑AZ standby |
| `db_deletion_protection` | `false` | Защита БД от удаления |
| `enable_deletion_protection` | `false` | Защита ALB от удаления |
| `create_github_oidc` | `true` | Создать GitHub OIDC provider + роль |
| `github_repository` / `github_branch` | `musaxasmammedov7/django-sample-app` / `main` | Кому разрешено деплоить |

Полный список — в `variables.tf`.

---

## 7. Секреты

| Секрет | Где хранится | Как попадает в контейнер |
|---|---|---|
| `DB_PASSWORD` | Secrets Manager (создаёт RDS‑модуль) | ECS `secrets` → env `DB_PASSWORD` |
| `SECRET_KEY` | Secrets Manager (`random_password`) | ECS `secrets` → env `SECRET_KEY` |

- В state Terraform секреты не хранятся в открытом виде.
- Task execution role получает доступ только к перечисленным ARN
  (`task_exec_secret_arns`).
- Приложение читает значения из переменных окружения (`hc/settings.py`).

---

## 8. CI/CD пайплайн

Файл `.github/workflows/ci-cd.yml`.

| Job | Что делает |
|---|---|
| `lint-test` | `manage.py check` + проверка неприменённых миграций |
| `trivy-repo-scan` | Trivy fs: уязвимости, секреты, misconfig → SARIF в Security tab |
| `build-scan-push` | buildx‑сборка `linux/amd64`, **Trivy image scan** (fail на HIGH/CRITICAL), push в ECR, новая ревизия task definition, `ecs wait services-stable` |

Пайплайн **не использует статичные AWS‑ключи**: он аутентифицируется через
**GitHub OIDC** и роль `django-sample-app-gha-deploy`, созданную Terraform.
Trust‑policy роли ограничена конкретным репозиторием и веткой
(`repo:<owner>/<name>:ref:refs/heads/main`).

Секреты не попадают в образ: сборка статики выполняется с временным
`SECRET_KEY=build-time-placeholder`, реальный подставляется при старте задачи.

---

## 9. Безопасность (best practices)

- Все вычислительные ресурсы (ECS, RDS) — в **private subnets**, без публичных IP.
- Security groups по принципу минимальных привилегий:
  - ALB ← :80/:443 из интернета;
  - ECS ← только из ALB;
  - RDS ← только из ECS на :5432.
- RDS: `storage_encrypted = true`, шифрование снапшотов и логов.
- Секреты — только в Secrets Manager, доступ через IAM.
- Принцип наименьших привилегий для CI‑роли (push в один ECR, update одного
  сервиса).
- Образ собирается multi‑stage, работает под non‑root (`USER 1000:1000`).
- Trivy‑скан блокирует деплой при HIGH/CRITICAL уязвимостях.

---

## 10. Стоимость и очистка

Основные статьи расходов: NAT Gateway (почасово), ALB, Fargate‑задачи, RDS
(`db.t4g.micro`), Secrets Manager, ECR‑хранилище. Для учебного стенда
рекомендуется удалять окружение после проверки.

```bash
cd terraform-aws-ecs-fargate
terraform destroy
```

> Если в ECR есть образы, `destroy` не удалит репозиторий по умолчанию
> (это защита от потери данных). Удалите образы вручную:
> `aws ecr batch-delete-image --repository-name django-sample-app --image-ids imageTag=latest`
> или выставьте `force_delete = true` в ресурсе ECR (осознанно).

---

## 11. Troubleshooting

| Симптом | Причина / решение |
|---|---|
| Задачи ECS в статусе `PENDING` и не запускаются | Образ не запушен в ECR или нет egress через NAT. Проверьте `image` в task definition и NAT Gateway. |
| ALB target группа `unhealthy` | Приложение не поднялось (ошибка миграций/подключения к БД). Смотрите логи: `aws logs tail /aws/ecs/... --follow`. |
| `Error: Invalid for_each argument ... sensitive value` | В `services` попало значение, помеченное sensitive. Мы решаем это через `nonsensitive()` для ARN и `var.db_username` для имени пользователя (см. `variables.tf`/`ecs.tf`). |
| Ошибка подключения к RDS | Проверьте, что БД в тех же сабнетах и `DB_SSLMODE`. RDS SG пускает только SG ECS. |
| `terraform destroy` падает на ECR | В репозитории есть образы — удалите их (см. раздел 10). |

---

## 12. Соответствие требованиям задания

| Требование задания | Как выполнено |
|---|---|
| Форк `django-sample-app` с изменениями | Dockerfile, entrypoint, `.dockerignore`, compose, CI |
| Dockerfile с зависимостями и конфигом Postgres | multi‑stage, `psycopg`/`pycurl`, env `DB=postgres`, миграции |
| Build & push образа в ECR | CI/CD GitHub Actions + ручные команды (раздел 5) |
| Проверка образа через `dive` | раздел 5, шаг 2 |
| ECS‑кластер | `ecs.tf` (`terraform-aws-modules/ecs`) |
| Postgres RDS | `db.tf` (`terraform-aws-modules/rds`) |
| Деплой в ECS | ECS service + ALB + CI (task definition revision) |
| Тестирование | `curl <application_url>`, health check `/api/v3/status/`, CloudWatch Logs |
| Структура IaC `terraform-aws-ecs-fargate` | все требуемые файлы присутствуют |
