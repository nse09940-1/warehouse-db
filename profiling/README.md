# Профилирование и оптимизация (пункты 1-3)



## Наблюдаемая деградация (1 -> 2)
Деградация подтверждена по p95 latency:
- `oltp_read`: 87.42 -> 169.99 ms (+94.45%)
- `oltp_insert`: 264.01 -> 504.62 ms (+91.14%)
- `oltp_update`: 147.47 -> 377.08 ms (+155.71%)
- `olap_revenue`: 1913.68 -> 30810.02 ms (+1509.99%)
- `olap_turnover`: 2478.94 -> 98293.63 ms (+3865.14%)
- `log_insert`: 125.40 -> 223.78 ms (+78.46%)

Ключевые признаки из EXPLAIN:
- `olap_revenue_by_day`: `Execution Time` вырос с ~758 ms до ~42719 ms, тяжёлые сортировки на диск (`external merge`) и крупные сканы.
- `olap_warehouse_turnover`: `Execution Time` ~25565 ms, дорогая агрегация/сортировка по большому объёму движений.

## План оптимизации
| Запрос / Профиль | Проблема (EXPLAIN / pg_stat) | Предлагаемое решение | Ожидаемый эффект |
|---|---|---|---|
| `GET /api/olap/revenue-by-day` (OLAP) | Очень высокая p95 и тяжёлая агрегация по заказам/позициям/аудиту | Материализованное представление + чтение из MV в API | Резкое снижение p95 OLAP-revenue |
| `GET /api/olap/warehouse-turnover` (OLAP) | Огромная промежуточная агрегация и выдача, диск-сорты | Ограничить расчёт top-N активных складов + индекс для диапазона движений | Снижение времени агрегации и стабилизация API |
| `GET /api/oltp/orders/{id}` (OLTP read) | LATERAL к `customer_order_audit_notes` без оптимального доступа к последним заметкам | Индекс `(customer_order_id, created_at DESC)` + BRIN по `created_at` | Ускорить подсчёт/получение последних заметок |
| `POST /api/oltp/orders`, `POST /api/oltp/orders/{id}/status` (OLTP write) | Риск замедления из-за новых индексов | Проверка write-only прогона после оптимизаций | Зафиксировать обратный эффект на запись |

## Применённые оптимизации
Каждая оптимизация оформлена отдельной миграцией с rollback:
- `migrations/011_idx_audit_notes_order_created.sql` (B-tree индекс `(customer_order_id, created_at DESC)` для быстрого поиска последних audit notes по заказу).
- `migrations/012_idx_audit_notes_created_brin.sql` (BRIN индекс по `created_at` для дешёвого доступа к большим временным диапазонам audit notes).
- `migrations/013_mv_revenue_by_day_category.sql` (предагрегация выручки по дню и категории в materialized view + индексы по `(sales_day, category_name)` и `revenue DESC`).
- `migrations/014_idx_inventory_movements_moved_warehouse_product.sql` (составной индекс `(moved_at, warehouse_id, product_id, movement_type)` для фильтрации движений по периоду и дальнейшей агрегации по складам/товарам).
- Материализованное представление `mv_revenue_by_day_category` + `API_USE_REVENUE_MV=true` (endpoint `revenue-by-day` читает готовую агрегированную таблицу вместо пересчёта join/group by на каждом запросе).
- `workload/src/main.cpp`: для `warehouse-turnover` добавлен CTE `top_warehouses` (top-100 по объёму) перед продуктовым ранжированием (сначала сокращается список складов, затем считаются товары только внутри выбранных складов).

## Проверка влияния на запись (write-only, 1 мин)
Источник: `profiling/3/k6_write_summary.json`.

Сравнение с p95 из пункта 1:
- `oltp_insert`: 264.01 ms (п.1) -> 170.35 ms (write-only п.3)
- `oltp_update`: 147.47 ms (п.1) -> 20.36 ms (write-only п.3)
- `log_insert`: 125.40 ms (п.1) -> 50.69 ms (write-only п.3)

Вывод:
- На write-only профиле деградации записи не обнаружено.
- По EXPLAIN у `oltp_insert_order` абсолютное время выше, чем в пункте 1 (рост объёма данных), но end-to-end p95 записи в write-only тесте остаётся лучше baseline.

## Результат оптимизаций (2 -> 3)
- `oltp_read`: 169.99 -> 31.18 ms (-81.66%)
- `oltp_insert`: 504.62 -> 545.40 ms (+8.08%)
- `oltp_update`: 377.08 -> 163.19 ms (-56.72%)
- `olap_revenue`: 30810.02 -> 79.17 ms (-89.95%)
- `olap_turnover`: 98293.63 -> 17618.86 ms (-82.08%)
- `log_insert`: 223.78 -> 74.53 ms (-66.69%)

Дополнительно по EXPLAIN:
- `olap_revenue_by_day_mv`: `Execution Time` ~0.123 ms.
- `olap_warehouse_turnover` после rewrite+индекса: `Execution Time` ~61.953 ms (ранее ~25565 ms в п.2).

## Итоговая сводная таблица
| Запрос / Эндпоинт | p95 (пункт 1), ms | p95 (пункт 2), ms | p95 (пункт 3), ms | Δ (1→2) | Δ (2→3) | Применённое решение |
|---|---:|---:|---:|---:|---:|---|
| `GET /api/oltp/orders/{id}` | 87.42 | 169.99 | 31.18 | +94.45% | -81.66% | Индексы `011/012`  |
| `POST /api/oltp/orders` | 264.01 | 504.62 | 545.40 | +91.14% | +8.08% | Побочный рост из-за доп. индексов/нагрузки на запись |
| `POST /api/oltp/orders/{id}/status` | 147.47 | 377.08 | 163.19 | +155.71% | -56.72% | Индексы по аудиту + стабилизация OLAP части |
| `GET /api/olap/revenue-by-day` | 1913.68 | 30810.02 | 79.17 | +1509.99% | -89.95% | MV `013` + `API_USE_REVENUE_MV=true` |
| `GET /api/olap/warehouse-turnover` | 2478.94 | 98293.63 | 17618.86 | +3865.14% | -82.08% | SQL rewrite (top warehouses) + индекс `014` |
| `POST /api/log/order-status-events` | 125.40 | 223.78 | 74.53 | +78.46% | -66.69% | Снижение конкуренции после OLAP-оптимизаций |

