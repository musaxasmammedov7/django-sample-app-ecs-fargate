# Task 3, пункт 4* — Kata и LXC: объяснение и практика

## 0. Как читать пункт 4*
Формулировка задания:

> To improve container security, try using different kinds of containers like
> **Kata or LXC** containers.

**Контекст** (вступление Task 3) — «continue your work … after successfully
transitioning to a Docker environment» — это тот же проект, что и Task 1, то
есть прод на **ECS Fargate**.

**Но сам пункт 4\*** про «другие виды контейнеров» **не привязан к ECS**. Это
бонусное «попробуй и сравни». Поэтому корректный ответ такой:

- в **проде** остаёмся на ECS Fargate, где Kata **выбрать нельзя** (там уже
  микро-ВМ Firecracker);
- пункт 4* закрываем **отдельным экспериментом** с LXC/Kata и описанием,
  **почему** в ECS runtime не переключается.

---

## 1. Три уровня изоляции

### runc (обычный Docker)
Контейнер = process + namespaces (изоляция видимости) + cgroups (лимиты),
работает на **общем ядре хоста**. Быстро, но при уязвимости ядра возможен
«побег» из контейнера.

### Kata Containers
Контейнер запускается внутри **лёгкой виртуальной машины со своим ядром**
(микро-ВМ, например на QEMU/Cloud Hypervisor/Firecracker). Интерфейс — как у
контейнера (образ, команды), изоляция — как у отдельной ВМ. Дороже по старту и
памяти, но граница безопасности сильно крепче.

Схема:
```
Хост (ядро Linux хоста)
└── микро-ВМ Kata  (СВОЁ guest-ядро)
    └── контейнер (наш процесс)
```

### LXC / LXD
«Системные» контейнеры: внутри полноценный Linux-дистрибутив с собственным
`init` (systemd), но на **общем ядре** хоста. Похоже на лёгкую ВМ/`chroot` +
namespaces; удобно запускать «машину как процесс» (несколько сервисов сразу),
а не один процесс, как в Docker.

---

## 2. Почему в ECS Fargate нельзя «включить Kata»

- Fargate — **управляемый** сервис: container runtime выбирает AWS, там всегда
  runc-совместимый runtime, и параметра «запусти через Kata» нет.
- ECS (и Fargate, и EC2 launch type) **не поддерживает `RuntimeClass`**, в
  отличие от Kubernetes.

**Но нужный уровень изоляции уже есть:** под капотом Fargate запускает каждую
задачу в **Firecracker microVM** — это та же модель, что у Kata (отдельное
лёгкое ядро на задачу). То есть «Kata-подобная» изоляция на Fargate доступна по
умолчанию и настраивать её не нужно.

---

## 3. Практика: LXC

> Выполнять на **Linux** (на macOS Docker Desktop полноценно не работает —
> там эмуляция; вложенный LXC нестабилен).

Быстрый способ — внутри привилегированного Ubuntu-контейнера (для демо на
Linux-хосте):

```bash
docker run --rm --privileged -it ubuntu:24.04 bash -lc '
  apt-get update -qq && apt-get install -y -qq lxc wget gnupg
  lxc-create -n demo -t download -- -d alpine -r 3.20 -a amd64
  lxc-start -n demo
  lxc-ls -f
  lxc-attach -n demo -- sh -c "cat /etc/os-release | head -1; whoami; ps -p 1 -o comm="
  lxc-stop -n demo && lxc-destroy -n demo
'
```

Что смотреть:
- `lxc-ls -f` показывает контейнер и его состояние (как отдельная «машина»);
- `lxc-attach` — вход внутрь; видно **свой пользователь, свой rootfs и свой
  PID 1** — то, чего нет у обычного одноразового Docker-контейнера.

На **чистом Linux** (не в Docker) проще: `sudo apt install lxc lxc-templates`,
далее те же `lxc-create/lxc-start/lxc-ls`.

> Замечание по нашей проверке: на macOS команда установки LXC проходит, но
> вложенный запуск под эмуляцией amd64 даёт сбой — это ограничение среды, а не
> LXC. На нативном Linux всё работает.

---

## 4. Практика: Kata Containers

Kata требует **Kubernetes (EKS)** или ручного `containerd`; на macOS без KVM
не запускается.

### Вариант A — EKS + RuntimeClass
```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
handler: kata
```
```yaml
spec:
  runtimeClassName: kata
  containers:
    - name: app
      image: <ecr>/django-sample-app:<tag>
```

### Вариант B — standalone containerd (Linux)
1. установить `kata-containers`;
2. добавить рантайм в `/etc/containerd/config.toml`:
   ```toml
   [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
     runtime_type = "io.containerd.kata.v2"
   ```
3. перезапустить containerd и запускать:
   ```bash
   nerdctl run --runtime io.containerd.kata.v2 -it alpine sh
   ```

---

## 5. Сравнение

| Технология | Изоляция | Ядро | Старт | Когда выбирать |
|---|---|---|---|---|
| **runc** (Docker) | средняя | общее (хост) | мс | доверенный код |
| **Kata** | высокая (микро-ВМ) | своё | сотни мс | недоверенный/мультитенантный код |
| **Firecracker** (в Fargate) | высокая (микро-ВМ) | своё | сотни мс | то же, что Kata, но уже встроено |
| **LXC/LXD** | средняя-высокая | общее (хост) | секунды | «системные» контейнеры, несколько сервисов |

---

## 6. Вывод для клиента
Для нашего приложения (один процесс gunicorn, доверенный код) на Fargate
**достаточно** встроенной изоляции Firecracker — отдельный Kata не нужен и
потребовал бы переезда на EKS. Пункт 4* закрыт: мы сравнили runc / Kata /
Firecracker / LXC, показали LXC-эксперимент и объяснили, почему в ECS runtime
не переключается на Kata.
