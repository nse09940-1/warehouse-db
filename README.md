# Warehouse PostgreSQL Workload Lab

Проект имитирует backend интернет-магазина и склада для нагрузочного тестирования PostgreSQL. Он моделирует работу с клиентскими заказами, товарами, складами, движениями остатков, историей статусов и аудитом изменений. C++ workload-сервис генерирует три типа нагрузки: быстрые пользовательские OLTP-операции, тяжелые OLAP-агрегации и постоянную вставку log/time-series событий. После прогонов собираются k6-метрики, `pg_stat_statements`, `EXPLAIN (ANALYZE, BUFFERS)` и показатели Prometheus/Grafana, чтобы сравнить деградацию запросов после изменений схемы и эффект последующих оптимизаций.

## Стек

- C++ / Drogon
- PostgreSQL 16
- Patroni
- etcd
- HAProxy
- Liquibase
- Seqwall
- k6
- Prometheus
- Grafana
- Swagger UI
- MinIO
- Docker

## Что внутри

- `warehouse-api` - C++ workload-сервис с HTTP endpoint-ами для нагрузки.
- `migrations` - Liquibase-миграции с rollback-секциями.
- `seeds` - SQL seed-скрипты для генерации тестовых данных.
- `load` - k6-сценарии для смешанной и write-only нагрузки.
- `profiling` - каталоги для результатов прогонов и анализа.
- `monitoring` - Prometheus/Grafana конфигурация и dashboard-ы.
- `scripts` - служебные скрипты миграций, seed, backup и сбора profiling-артефактов.
- `openapi.yaml` - OpenAPI-спецификация для Swagger UI.

## Предметная область

Система моделирует склад интернет-магазина:

- товары, бренды и категории;
- поставщики, клиенты, сотрудники и склады;
- клиентские заказы и строки заказов;
- складские движения товаров;
- история изменений статусов заказов;
- audit notes по заказам;
- денормализованные суммы и количество позиций в заказе.

## API

Swagger UI доступен по адресу:

```text
http://localhost:8081
```


| Метод | Endpoint | Профиль |
|---|---|---|
| `GET` | `/health` | healthcheck |
| `GET` | `/api/oltp/orders/{id}` | OLTP read, join 3+ таблиц |
| `POST` | `/api/oltp/orders` | OLTP insert |
| `POST` | `/api/oltp/orders/{id}/status` | OLTP update + event/audit insert |
| `GET` | `/api/olap/revenue-by-day` | OLAP aggregation |
| `GET` | `/api/olap/warehouse-turnover` | OLAP/window query |
| `POST` | `/api/log/order-status-events` | log/time-series insert |

## Сервисы

| Сервис | URL |
|---|---|
| API | `http://localhost:8080` |
| Swagger UI | `http://localhost:8081` |
| Grafana | `http://localhost:3000` |
| Prometheus | `http://localhost:9090` |
| HAProxy stats | `http://localhost:8404/stats` |
| PostgreSQL через HAProxy | `localhost:5432` |
| MinIO API | `http://localhost:9000` |
| MinIO Console | `http://localhost:9001` |

Grafana по умолчанию:

```text
login: admin
password: admin
```

## Нагрузочные профили

Проект реализует три профиля нагрузки:

| Профиль | Назначение | Endpoint-ы |
|---|---|---|
| OLTP | Частые быстрые операции пользователей | `GET /api/oltp/orders/{id}`, `POST /api/oltp/orders`, `POST /api/oltp/orders/{id}/status` |
| OLAP | Тяжелые аналитические запросы | `GET /api/olap/revenue-by-day`, `GET /api/olap/warehouse-turnover` |
| Log / Time-series | Быстрорастущая история событий | `POST /api/log/order-status-events` |

## Профилирование

Артефакты прогонов сохраняются в:

```text
profiling/1/
profiling/2/
profiling/3/
```

Ожидаемые файлы:

- `k6_summary.json` - summary k6;
- `pg_stat_statements.csv` - срез запросов PostgreSQL;
- `explain/*.txt` - `EXPLAIN (ANALYZE, BUFFERS)` для workload-запросов.

Подробный анализ деградации и оптимизаций находится в [profiling/README.md](./profiling/README.md).

## Миграции и изменения схемы

Проект содержит базовую схему склада и последующие бизнес-изменения:

- nullable-колонки delivery window в горячей таблице `customer_orders`;
- новая таблица `customer_order_audit_notes` с FK на `customer_orders`;
- денормализованные поля `total_amount`, `items_count`, `last_status_changed_at`;
- дополнительные индексы для audit/time-range запросов;
- материализованное представление `mv_revenue_by_day_category`.

Миграции, изменяющие схему и индексы, содержат rollback-секции.

## Оптимизации

В проекте применяются:

- индекс `idx_customer_order_audit_notes_order_created` на `(customer_order_id, created_at DESC)`;
- BRIN-индекс `brin_customer_order_audit_notes_created_at` на `created_at`;
- materialized view для аналитики `revenue-by-day`;
- переключение OLAP endpoint-а на чтение из materialized view через `API_USE_REVENUE_MV`.

## Мониторинг

Grafana dashboard-ы автоматически provision-ятся из:

```text
monitoring/grafana/dashboards
```

Оптимизационный dashboard:

```text
monitoring/grafana/dashboards/optimization.json
```

Панели включают:

- top-5 долгих запросов из `pg_stat_statements`;
- cache hit ratio;
- active/idle connections;
- метрики PostgreSQL, HAProxy и Patroni.

## Seed

Для полноценного лабораторного прогона в `.env.example` задан большой объем данных:

```text
SEED_COUNT=60000
K6_ORDER_COUNT=300000
```

Для быстрой локальной проверки можно переопределять эти значения через переменные окружения, не изменяя `.env`.
