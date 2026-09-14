# postgres-setup role

Installs PostgreSQL 15, initializes the database, creates a user and database for the Django application.

## Variables

| Variable | Default | Description |
|---|---|---|
| db_name | hc | Database name |
| db_user | hc_user | Database user |
| db_password | ***REMOVED*** | Database password |
| db_port | 5432 | PostgreSQL port |

## Usage

```yaml
- hosts: database
  roles:
    - postgres-setup
```
