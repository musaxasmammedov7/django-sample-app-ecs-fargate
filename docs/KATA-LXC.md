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

## 3. Практика: LXC (реально прогнано)

**Среда эксперимента:** Apple M1 (arm64), Linux-ядро Docker Desktop
(`7.0.14-linuxkit`), привилегированный контейнер `ubuntu:24.04`. LXC использует
namespaces того же ядра, поэтому KVM (как у Kata) ему не нужен.

Команды:
```bash
docker run --rm --privileged --platform linux/arm64 ubuntu:24.04 bash -lc '
  apt-get update -qq && apt-get install -y -qq lxc lxc-templates busybox-static
  lxc-create -n c1 -t busybox
  sed -i "/^lxc.net/d" /var/lib/lxc/c1/config   # сеть в этой среде недоступна
  echo "lxc.net.0.type = none" >> /var/lib/lxc/c1/config
  lxc-start -n c1
  lxc-ls -f
  lxc-attach -n c1 -- sh -c "uname -r; cat /proc/1/comm; id; cat /proc/self/uid_map"
  lxc-stop -n c1 && lxc-destroy -n c1
'
```

**Реальный вывод:**

| Что проверяем | Хост | LXC-контейнер `c1` |
|---|---|---|
| `uname -r` (ядро) | `7.0.14-linuxkit` | `7.0.14-linuxkit` — **то же самое** |
| `PID 1` | `bash` | `init` — **свой init** |
| `id` | `uid=0(root)` | `uid=0(root)` |
| `uid_map` | — | `0 0 4294967295` |

**Что это доказывает:**
- LXC даёт контейнеру **свой rootfs и свой init** — это «системный» контейнер,
  а не один процесс, как обычно в Docker;
- ядро **общее с хостом** (`uname -r` совпадает) — именно этим LXC принципиально
  отличается от Kata (у которого в микро-ВМ **своё** ядро).

### Unprivileged LXC — где именно «безопасность»
`uid_map = 0 0 4294967295` означает: **root внутри контейнера = root на хосте**
(обычный, *privileged*, LXC). Чтобы это исправить, добавляют маппинг:
```toml
lxc.idmap = u 0 100000 65536
lxc.idmap = g 0 100000 65536
```
Тогда uid 0 в контейнере мапится на **непривилегированный uid 100000** на хосте:
«root» внутри уже не root снаружи. Это и есть реальный вклад LXC в безопасность —
**unprivileged (rootless) режим**, а не LXC сам по себе.

> Честное замечание: в среде macOS/Docker Desktop (overlayfs) unprivileged
> контейнер не стартует (`Permission denied` на `rootfs`/`chown` — ограничение
> хранилища), поэтому показан только privileged. На нативном Linux / EC2 этот
> вариант работает.

**Вывод:** LXC сам по себе **не безопаснее** Docker (то же ядро). Усиление даёт
либо **unprivileged/rootless** режим, либо **изоляция уровня ВМ** (Kata /
Firecracker).

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
