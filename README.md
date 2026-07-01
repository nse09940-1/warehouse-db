# Warehouse PostgreSQL Workload Lab

Проект имитирует backend интернет-магазина и склада для нагрузочного тестирования PostgreSQL, проверки отказоустойчивости и построения BI-витрины на CDC-событиях. Он моделирует работу с клиентскими заказами, товарами, складами, движениями остатков, историей статусов и аудитом изменений.

C++ workload-сервис генерирует три типа нагрузки: быстрые пользовательские OLTP-операции, тяжелые OLAP-агрегации и постоянную вставку log/time-series событий. После прогонов собираются k6-метрики, `pg_stat_statements`, `EXPLAIN (ANALYZE, BUFFERS)` и показатели Prometheus/Grafana, чтобы сравнить деградацию запросов после изменений схемы и эффект последующих оптимизаций.

Дополнительно проект содержит BI/CDC-контур: изменения из PostgreSQL primary по таблице `inventory_movements` читаются Debezium, попадают в Kafka, загружаются в ClickHouse и используются в Metabase dashboard-ах.

## Стек

- C++ / Drogon
- PostgreSQL 16
- Patroni
- etcd
- HAProxy
- Liquibase
- Seqwall
- Debezium / Kafka Connect
- Kafka 3.9 в режиме KRaft
- Kafka UI
- ClickHouse
- Metabase
- k6
- Prometheus
- Grafana
- MinIO
- Docker / Docker Compose

## Что внутри

- `warehouse-api` - C++ workload-сервис с HTTP endpoint-ами для нагрузки.
- `migrations` - Liquibase-миграции с rollback-секциями.
- `seeds` - SQL seed-скрипты для генерации тестовых данных.
- `load` - k6-сценарии для смешанной и write-only нагрузки.
- `profiling` - каталоги для результатов прогонов и анализа.
- `monitoring` и `grafana` - Prometheus/Grafana конфигурация и dashboard-ы.
- `cdc` - конфигурация Debezium PostgreSQL connector, регистрация и watchdog.
- `clickhouse` - конфигурация ClickHouse и инициализация CDC-таблиц.
- `bi/sql` - SQL-запросы для BI-карточек Metabase.
- `scripts` - служебные скрипты миграций, seed, backup, failover, CDC smoke-test и сбора profiling-артефактов.

## Предметная область

Система моделирует склад интернет-магазина:

- товары, бренды и категории;
- поставщики, клиенты, сотрудники и склады;
- клиентские заказы и строки заказов;
- складские движения товаров;
- история изменений статусов заказов;
- audit notes по заказам;
- денормализованные суммы и количество позиций в заказе;
- CDC-поток движений товаров для аналитики.

## API

Workload API доступен по адресу:

```text
http://localhost:8080
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
| Grafana | `http://localhost:3000` |
| Prometheus | `http://localhost:9090` |
| HAProxy stats | `http://localhost:8404/stats` |
| PostgreSQL через HAProxy | `localhost:5432` |
| Debezium Connect REST API | `http://localhost:8083` |
| Kafka external listener | `localhost:29092` |
| Kafka UI | `http://localhost:8088` |
| ClickHouse HTTP | `http://localhost:8123` |
| Metabase | `http://localhost:3001` |
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
- таблица log/time-series событий `order_status_events`;
- дополнительные индексы для audit/time-range запросов;
- материализованное представление `mv_revenue_by_day_category`;
- BI/CDC-настройки в `015_bi_cdc_setup.sql`: Debezium replication role, права на `inventory_movements`, publication для logical replication и пользователь Metabase.

Миграции, изменяющие схему и индексы, содержат rollback-секции.

## Оптимизации

В проекте применяются:

- индекс `idx_customer_order_audit_notes_order_created` на `(customer_order_id, created_at DESC)`;
- BRIN-индекс `brin_customer_order_audit_notes_created_at` на `created_at`;
- materialized view для аналитики `revenue-by-day`;
- составной индекс `idx_inventory_movements_moved_warehouse_product` для аналитики складских движений;
- переключение OLAP endpoint-а на чтение из materialized view через `API_USE_REVENUE_MV`.

## BI и CDC

BI-пайплайн:

```text
PostgreSQL primary -> Debezium -> Kafka (KRaft) -> ClickHouse -> Metabase
```

Основная CDC-таблица: `public.inventory_movements`. Она выбрана как быстрорастущая таблица складских движений с удобными аналитическими полями: `moved_at`, `movement_type`, `quantity`, `warehouse_id`.

Debezium connector читает только `public.inventory_movements` через `pgoutput` и публикует события в topic:

```text
warehouse_cdc.public.inventory_movements
```

В ClickHouse создаются:

- база `bi_analytics`;
- Kafka Engine таблица `inventory_movements_queue`;
- CDC-таблица `inventory_movements_cdc` на `ReplacingMergeTree(version)`;
- materialized view `inventory_movements_queue_mv`;
- аналитическое view `inventory_movements_current` с актуальными неудаленными строками.

SQL для карточек Metabase хранится в `bi/sql`:

- `01_total_quantity_kpi.sql`;
- `02_daily_trend_by_type.sql`;
- `03_top_warehouses.sql`;
- `04_movement_type_share.sql`.

После основного запуска connector регистрируется отдельным init-профилем:

```bash
docker compose --profile bi-init up debezium-register
```

`debezium-watchdog` остается запущенным и перерегистрирует или перезапускает connector через Kafka Connect REST API, если после failover Debezium потерял подключение.

Проверка CDC-контура:

```bash
bash ./scripts/bi-cdc-smoke.sh
```

Проверка topic:

```bash
docker compose exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:9092 --describe --topic warehouse_cdc.public.inventory_movements
```

Проверка ClickHouse:

```bash
docker compose exec -T clickhouse clickhouse-client --user clickhouse_admin --password clickhouse_admin_password --query "SELECT count() FROM bi_analytics.inventory_movements_current"
```

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
- метрики PostgreSQL, HAProxy и Patroni;
- статус бэкапов;
- метрики MinIO;
- метрики оптимизации запросов.

## Отказоустойчивость

Patroni управляет PostgreSQL-кластером из двух узлов, HAProxy направляет подключения к актуальному leader, а etcd используется как DCS. В `patroni.yml.tmpl` включен `wal_level: logical`, чтобы Debezium мог читать WAL через logical replication.

Сценарии проверки:

```bash
bash ./scripts/demo-failover.sh
bash ./scripts/demo-etcd-quorum-loss.sh
```

Для проверки BI после failover:

```bash
bash ./scripts/demo-failover.sh
bash ./scripts/bi-cdc-smoke.sh
```

## Seed

Для полноценного лабораторного прогона в `.env.example` задан большой объем данных:

```text
SEED_COUNT=60000
K6_ORDER_COUNT=300000
```

Для быстрой локальной проверки можно переопределять эти значения через переменные окружения, не изменяя `.env`.
