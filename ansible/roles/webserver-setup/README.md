# webserver-setup role

Installs Python 3, pip, gunicorn, and Nginx on application servers.

## Variables

| Variable | Default | Description |
|---|---|---|
| nginx_listen_port | 80 | Nginx listen port |
| django_port | 8000 | Django app port (gunicorn) |
| python_version | 3.12 | Python version |

## Usage

```yaml
- hosts: webservers
  roles:
    - webserver-setup
```
